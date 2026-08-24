# ---------------------------------------------------------------
# Application instance
#
# One box runs the entire stack via Docker Compose:
#   kong · gotrue · postgrest · realtime · storage-api · imgproxy · app
#
# Postgres is the one piece that is NOT here — it lives on RDS.
# ---------------------------------------------------------------

# Amazon Linux 2023, x86_64. Switch the parameter name to
# `...al2023-ami-kernel-6.1-arm64` if you move instance_type to a
# Graviton family (t4g.*).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_instance" "app" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public[0].id

  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  key_name               = var.key_pair_name == "" ? null : var.key_pair_name

  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # storage-api reaches the metadata service through the Docker
    # bridge, which adds a hop, so the default limit of 1 would drop
    # its credential lookups.
    http_put_response_hop_limit = 2
  }

  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region     = var.aws_region
    secret_id      = aws_secretsmanager_secret.config.id
    log_group      = aws_cloudwatch_log_group.app.name
    repo_url       = var.app_repo_url
    repo_branch    = var.app_repo_branch
    db_host        = aws_db_instance.main.address
    db_port        = tostring(aws_db_instance.main.port)
    db_name        = "postgres"
    s3_bucket      = aws_s3_bucket.storage.id
    app_url        = local.app_url
    supabase_url   = local.supabase_url
    app_fqdn       = local.app_fqdn
    app_locale     = var.app_locale
    smtp_host      = "email-smtp.${var.aws_region}.amazonaws.com"
    smtp_sender    = var.ses_from_address
    smtp_name      = var.ses_sender_name
    autoconfirm    = var.mailer_autoconfirm ? "true" : "false"
    disable_signup = var.disable_signup ? "true" : "false"
    file_size_limit = tostring(var.storage_file_size_limit)
  })

  tags = { Name = "${local.name}-app" }

  # The bootstrap script runs migrations against RDS on first boot, so
  # the database has to exist first. Terraform infers the dependency
  # from db_host, but the secret is only referenced by id — make it
  # explicit so a fresh apply cannot race.
  depends_on = [
    aws_secretsmanager_secret_version.config,
    aws_db_instance.main,
  ]
}

# Elastic IP so the instance keeps a stable outbound address across
# stop/start. Meta does not require an allow-listed source IP today,
# but a stable egress IP is worth having the day some upstream does.
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = { Name = "${local.name}-eip" }
}
