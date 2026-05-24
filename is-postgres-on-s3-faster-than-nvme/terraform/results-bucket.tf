# Lookup the persistent results bucket created by `terraform/persistent/`.
# This file MUST find the bucket — if it can't, the operator forgot to
# `make bootstrap` first. The bucket name is deterministic from account-id
# and region, so no remote-state plumbing is required.

data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "results" {
  bucket = "pgbench-results-${data.aws_caller_identity.current.account_id}-${var.region}"
}
