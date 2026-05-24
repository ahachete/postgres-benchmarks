#!/usr/bin/env bash
# Cluster smoke test — Phase 2 HA path validation.
#
# Brings up a 3-node nvme-ext4 cluster, verifies streaming replication, runs
# a tiny pgbench under sync replication, verifies replicas catch up, and
# tears down on success. `set -e` (from _lib.sh) ensures any failure aborts
# the script before teardown — so a failed cluster stays up for inspection.

source "$(dirname "$0")/_lib.sh"

START_TS=$(date +%s)

stamp() { printf '\n[%s]  ' "$(date -u +%H:%M:%SZ)"; }

stamp; info "==> [1/5] Bringing up 3-node cluster (nvme-ext4, 3 AZs)"
make -C "$REPO_ROOT" up CLUSTER=true SCENARIO=nvme-ext4

stamp; info "==> [2/5] Verifying streaming replication"
ssm_run_on_primary 'sudo -u postgres psql -tAXc "
  SELECT application_name,
         state,
         sync_state,
         write_lag,
         flush_lag,
         replay_lag
  FROM pg_stat_replication
  ORDER BY application_name;"'

stamp; info "==> [3/5] Running tiny pgbench under sync replication"
make -C "$REPO_ROOT" bench \
    SCENARIO=nvme-ext4 WORKLOAD=tpcb \
    SCALE=100 DURATION=60 WARMUP=15 CLIENTS=16 JOBS=8

stamp; info "==> [4/5] Verifying replicas caught up after run"
ssm_run_on_primary 'sudo -u postgres psql -tAXc "
  SELECT application_name,
         state,
         sync_state,
         pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)  AS flush_lag_bytes,
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
  FROM pg_stat_replication
  ORDER BY application_name;"'

stamp; info "==> [5/5] Tearing down cluster infra (results bucket / AMI untouched)"
make -C "$REPO_ROOT" down

END_TS=$(date +%s)
stamp; info "==> Cluster smoke complete in $(( END_TS - START_TS ))s. All resources cleaned up."
