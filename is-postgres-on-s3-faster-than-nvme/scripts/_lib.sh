#!/usr/bin/env bash
# Shared helpers for the bench-* scripts. Source from each script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible"
RESULTS_DIR="$REPO_ROOT/results"

# Pick OpenTofu over Terraform when both are present. Override via TF=... env
# (e.g. TF=terraform make up) if you need to force one.
if [[ -z "${TF:-}" ]]; then
  if   command -v tofu      >/dev/null 2>&1; then TF=tofu
  elif command -v terraform >/dev/null 2>&1; then TF=terraform
  else TF=tofu  # let the require() check fail loudly with a useful message
  fi
fi
export TF

# Share provider plugins across terraform roots so we don't carry two copies
# of the ~700 MB AWS provider (terraform/ + terraform/persistent/ = 1.4 GB
# without this). tofu/terraform hard-link plugins from this cache instead of
# downloading per-root.
if [[ -z "${TF_PLUGIN_CACHE_DIR:-}" ]]; then
  export TF_PLUGIN_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tofu-plugins"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
fi

color_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
color_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

err()  { color_red   "ERROR: $*" >&2; }
warn() { color_yellow "WARN: $*"  >&2; }
info() { color_green "$*"; }

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || {
      err "$tool not found in PATH"
      exit 1
    }
  done
}

require_tf() {
  command -v "$TF" >/dev/null 2>&1 || {
    err "neither 'tofu' nor 'terraform' found in PATH (set TF=... to force)"
    exit 1
  }
}

require_ssm() {
  require aws
  command -v session-manager-plugin >/dev/null 2>&1 || {
    err "session-manager-plugin not found. Install from https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    exit 1
  }
}

# Ansible's Python (the interpreter that ansible-playbook itself runs under)
# must have boto3 + botocore — the community.aws.aws_ssm connection plugin
# imports them in the controller-side process. Verify upfront so we fail
# loudly here rather than mid-playbook.
require_ansible_with_boto3() {
  command -v ansible-playbook >/dev/null 2>&1 || {
    err "ansible-playbook not found. Run inside nix-shell (see shell.nix) or install ansible-core ≥ 2.16."
    exit 1
  }

  # Extract Ansible's Python interpreter path from `ansible-playbook --version`
  # output. The "python version = ..." line ends with the interpreter path in
  # parentheses, e.g.:
  #     python version = 3.13.11 (main, Dec  5 2025, 16:06:33) [GCC 15.2.0] (/nix/store/…/python3.13)
  # Splitting on '(' / ')' and taking the second-to-last field gives the path
  # robustly — works on Nix (where ansible-core and the python interpreter live
  # in DIFFERENT store paths), pip-installed venvs, and system packages alike.
  local ansible_py
  ansible_py=$(ansible-playbook --version 2>/dev/null \
      | awk -F'[()]' '/python version/ { print $(NF-1) }')

  [[ -x "$ansible_py" ]] || {
    err "could not locate Ansible's Python interpreter from \`ansible-playbook --version\`."
    exit 1
  }

  "$ansible_py" -c 'import boto3, botocore' 2>/dev/null || {
    err "boto3 / botocore not importable by Ansible's Python ($ansible_py)."
    err "  On Nix:    nix-shell  (then re-run make from inside)"
    err "  Otherwise: pip install boto3 botocore  into the venv that hosts ansible-core"
    exit 1
  }
}

tf_output_json() {
  local key="${1:?key required}"
  "$TF" -chdir="$TF_DIR" output -json "$key"
}

tf_output_raw() {
  local key="${1:?key required}"
  "$TF" -chdir="$TF_DIR" output -raw "$key"
}

primary_instance_id() {
  tf_output_raw primary_instance_id
}

primary_ip() {
  tf_output_raw primary_public_ip
}

aws_region() {
  tf_output_raw region
}

results_bucket() {
  # Prefer the persistent state's output (terraform/persistent/) so the
  # function still works after `make down` has torn down the per-scenario
  # state. Fall back to per-scenario output only if persistent isn't set up.
  local from_persistent
  from_persistent=$("$TF" -chdir="$TF_DIR/persistent" output -raw results_bucket 2>/dev/null || true)
  if [ -n "$from_persistent" ]; then
    echo "$from_persistent"
    return
  fi
  tf_output_raw results_bucket
}

scenario_from_state() {
  tf_output_raw scenario
}

# Wait until ALL bench instances (primary + any replicas in cluster mode)
# are registered with SSM. In cluster mode, replicas often register a few
# seconds after the primary; without waiting on each one, ansible's first
# task on the laggard replica fails with `TargetNotConnected` because the
# SSM agent hasn't called home yet.
ssm_wait_ready() {
  local region primary replicas_json instance_ids inst
  region="$(aws_region)"
  primary="$(primary_instance_id)"
  # replica_instance_ids is `[]` for single-node, a 2-element list for cluster.
  replicas_json=$("$TF" -chdir="$TF_DIR" output -json replica_instance_ids 2>/dev/null || echo '[]')
  # shellcheck disable=SC2207
  instance_ids=( "$primary" $(echo "$replicas_json" | jq -r '.[]' 2>/dev/null) )

  for inst in "${instance_ids[@]}"; do
    info "==> Waiting for SSM agent on $inst"
    local ready=false
    for _ in $(seq 1 60); do
      local state
      state=$(aws ssm describe-instance-information \
          --region "$region" \
          --filters "Key=InstanceIds,Values=$inst" \
          --query 'InstanceInformationList[0].PingStatus' \
          --output text 2>/dev/null || echo None)
      if [[ "$state" == "Online" ]]; then
        info "    $inst SSM Online"
        ready=true
        break
      fi
      sleep 5
    done
    if ! $ready; then
      err "SSM agent never came online for $inst"
      return 1
    fi
  done
}

# Run a command (multi-line OK) on the primary via SSM, streaming output.
# Usage: ssm_run_on_primary "cmd; cmd; ..."
ssm_run_on_primary() {
  local instance_id region cmd_id rc params
  instance_id="$(primary_instance_id)"
  region="$(aws_region)"

  # Build the parameters as full JSON. The shorthand `commands=[…]` form
  # mangles embedded newlines, leaving `set -eu\naws…` as one literal line
  # on the host (dash then complains about `-eunaws…` as a flag string).
  params=$(jq -n --arg cmd "$1" '{commands:[$cmd]}')

  cmd_id=$(aws ssm send-command \
      --region "$region" \
      --instance-ids "$instance_id" \
      --document-name AWS-RunShellScript \
      --parameters "$params" \
      --output text --query Command.CommandId)

  info "    SSM command-id: $cmd_id  (polling…)"

  # Poll until done; stream stdout when available.
  while :; do
    local status
    status=$(aws ssm get-command-invocation \
        --region "$region" \
        --instance-id "$instance_id" \
        --command-id "$cmd_id" \
        --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) rc=0; break ;;
      Failed|Cancelled|TimedOut) rc=1; break ;;
      *) sleep 5 ;;
    esac
  done

  aws ssm get-command-invocation \
      --region "$region" \
      --instance-id "$instance_id" \
      --command-id "$cmd_id" \
      --query StandardOutputContent --output text

  if [[ $rc -ne 0 ]]; then
    err "command failed (status=$status)"
    aws ssm get-command-invocation \
        --region "$region" \
        --instance-id "$instance_id" \
        --command-id "$cmd_id" \
        --query StandardErrorContent --output text >&2
  fi
  return $rc
}
