# For S3-backed scenarios this is the bucket the storage daemon talks to;
# for NVMe-only scenarios it's still useful as the result-artifact target.
# We always create the Standard bucket (cheap, even when unused as a backing
# store) and add a directory (Express) bucket only for `*-express` scenarios.

# ---------------------------------------------------------------------------
# Standard S3 bucket — present in every scenario.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "standard" {
  bucket        = "${local.name_prefix}-data"
  force_destroy = !var.keep_bucket
}

resource "aws_s3_bucket_public_access_block" "standard" {
  bucket = aws_s3_bucket.standard.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "standard" {
  bucket = aws_s3_bucket.standard.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "standard" {
  bucket = aws_s3_bucket.standard.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "standard" {
  count  = var.keep_bucket ? 0 : 1
  bucket = aws_s3_bucket.standard.id

  # ZeroFS / slatedb-nbd churn multipart uploads heavily; keep the bucket
  # clean of orphaned parts.
  rule {
    id     = "cleanup-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }

    filter {}
  }
}

# ---------------------------------------------------------------------------
# S3 Express One Zone (directory bucket) — only for `*-express` scenarios.
# Lives in the same AZ as the EC2 instance so PUT latency is in the
# single-digit-ms range. Bucket name MUST end in `--<azid>--x-s3` per AWS.
# ---------------------------------------------------------------------------
resource "aws_s3_directory_bucket" "express" {
  count    = local.needs_directory_bckt ? 1 : 0
  bucket   = "${local.name_prefix}--${local.az_ids[0]}--x-s3"
  type     = "Directory"
  force_destroy = !var.keep_bucket

  data_redundancy = "SingleAvailabilityZone"

  location {
    name = local.az_ids[0]
    type = "AvailabilityZone"
  }
}
