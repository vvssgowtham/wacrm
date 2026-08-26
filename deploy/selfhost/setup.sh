#!/usr/bin/env bash
# =================================================================
# setup.sh — one-time preparation of a fresh Amazon Linux 2023 box.
#
#   sudo /opt/wacrm/src/deploy/selfhost/setup.sh <ELASTIC_IP>
#
# Installs Docker, generates every secret, writes the deploy config,
# installs the systemd unit and cron entries, then hands off to
# deploy.sh — which is the script you use from then on.
#
# Idempotent. Re-running will NOT regenerate secrets (that would
# orphan every encrypted WhatsApp/AI token and invalidate every
# session); it tops up any key that is missing and leaves the rest
# alone.
#
# The AWS equivalent of this file is
# deploy/aws/terraform/templates/user-data.sh.tftpl, which cloud-init
# runs automatically. Here you run it by hand, because there is no
# Terraform.
# =================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo." >&2
  exit 1
fi

PUBLIC_IP="${1:-}"
if [ -z "$PUBLIC_IP" ]; then
  cat >&2 <<'USAGE'
Usage: sudo setup.sh <ELASTIC_IP>

Pass the instance's Elastic IP — NOT the auto-assigned public IP.
It is baked into the browser bundle (NEXT_PUBLIC_SUPABASE_URL), so
if it ever changes the app breaks until you rebuild. An Elastic IP
survives stop/start; an auto-assigned one does not.

Find it with:  EC2 console -> Elastic IPs
USAGE
  exit 2
fi

if ! [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "FATAL: '$PUBLIC_IP' is not an IPv4 address." >&2
  exit 2
fi

REPO_URL="${REPO_URL:-https://github.com/vvssgowtham/wacrm.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
SRC_DIR=/opt/wacrm/src

exec > >(tee -a /var/log/wacrm-bootstrap.log) 2>&1
echo "=== setup.sh starting at $(date -u +%FT%TZ) for $PUBLIC_IP ==="

# -----------------------------------------------------------------
# Swap.
#
# `next build` peaks well past 2 GB. A t3.medium has 4 GB total, and
# here Postgres shares the box with it as well as the five Supabase
# containers — so 6 GB of swap rather than the AWS stack's 4 GB.
# Without it the build is OOM-killed and reports a misleading
# "exit code 137".
# -----------------------------------------------------------------
if [ ! -f /swapfile ]; then
  echo "--- creating 6 GB swapfile"
  dd if=/dev/zero of=/swapfile bs=1M count=6144 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "--- swapfile already present"
fi

# -----------------------------------------------------------------
# Packages
# -----------------------------------------------------------------
echo "--- installing packages"
dnf update -y -q
dnf install -y -q docker git jq openssl tar gzip cronie

# psql, used to apply the bootstrap SQL and the app's migrations from
# the host. AL2023 ships different major versions over time; any
# client >= 15 speaks the wire protocol a PG17 server expects.
dnf install -y -q postgresql17 || dnf install -y -q postgresql16 || dnf install -y -q postgresql15

systemctl enable --now docker
systemctl enable --now crond

# The Compose plugin is not packaged for AL2023. Pinned rather than
# `latest` so a rebuild six months from now behaves identically.
if ! docker compose version >/dev/null 2>&1; then
  echo "--- installing docker compose plugin"
  COMPOSE_VERSION=v2.29.7
  mkdir -p /usr/libexec/docker/cli-plugins
  curl -fsSL \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  chmod +x /usr/libexec/docker/cli-plugins/docker-compose
fi

# Lets `ec2-user` run docker without sudo after the next login.
usermod -aG docker ec2-user || true

mkdir -p /etc/wacrm /opt/wacrm/backups

# -----------------------------------------------------------------
# Secrets.
#
# Every password here is interpolated into a postgres:// URL, so all
# of them are plain hex — a `@`, `:` or `/` in a password silently
# corrupts the connection string and produces authentication errors
# that look like a wrong password.
#
# ENCRYPTION_KEY must be exactly 64 hex characters: it is the
# AES-256-GCM key for stored WhatsApp and AI provider tokens.
# Changing it orphans every token already encrypted under the old
# one, which is why this block never overwrites an existing value.
# -----------------------------------------------------------------
SECRETS_FILE=/etc/wacrm/secrets.json

if [ ! -f "$SECRETS_FILE" ]; then
  echo "--- generating $SECRETS_FILE"
  umask 077
  cat > "$SECRETS_FILE" <<JSON
{
  "POSTGRES_PASSWORD":                "$(openssl rand -hex 16)",
  "AUTHENTICATOR_PASSWORD":           "$(openssl rand -hex 16)",
  "SUPABASE_AUTH_ADMIN_PASSWORD":     "$(openssl rand -hex 16)",
  "SUPABASE_STORAGE_ADMIN_PASSWORD":  "$(openssl rand -hex 16)",
  "SUPABASE_ADMIN_PASSWORD":          "$(openssl rand -hex 16)",
  "DB_ENC_KEY":                       "$(openssl rand -hex 16)",
  "JWT_SECRET":                       "$(openssl rand -hex 32)",
  "SECRET_KEY_BASE":                  "$(openssl rand -hex 32)",
  "ENCRYPTION_KEY":                   "$(openssl rand -hex 32)",
  "AUTOMATION_CRON_SECRET":           "$(openssl rand -hex 32)",
  "META_APP_SECRET":                  "",
  "META_APP_ID":                      ""
}
JSON
  umask 022
  echo "    generated. BACK THIS FILE UP — losing ENCRYPTION_KEY means"
  echo "    every stored WhatsApp and AI token becomes unreadable."
else
  echo "--- $SECRETS_FILE exists, leaving it alone"
  # Top up anything a newer version of this script expects but an
  # older run did not create. Never overwrites.
  for key in POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD SUPABASE_AUTH_ADMIN_PASSWORD \
             SUPABASE_STORAGE_ADMIN_PASSWORD SUPABASE_ADMIN_PASSWORD DB_ENC_KEY; do
    if [ -z "$(jq -r --arg k "$key" '.[$k] // ""' "$SECRETS_FILE")" ]; then
      echo "    adding missing $key"
      tmp="$(mktemp)"
      jq --arg k "$key" --arg v "$(openssl rand -hex 16)" '.[$k] = $v' "$SECRETS_FILE" > "$tmp"
      mv "$tmp" "$SECRETS_FILE"
    fi
  done
  for key in JWT_SECRET SECRET_KEY_BASE ENCRYPTION_KEY AUTOMATION_CRON_SECRET; do
    if [ -z "$(jq -r --arg k "$key" '.[$k] // ""' "$SECRETS_FILE")" ]; then
      echo "    adding missing $key"
      tmp="$(mktemp)"
      jq --arg k "$key" --arg v "$(openssl rand -hex 32)" '.[$k] = $v' "$SECRETS_FILE" > "$tmp"
      mv "$tmp" "$SECRETS_FILE"
    fi
  done
fi
chmod 600 "$SECRETS_FILE"

# -----------------------------------------------------------------
# Deploy-time configuration.
#
# Non-secret only. Same shape as the file Terraform writes in the
# AWS deployment, minus AWS_REGION / SECRET_ID / S3_BUCKET / SMTP_*.
#
# DB_HOST is the compose service name — it resolves inside the docker
# network. DB_ADMIN_HOST is how psql on the HOST reaches the same
# database, over the loopback port the db service publishes.
# -----------------------------------------------------------------
echo "--- writing /etc/wacrm/deploy.env"
cat > /etc/wacrm/deploy.env <<DEPLOYENV
# Written by setup.sh. Safe to edit by hand — re-run deploy.sh after.
REPO_URL=$REPO_URL
REPO_BRANCH=$REPO_BRANCH

DB_HOST=db
DB_PORT=5432
DB_NAME=postgres
DB_ADMIN_HOST=127.0.0.1
DB_ADMIN_PORT=5432

# These two contain the IP and are baked into the browser bundle.
# Changing either one needs 'deploy.sh --rebuild', not a restart.
APP_URL=http://$PUBLIC_IP:3000
SUPABASE_PUBLIC_URL=http://$PUBLIC_IP:8000
APP_FQDN=$PUBLIC_IP
APP_LOCALE=en

# No SMTP is configured (no domain means no verified sender), so
# signup must auto-confirm or nobody can ever log in.
MAILER_AUTOCONFIRM=true

# Flip to true once your owner account exists, then re-run
# 'deploy.sh --skip-migrations'. Team invites are unaffected.
DISABLE_SIGNUP=false

STORAGE_FILE_SIZE_LIMIT=52428800
DEPLOYENV
chmod 644 /etc/wacrm/deploy.env

# -----------------------------------------------------------------
# Source
# -----------------------------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  echo "--- cloning $REPO_URL ($REPO_BRANCH)"
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
fi
chmod +x "$SRC_DIR"/deploy/selfhost/*.sh "$SRC_DIR"/deploy/aws/scripts/*.sh

# -----------------------------------------------------------------
# systemd — brings the stack back up after a reboot WITHOUT
# re-running migrations or rebuilding the image.
# -----------------------------------------------------------------
echo "--- installing wacrm.service"
install -m 0644 "$SRC_DIR/deploy/selfhost/wacrm.service" /etc/systemd/system/wacrm.service
systemctl daemon-reload
systemctl enable wacrm.service

# -----------------------------------------------------------------
# Cron.
#
# The AWS deployment drives these two endpoints with EventBridge API
# destinations, which require an HTTPS target — unavailable here. A
# plain crontab does the same job.
#
# /api/flows/cron is NOT optional: without it an abandoned flow run
# is never timed out, and the partial unique index
# idx_one_active_run_per_contact then blocks every new trigger for
# that contact, permanently.
# -----------------------------------------------------------------
echo "--- installing /etc/cron.d/wacrm"
CRON_SECRET="$(jq -r '.AUTOMATION_CRON_SECRET' "$SECRETS_FILE")"
cat > /etc/cron.d/wacrm <<CRONEOF
# Managed by deploy/selfhost/setup.sh. Re-run it after rotating
# AUTOMATION_CRON_SECRET.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

* * * * * root curl -fsS -m 45 -H 'x-cron-secret: $CRON_SECRET' http://localhost:3000/api/automations/cron >/dev/null 2>&1
* * * * * root curl -fsS -m 45 -H 'x-cron-secret: $CRON_SECRET' http://localhost:3000/api/flows/cron >/dev/null 2>&1
30 2 * * * root $SRC_DIR/deploy/selfhost/backup.sh >> /var/log/wacrm-backup.log 2>&1
CRONEOF
chmod 600 /etc/cron.d/wacrm

# -----------------------------------------------------------------
# Hand off.
# -----------------------------------------------------------------
echo "--- handing off to deploy.sh (this is the slow part: 10-20 min)"
exec "$SRC_DIR/deploy/selfhost/deploy.sh"
