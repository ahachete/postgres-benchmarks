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

# SSM Session Manager — operator access.
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch agent — same as benchmark instances. Pretty light here, but
# useful if you want to monitor the analysis box's resource use over a
# long campaign-comparison run.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Read-only on the persistent results bucket EXCEPT for the `analysis/`
# prefix, which the box can write to. This lets the box publish rendered
# plots / summary CSVs back to S3 (where the operator can `aws s3 sync`
# them locally) without granting write to any campaign data. The narrow
# write scope keeps it impossible to accidentally clobber campaign output.
data "aws_iam_policy_document" "results_bucket_rw_analysis" {
  statement {
    sid    = "ResultsBucketList"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [data.aws_s3_bucket.results.arn]
  }

  statement {
    sid    = "ResultsObjectRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = ["${data.aws_s3_bucket.results.arn}/*"]
  }

  statement {
    sid    = "AnalysisPrefixWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${data.aws_s3_bucket.results.arn}/analysis/*"]
  }
}

resource "aws_iam_role_policy" "results_bucket_rw_analysis" {
  name   = "${local.name_prefix}-results-bucket-rw-analysis"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.results_bucket_rw_analysis.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}
