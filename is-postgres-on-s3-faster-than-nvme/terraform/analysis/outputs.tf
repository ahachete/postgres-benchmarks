output "instance_id" {
  description = "EC2 instance ID. Use as --target for `aws ssm start-session`."
  value       = aws_instance.analysis.id
}

output "region" {
  value = var.region
}

output "ssm_session_command" {
  description = "Copy-paste shell command to open an SSM session against the analysis box."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.analysis.id}"
}

output "public_ip" {
  description = "Public IP (diagnostics only; SSM does not require it)."
  value       = aws_instance.analysis.public_ip
}

output "results_bucket" {
  description = "Persistent results bucket the box can read from."
  value       = data.aws_s3_bucket.results.bucket
}
