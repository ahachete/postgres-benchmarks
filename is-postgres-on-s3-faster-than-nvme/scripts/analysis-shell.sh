#!/usr/bin/env bash
# Open an interactive SSM session on the analysis workstation.

source "$(dirname "$0")/_lib.sh"

require_tf
require_ssm

ANALYSIS_DIR="$TF_DIR/analysis"

INSTANCE=$("$TF" -chdir="$ANALYSIS_DIR" output -raw instance_id 2>/dev/null || true)
REGION=$("$TF"  -chdir="$ANALYSIS_DIR" output -raw region      2>/dev/null || echo us-east-2)

if [ -z "$INSTANCE" ]; then
  err "No analysis instance found. Run 'make analysis-up' first."
  exit 1
fi

info "==> SSM session → $INSTANCE (region $REGION)"
aws ssm start-session --region "$REGION" --target "$INSTANCE"
