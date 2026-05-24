resource "aws_security_group" "this" {
  name        = "${local.name_prefix}-sg"
  description = "Postgres benchmark: SSM-only operator access, intra-cluster Postgres replication"
  vpc_id      = aws_vpc.this.id

  # No SSH ingress — operator access is via AWS SSM Session Manager.
  # SSM is initiated outbound from the instance to the SSM endpoints
  # (covered by egress-all below), so the operator never needs an open port.

  ingress {
    description = "Postgres replication, intra-VPC only"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All egress (SSM agent, apt, S3, PGDG, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg" }
}
