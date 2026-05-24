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

# user_data: install Nix (Determinate, daemon mode) + git + aws CLI v2.
# Runs as root once, on first boot. Subsequent SSM sessions get a ready
# system; the operator just clones the repo and `nix-shell`s into the
# project's dev shell.
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Operational basics.
    apt-get update -y
    apt-get install -y --no-install-recommends git curl ca-certificates xz-utils zstd unzip

    # AWS CLI v2 (ubuntu 24.04 doesn't ship awscli; we need v2 for S3 Express
    # support and for parity with the benchmark instances).
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install --update
    rm -rf /tmp/aws /tmp/awscliv2.zip

    # Nix (Determinate installer, daemon mode). Adds /etc/profile.d/nix.sh
    # so login shells (including ssm-user's) get nix on PATH.
    curl -fsSL https://install.determinate.systems/nix \
        | sh -s -- install linux --no-confirm --determinate

    # Pre-warm common Nix substitutes so the first `nix-shell` in the repo
    # doesn't sit for 5 min downloading the world. Best-effort; failures
    # here don't block.
    sudo -i -u root bash -c '. /etc/profile.d/nix.sh && \
        nix-channel --update || true' || true

    echo "user_data complete at $(date -Iseconds)" > /var/log/user_data.done
  EOF
}

resource "aws_instance" "analysis" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  monitoring = true
  user_data  = local.user_data
  # Re-create the instance if the user_data changes (it captures the
  # full bootstrap script).
  user_data_replace_on_change = true

  # Spot — analysis workstation is cheap to re-provision (`make analysis-up`
  # re-runs user_data; Nix/uv install in ~3-5 min). Mid-analysis interruption
  # just means re-running the analysis driver, which is idempotent against
  # the S3-hosted result tree. See terraform/ec2.tf for the longer rationale.
  #
  # `use_spot = false` falls back to on-demand for runs that can't tolerate
  # mid-flight interruption (we saw the analysis-on-box driver get killed
  # by Server.SpotInstanceTermination ~30 min in once).
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
    volume_size = var.root_volume_gb
    iops        = 3000
    throughput  = 250
    encrypted   = true
    tags = {
      Name = "${local.name_prefix}-root"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = {
    Name = local.name_prefix
    Role = "analysis"
  }
}
