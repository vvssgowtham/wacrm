#!/usr/bin/env bash
# =================================================================
# Mint a Supabase API key (an HS256 JWT) from the JWT secret.
#
#   ./gen-jwt.sh <jwt-secret> <role>
#
# where <role> is `anon` or `service_role`.
#
# Self-hosted Supabase has no key-issuing service: the anon and
# service_role keys ARE just long-lived JWTs signed with JWT_SECRET,
# carrying a `role` claim. PostgREST verifies the signature and
# SET ROLEs to whatever `role` says, which is why the service_role
# key is equivalent to database owner access and must never reach a
# browser.
#
# Pure openssl — no Node, no Python, no jq. The instance has openssl
# before it has anything else, and this runs before Docker is up.
# =================================================================
set -euo pipefail

SECRET="${1:?usage: gen-jwt.sh <jwt-secret> <anon|service_role>}"
ROLE="${2:?usage: gen-jwt.sh <jwt-secret> <anon|service_role>}"

case "$ROLE" in
  anon | service_role) ;;
  *)
    echo "gen-jwt.sh: role must be 'anon' or 'service_role', got '$ROLE'" >&2
    exit 1
    ;;
esac

# base64url: standard base64, then swap the two URL-unsafe characters
# and drop the padding. `-A` keeps it on one line.
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

IAT="$(date +%s)"
# Ten years. These are infrastructure credentials, not sessions —
# hosted Supabase issues them with the same kind of horizon. Rotate
# by changing JWT_SECRET, which invalidates both keys at once.
EXP=$((IAT + 315360000))

HEADER="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
PAYLOAD="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$ROLE" "$IAT" "$EXP" | b64url)"

SIGNING_INPUT="${HEADER}.${PAYLOAD}"

SIGNATURE="$(
  printf '%s' "$SIGNING_INPUT" |
    openssl dgst -sha256 -hmac "$SECRET" -binary |
    b64url
)"

printf '%s.%s\n' "$SIGNING_INPUT" "$SIGNATURE"
