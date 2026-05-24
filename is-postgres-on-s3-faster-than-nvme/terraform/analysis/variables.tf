variable "region" {
  description = "AWS region. Must match terraform/persistent/ so the bucket lookup resolves."
  type        = string
  default     = "us-east-2"
}

variable "instance_type" {
  description = "EC2 instance type. c7i.4xlarge = 16 vCPU Sapphire Rapids, 32 GB RAM, ~$0.71/hr on-demand — comfortable for compare-scenarios over a 7-scenario campaign."
  type        = string
  default     = "c7i.4xlarge"
}

variable "root_volume_gb" {
  description = "Root EBS size. Needs to fit /nix/store (~10 GB) + one decompressed campaign (~15 GB) + analysis outputs."
  type        = number
  default     = 100
}

variable "use_spot" {
  description = "If true (default), request a spot instance. Override to false for one-shot runs you can't afford to have spot-interrupted mid-execution (e.g. a 60-min compare-scenarios job)."
  type        = bool
  default     = true
}
