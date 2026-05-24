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

  # Whether this scenario uses S3 at all, and which class (Standard / Express).
  # `is_express` matches both `*-express` and `*-express-ext4` — the FS-layer
  # suffix doesn't change the S3 tier.
  is_s3_scenario       = contains(["zerofs-standard", "zerofs-express", "zerofs-standard-ext4", "zerofs-express-ext4", "mountpoint"], var.scenario)
  is_express           = strcontains(var.scenario, "-express")
  is_standard_s3       = local.is_s3_scenario && !local.is_express
  needs_directory_bckt = local.is_express
}
