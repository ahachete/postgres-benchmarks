#!/usr/bin/env bash
# Snapshot the in-flight benchmark on the primary EC2 instance.
# Safe to run any time — read-only, doesn't touch the running pgbench.
#
# Distinguishes the three phases of bench-run.sh:
#   Phase 1 — pgbench -i (loading data; no run-dir yet)
#   Phase 2 — cold restart (PG stopping/starting; very short)
#   Phase 3 — warmup + steady-state (run-dir + pgbench_summary.log present)

source "$(dirname "$0")/_lib.sh"

require_tf
require_ssm
require aws

INSTANCE="$(primary_instance_id)"
REGION="$(aws_region)"
RESULTS_BUCKET="$(results_bucket)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

STATUS_SCRIPT="$(mktemp /tmp/bench-status.XXXXXX.sh)"
trap 'rm -f "$STATUS_SCRIPT"' EXIT

cat > "$STATUS_SCRIPT" <<'STATUS_EOF'
#!/usr/bin/env bash
LATEST=$(ls -td /opt/bench/runs/*/*/* 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
    # =====================================================================
    # Pre-Phase-3: pgbench -i is loading, or PG is cold-restarting.
    # =====================================================================
    echo "=== No run directory yet — Phase 1 (pgbench -i) or Phase 2 (cold restart) ==="

    echo
    echo "=== Postgres status ==="
    systemctl is-active postgresql@18-main 2>&1
    pg_isready -h 127.0.0.1 -p 5432 2>&1 || true

    echo
    echo "=== pg_stat_progress_copy (pgbench -i bulk load) ==="
    sudo -u postgres psql -d bench -c \
        "SELECT relid::regclass AS rel,
                pg_size_pretty(bytes_processed) AS bytes,
                pg_size_pretty(bytes_total) AS total,
                tuples_processed
         FROM pg_stat_progress_copy" 2>/dev/null || \
            echo "  (Postgres not accepting queries yet — likely Phase 2 cold restart)"

    echo "=== pgbench process(es) ==="
    ps -eo pid,etime,user,cmd | grep -E '(pgbench|psql|VACUUM)' | grep -v grep || echo "  (no pgbench running)"

    echo "=== Recent server log (last 8 lines) ==="
    ls -t /mnt/pgdata/main/log/postgresql-*.log 2>/dev/null | head -1 | xargs -r tail -8

    exit 0
fi

# =========================================================================
# Phase 3: warmup or steady-state. Use the existing run-dir based view.
# =========================================================================
echo "=== Phase 3: run dir ==="
echo "$LATEST"

echo
echo "=== run.log (last 12) ==="
tail -12 "$LATEST/run.log" 2>/dev/null

echo
echo "=== pgbench progress (last 8 lines) ==="
tail -50 "$LATEST/pgbench_summary.log" 2>/dev/null \
    | grep -E '^(progress|starting|pgbench|scaling factor|number of)' \
    | tail -8

echo
echo "=== pg_stat_activity (active backends) ==="
sudo -u postgres psql -d bench -c \
    "SELECT state, count(*) FROM pg_stat_activity \
     WHERE backend_type='client backend' GROUP BY state ORDER BY state"

echo "=== pg_stat_wal ==="
sudo -u postgres psql -d bench -c \
    "SELECT wal_records, pg_size_pretty(wal_bytes) AS wal_volume, \
            wal_fpi, wal_buffers_full FROM pg_stat_wal"

echo "=== latest iostat sample (nvme1n1) ==="
tail -50 "$LATEST/iostat.log" 2>/dev/null \
    | awk '/^Device/{hdr=$0} /^nvme1n1/{last=$0} END{print hdr; print last}'

echo
echo "=== bgwriter / checkpointer ==="
sudo -u postgres psql -d bench -c "SELECT * FROM pg_stat_bgwriter" 2>/dev/null
sudo -u postgres psql -d bench -c "SELECT * FROM pg_stat_checkpointer" 2>/dev/null

echo "=== recent checkpoints (server log) ==="
ls -t /mnt/pgdata/main/log/postgresql-*.log 2>/dev/null | head -1 \
    | xargs -r grep -E 'checkpoint (starting|complete)' | tail -5
STATUS_EOF

S3_KEY="_tmp/bench-status-${TIMESTAMP}.sh"
S3_URI="s3://$RESULTS_BUCKET/$S3_KEY"

aws s3 cp --region "$REGION" --quiet "$STATUS_SCRIPT" "$S3_URI"

ssm_run_on_primary "set -eu
aws s3 cp --region $REGION '$S3_URI' /tmp/bench-status.sh
bash /tmp/bench-status.sh
rm -f /tmp/bench-status.sh
aws s3 rm --region $REGION '$S3_URI' >/dev/null
"
