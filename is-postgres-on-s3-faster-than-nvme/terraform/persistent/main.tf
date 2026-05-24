# Persistent infrastructure for the postgres-benchmark-s3-nvme project.
#
# Holds ONE long-lived resource — the results S3 bucket — separate from the
# per-scenario state in ../ so that `make down` (which runs tofu destroy in
# ../) leaves campaign artifacts untouched. Only `make destroy` (which calls
# tofu destroy in BOTH this dir AND ../) removes the bucket.
#
# Bucket name: pgbench-results-<account-id>-<region>. Stable across applies
# so the per-scenario configuration can look it up via `data.aws_s3_bucket`.
# `force_destroy = true` so a deliberate `tofu destroy` from this directory
# wipes the non-empty bucket (used by `make destroy`).

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "region" {
  description = "AWS region for the results bucket. Must match the per-scenario region."
  type        = string
  default     = "us-east-2"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "postgres-benchmark-s3-nvme"
      ManagedBy = "terraform-persistent"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "results" {
  bucket        = "pgbench-results-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "cleanup-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }

    filter {}
  }
}

output "results_bucket" {
  description = "Persistent S3 bucket for benchmark artifacts. Survives `make down`."
  value       = aws_s3_bucket.results.bucket
}

output "results_bucket_arn" {
  value = aws_s3_bucket.results.arn
}

output "region" {
  value = var.region
}
