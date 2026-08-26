#!/usr/bin/env bash
# =================================================================
# check-image-tags.sh — compare the pinned Supabase service versions
# against the ones upstream currently ships.
#
#   ./check-image-tags.sh
#
# The tags in docker-compose.yml are pinned on purpose: these five
# services have to agree with each other about the JWT format, the
# schema of the tables they own, and the wire protocol between them,
# and upstream bumps them as a set. Pinning means a rebuild six
# months from now behaves identically to today's.
#
# It also means they go stale. Run this occasionally, read the diff,
# and bump deliberately — put the *_VERSION overrides in
# /etc/wacrm/versions.env rather than editing docker-compose.yml, so
# neither a `git pull` nor a deploy.sh run reverts your choice.
# =================================================================
set -euo pipefail

UPSTREAM=https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml
COMPOSE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stack" && pwd)/docker-compose.yml"

echo "Fetching upstream compose file..."
remote="$(curl -fsSL "$UPSTREAM")" || {
  echo "Could not fetch $UPSTREAM" >&2
  exit 1
}

printf '\n%-14s %-22s %-22s\n' "SERVICE" "PINNED HERE" "UPSTREAM"
printf '%-14s %-22s %-22s\n' "-------" "-----------" "--------"

compare() { # compare <label> <image prefix> <default-var pattern>
  local label="$1" prefix="$2" pattern="$3" mine theirs

  mine="$(grep -oE "$pattern" "$COMPOSE" | head -1 | grep -oE '[^-]+$' || true)"
  theirs="$(printf '%s' "$remote" | grep -oE "${prefix}:[A-Za-z0-9._-]+" | head -1 | cut -d: -f2- || true)"

  if [ -z "$theirs" ]; then
    theirs="(not found)"
  fi

  if [ "$mine" = "$theirs" ]; then
    printf '%-14s %-22s %-22s  same\n' "$label" "$mine" "$theirs"
  else
    printf '%-14s %-22s %-22s  \033[33mDIFFERS\033[0m\n' "$label" "$mine" "$theirs"
  fi
}

compare "kong"      "kong"                    'KONG_VERSION:-[^}]+'
compare "gotrue"    "supabase/gotrue"         'GOTRUE_VERSION:-[^}]+'
compare "postgrest" "postgrest/postgrest"     'POSTGREST_VERSION:-[^}]+'
compare "realtime"  "supabase/realtime"       'REALTIME_VERSION:-[^}]+'
compare "storage"   "supabase/storage-api"    'STORAGE_VERSION:-[^}]+'

cat <<'NOTE'

To adopt a newer set, write the overrides to /etc/wacrm/versions.env
on the instance (deploy.sh appends that file to the generated .env,
so it survives a redeploy):

    sudo tee -a /etc/wacrm/versions.env <<'EOF'
    GOTRUE_VERSION=v2.180.0
    STORAGE_VERSION=v1.26.0
    EOF

then:

    sudo /opt/wacrm/src/deploy/aws/scripts/deploy.sh --pull

Bump one service at a time and run doctor.sh after each. A storage or
realtime upgrade runs its own schema migrations against your database
and is not trivially reversible — take an RDS snapshot first.
NOTE
