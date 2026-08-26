#!/usr/bin/env bash
# =================================================================
# deploy.sh — bring up (or update) the whole stack on this instance.
#
# Adapted from deploy/aws/scripts/deploy.sh. The ordering below is
# the important part and is unchanged from that file; what differs is
# only where secrets come from (a local file, not Secrets Manager)
# and that Postgres is a container we start rather than an RDS
# instance that already exists.
#
# Safe to run as many times as you like:
#
#   sudo /opt/wacrm/src/deploy/selfhost/deploy.sh
#
# Flags:
#   --rebuild            force a rebuild of the app image (needed
#                        after changing any NEXT_PUBLIC_* value, since
#                        those are inlined into the client bundle at
#                        build time)
#   --pull               pull newer Supabase service images first
#   --skip-migrations    bring containers up without touching SQL
#   --force-migrations   replay every migration, ignoring the ledger
#   --update             git pull the configured branch first
#
# ORDER OF OPERATIONS — this is the part that matters.
#
#   0. start Postgres          (the AWS stack gets this from RDS)
#   1. bootstrap SQL           roles, schemas, extensions, auth.uid(),
#                              the supabase_realtime publication
#   2. start auth/rest/storage/realtime   each runs its OWN migrations
#   3. post-service grants     needs auth.users + storage.buckets to
#                              exist, so it cannot run before step 2
#   4. app migrations          FK to auth.users (001), INSERT into
#                              storage.buckets (008/016/023)
#   5. post-app grants         GRANT ON ALL TABLES only covers tables
#                              that exist when it runs
#   6. start kong + app
#
# Getting 2 and 4 the wrong way round is the single most common way
# to break a self-hosted Supabase install: migration 001 aborts with
# "relation auth.users does not exist".
# =================================================================
set -euo pipefail

exec > >(tee -a /var/log/wacrm-deploy.log) 2>&1
echo "=== deploy.sh starting at $(date -u +%FT%TZ) ==="

REBUILD=0
PULL=0
SKIP_MIGRATIONS=0
FORCE_MIGRATIONS=0
UPDATE=0
# Every flag except --update, so the post-pull re-exec below does not
# loop forever.
PASSTHROUGH=()

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --pull) PULL=1 ;;
    --skip-migrations) SKIP_MIGRATIONS=1 ;;
    --force-migrations) FORCE_MIGRATIONS=1 ;;
    --update)
      UPDATE=1
      continue
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
  PASSTHROUGH+=("$arg")
done

SRC_DIR=/opt/wacrm/src
STACK_DIR="$SRC_DIR/deploy/selfhost"
# The bootstrap and grant SQL is shared with the AWS deployment and
# needs no changes — it was written against a vanilla Postgres.
SQL_DIR="$SRC_DIR/deploy/aws/sql"
SCRIPTS_DIR="$SRC_DIR/deploy/selfhost"
# gen-jwt.sh is likewise unchanged.
AWS_SCRIPTS_DIR="$SRC_DIR/deploy/aws/scripts"

# -----------------------------------------------------------------
# Infrastructure values, written once by setup.sh.
# -----------------------------------------------------------------
# shellcheck disable=SC1091
source /etc/wacrm/deploy.env

# DB_HOST is the compose service name, which only resolves INSIDE the
# docker network. psql runs on the host, so it needs the loopback
# address the db service publishes on instead.
DB_ADMIN_HOST="${DB_ADMIN_HOST:-127.0.0.1}"
DB_ADMIN_PORT="${DB_ADMIN_PORT:-5432}"

if [ "$UPDATE" -eq 1 ]; then
  echo "--- pulling $REPO_BRANCH"
  git -C "$SRC_DIR" fetch --prune origin
  git -C "$SRC_DIR" checkout "$REPO_BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/$REPO_BRANCH"
  # A pull can change this script mid-execution — bash reads the file
  # lazily, so editing it under a running shell produces syntax errors
  # at the seam. Re-exec the new copy, minus --update.
  echo "--- re-running the updated deploy.sh"
  exec "$SCRIPTS_DIR/deploy.sh" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
fi

# -----------------------------------------------------------------
# Secrets.
#
# Generated once by setup.sh into a chmod 600 file. Read straight
# into shell variables via jq; never written anywhere except the
# compose .env file, which is also chmod 600.
# -----------------------------------------------------------------
SECRETS_FILE=/etc/wacrm/secrets.json

if [ ! -f "$SECRETS_FILE" ]; then
  echo "FATAL: $SECRETS_FILE does not exist. Run setup.sh first." >&2
  exit 1
fi

echo "--- reading $SECRETS_FILE"
SECRET_JSON="$(cat "$SECRETS_FILE")"

jqs() { printf '%s' "$SECRET_JSON" | jq -r --arg k "$1" '.[$k] // ""'; }

POSTGRES_PASSWORD="$(jqs POSTGRES_PASSWORD)"
AUTHENTICATOR_PASSWORD="$(jqs AUTHENTICATOR_PASSWORD)"
SUPABASE_AUTH_ADMIN_PASSWORD="$(jqs SUPABASE_AUTH_ADMIN_PASSWORD)"
SUPABASE_STORAGE_ADMIN_PASSWORD="$(jqs SUPABASE_STORAGE_ADMIN_PASSWORD)"
SUPABASE_ADMIN_PASSWORD="$(jqs SUPABASE_ADMIN_PASSWORD)"
JWT_SECRET="$(jqs JWT_SECRET)"
SECRET_KEY_BASE="$(jqs SECRET_KEY_BASE)"
DB_ENC_KEY="$(jqs DB_ENC_KEY)"
ENCRYPTION_KEY="$(jqs ENCRYPTION_KEY)"
AUTOMATION_CRON_SECRET="$(jqs AUTOMATION_CRON_SECRET)"
META_APP_SECRET="$(jqs META_APP_SECRET)"
META_APP_ID="$(jqs META_APP_ID)"

if [ -z "$JWT_SECRET" ]; then
  echo "FATAL: JWT_SECRET is empty in $SECRETS_FILE" >&2
  exit 1
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "FATAL: POSTGRES_PASSWORD is empty in $SECRETS_FILE" >&2
  exit 1
fi

if [ -z "$META_APP_SECRET" ]; then
  echo
  echo "  NOTE: META_APP_SECRET is empty. The app will start, but"
  echo "  POST /api/whatsapp/webhook rejects every request until it is"
  echo "  set — it verifies Meta's HMAC-SHA256 signature with it."
  echo "  (WhatsApp also needs public HTTPS, which an IP-only deploy"
  echo "  does not have. See README.md.)"
  echo
fi

# -----------------------------------------------------------------
# The two Supabase API keys.
#
# Deterministic in the secret but not in time (they carry iat/exp),
# so they are minted fresh each run rather than stored. Both are
# derived from JWT_SECRET, so they only change if that changes.
# -----------------------------------------------------------------
echo "--- minting anon and service_role keys"
SUPABASE_ANON_KEY="$("$AWS_SCRIPTS_DIR/gen-jwt.sh" "$JWT_SECRET" anon)"
SUPABASE_SERVICE_ROLE_KEY="$("$AWS_SCRIPTS_DIR/gen-jwt.sh" "$JWT_SECRET" service_role)"

# -----------------------------------------------------------------
# Compose environment file.
# -----------------------------------------------------------------
echo "--- writing $STACK_DIR/.env"
umask 077
cat > "$STACK_DIR/.env" <<ENVEOF
# Generated by deploy.sh at $(date -u +%FT%TZ). Do not edit by hand —
# every value here comes from /etc/wacrm/deploy.env or
# /etc/wacrm/secrets.json and is overwritten on the next run. Change
# the source, then re-run.

DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME

APP_URL=$APP_URL
APP_FQDN=$APP_FQDN
APP_LOCALE=$APP_LOCALE
SUPABASE_PUBLIC_URL=$SUPABASE_PUBLIC_URL

POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
SECRET_KEY_BASE=$SECRET_KEY_BASE
DB_ENC_KEY=$DB_ENC_KEY
SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SUPABASE_SERVICE_ROLE_KEY

AUTHENTICATOR_PASSWORD=$AUTHENTICATOR_PASSWORD
SUPABASE_AUTH_ADMIN_PASSWORD=$SUPABASE_AUTH_ADMIN_PASSWORD
SUPABASE_STORAGE_ADMIN_PASSWORD=$SUPABASE_STORAGE_ADMIN_PASSWORD
SUPABASE_ADMIN_PASSWORD=$SUPABASE_ADMIN_PASSWORD

ENCRYPTION_KEY=$ENCRYPTION_KEY
AUTOMATION_CRON_SECRET=$AUTOMATION_CRON_SECRET
META_APP_SECRET=$META_APP_SECRET
META_APP_ID=$META_APP_ID

MAILER_AUTOCONFIRM=$MAILER_AUTOCONFIRM
DISABLE_SIGNUP=$DISABLE_SIGNUP
STORAGE_FILE_SIZE_LIMIT=$STORAGE_FILE_SIZE_LIMIT
ENVEOF

# Optional pinned-version overrides, e.g.
#   GOTRUE_VERSION=v2.180.0
# Kept in a separate file because this one is rewritten every run.
# See deploy/aws/scripts/check-image-tags.sh.
if [ -f /etc/wacrm/versions.env ]; then
  echo "--- applying version overrides from /etc/wacrm/versions.env"
  {
    echo
    echo "# --- from /etc/wacrm/versions.env ---"
    cat /etc/wacrm/versions.env
  } >> "$STACK_DIR/.env"
fi

chmod 600 "$STACK_DIR/.env"
umask 022

compose() {
  docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/docker-compose.yml" "$@"
}

if [ "$PULL" -eq 1 ]; then
  echo "--- pulling service images"
  compose pull db kong auth rest realtime storage
fi

# =================================================================
# 0. Postgres
#
# The AWS stack has RDS here and only has to wait. On this box the
# database is a container, so start it first — everything below
# connects to it.
# =================================================================
echo "--- [0/5] starting postgres"
compose up -d db

# -----------------------------------------------------------------
# Database helpers. Host-side psql, hence DB_ADMIN_HOST.
# -----------------------------------------------------------------
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL=(psql --host "$DB_ADMIN_HOST" --port "$DB_ADMIN_PORT" --username postgres --dbname "$DB_NAME" --no-password)

psql_q() { "${PSQL[@]}" --tuples-only --no-align --quiet -c "$1"; }

echo "--- waiting for postgres on $DB_ADMIN_HOST:$DB_ADMIN_PORT"
for attempt in $(seq 1 60); do
  if psql_q 'SELECT 1' >/dev/null 2>&1; then
    echo "    database reachable after ${attempt} attempt(s)"
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "FATAL: could not reach the database after 5 minutes." >&2
    echo "Run: docker compose --project-directory $STACK_DIR logs db" >&2
    exit 1
  fi
  sleep 5
done

# wal_level is set by the db service's `command:`. If it is not
# logical, Realtime will connect, report no error, and silently
# deliver nothing — so fail loudly here instead.
wal_level="$(psql_q "SELECT current_setting('wal_level')" || echo unknown)"
if [ "$wal_level" != "logical" ]; then
  echo "FATAL: wal_level is '$wal_level', expected 'logical'." >&2
  echo "Realtime cannot work without it. Check the db service's" >&2
  echo "command: block in docker-compose.yml, then:" >&2
  echo "  docker compose --project-directory $STACK_DIR up -d --force-recreate db" >&2
  exit 1
fi

# =================================================================
# 1. Bootstrap SQL
# =================================================================
if [ "$SKIP_MIGRATIONS" -eq 0 ]; then
  echo "--- [1/5] bootstrap: roles, schemas, extensions, auth.uid()"
  "${PSQL[@]}" \
    --set ON_ERROR_STOP=1 \
    --set "authenticator_password=$AUTHENTICATOR_PASSWORD" \
    --set "auth_admin_password=$SUPABASE_AUTH_ADMIN_PASSWORD" \
    --set "storage_admin_password=$SUPABASE_STORAGE_ADMIN_PASSWORD" \
    --set "supabase_admin_password=$SUPABASE_ADMIN_PASSWORD" \
    --file "$SQL_DIR/000_bootstrap.sql"
fi

# =================================================================
# 2. Start the Supabase services so they run their own migrations
# =================================================================
echo "--- [2/5] starting auth, rest, realtime, storage"
compose up -d auth rest realtime storage

if [ "$SKIP_MIGRATIONS" -eq 0 ]; then
  # Poll for the tables rather than the container health status: a
  # container reports healthy the moment its HTTP port answers, which
  # is before its migrations have finished.
  echo "--- waiting for GoTrue to create auth.users"
  for attempt in $(seq 1 60); do
    if [ "$(psql_q "SELECT to_regclass('auth.users') IS NOT NULL")" = "t" ]; then
      echo "    auth.users present"
      break
    fi
    if [ "$attempt" -eq 60 ]; then
      echo "FATAL: auth.users never appeared. Run:" >&2
      echo "  docker compose --project-directory $STACK_DIR logs auth" >&2
      exit 1
    fi
    sleep 5
  done

  echo "--- waiting for storage-api to create storage.buckets"
  for attempt in $(seq 1 60); do
    if [ "$(psql_q "SELECT to_regclass('storage.buckets') IS NOT NULL")" = "t" ]; then
      echo "    storage.buckets present"
      break
    fi
    if [ "$attempt" -eq 60 ]; then
      echo "FATAL: storage.buckets never appeared. Run:" >&2
      echo "  docker compose --project-directory $STACK_DIR logs storage" >&2
      exit 1
    fi
    sleep 5
  done

  # =================================================================
  # 3. Grants that need the service-owned tables to exist
  # =================================================================
  echo "--- [3/5] post-service grants"
  "${PSQL[@]}" --set ON_ERROR_STOP=1 --file "$SQL_DIR/010_post_service_grants.sql"

  # =================================================================
  # 4. The application's own migrations
  # =================================================================
  echo "--- [4/5] applying supabase/migrations"

  # A ledger, so a re-run after a partial failure resumes rather than
  # replaying. The migrations upstream are written to be idempotent,
  # but "written to be" and "is" are different claims and a partial
  # apply is exactly when the difference bites.
  psql_q "
    CREATE TABLE IF NOT EXISTS public._wacrm_migrations (
      filename    text PRIMARY KEY,
      applied_at  timestamptz NOT NULL DEFAULT now()
    )" >/dev/null

  if [ "$FORCE_MIGRATIONS" -eq 1 ]; then
    echo "    --force-migrations: clearing the ledger"
    psql_q 'TRUNCATE public._wacrm_migrations' >/dev/null
  fi

  applied=0
  skipped=0
  for migration in "$SRC_DIR"/supabase/migrations/*.sql; do
    fname="$(basename "$migration")"

    already="$(psql_q "SELECT 1 FROM public._wacrm_migrations WHERE filename = '$fname'")"
    if [ -n "$already" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    echo "    applying $fname"
    "${PSQL[@]}" --set ON_ERROR_STOP=1 --file "$migration"
    psql_q "INSERT INTO public._wacrm_migrations (filename) VALUES ('$fname')
            ON CONFLICT (filename) DO NOTHING" >/dev/null
    applied=$((applied + 1))
  done
  echo "    $applied applied, $skipped already recorded"

  # =================================================================
  # 5. Grants over everything the migrations just created
  # =================================================================
  echo "--- [5/5] post-migration grants"
  "${PSQL[@]}" --set ON_ERROR_STOP=1 --file "$SQL_DIR/020_post_app_grants.sql"
fi

unset PGPASSWORD

# =================================================================
# Gateway + application
# =================================================================
echo "--- starting kong"
compose up -d kong

echo "--- building and starting the app"
if [ "$REBUILD" -eq 1 ]; then
  compose build --no-cache app
else
  compose build app
fi
compose up -d app

# Restart PostgREST so it picks up the schema even if the NOTIFY in
# 020 was missed (it is only delivered to a listener that was already
# connected).
echo "--- reloading PostgREST schema cache"
compose restart rest

echo
echo "=== deploy complete at $(date -u +%FT%TZ) ==="
compose ps
echo
echo "  app:      $APP_URL"
echo "  supabase: $SUPABASE_PUBLIC_URL"
echo
echo "  health:   sudo $SCRIPTS_DIR/doctor.sh"
echo "  logs:     docker compose --project-directory $STACK_DIR logs -f app"
echo
