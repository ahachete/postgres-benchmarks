#!/usr/bin/env bash
# Tear down EVERYTHING including the persistent results bucket.
# `make down` tears down only the per-scenario infra.

source "$(dirname "$0")/_lib.sh"

REGION="${1:-us-east-2}"

require_tf

info "==> $TF destroy (per-scenario)"
"$TF" -chdir="$TF_DIR" destroy -auto-approve || warn "per-scenario destroy reported errors — continuing"

info "==> $TF destroy (persistent results bucket)"
"$TF" -chdir="$TF_DIR/persistent" destroy -auto-approve -var="region=$REGION"

info "==> All infrastructure destroyed."
