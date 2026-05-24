#!/usr/bin/env bash
# bench-campaign.sh — run every remaining Phase 1 scenario back-to-back.
#
# For each scenario in $SCENARIOS:
#   1. make down            tear down whatever's currently up
#   2. make up SCENARIO=…   fresh provision from the baked AMI
#   3. make bench tpcb      (skipped for mountpoint, which fails by design)
#   4. make bench mixed     (skipped for mountpoint)
#
# Results upload to the LONG-LIVED s3://pgbench-results-<account>-<region>/
# bucket (managed by terraform/persistent/) and SURVIVE `make down`. Run
# `make bootstrap` once before starting the campaign so that bucket exists.
#
# After the script completes there is no live infra (final make down).
# All results stay in the persistent S3 bucket. To analyze:
#   make fetch SCENARIO=<s>      # pulls + runs analysis for one scenario, OR
#   aws s3 sync s3://pgbench-results-<acct>-<region>/results/  results/<tag>/
#   cd analysis && uv run compare-scenarios ../results/<tag>
#
# Total wall ≈ 11-13 hours for 6 working scenarios × 2 workloads + 1 docs failure.
# EC2 cost ≈ $20-25.
#
# Run from inside `nix-shell` so ansible-core has boto3 + botocore available.
# Use tmux/screen so the session survives laptop sleep:
#   nix-shell
#   tmux new-session -d -s campaign 'bash scripts/bench-campaign.sh 2>&1 | tee /tmp/campaign.out'
#   tmux attach -t campaign     # to peek; Ctrl-b d to detach

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="results/campaign-${CAMPAIGN_TS}"
mkdir -p "$CAMPAIGN_DIR"

# Phase 1 remaining scenarios. nvme-ext4 is already done (out of band).
# Order: NVMe pair first (fast, no daemon builds), mountpoint last (quick
# failure capture), S3-backed scenarios in the middle (each has a ~10 min
# cargo build for the daemon on first provision).
#
# Override via env var, e.g. to re-run just the S3-backed scenarios:
#   SCENARIOS="zerofs-standard zerofs-express slatedb-nbd-standard slatedb-nbd-express" \
#       bash scripts/bench-campaign.sh
if [[ -n "${SCENARIOS:-}" ]]; then
  # shellcheck disable=SC2206
  SCENARIOS=( $SCENARIOS )
else
  SCENARIOS=(
    nvme-zfs
    nvme-zfs-fpi
    zerofs-standard
    zerofs-express
    slatedb-nbd-standard
    slatedb-nbd-express
    mountpoint
  )
fi

declare -a SUMMARY=()

log() {
  printf '%s [campaign] %s\n' "$(date -Iseconds)" "$*" \
    | tee -a "$CAMPAIGN_DIR/campaign.log"
}

run_step() {
  # run_step <label> <logfile> <cmd…>
  #
  # BEWARE: do NOT use `if "$@"; then ...; fi; rc=$?` — after a false `if`
  # with no else, $? is 0 in bash. Capture the command's exit directly via
  # `cmd || rc=$?`, then branch on it.
  local label="$1" logfile="$2"
  shift 2
  log "  ▶ $label"
  local rc=0
  "$@" >>"$logfile" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    log "  ✓ $label"
  else
    log "  ✗ $label (rc=$rc) — see $logfile"
  fi
  return $rc
}

CAMPAIGN_START=$(date +%s)
log "=== Campaign start. Scenarios: ${SCENARIOS[*]} ==="

# Pre-flight: persistent results bucket must exist (make bootstrap).
if ! tofu -chdir=terraform/persistent output -raw results_bucket >/dev/null 2>&1; then
  log "✗ Persistent results bucket not found. Run 'make bootstrap' first."
  exit 1
fi
log "Results bucket: $(tofu -chdir=terraform/persistent output -raw results_bucket)"

for SCEN in "${SCENARIOS[@]}"; do
  SCEN_START=$(date +%s)
  log ""
  log "================================================================"
  log "Scenario: $SCEN"
  log "================================================================"
  SCEN_DIR="$CAMPAIGN_DIR/$SCEN"
  mkdir -p "$SCEN_DIR"

  # Down. Fine to fail on the first iteration (nothing to destroy).
  run_step "make down" "$SCEN_DIR/down.log" make down || true

  if ! run_step "make up SCENARIO=$SCEN" "$SCEN_DIR/up.log" \
        make up SCENARIO="$SCEN"; then
    SUMMARY+=("$SCEN: ✗ FAILED at make up — see $SCEN_DIR/up.log")
    continue
  fi

  # mountpoint scenario: provisioning itself captures the documented failure.
  if [[ "$SCEN" == "mountpoint" ]]; then
    local_min=$(( ($(date +%s) - SCEN_START) / 60 ))
    SUMMARY+=("$SCEN: ✓ provisioned (failure record captured) — ${local_min} min")
    continue
  fi

  WL_FAILED=""
  for WL in tpcb mixed; do
    if ! run_step "make bench WORKLOAD=$WL" "$SCEN_DIR/bench-$WL.log" \
          make bench SCENARIO="$SCEN" WORKLOAD="$WL"; then
      WL_FAILED="$WL"
      break
    fi
  done

  scen_min=$(( ($(date +%s) - SCEN_START) / 60 ))
  if [ -z "$WL_FAILED" ]; then
    SUMMARY+=("$SCEN: ✓ tpcb + mixed completed — ${scen_min} min")
  else
    SUMMARY+=("$SCEN: ✗ FAILED at $WL_FAILED (see $SCEN_DIR/bench-$WL_FAILED.log) — ${scen_min} min")
  fi
done

log ""
log "=== Final teardown ==="
run_step "make down" "$CAMPAIGN_DIR/down-final.log" make down || true

TOTAL_MIN=$(( ($(date +%s) - CAMPAIGN_START) / 60 ))

log ""
log "================================================================"
log "Campaign complete in ${TOTAL_MIN} min"
log "================================================================"
for line in "${SUMMARY[@]}"; do
  log "  $line"
done
log ""
log "Logs (local): $CAMPAIGN_DIR"
log "Results (S3): s3://$(tofu -chdir=terraform/persistent output -raw results_bucket)/results/"
log ""
log "To analyze a single scenario locally:"
log "  make fetch SCENARIO=<s>  # adds --clean-raw for low-disk hosts"
log ""
log "To analyze the whole campaign locally:"
log "  BUCKET=\$(tofu -chdir=terraform/persistent output -raw results_bucket)"
log "  aws s3 sync s3://\$BUCKET/results/ results/campaign-final/"
log "  cd analysis && uv sync && uv run compare-scenarios ../results/campaign-final"
log ""
log "To run analysis on a remote EC2 (e.g. for low local disk):"
log "  # Provision a small instance; aws-cli + uv-installed; aws s3 sync the bucket;"
log "  # rsync the analysis/ dir up; uv run compare-scenarios there."
