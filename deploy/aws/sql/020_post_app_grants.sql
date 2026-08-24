-- =================================================================
-- 020_post_app_grants.sql
--
-- Run AFTER every file in supabase/migrations/ has been applied.
--
-- The default privileges set in 000 cover tables created from that
-- point on, but only for the role that created them and only for
-- objects created after the ALTER DEFAULT PRIVILEGES ran. This file
-- is the belt to that braces: it grants explicitly on everything that
-- now exists, so a table added by a migration that ran under any
-- other path is still reachable.
--
-- Without these grants, PostgREST returns
--   "permission denied for table contacts"
-- on every request, regardless of how correct the RLS policies are.
-- RLS filters rows; GRANT decides whether the table can be addressed
-- at all. They are separate gates and both have to be open.
--
-- Functions are deliberately left alone — see the note in 000.
--
-- Idempotent.
-- =================================================================

\set ON_ERROR_STOP on

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

GRANT ALL ON ALL TABLES    IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;

-- Realtime builds change payloads by reading the replicated rows as
-- supabase_admin. pg_read_all_data (granted in 000) normally covers
-- this; the explicit grant makes it work even where that role-grant
-- was refused.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO supabase_admin;

-- -----------------------------------------------------------------
-- Sanity checks on the things that are easy to get wrong and hard to
-- notice: they fail as empty result sets at runtime, not as errors.
-- -----------------------------------------------------------------
DO $$
DECLARE
  missing_buckets text[];
  missing_realtime text[];
BEGIN
  SELECT array_agg(b)
    INTO missing_buckets
    FROM unnest(ARRAY['avatars', 'flow-media', 'chat-media']) AS b
   WHERE NOT EXISTS (SELECT FROM storage.buckets WHERE id = b);

  IF missing_buckets IS NOT NULL THEN
    RAISE EXCEPTION
      'Storage buckets not created: %. Migrations 008 / 016 / 023 '
      'INSERT these into storage.buckets; if they are absent, those '
      'migrations were skipped or ran before storage-api migrated.',
      array_to_string(missing_buckets, ', ');
  END IF;

  SELECT array_agg(t)
    INTO missing_realtime
    FROM unnest(ARRAY['messages', 'conversations', 'notifications', 'member_presence']) AS t
   WHERE NOT EXISTS (
     SELECT FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND tablename = t
   );

  IF missing_realtime IS NOT NULL THEN
    RAISE WARNING
      'Tables missing from the supabase_realtime publication: %. '
      'The inbox, notification bell and presence dots will not update '
      'live for these.',
      array_to_string(missing_realtime, ', ');
  END IF;

  RAISE NOTICE 'post-migration grants OK';
END
$$;

-- Tell PostgREST to re-read the schema cache. Without this it keeps
-- serving 404s for tables and RPCs added by the migrations until the
-- container is restarted.
NOTIFY pgrst, 'reload schema';
