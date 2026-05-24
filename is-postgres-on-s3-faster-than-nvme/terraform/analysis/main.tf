# Analysis workstation.
#
# A dedicated EC2 instance for running `compare-scenarios` + ad-hoc data
# exploration on campaign results pulled from the persistent S3 bucket.
# Lives in its own Terraform root so its lifecycle is independent of both
# the per-scenario benchmark infra (terraform/) and the persistent bucket
# (terraform/persistent/): you can spin it up while a benchmark campaign
# is running, kill it any time without affecting either.
#
# Pre-installed via user_data:
#   - Nix (Determinate installer, multi-user / daemon mode)
#   - git, aws CLI v2
# After SSM-ing in, the operator clones the repo and `nix-shell` brings up
# the same dev env as the operator's laptop (shell.nix at the repo root).
#
# Workflow:
#   make analysis-up
#   make analysis-shell                       # opens an SSM session
#   # inside: clone repo, cd, nix-shell, aws s3 sync, run compare-scenarios
#   make analysis-down

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "postgres-benchmark-s3-nvme"
      Role      = "analysis"
      ManagedBy = "terraform-analysis"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "aws_caller_identity" "current" {}

# Lookup the persistent results bucket — created by terraform/persistent/.
data "aws_s3_bucket" "results" {
  bucket = "pgbench-results-${data.aws_caller_identity.current.account_id}-${var.region}"
}

locals {
  name_prefix = "pgbench-analysis-${random_id.suffix.hex}"
}
