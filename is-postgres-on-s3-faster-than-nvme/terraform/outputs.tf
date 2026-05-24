output "scenario" {
  description = "Active scenario."
  value       = var.scenario
}

output "scenario_family" {
  description = "Scenario family with the recordsize suffix stripped (e.g. nvme-zfs-rec32k → nvme-zfs)."
  value       = replace(var.scenario, "/-rec[0-9]+k$/", "")
}

output "s3_class" {
  description = "S3 storage class for this scenario: 'standard', 'express', or '' for nvme-only."
  value       = local.is_express ? "express" : (local.is_standard_s3 ? "standard" : "")
}

output "cluster" {
  description = "Whether this is a 3-node cluster (Phase 2) or single node (Phase 1)."
  value       = var.cluster
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "az_id" {
  description = "AZ-id of the primary node (e.g. use1-az1). Used for Express bucket placement and endpoint."
  value       = local.az_ids[0]
}

output "bench_bucket" {
  description = "Bucket name the storage daemon should connect to. For Express scenarios this is the directory bucket; for everything else it's the standard bucket (used at minimum for result-artifact storage)."
  value       = local.is_express ? aws_s3_directory_bucket.express[0].bucket : aws_s3_bucket.standard.bucket
}

output "results_bucket" {
  description = "Long-lived persistent bucket for run artifacts (terraform/persistent/). Survives `make down`."
  value       = data.aws_s3_bucket.results.bucket
}

output "s3_endpoint_url" {
  description = "Explicit endpoint URL for the storage daemon. Empty for Standard (default SDK behavior); set for Express."
  value       = local.is_express ? "https://s3express-${local.az_ids[0]}.${var.region}.amazonaws.com" : ""
}

output "primary_instance_id" {
  description = "EC2 instance ID of the primary node — use as the --target for `aws ssm start-session`."
  value       = aws_instance.node[0].id
}

output "replica_instance_ids" {
  description = "EC2 instance IDs of replica nodes (cluster mode only)."
  value       = local.is_cluster ? [for i in [1, 2] : aws_instance.node[i].id] : []
}

output "ssm_session_command" {
  description = "Copy-paste shell command to open an SSM session against the primary node."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.node[0].id}"
}

output "primary_public_ip" {
  description = "Public IP of the primary node (for diagnostics; SSM does not require it)."
  value       = aws_instance.node[0].public_ip
}

output "primary_private_ip" {
  description = "Private IP of the primary node."
  value       = aws_instance.node[0].private_ip
}

output "replica_public_ips" {
  description = "Public IPs of replica nodes (cluster mode only; empty list otherwise)."
  value       = local.is_cluster ? [for i in [1, 2] : aws_instance.node[i].public_ip] : []
}

output "replica_private_ips" {
  description = "Private IPs of replica nodes (cluster mode only)."
  value       = local.is_cluster ? [for i in [1, 2] : aws_instance.node[i].private_ip] : []
}

output "budget_limit_usd" {
  description = "Active monthly AWS Budgets cap (0 if disabled)."
  value       = var.budget_limit_usd
}

# JSON-shaped output used by ansible/inventory.py — keep the schema stable.
output "ansible_inventory" {
  description = "Structured inventory consumed by ansible/inventory.py."
  value = {
    scenario        = var.scenario
    scenario_family = replace(var.scenario, "/-rec[0-9]+k$/", "")
    s3_class        = local.is_express ? "express" : (local.is_standard_s3 ? "standard" : "")
    s3_endpoint_url = local.is_express ? "https://s3express-${local.az_ids[0]}.${var.region}.amazonaws.com" : ""
    cluster         = var.cluster
    region          = var.region
    az_id           = local.az_ids[0]
    bucket          = local.is_express ? aws_s3_directory_bucket.express[0].bucket : aws_s3_bucket.standard.bucket
    results_bucket  = data.aws_s3_bucket.results.bucket
    nodes = [
      for i, inst in aws_instance.node : {
        role        = local.node_roles[i]
        public_ip   = inst.public_ip
        private_ip  = inst.private_ip
        az          = local.azs[i]
        az_id       = local.az_ids[i]
        instance_id = inst.id
      }
    ]
  }
}
