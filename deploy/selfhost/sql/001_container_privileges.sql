-- =================================================================
-- Privileges that a Postgres container can grant and RDS cannot.
--
-- Runs immediately after deploy/aws/sql/000_bootstrap.sql, which is
-- shared with the AWS deployment. That file is deliberately
-- conservative: on RDS the master user is NOT a superuser, so it
-- creates the Supabase service roles with the narrowest privileges
-- that still work there, and falls back to weaker mechanisms when a
-- grant is refused.
--
-- Here Postgres runs in a container and `postgres` IS a superuser, so
-- none of those constraints apply. This file closes the gap by
-- granting what the official `supabase/postgres` image grants.
--
-- Without it, three containers crash-loop with errors that name a
-- privilege rather than the missing grant:
--
--   storage-api:  Migration failed. Reason:
--                 permission denied for database postgres
--   gotrue:       permission denied for schema public (SQLSTATE 42501)
--   realtime:     fails to create its replication slot
--
-- Idempotent. Safe to re-run.
-- =================================================================

-- -----------------------------------------------------------------
-- supabase_admin
--
-- A SUPERUSER in the supabase/postgres image. Realtime connects as
-- this role: it owns and migrates the `_realtime` schema, creates the
-- logical replication slot, and reads every table in the
-- supabase_realtime publication to build change payloads.
--
-- 000_bootstrap.sql can only give it LOGIN CREATEROLE CREATEDB plus
-- the REPLICATION attribute, because that is RDS's ceiling.
-- -----------------------------------------------------------------
ALTER ROLE supabase_admin WITH SUPERUSER;

-- -----------------------------------------------------------------
-- GoTrue and storage-api need CREATE at the DATABASE level.
--
-- Both migrators do more than create tables in their own schema —
-- they issue statements checked against the database itself, which
-- fails as "permission denied for database <name>" no matter how
-- much access the role has on `auth` or `storage`.
--
-- The database name comes from current_database() rather than being
-- hard-coded, so this holds whatever DB_NAME is set to.
-- -----------------------------------------------------------------
DO $$
BEGIN
  EXECUTE format(
    'GRANT CREATE, CONNECT, TEMPORARY ON DATABASE %I TO '
    'supabase_auth_admin, supabase_storage_admin, supabase_admin',
    current_database()
  );
END
$$;

-- -----------------------------------------------------------------
-- service_role BYPASSRLS.
--
-- 000_bootstrap.sql tries this, and on failure falls back to granting
-- `postgres` membership — a blunter instrument it documents as a
-- compromise. In a container the attribute itself is always
-- grantable, so set it directly and get the precise behaviour.
--
-- This is the line that matters most in the whole deployment: without
-- it, every server-side path using the service-role key (the WhatsApp
-- webhook, the automation and flow engines, the AI auto-reply, the
-- public API's key lookup) silently returns zero rows instead of
-- erroring, because RLS filters them out rather than rejecting them.
-- -----------------------------------------------------------------
ALTER ROLE service_role WITH BYPASSRLS;

-- -----------------------------------------------------------------
-- Report, so the deploy log shows what actually landed.
-- -----------------------------------------------------------------
DO $$
DECLARE
  problems text[] := '{}';
BEGIN
  IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    problems := problems || 'supabase_admin is not a superuser';
  END IF;

  IF NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role') THEN
    problems := problems || 'service_role lacks BYPASSRLS';
  END IF;

  IF NOT has_database_privilege('supabase_storage_admin', current_database(), 'CREATE') THEN
    problems := problems || 'supabase_storage_admin lacks CREATE on the database';
  END IF;

  IF NOT has_database_privilege('supabase_auth_admin', current_database(), 'CREATE') THEN
    problems := problems || 'supabase_auth_admin lacks CREATE on the database';
  END IF;

  IF array_length(problems, 1) IS NULL THEN
    RAISE NOTICE 'container privileges OK';
  ELSE
    RAISE EXCEPTION 'container privileges incomplete: %',
      array_to_string(problems, '; ');
  END IF;
END
$$;
