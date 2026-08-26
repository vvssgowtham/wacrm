#!/usr/bin/env bash
# =================================================================
# doctor.sh — check the things that fail silently.
#
#   sudo /opt/wacrm/src/deploy/selfhost/doctor.sh
#
# Self-hosted Supabase has a small set of misconfigurations that do
# not produce errors, only empty results: a missing BYPASSRLS, a
# table absent from the realtime publication, a bucket that never got
# inserted. Those are what this checks.
#
# Adapted from deploy/aws/scripts/doctor.sh. Differences: secrets come
# from a local file rather than Secrets Manager, psql connects over
# loopback rather than to RDS, and the two public-URL probes are
# advisory (see the note next to them).
# =================================================================
set -uo pipefail

SRC_DIR=/opt/wacrm/src
STACK_DIR="$SRC_DIR/deploy/selfhost"

# shellcheck disable=SC1091
source /etc/wacrm/deploy.env

DB_ADMIN_HOST="${DB_ADMIN_HOST:-127.0.0.1}"
DB_ADMIN_PORT="${DB_ADMIN_PORT:-5432}"

PGPASSWORD="$(jq -r '.POSTGRES_PASSWORD' /etc/wacrm/secrets.json)"
export PGPASSWORD

PSQL=(psql --host "$DB_ADMIN_HOST" --port "$DB_ADMIN_PORT" --username postgres --dbname "$DB_NAME" --no-password --tuples-only --no-align --quiet)

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

# 39 migrations at the time of writing; the check is "did the ledger
# get populated at all", not an exact count, so it survives new ones.
migrations="$("${PSQL[@]}" -c "SELECT count(*) FROM public._wacrm_migrations" 2>/dev/null)"
on_disk="$(find "$SRC_DIR/supabase/migrations" -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${migrations:-0}" -ge "${on_disk:-1}" ]; then
  ok "$migrations of $on_disk app migrations recorded"
else
  bad "only ${migrations:-0} of $on_disk app migrations recorded — re-run deploy.sh"
fi

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
for table in messages conversations notifications member_presence flows; do
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

# An instance generally cannot reach its own Elastic IP from inside
# the VPC — traffic to it leaves for the internet gateway and is not
# hairpinned back. A failure here therefore means nothing on its own,
# which is why it is advisory. The security group is what actually
# decides whether the outside world can get in, so test these two
# from your laptop's browser.
echo
echo "Public URLs (advisory — test these from your laptop instead)"
echo "-----------------------------------------------------------"
soft_probe() { # soft_probe <description> <url> <expected status>
  local desc="$1" url="$2" want="$3" got
  got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)"
  if [ "$got" = "$want" ]; then
    ok "$desc ($got)"
  else
    warn "$desc — got $got  [$url]"
    warn "  expected on EC2: an instance cannot reach its own public IP."
  fi
}
soft_probe "app URL end to end" "$APP_URL/login" 200
soft_probe "supabase URL end to end" "$SUPABASE_PUBLIC_URL/auth/v1/health" 200

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n\n'
  echo "  From your laptop, confirm both of these load:"
  echo "    $APP_URL/login"
  echo "    $SUPABASE_PUBLIC_URL/auth/v1/health"
  echo
  echo "  If the first works and the second does not, port 8000 is"
  echo "  closed in the security group. The browser calls Kong"
  echo "  directly, so the app will not function without it."
  echo
else
  printf '\033[31m%d check(s) failed.\033[0m See deploy/selfhost/README.md.\n\n' "$FAILURES"
  exit 1
fi
