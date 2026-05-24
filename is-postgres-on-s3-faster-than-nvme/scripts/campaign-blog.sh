#!/usr/bin/env bash
# campaign-blog.sh — single-shot 2-phase campaign for the
# "Postgres on NVMe: ext4 vs ZFS, single-node vs 3-AZ HA" blog post.
#
# Phase 1 — single-node (CLUSTER=false), ~10h:
#   nvme-ext4     — ext4 baseline (FPW=on)
#   nvme-zfs      — ZFS striped pool, recordsize=32K, FPW=off (CoW-safe)
#   nvme-zfs-fpi  — same as nvme-zfs but FPW=on (cost-of-FPW datapoint)
#
# Phase 2 — 3-node sync-replicated cluster (CLUSTER=true), ~4h:
#   nvme-ext4     — ext4 in HA (FPW=on)
#   nvme-zfs      — ZFS in HA (FPW=off, optimized)
#
# Per scenario:
#   - make down (idempotent — no-op if nothing is up)
#   - make up SCENARIO=<s> CLUSTER=<c>
#   - make bench WORKLOAD=tpcb
#   - make bench WORKLOAD=mixed
# Between scenarios, make down. On any exit (success or failure), trap fires
# a final make down so the campaign never leaves instances running.
#
# Run from inside `nix-shell` (so ansible-core has boto3/botocore) and with
# AWS_PROFILE exported. Use tmux/screen so the session survives laptop sleep:
#   tmux new-session -d -s blog 'bash scripts/campaign-blog.sh 2>&1 | tee /tmp/campaign-blog.out'
#   tmux attach -t blog        # peek; Ctrl-b d to detach
#
# Results upload to the long-lived results bucket (managed by
# terraform/persistent/). S3 layout doesn't encode phase, so the campaign
# writes a manifest.tsv recording phase|scenario|workload|timestamp|s3_path
# for unambiguous downstream analysis. Run `make bootstrap` once before
# starting.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="results/campaign-blog-${CAMPAIGN_TS}"
mkdir -p "$CAMPAIGN_DIR"

MANIFEST="$CAMPAIGN_DIR/manifest.tsv"
printf 'phase\tscenario\tworkload\tstart_ts_utc\tstop_ts_utc\tduration_sec\trc\ts3_path_hint\n' > "$MANIFEST"

PHASE1_SCENARIOS=(nvme-ext4 nvme-zfs nvme-zfs-fpi)
PHASE2_SCENARIOS=(nvme-ext4 nvme-zfs)
WORKLOADS=(tpcb mixed)

declare -a SUMMARY=()

log() {
  printf '%s [campaign-blog] %s\n' "$(date -Iseconds)" "$*" \
    | tee -a "$CAMPAIGN_DIR/campaign.log"
}

run_step() {
  # run_step <label> <logfile> <cmd…>
  # After `if cmd; then …; fi` with no else, $? is 0 in bash — capture rc
  # directly via `|| rc=$?`, then branch on it.
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

# Safety net: tear down on any exit so failures don't leave instances running.
cleanup_on_exit() {
  log ""
  log "==> EXIT trap: final teardown (no-op if already down)"
  make down >>"$CAMPAIGN_DIR/down-final.log" 2>&1 || true
}
trap cleanup_on_exit EXIT

# Pre-flight: persistent results bucket must exist (make bootstrap).
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

  if ! run_step "make up SCENARIO=$scen CLUSTER=$cluster" "$scen_dir/up.log" \
        make up SCENARIO="$scen" CLUSTER="$cluster"; then
    SUMMARY+=("[$phase] $scen: ✗ FAILED at make up — see $scen_dir/up.log")
    return 1
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

    # Record in manifest regardless of success/failure so we know what happened.
    # s3_path_hint is "results/<scenario>/<workload>/<timestamp-in-this-window>/"
    # — the actual timestamp is bench-run.sh's, embedded in the upload path
    # printed to bench-$wl.log; we grep it out to make the hint exact.
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
log "To analyze on the in-region analysis box (recommended for large pulls):"
log "  make analysis-up"
log "  # in the SSM session, in nix-shell, on the analysis box:"
log "  aws s3 sync s3://$BUCKET/results/ ../results/campaign-blog-${CAMPAIGN_TS}/"
log "  # then group by phase using $(basename "$MANIFEST")"
