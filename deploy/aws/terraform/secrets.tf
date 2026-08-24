# ---------------------------------------------------------------
# Generated secrets
#
# `special = false` on every password is deliberate: each of these
# ends up inside a `postgres://user:pass@host/db` URL in a container
# environment variable, and GoTrue / PostgREST / storage-api / Realtime
# do not agree on percent-decoding. Alphanumeric-only sidesteps the
# whole class of bug at a negligible entropy cost (62^32).
# ---------------------------------------------------------------

resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "random_password" "authenticator" {
  length  = 32
  special = false
}

resource "random_password" "auth_admin" {
  length  = 32
  special = false
}

resource "random_password" "storage_admin" {
  length  = 32
  special = false
}

resource "random_password" "supabase_admin" {
  length  = 32
  special = false
}

# Signs every Supabase JWT: the anon key, the service_role key, and
# every user session GoTrue issues. PostgREST, Realtime and
# storage-api all verify against it. Rotating it invalidates every
# session and both API keys at once.
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

# Phoenix requires >= 64 bytes for the Realtime container.
resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

# Realtime encrypts per-tenant DB credentials with this.
resource "random_password" "db_enc_key" {
  length  = 32
  special = false
}

# ENCRYPTION_KEY for the app: AES-256-GCM over stored WhatsApp and AI
# provider tokens. The app parses it as hex and requires exactly 32
# bytes, so random_id.hex (2 chars per byte) is the right generator —
# a random_password would produce 64 characters that are not valid hex.
resource "random_id" "encryption_key" {
  byte_length = 32
}

# Shared secret on GET /api/automations/cron and /api/flows/cron.
resource "random_id" "cron_secret" {
  byte_length = 32
}

# ---------------------------------------------------------------
# Secrets Manager
#
# One JSON secret holds everything the instance needs at boot. The
# instance profile can read exactly this one secret and nothing else.
#
# META_APP_SECRET / META_APP_ID start empty because only you can
# supply them. Fill them in via the console or the CLI, then re-run
# the deploy script on the box — see deploy/aws/README.md, step 7.
# `ignore_changes` on the version keeps Terraform from stomping your
# edit on the next apply.
# ---------------------------------------------------------------

resource "aws_secretsmanager_secret" "config" {
  name        = "${local.name}/config"
  description = "wacrm + self-hosted Supabase runtime configuration"

  # Zero so a `terraform destroy` followed by an `apply` does not
  # collide with a soft-deleted secret of the same name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id = aws_secretsmanager_secret.config.id

  secret_string = jsonencode({
    # --- Postgres roles ---------------------------------------
    POSTGRES_PASSWORD               = random_password.db_master.result
    AUTHENTICATOR_PASSWORD          = random_password.authenticator.result
    SUPABASE_AUTH_ADMIN_PASSWORD    = random_password.auth_admin.result
    SUPABASE_STORAGE_ADMIN_PASSWORD = random_password.storage_admin.result
    SUPABASE_ADMIN_PASSWORD         = random_password.supabase_admin.result

    # --- Supabase platform ------------------------------------
    JWT_SECRET      = random_password.jwt_secret.result
    SECRET_KEY_BASE = random_password.secret_key_base.result
    DB_ENC_KEY      = random_password.db_enc_key.result

    # --- Application ------------------------------------------
    ENCRYPTION_KEY         = random_id.encryption_key.hex
    AUTOMATION_CRON_SECRET = random_id.cron_secret.hex

    # --- SMTP (SES) -------------------------------------------
    SMTP_USER = var.ses_from_address == "" ? "" : aws_iam_access_key.ses[0].id
    SMTP_PASS = var.ses_from_address == "" ? "" : aws_iam_access_key.ses[0].ses_smtp_password_v4

    # --- Meta / WhatsApp (you fill these in) ------------------
    META_APP_SECRET = ""
    META_APP_ID     = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
