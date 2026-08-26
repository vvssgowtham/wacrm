-- =================================================================
-- 000_bootstrap.sql — make a stock Postgres look like a Supabase one
--
-- WHY THIS FILE EXISTS
--
-- The upstream Supabase self-host stack runs `supabase/postgres`,
-- which is Postgres plus an init bundle nobody ever reads. Point the
-- same stack at RDS and none of that init has happened, so:
--
--   * PostgREST cannot log in            — `authenticator` missing
--   * every RLS policy errors            — `auth.uid()` missing
--   * GoTrue cannot migrate              — `auth` schema missing
--   * migration 001 aborts               — `supabase_realtime`
--                                          publication missing
--   * migrations 001/017 abort           — no role named `postgres`
--                                          (RDS master is named
--                                          `postgres` for this reason)
--   * migrations 008/016/023 abort       — `postgres` is not the
--                                          owner of storage.objects
--
-- This file fixes all of it. Run it ONCE, as the RDS master user,
-- BEFORE starting any container.
--
-- Invocation (deploy.sh does this for you):
--   psql "$ADMIN_URL" -v ON_ERROR_STOP=1 \
--     -v authenticator_password="..." \
--     -v auth_admin_password="..." \
--     -v storage_admin_password="..." \
--     -v supabase_admin_password="..." \
--     -f 000_bootstrap.sql
--
-- Idempotent — safe to re-run.
-- =================================================================

\set ON_ERROR_STOP on

-- -----------------------------------------------------------------
-- Extensions
--
-- Created in `public`, not `extensions`. The app's own migrations run
-- `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"` and
-- `CREATE EXTENSION IF NOT EXISTS vector` with no schema qualifier,
-- so they resolve against the default search_path. Putting them
-- anywhere else would make those statements create a SECOND copy or
-- fail outright.
-- -----------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- pgvector backs the optional semantic search in the AI knowledge
-- base (migration 030). RDS ships it for Postgres 15.5+ / 16.1+ / 17.
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS vector;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING
    'Could not create the `vector` extension: %. The AI knowledge base '
    'will fall back to Postgres full-text search, which needs no '
    'extension. Check that your RDS engine version supports pgvector.',
    SQLERRM;
END
$$;

-- -----------------------------------------------------------------
-- Roles
--
-- `\gexec` rather than a DO block: psql does not interpolate :'vars'
-- inside dollar-quoted strings, and the passwords have to come in as
-- psql variables so they never touch the filesystem.
--
-- NOINHERIT on `authenticator` is load-bearing. PostgREST logs in as
-- authenticator and then SET ROLEs to anon / authenticated /
-- service_role per request. If authenticator inherited those roles it
-- would carry service_role's privileges on every anonymous request.
-- -----------------------------------------------------------------

SELECT 'CREATE ROLE anon NOLOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') \gexec

SELECT 'CREATE ROLE authenticated NOLOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') \gexec

SELECT 'CREATE ROLE service_role NOLOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') \gexec

SELECT 'CREATE ROLE authenticator LOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') \gexec

SELECT 'CREATE ROLE supabase_auth_admin LOGIN NOINHERIT CREATEROLE'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') \gexec

SELECT 'CREATE ROLE supabase_storage_admin LOGIN NOINHERIT CREATEROLE'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') \gexec

SELECT 'CREATE ROLE supabase_admin LOGIN CREATEROLE CREATEDB'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') \gexec

ALTER ROLE authenticator          WITH PASSWORD :'authenticator_password';
ALTER ROLE supabase_auth_admin    WITH PASSWORD :'auth_admin_password';
ALTER ROLE supabase_storage_admin WITH PASSWORD :'storage_admin_password';
ALTER ROLE supabase_admin         WITH PASSWORD :'supabase_admin_password';

-- Pin each service role's search_path to the schema it owns.
--
-- This is NOT cosmetic, and leaving it out breaks GoTrue in a way
-- that takes a long time to diagnose. Its migrations are inconsistent
-- about qualifying names. 20220615000000_add_mfa_schema creates the
-- enum UNQUALIFIED:
--
--   create type factor_type as enum('totp', 'webauthn');
--
-- while 20240729123726_add_mfa_phone_config, added two years later,
-- refers to it QUALIFIED:
--
--   alter type auth.factor_type add value 'phone';
--
-- With the default search_path ("$user", public) the first statement
-- puts the type in `public`, so the second fails with
--
--   ERROR: type "auth.factor_type" does not exist (SQLSTATE 42704)
--
-- and GoTrue crash-loops forever on a database that otherwise looks
-- perfectly healthy. The same mechanism sends its `schema_migrations`
-- bookkeeping table to `public` instead of `auth`.
--
-- The supabase/postgres image sets this; a plain Postgres does not.
-- storage-api has the same pattern against its own schema.
ALTER ROLE supabase_auth_admin    SET search_path = auth;
ALTER ROLE supabase_storage_admin SET search_path = storage;

-- BYPASSRLS on service_role.
--
-- This is the single most important line in the file and the one most
-- likely to fail. Postgres normally reserves the BYPASSRLS attribute
-- for superusers, and the RDS master user is not one. AWS grants
-- rds_superuser the ability to set it, but that behaviour has varied
-- across engine versions.
--
-- If it fails, every server-side path that uses the service-role key
-- (the WhatsApp webhook, the automation and flow engines, the AI
-- auto-reply bot, the public API's key-auth lookup) starts silently
-- returning zero rows instead of erroring, because RLS filters them
-- out rather than rejecting them. Verify explicitly — see the check
-- at the bottom of this file and README step 6.
DO $$
BEGIN
  IF NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'ALTER ROLE service_role WITH BYPASSRLS';
    RAISE NOTICE 'service_role: BYPASSRLS set';
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Fallback: ownership satisfies the RLS bypass check too. Postgres
  -- skips row security when the current user has the privileges of
  -- the table's owner, and every table in `public` is owned by
  -- `postgres`. Making service_role an inheriting member of postgres
  -- therefore achieves the same effect using only privileges the RDS
  -- master user definitely has.
  --
  -- It is a blunter instrument than BYPASSRLS — service_role gains
  -- full owner rights, not just row-security exemption — which is why
  -- it is the fallback and not the default.
  RAISE WARNING 'ALTER ROLE service_role BYPASSRLS failed (%); falling back to postgres membership.', SQLERRM;
  EXECUTE 'ALTER ROLE service_role WITH INHERIT';
  EXECUTE 'GRANT postgres TO service_role';
END
$$;

-- PostgREST's login role can assume the three request roles.
GRANT anon, authenticated, service_role TO authenticator;

-- Make the migration runner a MEMBER of the service-owner roles.
--
-- Postgres ownership checks are satisfied by role membership, not
-- just by being the literal owner. Without this, migrations 008 /
-- 016 / 023 fail with "must be owner of table objects" when they
-- CREATE POLICY on storage.objects, and migration 001 fails when it
-- puts a trigger on auth.users — both tables are created and owned by
-- their service, not by the migration runner.
--
-- It also means `postgres` passes the owner check on auth.users and
-- therefore bypasses any RLS a future GoTrue release enables there.
GRANT supabase_auth_admin, supabase_storage_admin, supabase_admin TO postgres;

-- Realtime connects as supabase_admin, reads the WAL through a
-- logical replication slot, and reads the replicated tables to build
-- change payloads.
DO $$
BEGIN
  -- RDS-only role. Absent on a plain Postgres, where the REPLICATION
  -- attribute is set directly instead.
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rds_replication') THEN
    EXECUTE 'GRANT rds_replication TO supabase_admin';
  ELSE
    EXECUTE 'ALTER ROLE supabase_admin WITH REPLICATION';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not grant replication to supabase_admin: %. '
                'Realtime postgres_changes subscriptions will not fire.', SQLERRM;
END
$$;

DO $$
BEGIN
  EXECUTE 'GRANT pg_read_all_data TO supabase_admin';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not grant pg_read_all_data to supabase_admin: %', SQLERRM;
END
$$;

-- -----------------------------------------------------------------
-- Schemas
--
-- Each service owns its own schema and runs its own migrations into
-- it. Pre-creating them with the right owner is what lets those
-- migrations succeed without a superuser.
--
-- `_realtime` in particular must exist before the Realtime container
-- starts: its connection runs `SET search_path TO _realtime` on
-- connect, which errors on a missing schema and crash-loops the
-- container with no useful message.
-- -----------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth       AUTHORIZATION supabase_auth_admin;
CREATE SCHEMA IF NOT EXISTS storage    AUTHORIZATION supabase_storage_admin;
CREATE SCHEMA IF NOT EXISTS realtime   AUTHORIZATION supabase_admin;
CREATE SCHEMA IF NOT EXISTS _realtime  AUTHORIZATION supabase_admin;
CREATE SCHEMA IF NOT EXISTS extensions AUTHORIZATION postgres;

GRANT USAGE ON SCHEMA auth    TO postgres, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA storage TO postgres, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public  TO postgres, anon, authenticated, service_role;

-- GoTrue and storage-api need CREATE on `public`, not just USAGE.
--
-- Both keep their real tables in their own schema (DB_NAMESPACE=auth,
-- and storage-api's equivalent), but their migrators create a
-- bookkeeping table — `schema_migrations` — with an UNQUALIFIED name.
-- That resolves through search_path to `public`.
--
-- Since PostgreSQL 15 the `public` schema is owned by
-- `pg_database_owner` and no longer grants CREATE to PUBLIC, so the
-- service roles are refused:
--
--   running db migrations: ... could not execute
--   CREATE TABLE "schema_migrations" ...
--   ERROR: permission denied for schema public (SQLSTATE 42501)
--
-- GoTrue then crash-loops, auth.users is never created, and deploy.sh
-- fails at step [2/5] waiting for a table that cannot appear.
GRANT USAGE, CREATE ON SCHEMA public TO supabase_auth_admin, supabase_storage_admin;

-- -----------------------------------------------------------------
-- auth.uid() and friends
--
-- GoTrue does NOT create these — on hosted Supabase they come from the
-- platform image. Every single RLS policy in supabase/migrations/
-- calls auth.uid(), so without them the app's migrations fail and,
-- worse, a policy that did somehow get created would error at query
-- time rather than at deploy time.
--
-- PostgREST publishes the verified JWT payload as the
-- `request.jwt.claims` GUC. The older `request.jwt.claim.<name>`
-- form is checked first for compatibility with anything that still
-- sets it.
-- -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

CREATE OR REPLACE FUNCTION auth.email()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;

ALTER FUNCTION auth.jwt()   OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.uid()   OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.role()  OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.email() OWNER TO supabase_auth_admin;

GRANT EXECUTE ON FUNCTION auth.jwt(), auth.uid(), auth.role(), auth.email()
  TO postgres, anon, authenticated, service_role;

-- -----------------------------------------------------------------
-- storage helper functions
--
-- Migrations 008 / 016 / 020 / 023 all write RLS policies of the form
--   (storage.foldername(name))[1] = auth.uid()::text
-- Recent storage-api releases create these themselves, but the app's
-- migrations may run first. CREATE OR REPLACE means storage-api can
-- still install its own version over the top without conflict.
-- -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  parts text[];
BEGIN
  parts := string_to_array(name, '/');
  RETURN parts[1 : array_length(parts, 1) - 1];
END
$$;

CREATE OR REPLACE FUNCTION storage.filename(name text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  parts text[];
BEGIN
  parts := string_to_array(name, '/');
  RETURN parts[array_length(parts, 1)];
END
$$;

CREATE OR REPLACE FUNCTION storage.extension(name text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  parts text[];
BEGIN
  parts := string_to_array(name, '.');
  RETURN parts[array_length(parts, 1)];
END
$$;

ALTER FUNCTION storage.foldername(text) OWNER TO supabase_storage_admin;
ALTER FUNCTION storage.filename(text)   OWNER TO supabase_storage_admin;
ALTER FUNCTION storage.extension(text)  OWNER TO supabase_storage_admin;

GRANT EXECUTE ON FUNCTION storage.foldername(text), storage.filename(text), storage.extension(text)
  TO postgres, anon, authenticated, service_role;

-- -----------------------------------------------------------------
-- Realtime publication
--
-- supabase/migrations/001, 009, 010, 024 and 027 all run
-- `ALTER PUBLICATION supabase_realtime ADD TABLE ...`. On hosted
-- Supabase the publication is created by the platform. Here it is
-- created empty and owned by the migration runner, which is what
-- makes those ALTERs legal.
-- -----------------------------------------------------------------
SELECT 'CREATE PUBLICATION supabase_realtime'
WHERE NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'supabase_realtime') \gexec

-- -----------------------------------------------------------------
-- Default privileges on public
--
-- PostgREST reaches tables as anon / authenticated / service_role.
-- RLS decides which ROWS they see; these grants decide whether they
-- can address the TABLE at all. Miss them and every query comes back
-- "permission denied for table X" no matter how correct the policies
-- are.
--
-- Functions are deliberately excluded. Postgres already grants
-- EXECUTE to PUBLIC on every new function, and several migrations
-- (018, 019, 030) intentionally REVOKE that and re-grant to a single
-- role. A blanket default grant here would hand those admin RPCs back
-- to anon.
-- -----------------------------------------------------------------
-- No FOR ROLE clause: these apply to objects created by the current
-- role, which is `postgres`, which is also the role deploy.sh uses to
-- run every migration.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- -----------------------------------------------------------------
-- Self-check. Anything printed as NOTICE below is a real problem.
-- -----------------------------------------------------------------
DO $$
DECLARE
  problems text[] := '{}';
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres') THEN
    problems := problems || 'role "postgres" is missing (migrations 001/017 will abort)';
  END IF;

  -- Either mechanism is acceptable: the BYPASSRLS attribute, or
  -- inheriting the privileges of the role that owns the tables.
  IF NOT (
    (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role')
    OR pg_has_role('service_role', 'postgres', 'USAGE')
  ) THEN
    problems := problems || 'service_role can neither bypass nor inherit past RLS (server-side writes will silently no-op)';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    problems := problems || 'publication supabase_realtime is missing';
  END IF;

  IF NOT EXISTS (
    SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'auth' AND p.proname = 'uid'
  ) THEN
    problems := problems || 'auth.uid() is missing';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_extension WHERE extname = 'uuid-ossp') THEN
    problems := problems || 'uuid-ossp extension is missing';
  END IF;

  IF array_length(problems, 1) IS NULL THEN
    RAISE NOTICE 'bootstrap OK';
  ELSE
    RAISE EXCEPTION 'bootstrap incomplete: %', array_to_string(problems, '; ');
  END IF;
END
$$;
