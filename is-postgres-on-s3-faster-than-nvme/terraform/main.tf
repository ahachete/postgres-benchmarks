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
      Project  = "postgres-benchmark-s3-nvme"
      Scenario = var.scenario
      ManagedBy = "terraform"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "pgbench-${var.scenario}-${random_id.suffix.hex}"
  is_cluster  = var.cluster
  node_count  = var.cluster ? 3 : 1

  # Reserved for future S3-backed scenarios (kept as inert defaults so the
  # rest of the stack's plumbing — bucket creation, outputs, ansible inventory
  # JSON — keeps the same shape regardless of scenario).
  is_s3_scenario       = false
  is_express           = false
  is_standard_s3       = false
  needs_directory_bckt = false
}
