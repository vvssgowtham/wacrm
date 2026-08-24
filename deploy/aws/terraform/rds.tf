# ---------------------------------------------------------------
# RDS PostgreSQL
#
# This replaces the `supabase/postgres` container from the upstream
# self-host compose file. That image is stock Postgres plus an init
# bundle that creates the Supabase roles, schemas, extensions and the
# `auth.uid()` family of helper functions. RDS gives you none of that,
# so `deploy/aws/sql/000_bootstrap.sql` reproduces it. Read the header
# of that file before changing anything here.
# ---------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.name}-db-subnet-group" }
}

resource "aws_db_parameter_group" "main" {
  name        = "${local.name}-pg17"
  family      = "postgres17"
  description = "wacrm / self-hosted Supabase on RDS"

  # Supabase Realtime consumes the WAL through a logical replication
  # slot. Without this the `realtime` container connects, fails to
  # create its slot, and every postgres_changes subscription silently
  # never fires. Static parameter — the instance reboots to apply it.
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = "20"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "20"
    apply_method = "pending-reboot"
  }

  # TLS between the instance and RDS is turned off.
  #
  # Why: GoTrue, PostgREST, storage-api and Realtime each configure
  # Postgres TLS differently, and two of them have no clean way to
  # trust the RDS CA bundle. Forcing SSL turns a one-evening deploy
  # into a certificate-plumbing exercise for traffic that never
  # leaves the VPC — the database has no public route, sits in a
  # subnet with an empty route table, and its security group accepts
  # port 5432 from exactly one security group.
  #
  # To turn it on later: set this to "1", add `?sslmode=require` to
  # every DATABASE_URL in deploy/aws/stack/docker-compose.yml, and
  # mount the RDS CA bundle into the containers that verify it.
  parameter {
    name         = "rds.force_ssl"
    value        = "0"
    apply_method = "pending-reboot"
  }

  # Postgres kills idle-in-transaction sessions after 5 minutes.
  # PostgREST and Realtime both hold pools; a wedged transaction
  # otherwise blocks VACUUM and holds locks indefinitely.
  parameter {
    name         = "idle_in_transaction_session_timeout"
    value        = "300000"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier = "${local.name}-db"

  engine = "postgres"
  # Major version only — RDS resolves the latest supported minor and
  # `auto_minor_version_upgrade` keeps it patched. 17 matches the
  # `major_version` pinned in supabase/config.toml, so CI and
  # production agree on what SQL is legal.
  engine_version              = "17"
  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = true

  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # Named `postgres` on purpose, not something project-specific.
  # supabase/migrations/001 and 017 both run
  # `ALTER FUNCTION ... OWNER TO postgres`, so a role with that exact
  # name has to exist or the migrations abort.
  username = "postgres"
  password = random_password.db_master.result

  # No db_name: the postgres engine always provisions the `postgres`
  # maintenance database, and that is what every service connects to.

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "18:00-19:00"
  maintenance_window      = "sun:19:30-sun:20:30"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-db-final"

  performance_insights_enabled = false
  apply_immediately            = true

  tags = { Name = "${local.name}-db" }
}
