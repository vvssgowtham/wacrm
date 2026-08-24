terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to a major that is known-good for every resource used here.
      # AWS provider 6.x should also work, but bump deliberately, not by
      # accident on a Tuesday.
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"

  app_fqdn      = "${var.app_subdomain}.${var.domain_name}"
  supabase_fqdn = "${var.supabase_subdomain}.${var.domain_name}"

  app_url      = "https://${local.app_fqdn}"
  supabase_url = "https://${local.supabase_fqdn}"

  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
