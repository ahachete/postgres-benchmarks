data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  node_roles = local.is_cluster ? ["primary", "replica1", "replica2"] : ["primary"]
  # Prefer the operator-baked AMI (var.base_ami_id, typically populated by
  # `make bake` into ami.auto.tfvars) so subsequent launches skip the heavy
  # apt-install half. Fall back to the latest Canonical Ubuntu 24.04 image
  # when no baked AMI is set — the bake itself runs against this fallback.
  ami_id = var.base_ami_id != "" ? var.base_ami_id : data.aws_ami.ubuntu_2404.id
}

resource "aws_instance" "node" {
  count = local.node_count

  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # 1-minute granularity CloudWatch metrics (CPU, network, EBS, status).
  # ~$2.10/instance/month extra; useful for at-a-glance health during the
  # 10-hour campaigns and for post-mortem after the EC2 is destroyed.
  monitoring = true

  # Spot pricing — typically 60-80% cheaper than on-demand on i7i. Trade-offs
  # we accept here:
  #   - `max_price` omitted → AWS caps at the on-demand price, so we never
  #     pay more than the regular rate, only less when capacity allows.
  #   - `spot_instance_type = "one-time"` keeps the lifecycle owned by this
  #     terraform state (a "persistent" request would silently re-launch
  #     after interruption, diverging from state).
  #   - Interruption behaviour = terminate. Mid-bench interruptions kill the
  #     in-flight run, but all completed results live in the persistent S3
  #     bucket and `results/campaign-blog-*/manifest.tsv` records which
  #     scenarios succeeded, so resuming = re-running just the failed ones.
  #   - HA cluster runs request 3 spot instances atomically across 3 AZs;
  #     if any AZ is short on capacity, the whole apply fails — never a
  #     partial cluster. Retry usually works on the next attempt.
  #   - AMI bake (one-shot, ~10 min) is also on spot; an interruption mid-
  #     bake forces `make bake` to be re-run. Probability is low and cost
  #     is bounded; not worth a separate code path.
  #
  # Wrapped in a `dynamic` block so `var.use_spot = false` falls back to
  # on-demand. Use the fallback when the account's spot vCPU quota is
  # below what a cluster run needs (e.g. quota ≤ 32 vCPU and a 3-node
  # i7i.4xlarge cluster needs 48 vCPU → MaxSpotInstanceCountExceeded).
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    iops        = 3000
    throughput  = 125
    encrypted   = true
    tags = {
      Name = "${local.name_prefix}-${local.node_roles[count.index]}-root"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = {
    Name = "${local.name_prefix}-${local.node_roles[count.index]}"
    Role = local.node_roles[count.index]
  }
}
