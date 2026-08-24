variable "aws_region" {
  description = "AWS region to deploy into. Must be a region where SES is available if you want auth emails."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short name used as a prefix on every resource."
  type        = string
  default     = "wacrm"
}

variable "environment" {
  description = "Environment suffix (prod, staging, ...)."
  type        = string
  default     = "prod"
}

# ---------------------------------------------------------------
# DNS
# ---------------------------------------------------------------

variable "domain_name" {
  description = <<-EOT
    Apex domain you already own, e.g. "example.com". A Route 53 PUBLIC
    hosted zone for this domain must already exist in this account —
    Terraform looks it up, it does not create it. If your registrar is
    not Route 53, create the hosted zone first and point the registrar's
    nameservers at it.
  EOT
  type        = string
}

variable "app_subdomain" {
  description = "Subdomain the CRM itself is served from."
  type        = string
  default     = "crm"
}

variable "supabase_subdomain" {
  description = <<-EOT
    Subdomain the self-hosted Supabase gateway (Kong) is served from.
    This becomes NEXT_PUBLIC_SUPABASE_URL. It must be a separate
    hostname from the app — the Supabase client needs an origin root,
    not a path prefix.
  EOT
  type        = string
  default     = "supabase"
}

# ---------------------------------------------------------------
# Networking
# ---------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
}

# ---------------------------------------------------------------
# Compute
# ---------------------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    EC2 instance type running the whole Docker Compose stack (Kong,
    GoTrue, PostgREST, Realtime, Storage, imgproxy, and the Next.js
    app). t3.medium (2 vCPU / 4 GB) is the practical floor because
    `next build` runs on the box; user-data adds 4 GB of swap to keep
    the build from OOM-ing. Step up to t3.large if builds are slow.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB. Docker images + build cache need room."
  type        = number
  default     = 50
}

variable "app_repo_url" {
  description = "Git URL of the wacrm fork to deploy. Must be publicly readable (no credentials are configured on the instance)."
  type        = string
  default     = "https://github.com/ajaychanumolu/wacrm.git"
}

variable "app_repo_branch" {
  description = "Branch to deploy."
  type        = string
  default     = "main"
}

# ---------------------------------------------------------------
# Database
# ---------------------------------------------------------------

variable "db_instance_class" {
  description = <<-EOT
    RDS instance class. db.t4g.small (2 GB) is the floor — GoTrue,
    PostgREST, Realtime, Storage and the app each hold a connection
    pool, and db.t4g.micro runs out of connections and memory quickly.
  EOT
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GB (autoscales up to db_max_allocated_storage)."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB."
  type        = number
  default     = 100
}

variable "db_backup_retention_days" {
  description = "Automated backup retention. Set to 0 to disable (not recommended)."
  type        = number
  default     = 7
}

variable "db_multi_az" {
  description = "Run RDS Multi-AZ. Roughly doubles the database cost; off by default."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Block `terraform destroy` from deleting the database."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------
# Application behaviour
# ---------------------------------------------------------------

variable "app_locale" {
  description = "NEXT_PUBLIC_APP_LOCALE."
  type        = string
  default     = "en"
}

variable "mailer_autoconfirm" {
  description = <<-EOT
    When true, GoTrue marks new signups as confirmed immediately and
    sends no confirmation email.

    This defaults to TRUE deliberately. The upstream app has no
    `/auth/callback` route, so the PKCE code that GoTrue appends to the
    confirmation redirect has nothing to exchange it for and the
    verification link dead-ends. Until that route exists, autoconfirm is
    the only signup flow that actually completes.

    Pair it with `disable_signup = true` once your owner account exists:
    teammates join through the in-app invite link (/join/<token>), which
    works regardless of this setting.
  EOT
  type        = bool
  default     = true
}

variable "disable_signup" {
  description = <<-EOT
    Set to true after you have created your owner account. With
    mailer_autoconfirm on, leaving public signup open lets anyone with
    the URL create an account.
  EOT
  type        = bool
  default     = false
}

variable "storage_file_size_limit" {
  description = "Max upload size in bytes accepted by storage-api. The app's chat-media bucket caps at 16 MB in SQL; this is the outer gate."
  type        = number
  default     = 52428800 # 50 MB
}

variable "cron_schedule_expression" {
  description = "EventBridge schedule for the automation + flow cron pingers."
  type        = string
  default     = "rate(1 minute)"
}

# ---------------------------------------------------------------
# Email (SES)
# ---------------------------------------------------------------

variable "ses_from_address" {
  description = <<-EOT
    From address for auth emails (password recovery, invitations).
    Must be on `domain_name` — Terraform verifies the domain identity
    via Route 53 DKIM records. Example: "no-reply@example.com".
  EOT
  type        = string
  default     = ""
}

variable "ses_sender_name" {
  description = "Display name on outbound auth emails."
  type        = string
  default     = "wacrm"
}

variable "manage_spf_record" {
  description = <<-EOT
    Publish `v=spf1 include:amazonses.com ~all` as a TXT record on the
    apex. Set to false if the apex already has TXT records — Route 53
    permits only one TXT record set per name, and you will need to
    merge the SES include into your existing SPF string manually.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------
# Access
# ---------------------------------------------------------------

variable "admin_cidr_blocks" {
  description = <<-EOT
    Optional CIDRs allowed to reach the instance on port 22.

    Leave empty (the default) and there is no SSH ingress at all — use
    `aws ssm start-session` instead, which the instance profile already
    permits and which needs no open port and no key pair.
  EOT
  type        = list(string)
  default     = []
}

variable "key_pair_name" {
  description = "Optional existing EC2 key pair name. Only useful alongside admin_cidr_blocks."
  type        = string
  default     = ""
}
