#!/usr/bin/env bash
# Kick off a benchmark run on the primary EC2 instance via AWS SSM.

source "$(dirname "$0")/_lib.sh"

SCENARIO=""
WORKLOAD=""
SCALE=15000
DURATION=1800
WARMUP=300
CLIENTS=64
JOBS=16

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --workload) WORKLOAD="$2"; shift 2 ;;
    --scale)    SCALE="$2";    shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --warmup)   WARMUP="$2";   shift 2 ;;
    --clients)  CLIENTS="$2";  shift 2 ;;
    --jobs)     JOBS="$2";     shift 2 ;;
    *) err "unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$SCENARIO" ]] || { err "--scenario required"; exit 2; }
[[ -n "$WORKLOAD" ]] || { err "--workload required"; exit 2; }

if [[ "$SCENARIO" == "mountpoint" ]]; then
  warn "Scenario 'mountpoint' is the documented-failure case — no benchmark will run."
  warn "The provisioning step already captured the failure to /opt/bench/mountpoint_failure.json."
  warn "Run 'make fetch SCENARIO=mountpoint' to retrieve it."
  exit 0
fi

require_tf
require_ssm
require jq

INSTANCE="$(primary_instance_id)"
REGION="$(aws_region)"

info "==> Running benchmark on $INSTANCE via SSM"
info "    scenario=$SCENARIO workload=$WORKLOAD scale=$SCALE duration=${DURATION}s"
info "    warmup=${WARMUP}s clients=$CLIENTS jobs=$JOBS"

# SSM send-command has a 48-hour max execution time but get-command-invocation
# polling is what gates us. Long-running commands are fine; we just poll
# the status until terminal.
# Three-phase orchestration for a fully cold-cache, pristine-data start:
#
#   1. Drop Linux caches → run pgbench -i + VACUUM as postgres (fills SB and
#      OS PC during init; we'll flush them again in phase 2).
#   2. systemctl stop postgres → sync → drop_caches → systemctl start postgres
#      → wait for ready. After this both shared_buffers and OS PC are EMPTY.
#   3. run.sh --skip-init: pg_stat_reset, background collectors, warmup,
#      pg_stat_reset, steady-state, capture, S3 upload.
#
# The cold-restart needs root (systemctl + /proc/sys/vm/drop_caches), which
# is fine because the outer SSM command runs as root and only the inner
# pgbench/psql work runs as postgres via `sudo -u`.
CMD="set -eu

echo '=== Phase 1: drop caches + pgbench -i + VACUUM ==='
sync
echo 3 > /proc/sys/vm/drop_caches
sudo -u postgres pgbench -i -s '$SCALE' --no-vacuum --foreign-keys -d bench
if [ '$WORKLOAD' = 'mixed' ]; then
    sudo -u postgres psql -d bench -f /opt/bench/workloads/init_mixed.sql
fi
sudo -u postgres psql -d bench -c 'VACUUM (ANALYZE) pgbench_accounts'
sudo -u postgres psql -d bench -c 'VACUUM (ANALYZE) pgbench_branches'
sudo -u postgres psql -d bench -c 'VACUUM (ANALYZE) pgbench_tellers'
sudo -u postgres psql -d bench -c 'VACUUM (ANALYZE) pgbench_history'
if [ '$WORKLOAD' = 'mixed' ]; then
    sudo -u postgres psql -d bench -c 'VACUUM (ANALYZE) bench_inserts'
fi
sudo -u postgres psql -d bench -c 'CHECKPOINT'

echo '=== Phase 2: cold restart (stop PG -> drop caches -> start PG) ==='
systemctl stop postgresql@18-main
sync
echo 3 > /proc/sys/vm/drop_caches
systemctl start postgresql@18-main
for i in \$(seq 1 60); do
    pg_isready -h 127.0.0.1 -p 5432 -q && break
    sleep 1
done
pg_isready -h 127.0.0.1 -p 5432 || { echo 'ERROR: Postgres did not come back online'; exit 1; }

echo '=== Phase 3: warmup + steady-state + capture + upload ==='
sudo -u postgres /opt/bench/run.sh \
    --scenario '$SCENARIO' \
    --workload '$WORKLOAD' \
    --scale '$SCALE' \
    --duration '$DURATION' \
    --warmup '$WARMUP' \
    --clients '$CLIENTS' \
    --jobs '$JOBS' \
    --skip-init"
# (Analysis runs locally on the operator side — see bench-fetch.sh.)

# Send and capture the command ID; we poll with a long timeout. Build the
# parameters as full JSON via jq -n so embedded newlines survive.
#
# executionTimeout is the AWS-RunShellScript-document-level kill timer that
# defaults to 3600 (1 hour) — the script is SIGTERM'd at that boundary even
# if --timeout-seconds (the API delivery timeout) is much longer. We bump
# it to 28800 (8 hours), enough for init (15-30 min) + warmup + steady-state
# at full scale plus a healthy margin.
PARAMS=$(jq -n --arg cmd "$CMD" \
    '{commands:[$cmd], executionTimeout:["28800"]}')
CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 172800 \
    --parameters "$PARAMS" \
    --output text --query Command.CommandId)

info "    SSM command-id: $CMD_ID"
info "    follow with: aws ssm get-command-invocation --region $REGION --instance-id $INSTANCE --command-id $CMD_ID"

# Poll. SSM commands stream incremental stdout to CloudWatch but
# get-command-invocation only returns final output after Status=Success.
while :; do
  STATUS=$(aws ssm get-command-invocation \
      --region "$REGION" \
      --instance-id "$INSTANCE" \
      --command-id "$CMD_ID" \
      --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Success)               info "    SSM run finished (Success)"; break ;;
    Failed|Cancelled|TimedOut) err  "    SSM run ended with status: $STATUS"; break ;;
    *)                     printf '.'; sleep 30 ;;
  esac
done
echo

# Cosmetic local logging of the SSM run's stdout. A transient AWS API blip
# here must NOT propagate non-zero — the bench itself already succeeded
# (Status=Success, artifacts already in S3 via the run.sh script). Without
# `|| true` the script would die on any 5-second laptop→SSM connectivity
# hiccup after a 2-hour bench, marking the run failed even though the
# data is safely uploaded.
{
  aws ssm get-command-invocation \
      --region "$REGION" \
      --instance-id "$INSTANCE" \
      --command-id "$CMD_ID" \
      --query StandardOutputContent --output text 2>/dev/null \
    | tail -50
} || true

if [[ "$STATUS" != "Success" ]]; then
  err "stderr tail:"
  {
    aws ssm get-command-invocation \
        --region "$REGION" \
        --instance-id "$INSTANCE" \
        --command-id "$CMD_ID" \
        --query StandardErrorContent --output text 2>/dev/null \
      | tail -50 >&2
  } || true
  exit 1
fi
