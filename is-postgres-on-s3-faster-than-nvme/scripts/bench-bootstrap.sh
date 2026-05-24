#!/usr/bin/env bash
# Create (or update, if exists) the long-lived results bucket via
# terraform/persistent/. Idempotent — safe to run any time.

source "$(dirname "$0")/_lib.sh"

REGION="${1:-us-east-2}"

require_tf

PERSISTENT_DIR="$TF_DIR/persistent"

info "==> $TF init (persistent)"
"$TF" -chdir="$PERSISTENT_DIR" init -upgrade

info "==> $TF apply (persistent, region=$REGION)"
"$TF" -chdir="$PERSISTENT_DIR" apply -auto-approve -var="region=$REGION"

BUCKET=$("$TF" -chdir="$PERSISTENT_DIR" output -raw results_bucket)
info "==> Persistent results bucket: $BUCKET"
