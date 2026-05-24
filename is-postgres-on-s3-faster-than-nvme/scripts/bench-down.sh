#!/usr/bin/env bash
# Tear down all infrastructure.

source "$(dirname "$0")/_lib.sh"

require_tf

info "==> $TF destroy"
"$TF" -chdir="$TF_DIR" destroy -auto-approve
info "==> destroyed"
