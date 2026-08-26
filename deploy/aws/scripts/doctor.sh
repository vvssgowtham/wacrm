#!/usr/bin/env bash
# =================================================================
# doctor.sh — check the things that fail silently.
#
#   sudo /opt/wacrm/src/deploy/aws/scripts/doctor.sh
#
# Self-hosted Supabase has a small set of misconfigurations that do
# not produce errors, only empty results: a missing BYPASSRLS, a
# table absent from the realtime publication, a bucket that never got
# inserted. Those are what this checks.
# =================================================================
set -uo pipefail

SRC_DIR=/opt/wacrm/src
STACK_DIR="$SRC_DIR/deploy/aws/stack"

# shellcheck disable=SC1091
source /etc/wacrm/deploy.env

SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" --region "$AWS_REGION" \
    --query SecretString --output text
)"
export PGPASSWORD="$(printf '%s' "$SECRET_JSON" | jq -r '.POSTGRES_PASSWORD')"

PSQL=(psql --host "$DB_HOST" --port "$DB_PORT" --username postgres --dbname "$DB_NAME" --no-password --tuples-only --no-align --quiet)

FAILURES=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }

check() { # check <description> <sql returning t/f>
  local desc="$1" sql="$2" result
  result="$("${PSQL[@]}" -c "$sql" 2>/dev/null)"
  if [ "$result" = "t" ]; then ok "$desc"; else bad "$desc"; fi
}

echo
echo "Database"
echo "--------"
check "reachable" "SELECT true"
check "role postgres exists (migrations 001/017 need it by name)" \
  "SELECT EXISTS (SELECT FROM pg_roles WHERE rolname='postgres')"
check "authenticator is NOINHERIT (else anon requests carry service_role)" \
  "SELECT NOT rolinherit FROM pg_roles WHERE rolname='authenticator'"
check "service_role can bypass RLS (else server-side writes no-op)" \
  "SELECT (SELECT rolbypassrls FROM pg_roles WHERE rolname='service_role')
          OR pg_has_role('service_role','postgres','USAGE')"
check "auth.uid() exists (every RLS policy calls it)" \
  "SELECT EXISTS (SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                  WHERE n.nspname='auth' AND p.proname='uid')"
check "storage.foldername() exists (storage RLS policies call it)" \
  "SELECT EXISTS (SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                  WHERE n.nspname='storage' AND p.proname='foldername')"
check "uuid-ossp installed" \
  "SELECT EXISTS (SELECT FROM pg_extension WHERE extname='uuid-ossp')"
check "auth.users exists" "SELECT to_regclass('auth.users') IS NOT NULL"
check "storage.buckets exists" "SELECT to_regclass('storage.buckets') IS NOT NULL"
check "anon can address public tables" \
  "SELECT has_table_privilege('anon','public.contacts','SELECT')"
check "authenticated can address public tables" \
  "SELECT has_table_privilege('authenticated','public.contacts','SELECT')"

if [ "$("${PSQL[@]}" -c "SELECT EXISTS (SELECT FROM pg_extension WHERE extname='vector')")" = "t" ]; then
  ok "pgvector installed (semantic AI knowledge search available)"
else
  warn "pgvector not installed — the AI knowledge base falls back to Postgres full-text search, which needs no extension"
fi

echo
echo "Storage buckets"
echo "---------------"
for bucket in avatars flow-media chat-media; do
  check "$bucket" "SELECT EXISTS (SELECT FROM storage.buckets WHERE id='$bucket')"
done

echo
echo "Realtime publication"
echo "--------------------"
check "logical replication enabled on the instance" \
  "SELECT current_setting('wal_level') = 'logical'"
# flow_runs, not flows. `flows` is the flow definition — configuration
# that never streams. 010_flows.sql:278 publishes flow_runs.
for table in messages conversations notifications member_presence flow_runs; do
  check "$table in supabase_realtime" \
    "SELECT EXISTS (SELECT FROM pg_publication_tables
                    WHERE pubname='supabase_realtime' AND tablename='$table')"
done
slots="$("${PSQL[@]}" -c "SELECT count(*) FROM pg_replication_slots WHERE active")"
if [ "${slots:-0}" -ge 1 ]; then
  ok "$slots active replication slot(s) — Realtime is consuming the WAL"
else
  bad "no active replication slot — Realtime is not consuming the WAL; check 'docker compose logs realtime'"
fi

unset PGPASSWORD

echo
echo "Containers"
echo "----------"
docker compose --project-directory "$STACK_DIR" ps --format '  {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null

echo
echo "Endpoints (from inside the instance)"
echo "------------------------------------"
probe() { # probe <description> <url> <expected status>
  local desc="$1" url="$2" want="$3" got
  got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)"
  if [ "$got" = "$want" ]; then ok "$desc ($got)"; else bad "$desc — expected $want, got $got  [$url]"; fi
}

probe "kong -> gotrue health" "http://localhost:8000/auth/v1/health" 200
# 401 is the CORRECT answer here: it proves key-auth is switched on.
probe "kong -> postgrest rejects an unkeyed request" "http://localhost:8000/rest/v1/" 401
probe "app /login" "http://localhost:3000/login" 200
probe "public app URL end to end" "$APP_URL/login" 200
probe "public supabase URL end to end" "$SUPABASE_PUBLIC_URL/auth/v1/health" 200

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n\n'
else
  printf '\033[31m%d check(s) failed.\033[0m See deploy/aws/README.md, "Troubleshooting".\n\n' "$FAILURES"
  exit 1
fi
