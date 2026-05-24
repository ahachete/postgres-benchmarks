#!/usr/bin/env bash
# campaign-s3.sh — single-shot S3 campaign for the
# "Postgres on S3 vs NVMe" follow-up post.
#
# Phase 1 — single-node (CLUSTER=false), 8 runs:
#   zerofs-standard         (ZFS on NBD, recordsize=32K, FPW off, S3 Standard)
#   zerofs-express          (ZFS on NBD, recordsize=32K, FPW off, S3 Express OZ)
#   zerofs-standard-ext4    (ext4 on NBD, FPW on, S3 Standard)
#   zerofs-express-ext4     (ext4 on NBD, FPW on, S3 Express OZ)
#   × 2 workloads (tpcb, mixed)
#
# Phase 2 — 3-node sync-replicated cluster (CLUSTER=true), 8 runs:
#   same 4 scenarios × 2 workloads
#
# Per scenario: make down → make up → bench tpcb → bench mixed → done.
# On any exit (success or failure), trap fires `make down` so the campaign
# never leaves instances running.
#
# Defaults from the Makefile (64 clients × 16 jobs × scale 15000 × 1800s
# steady-state × 300s warmup) are deliberately the same as the NVMe campaign
# so cross-campaign comparisons are apples-to-apples.
#
# Run from inside `nix-shell` with AWS_PROFILE exported. Use tmux/screen
# so the session survives laptop sleep:
#   tmux new-session -d -s s3 'bash scripts/campaign-s3.sh 2>&1 | tee /tmp/campaign-s3.out'
#   tmux attach -t s3
#
# Estimated wallclock: 30-50 hours. pgbench init at scale=15000 against an
# S3-backed Postgres can take 60-120 min vs the 30 min it takes on NVMe;
# steady-state at 64 clients should run in the warm-cache regime once
# warmup completes.
# Estimated cost on i7i.4xlarge spot: ~$60-75 worst case.
#
# Results upload to the long-lived results bucket (terraform/persistent/).
# A manifest.tsv records phase|scenario|workload|s3_path so downstream
# analysis can disambiguate the multiple campaigns sharing the same scenario
# names.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="results/campaign-s3-${CAMPAIGN_TS}"
mkdir -p "$CAMPAIGN_DIR"

MANIFEST="$CAMPAIGN_DIR/manifest.tsv"
printf 'phase\tscenario\tworkload\tstart_ts_utc\tstop_ts_utc\tduration_sec\trc\ts3_path_hint\n' > "$MANIFEST"

# Defaults: full matrix. Override either list via env var to run a subset:
#   PHASE1_SCENARIOS="zerofs-standard zerofs-standard-ext4" PHASE2_SCENARIOS="" bash scripts/campaign-s3.sh
# An EXPLICIT empty value (PHASE1_SCENARIOS="") skips that whole phase.
#
# We use `${VAR+x}` instead of `${VAR:-}` here: the former is set-or-not,
# the latter conflates unset and empty-string. With `:-` an explicit
# empty fall-through to the default — which silently runs the full matrix
# even though the operator asked for nothing. Use `+x` so empty = skip.
if [[ -n "${PHASE1_SCENARIOS+x}" ]]; then
  # shellcheck disable=SC2206
  PHASE1_SCENARIOS=( $PHASE1_SCENARIOS )
else
  PHASE1_SCENARIOS=(zerofs-standard zerofs-express zerofs-standard-ext4 zerofs-express-ext4)
fi
if [[ -n "${PHASE2_SCENARIOS+x}" ]]; then
  # shellcheck disable=SC2206
  PHASE2_SCENARIOS=( $PHASE2_SCENARIOS )
else
  PHASE2_SCENARIOS=(zerofs-standard zerofs-express zerofs-standard-ext4 zerofs-express-ext4)
fi
WORKLOADS=(tpcb mixed)

declare -a SUMMARY=()

log() {
  printf '%s [campaign-s3] %s\n' "$(date -Iseconds)" "$*" \
    | tee -a "$CAMPAIGN_DIR/campaign.log"
}

run_step() {
  # run_step <label> <logfile> <cmd…>
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

# Safety net: tear down on any exit so failures (and a Ctrl-C) don't leave
# instances running.
cleanup_on_exit() {
  log ""
  log "==> EXIT trap: final teardown (no-op if already down)"
  make down >>"$CAMPAIGN_DIR/down-final.log" 2>&1 || true
}
trap cleanup_on_exit EXIT

# Pre-flight
if ! tofu -chdir=terraform/persistent output -raw results_bucket >/dev/null 2>&1; then
  log "✗ Persistent results bucket not found. Run 'make bootstrap' first."
  exit 1
fi
BUCKET="$(tofu -chdir=terraform/persistent output -raw results_bucket)"
log "Results bucket: $BUCKET"

run_scenario() {
  local phase="$1" cluster="$2" scen="$3"
  local scen_start scen_end
  scen_start=$(date +%s)
  log ""
  log "================================================================"
  log "[$phase] Scenario: $scen (cluster=$cluster)"
  log "================================================================"
  local scen_dir="$CAMPAIGN_DIR/${phase}-${scen}"
  mkdir -p "$scen_dir"

  # Down. Fine if nothing's up (first iteration, or prior scenario's down).
  run_step "make down" "$scen_dir/down.log" make down || true

  # First make-up attempt.
  if ! run_step "make up SCENARIO=$scen CLUSTER=$cluster" "$scen_dir/up.log" \
        make up SCENARIO="$scen" CLUSTER="$cluster"; then
    # Retry once — covers transient failures (Ansible SSM connection plugin
    # wedge, spot capacity flicker, etc.). Tear down stale partial state
    # first to start from a clean slate.
    log "  ⟳ retrying make up after first failure"
    run_step "make down (pre-retry)" "$scen_dir/down-retry.log" make down || true
    if ! run_step "make up SCENARIO=$scen CLUSTER=$cluster (retry)" "$scen_dir/up-retry.log" \
          make up SCENARIO="$scen" CLUSTER="$cluster"; then
      SUMMARY+=("[$phase] $scen: ✗ FAILED at make up (both attempts) — see $scen_dir/up.log and $scen_dir/up-retry.log")
      return 1
    fi
  fi

  local wl_failed=""
  for wl in "${WORKLOADS[@]}"; do
    local wl_start_iso wl_stop_iso wl_start_s wl_stop_s wl_rc=0
    wl_start_iso=$(date -u +%Y%m%dT%H%M%SZ)
    wl_start_s=$(date +%s)
    run_step "make bench WORKLOAD=$wl" "$scen_dir/bench-$wl.log" \
        make bench SCENARIO="$scen" WORKLOAD="$wl" || wl_rc=$?
    wl_stop_iso=$(date -u +%Y%m%dT%H%M%SZ)
    wl_stop_s=$(date +%s)

    # Record in manifest regardless of success/failure. s3_path_hint is
    # extracted from the "Uploading artifacts to s3://…" line printed by
    # bench-run.sh so analysis tooling can map run dirs to runs.
    local s3_hint
    s3_hint=$(grep -oE "s3://${BUCKET}/results/${scen}/${wl}/[0-9TZ]+/" "$scen_dir/bench-$wl.log" 2>/dev/null | tail -1)
    [ -z "$s3_hint" ] && s3_hint="s3://${BUCKET}/results/${scen}/${wl}/<ts between ${wl_start_iso} and ${wl_stop_iso}>"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n' \
        "$phase" "$scen" "$wl" "$wl_start_iso" "$wl_stop_iso" \
        "$(( wl_stop_s - wl_start_s ))" "$wl_rc" "$s3_hint" \
        >> "$MANIFEST"

    if [[ $wl_rc -ne 0 ]]; then
      wl_failed="$wl"
      break
    fi
  done

  scen_end=$(date +%s)
  local scen_min=$(( (scen_end - scen_start) / 60 ))
  if [ -z "$wl_failed" ]; then
    SUMMARY+=("[$phase] $scen: ✓ tpcb + mixed completed — ${scen_min} min")
  else
    SUMMARY+=("[$phase] $scen: ✗ FAILED at $wl_failed (see $scen_dir/bench-$wl_failed.log) — ${scen_min} min")
  fi
}

CAMPAIGN_START=$(date +%s)
log "=== Campaign start ==="
log "Phase 1 (single-node, CLUSTER=false): ${PHASE1_SCENARIOS[*]}"
log "Phase 2 (3-node,      CLUSTER=true):  ${PHASE2_SCENARIOS[*]}"
log "Workloads:                            ${WORKLOADS[*]}"
log "Per-run defaults (from Makefile):     CLIENTS=64 JOBS=16 SCALE=15000 DURATION=1800 WARMUP=300"
log "Manifest:                             $MANIFEST"

log ""
log "################## PHASE 1: single-node ##################"
for scen in "${PHASE1_SCENARIOS[@]}"; do
  run_scenario phase1 false "$scen" || true
done

log ""
log "################## PHASE 2: 3-node cluster ##################"
for scen in "${PHASE2_SCENARIOS[@]}"; do
  run_scenario phase2 true "$scen" || true
done

TOTAL_MIN=$(( ($(date +%s) - CAMPAIGN_START) / 60 ))

log ""
log "================================================================"
log "Campaign complete in ${TOTAL_MIN} min"
log "================================================================"
for line in "${SUMMARY[@]}"; do
  log "  $line"
done
log ""
log "Manifest:    $MANIFEST"
log "Local logs:  $CAMPAIGN_DIR"
log "Results S3:  s3://$BUCKET/results/"
log ""
log "To analyze on the in-region analysis box (recommended — large S3 pulls):"
log "  make analysis-up"
log "  aws s3 cp $MANIFEST s3://$BUCKET/manifests/campaign-s3-${CAMPAIGN_TS}.tsv"
log "  # then ssm in and run scripts/analysis-on-box.sh with CAMPAIGN_TS=s3-${CAMPAIGN_TS}"
