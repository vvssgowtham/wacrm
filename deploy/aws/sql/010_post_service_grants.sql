-- =================================================================
-- 010_post_service_grants.sql
--
-- Run AFTER GoTrue, storage-api and Realtime have started and applied
-- their own migrations, and BEFORE the app's supabase/migrations/*.
--
-- Ordering matters and is not negotiable:
--
--   * `auth.users` does not exist until GoTrue migrates. The app's
--     migration 001 declares a foreign key to it and hangs a trigger
--     on it, so it must exist first.
--   * `storage.buckets` does not exist until storage-api migrates.
--     Migrations 008 / 016 / 023 INSERT bucket rows into it.
--
-- Grants cannot be written ahead of time either — GRANT ON ALL
-- TABLES IN SCHEMA only affects tables that exist when it runs, which
-- is exactly why this is a separate file rather than part of 000.
--
-- Idempotent.
-- =================================================================

\set ON_ERROR_STOP on

-- -----------------------------------------------------------------
-- auth schema
--
-- `postgres` needs full rights on auth.users to create the
-- on_auth_user_created trigger (migrations 001 and 017) and to
-- declare the FKs from profiles / accounts / invitations.
--
-- anon and authenticated get USAGE on the schema only — enough to
-- call auth.uid(), nothing more. auth.users is never exposed through
-- PostgREST because PGRST_DB_SCHEMAS lists only `public`.
-- -----------------------------------------------------------------
GRANT USAGE ON SCHEMA auth TO postgres, anon, authenticated, service_role;

GRANT ALL ON ALL TABLES    IN SCHEMA auth TO postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO postgres;

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth
  GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth
  GRANT ALL ON SEQUENCES TO postgres;

-- -----------------------------------------------------------------
-- storage schema
--
-- storage-api authenticates the caller's JWT and then acts as the
-- matching role so the RLS policies on storage.objects apply. Those
-- roles therefore need table-level access, not just schema usage.
--
-- `postgres` needs owner-level rights so migrations 008 / 016 / 020 /
-- 023 can CREATE POLICY on storage.objects. Membership in
-- supabase_storage_admin (granted in 000) covers the ownership check;
-- these grants cover the rest.
-- -----------------------------------------------------------------
GRANT USAGE ON SCHEMA storage TO postgres, anon, authenticated, service_role;

GRANT ALL ON ALL TABLES    IN SCHEMA storage TO postgres, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO postgres, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA storage
  TO anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage
  GRANT ALL ON TABLES TO postgres, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;

-- -----------------------------------------------------------------
-- Verify the two tables the app's migrations depend on actually
-- exist. Failing here with a clear message beats failing 400 lines
-- into migration 001 with "relation auth.users does not exist".
-- -----------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE EXCEPTION
      'auth.users does not exist — GoTrue has not finished migrating. '
      'Check `docker compose logs auth` before re-running.';
  END IF;

  IF to_regclass('storage.buckets') IS NULL THEN
    RAISE EXCEPTION
      'storage.buckets does not exist — storage-api has not finished '
      'migrating. Check `docker compose logs storage` before re-running.';
  END IF;

  RAISE NOTICE 'post-service grants OK';
END
$$;
