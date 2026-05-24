#!/usr/bin/env bash
# Bring up infrastructure (Terraform) and provision software (Ansible).
#
# Usage:
#   bench-up.sh <scenario> <cluster:true|false> [region] [--provision-only]

source "$(dirname "$0")/_lib.sh"

SCENARIO="${1:?usage: bench-up.sh <scenario> <cluster> [region] [--provision-only]}"
CLUSTER="${2:?cluster (true|false) required}"
REGION="${3:-us-east-1}"
PROVISION_ONLY=false

if [[ "${4:-}" == "--provision-only" ]]; then
  PROVISION_ONLY=true
fi

require_tf
require_ssm
require_ansible_with_boto3

# The per-scenario terraform pulls the results bucket via a data source.
# If the persistent root wasn't bootstrapped, the data lookup fails with
# an opaque "no matching bucket" — pre-flight check gives a better hint.
if ! "$TF" -chdir="$TF_DIR/persistent" output -raw results_bucket >/dev/null 2>&1; then
  err "Persistent results bucket not found in terraform/persistent/ state."
  err "Run 'make bootstrap' first (one-time, idempotent)."
  exit 1
fi

# ---- Infra (tofu / terraform) ---------------------------------------------
if [[ "$PROVISION_ONLY" != true ]]; then
  info "==> $TF init"
  "$TF" -chdir="$TF_DIR" init -upgrade

  info "==> $TF apply (scenario=$SCENARIO cluster=$CLUSTER region=$REGION instance_type=${INSTANCE_TYPE:-i7i.4xlarge} use_spot=${USE_SPOT:-true})"
  TF_VARS=(
    -var="scenario=$SCENARIO"
    -var="cluster=$CLUSTER"
    -var="region=$REGION"
    -var="budget_limit_usd=${BUDGET_USD:-30}"
    -var="budget_alert_email=${BUDGET_EMAIL:-}"
    -var="use_spot=${USE_SPOT:-true}"
  )
  if [[ -n "${INSTANCE_TYPE:-}" ]]; then
    TF_VARS+=(-var="instance_type=$INSTANCE_TYPE")
  fi
  "$TF" -chdir="$TF_DIR" apply -auto-approve "${TF_VARS[@]}"
fi

ssm_wait_ready

# ---- Ansible ---------------------------------------------------------------
if [[ ! -d "$ANSIBLE_DIR/.collections/ansible_collections/community/general" ]]; then
  info "==> ansible-galaxy collection install (one-time)"
  ansible-galaxy collection install \
      -p "$ANSIBLE_DIR/.collections" \
      -r "$ANSIBLE_DIR/requirements.yml"
fi

info "==> ansible-playbook site.yml (scenario=$SCENARIO)"
(cd "$ANSIBLE_DIR" && ansible-playbook site.yml)

INSTANCE="$(primary_instance_id)"
REGION="$(aws_region)"
info "==> Up: scenario=$SCENARIO"
info "    SSM: aws ssm start-session --region $REGION --target $INSTANCE"
