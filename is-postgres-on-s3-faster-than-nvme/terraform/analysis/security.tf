resource "aws_security_group" "this" {
  name        = "${local.name_prefix}-sg"
  description = "Analysis workstation: egress only (SSM is initiated outbound)"
  vpc_id      = aws_vpc.this.id

  # No ingress — operator access via AWS SSM Session Manager.

  egress {
    description = "All egress (SSM, apt, S3, nixos.org, github.com, ...)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg" }
}
