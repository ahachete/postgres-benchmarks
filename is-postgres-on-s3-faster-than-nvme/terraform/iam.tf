data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# AWS SSM Session Manager — operator runs commands and ansible plays via the
# SSM API rather than SSH. The instance still needs outbound egress to reach
# the SSM endpoints; that's covered by the egress-all rule on the SG.
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch agent — installed at AMI bake time (see roles/common/bake.yml),
# ships memory/disk/diskio/netstat metrics and the postgres server log to
# CloudWatch. Standard EC2 metrics don't include memory; this fills that gap
# and gives a unified per-run view that persists after the EC2 is destroyed.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Standard-S3 access on the bench bucket. Always granted — even nvme-only
# scenarios use the bucket for result artifact archival.
data "aws_iam_policy_document" "bench_bucket_rw" {
  statement {
    sid     = "BenchBucketList"
    effect  = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.standard.arn]
  }

  statement {
    sid    = "BenchObjectReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.standard.arn}/*"]
  }
}

resource "aws_iam_role_policy" "bench_bucket_rw" {
  name   = "${local.name_prefix}-bench-bucket-rw"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.bench_bucket_rw.json
}

# Results bucket — long-lived, managed by terraform/persistent/. The EC2
# uploads every run's artifacts here so they survive `make down`.
data "aws_iam_policy_document" "results_bucket_rw" {
  statement {
    sid     = "ResultsBucketList"
    effect  = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [data.aws_s3_bucket.results.arn]
  }

  statement {
    sid    = "ResultsObjectReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${data.aws_s3_bucket.results.arn}/*"]
  }
}

resource "aws_iam_role_policy" "results_bucket_rw" {
  name   = "${local.name_prefix}-results-bucket-rw"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.results_bucket_rw.json
}

# S3 Express requires CreateSession; once the session token is acquired the
# normal s3express:GetObject/PutObject/etc are gated on it. Scope this
# permission to the directory bucket ARN only.
data "aws_iam_policy_document" "express_bucket_rw" {
  count = local.needs_directory_bckt ? 1 : 0

  statement {
    sid    = "ExpressCreateSession"
    effect = "Allow"
    actions = [
      "s3express:CreateSession",
    ]
    resources = [aws_s3_directory_bucket.express[0].arn]
  }
}

resource "aws_iam_role_policy" "express_bucket_rw" {
  count  = local.needs_directory_bckt ? 1 : 0
  name   = "${local.name_prefix}-express-bucket-rw"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.express_bucket_rw[0].json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}
