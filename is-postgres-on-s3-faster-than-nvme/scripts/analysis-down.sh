#!/usr/bin/env bash
# Tear down the analysis workstation. The persistent bucket and any live
# benchmark infra in terraform/ are untouched.

source "$(dirname "$0")/_lib.sh"

REGION="${1:-us-east-2}"

require_tf

info "==> $TF destroy (analysis)"
"$TF" -chdir="$TF_DIR/analysis" destroy -auto-approve -var="region=$REGION"

info "==> Analysis workstation destroyed."
