#!/usr/bin/env bash
# =================================================================
# backup.sh — nightly database + uploaded-files backup.
#
#   sudo /opt/wacrm/src/deploy/selfhost/backup.sh
#
# Installed as a 02:30 cron entry by setup.sh.
#
# This exists because there is no RDS here. RDS would give you
# automated snapshots and point-in-time restore; a Postgres container
# gives you neither, so this is the substitute. Two artefacts per
# night, 7 days retained:
#
#   db-<stamp>.sql.gz        pg_dump of the whole database
#   storage-<stamp>.tar.gz   the storage-data volume (uploaded files)
#
# Both are needed. The database rows in storage.objects and the bytes
# on disk are useless without each other.
#
# IMPORTANT: this writes to the same EBS volume as the data it is
# backing up, so it protects against "someone deleted the wrong rows"
# but NOT against losing the instance. Copy the directory off the box
# — or take EBS snapshots — for that. See README.md.
# =================================================================
set -euo pipefail

SRC_DIR=/opt/wacrm/src
STACK_DIR="$SRC_DIR/deploy/selfhost"
BACKUP_DIR=/opt/wacrm/backups
RETAIN_DAYS=7

# shellcheck disable=SC1091
source /etc/wacrm/deploy.env

DB_ADMIN_HOST="${DB_ADMIN_HOST:-127.0.0.1}"
DB_ADMIN_PORT="${DB_ADMIN_PORT:-5432}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"

echo "=== backup starting at $(date -u +%FT%TZ) ==="

# -----------------------------------------------------------------
# Database
# -----------------------------------------------------------------
PGPASSWORD="$(jq -r '.POSTGRES_PASSWORD' /etc/wacrm/secrets.json)"
export PGPASSWORD

DB_FILE="$BACKUP_DIR/db-$STAMP.sql.gz"
echo "--- dumping $DB_NAME -> $DB_FILE"
umask 077
pg_dump \
  --host "$DB_ADMIN_HOST" \
  --port "$DB_ADMIN_PORT" \
  --username postgres \
  --dbname "$DB_NAME" \
  --no-password \
  --clean \
  --if-exists \
  | gzip > "$DB_FILE"
unset PGPASSWORD

# A dump that failed halfway still leaves a file, so check it is
# readable end to end rather than merely present.
if ! gzip -t "$DB_FILE"; then
  echo "FATAL: $DB_FILE is corrupt; removing it." >&2
  rm -f "$DB_FILE"
  exit 1
fi
echo "    $(du -h "$DB_FILE" | cut -f1)"

# -----------------------------------------------------------------
# Uploaded files.
#
# Read out of the named volume through a throwaway container, so this
# works whether or not the storage service is running.
# -----------------------------------------------------------------
STORAGE_FILE="$BACKUP_DIR/storage-$STAMP.tar.gz"
echo "--- archiving storage volume -> $STORAGE_FILE"
docker run --rm \
  -v wacrm_storage-data:/data:ro \
  -v "$BACKUP_DIR":/backup \
  alpine:3.20 \
  tar czf "/backup/storage-$STAMP.tar.gz" -C /data . 2>/dev/null

echo "    $(du -h "$STORAGE_FILE" | cut -f1)"
umask 022

# -----------------------------------------------------------------
# Retention
# -----------------------------------------------------------------
echo "--- pruning backups older than $RETAIN_DAYS days"
find "$BACKUP_DIR" -maxdepth 1 -name 'db-*.sql.gz'      -mtime "+$RETAIN_DAYS" -print -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'storage-*.tar.gz' -mtime "+$RETAIN_DAYS" -print -delete

echo "=== backup complete at $(date -u +%FT%TZ) ==="
df -h /opt/wacrm | tail -1

# -----------------------------------------------------------------
# To restore (destructive — read this before you need it):
#
# The dump carries schemas, tables and data, but NOT roles. The
# `anon` / `authenticated` / `service_role` / `authenticator` roles it
# grants to must already exist, so on a rebuilt box restore
# /etc/wacrm/secrets.json first and run setup.sh — its bootstrap
# stage creates them — and only then load the dump. Restoring under
# freshly generated secrets will not work: the passwords in the dump's
# grants would no longer match the ones the containers use.
#
#   cd /opt/wacrm/src/deploy/selfhost
#   sudo docker compose stop app kong auth rest realtime storage
#
#   PGPASSWORD=$(sudo jq -r .POSTGRES_PASSWORD /etc/wacrm/secrets.json) \
#     gunzip -c /opt/wacrm/backups/db-<stamp>.sql.gz \
#     | psql -h 127.0.0.1 -U postgres -d postgres
#
#   sudo docker run --rm -v wacrm_storage-data:/data \
#     -v /opt/wacrm/backups:/backup alpine:3.20 \
#     sh -c 'rm -rf /data/* && tar xzf /backup/storage-<stamp>.tar.gz -C /data'
#
#   sudo ./deploy.sh --skip-migrations
# -----------------------------------------------------------------
