#!/usr/bin/env bash
# Canonical benchmark runner — executed on the primary EC2 instance as the
# `postgres` user. Idempotent w.r.t. dataset init; the run itself is timestamped.
#
# Usage:
#   run.sh --scenario nvme-ext4 --workload tpcb \
#          --scale 15000 --duration 3600 --warmup 600 \
#          --clients 64 --jobs 16

set -euo pipefail

SCENARIO=""
WORKLOAD=""
SCALE=15000
DURATION=3600
WARMUP=600
CLIENTS=64
JOBS=16
DBNAME="${PGDATABASE:-bench}"
SKIP_INIT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)  SCENARIO="$2";  shift 2 ;;
    --workload)  WORKLOAD="$2";  shift 2 ;;
    --scale)     SCALE="$2";     shift 2 ;;
    --duration)  DURATION="$2";  shift 2 ;;
    --warmup)    WARMUP="$2";    shift 2 ;;
    --clients)   CLIENTS="$2";   shift 2 ;;
    --jobs)      JOBS="$2";      shift 2 ;;
    --dbname)    DBNAME="$2";    shift 2 ;;
    # --skip-init: the operator (bench-run.sh) already ran pgbench -i,
    # VACUUM, CHECKPOINT, AND a Postgres cold-restart with drop_caches.
    # We start straight at the warmup phase against a freshly-loaded
    # dataset and empty SB / OS page cache.
    --skip-init) SKIP_INIT=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SCENARIO" ]] || { echo "ERROR: --scenario required" >&2; exit 2; }
[[ -n "$WORKLOAD" ]] || { echo "ERROR: --workload required" >&2; exit 2; }

case "$WORKLOAD" in
  tpcb|mixed) ;;
  *) echo "ERROR: --workload must be tpcb or mixed (got: $WORKLOAD)" >&2; exit 2 ;;
esac

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="/opt/bench/runs/${SCENARIO}/${WORKLOAD}/${TIMESTAMP}"
mkdir -p "$RUN_DIR"
cd "$RUN_DIR"

WORKLOAD_DIR="/opt/bench/workloads"

log() { echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$RUN_DIR/run.log" ; }

log "Scenario=$SCENARIO Workload=$WORKLOAD Scale=$SCALE Duration=${DURATION}s Warmup=${WARMUP}s Clients=$CLIENTS Jobs=$JOBS"
log "Run directory: $RUN_DIR"

# -----------------------------------------------------------------------------
# 0. S3 bucket pre-snapshot — captures object count + bytes so the campaign
#    can compare deltas and flag any scenario that churns out an order of
#    magnitude more objects than expected (cost guard, see docs/design.md §11b).
# -----------------------------------------------------------------------------
S3_BUCKET="$(jq -r .s3_bucket /opt/bench/scenario.json 2>/dev/null || true)"
S3_CLASS="$(jq -r .s3_class /opt/bench/scenario.json 2>/dev/null || true)"
if [[ -n "$S3_BUCKET" && "$S3_BUCKET" != "null" ]]; then
  log "S3 pre-snapshot for s3://$S3_BUCKET ($S3_CLASS)"
  if [[ "$S3_CLASS" == "express" ]]; then
    # Directory buckets need the express endpoint and CreateSession-based auth.
    AZID="$(jq -r .s3_az_id /opt/bench/scenario.json 2>/dev/null || true)"
    REGION="$(jq -r .aws_region /opt/bench/scenario.json 2>/dev/null || echo us-east-1)"
    EXPRESS_ENDPOINT="https://s3express-${AZID}.${REGION}.amazonaws.com"
    aws s3api list-objects-v2 --bucket "$S3_BUCKET" \
        --endpoint-url "$EXPRESS_ENDPOINT" --no-paginate \
        --query 'length(Contents || `[]`)' --output text \
        > "$RUN_DIR/s3_objects_pre.txt" 2>/dev/null || echo 0 > "$RUN_DIR/s3_objects_pre.txt"
  else
    aws s3api list-objects-v2 --bucket "$S3_BUCKET" --no-paginate \
        --query 'length(Contents || `[]`)' --output text \
        > "$RUN_DIR/s3_objects_pre.txt" 2>/dev/null || echo 0 > "$RUN_DIR/s3_objects_pre.txt"
  fi
  log "  pre objects: $(cat "$RUN_DIR/s3_objects_pre.txt")"
fi

# -----------------------------------------------------------------------------
# 1. Initialize dataset — ALWAYS fresh (unless --skip-init).
# -----------------------------------------------------------------------------
# Each benchmark run starts from a pristine dataset. Skipping re-init across
# workloads contaminates the second one (e.g. tpcb leaves pgbench_history
# 5-10 GB larger and pgbench_accounts with millions of dead tuples in flight
# of autovacuum). pgbench -i drops + recreates + bulk-loads in one shot.
#
# With --skip-init, bench-run.sh has already handled init + VACUUM + cold
# Postgres restart + drop_caches. We jump straight to housekeeping reset.
if [[ "$SKIP_INIT" != true ]]; then
  log "Initializing dataset at scale $SCALE (pgbench -i, fresh)"
  pgbench -i -s "$SCALE" --no-vacuum --foreign-keys -d "$DBNAME" \
      2>&1 | tee "$RUN_DIR/init.log"

  if [[ "$WORKLOAD" == "mixed" ]]; then
    log "Creating bench_inserts table (mixed workload)"
    psql -d "$DBNAME" -f "$WORKLOAD_DIR/init_mixed.sql" \
        2>&1 | tee -a "$RUN_DIR/init.log"
  fi

  log "VACUUM ANALYZE + CHECKPOINT"
  psql -d "$DBNAME" -c "VACUUM (ANALYZE) pgbench_accounts;" >> "$RUN_DIR/run.log" 2>&1
  psql -d "$DBNAME" -c "VACUUM (ANALYZE) pgbench_branches;" >> "$RUN_DIR/run.log" 2>&1
  psql -d "$DBNAME" -c "VACUUM (ANALYZE) pgbench_tellers;"  >> "$RUN_DIR/run.log" 2>&1
  psql -d "$DBNAME" -c "VACUUM (ANALYZE) pgbench_history;"  >> "$RUN_DIR/run.log" 2>&1
  [[ "$WORKLOAD" == "mixed" ]] && \
      psql -d "$DBNAME" -c "VACUUM (ANALYZE) bench_inserts;" >> "$RUN_DIR/run.log" 2>&1
  psql -d "$DBNAME" -c "CHECKPOINT;" >> "$RUN_DIR/run.log" 2>&1
else
  log "Skipping init (bench-run.sh already loaded data + cold-restarted Postgres)"
fi

# -----------------------------------------------------------------------------
# 2. Pre-run reset — always. Post-restart Postgres has zeroed pg_stat
# counters already, but explicit reset is cheap insurance for both paths.
# -----------------------------------------------------------------------------
psql -d "$DBNAME" -c "SELECT pg_stat_reset();"            >> "$RUN_DIR/run.log" 2>&1
psql -d "$DBNAME" -c "SELECT pg_stat_statements_reset();" >> "$RUN_DIR/run.log" 2>&1 || true

# -----------------------------------------------------------------------------
# 3. Background system metrics (iostat, zpool iostat, vmstat).
# -----------------------------------------------------------------------------
log "Starting background metrics collectors"
TOTAL_SECS=$((WARMUP + DURATION + 30))

iostat -x -t -m 1 "$TOTAL_SECS" > "$RUN_DIR/iostat.log" 2>&1 &
IOSTAT_PID=$!

vmstat 1 "$TOTAL_SECS" > "$RUN_DIR/vmstat.log" 2>&1 &
VMSTAT_PID=$!

if zpool list bench >/dev/null 2>&1; then
  ( for _ in $(seq 1 "$TOTAL_SECS"); do
      date -u +%FT%TZ; zpool iostat -v bench 1 1 | tail -n +3
      sleep 1
    done ) > "$RUN_DIR/zpool_iostat.log" 2>&1 &
  ZPOOL_PID=$!
else
  ZPOOL_PID=""
fi

# pg_stat_wal time-series sampler. 5 s interval gives ~360 samples over the
# 30 min steady-state — enough resolution to see FPI-rate decay between
# checkpoint cycles (the "FPI storm" signature) when plotted alongside TPS.
# pg_stat_wal counters are cluster-global and survived since the Phase 2
# Postgres restart, so deltas between samples give true per-interval rate.
log "Starting pg_stat_wal sampler (5s interval, $TOTAL_SECS s total)"
(
  printf 'epoch\twal_records\twal_fpi\twal_bytes\n'
  for _ in $(seq 1 "$((TOTAL_SECS / 5))"); do
    psql -d "$DBNAME" -At -F$'\t' -c \
      "SELECT extract(epoch from now())::bigint, wal_records, wal_fpi, wal_bytes FROM pg_stat_wal" \
      2>/dev/null || break
    sleep 5
  done
) > "$RUN_DIR/pg_stat_wal_samples.tsv" &
WAL_SAMPLER_PID=$!

cleanup() {
  kill "$IOSTAT_PID" "$VMSTAT_PID" "$WAL_SAMPLER_PID" 2>/dev/null || true
  [[ -n "$ZPOOL_PID" ]] && kill "$ZPOOL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 4. Warmup phase — discarded.
# -----------------------------------------------------------------------------
log "Warmup: ${WARMUP}s"
WARMUP_ARGS=( -c "$CLIENTS" -j "$JOBS" -T "$WARMUP" -P 30 -d "$DBNAME" )
case "$WORKLOAD" in
  tpcb)  WARMUP_ARGS+=( -b tpcb-like ) ;;
  mixed) WARMUP_ARGS+=( -f "$WORKLOAD_DIR/mixed_75_5_20.sql" ) ;;
esac
pgbench "${WARMUP_ARGS[@]}" > "$RUN_DIR/warmup.log" 2>&1 || true

# Reset stats again so steady-state numbers are clean.
psql -d "$DBNAME" -c "SELECT pg_stat_reset();"            >> "$RUN_DIR/run.log" 2>&1
psql -d "$DBNAME" -c "SELECT pg_stat_statements_reset();" >> "$RUN_DIR/run.log" 2>&1

# -----------------------------------------------------------------------------
# 5. Steady-state run.
# -----------------------------------------------------------------------------
log "Steady-state: ${DURATION}s, $CLIENTS clients, $JOBS jobs"
RUN_ARGS=(
  -c "$CLIENTS"
  -j "$JOBS"
  -T "$DURATION"
  -P 10
  -d "$DBNAME"
  --log
  --log-prefix="$RUN_DIR/pgbench"
  --no-vacuum
)
case "$WORKLOAD" in
  tpcb)  RUN_ARGS+=( -b tpcb-like ) ;;
  mixed) RUN_ARGS+=( -f "$WORKLOAD_DIR/mixed_75_5_20.sql" ) ;;
esac

pgbench "${RUN_ARGS[@]}" > "$RUN_DIR/pgbench_summary.log" 2>&1

# -----------------------------------------------------------------------------
# 6. Post-run snapshots.
# -----------------------------------------------------------------------------
log "Capturing post-run statistics"

psql -d "$DBNAME" -c "\\copy (SELECT * FROM pg_stat_io)            TO '$RUN_DIR/pg_stat_io.tsv'           WITH (FORMAT csv, DELIMITER E'\\t', HEADER)" >> "$RUN_DIR/run.log" 2>&1 || true
psql -d "$DBNAME" -c "\\copy (SELECT * FROM pg_stat_wal)           TO '$RUN_DIR/pg_stat_wal.tsv'          WITH (FORMAT csv, DELIMITER E'\\t', HEADER)" >> "$RUN_DIR/run.log" 2>&1 || true
psql -d "$DBNAME" -c "\\copy (SELECT * FROM pg_stat_bgwriter)      TO '$RUN_DIR/pg_stat_bgwriter.tsv'     WITH (FORMAT csv, DELIMITER E'\\t', HEADER)" >> "$RUN_DIR/run.log" 2>&1 || true
psql -d "$DBNAME" -c "\\copy (SELECT * FROM pg_stat_database WHERE datname = '$DBNAME') TO '$RUN_DIR/pg_stat_database.tsv' WITH (FORMAT csv, DELIMITER E'\\t', HEADER)" >> "$RUN_DIR/run.log" 2>&1 || true
psql -d "$DBNAME" -c "\\copy (SELECT calls, total_exec_time, mean_exec_time, rows, query FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 50) TO '$RUN_DIR/pg_stat_statements_top.tsv' WITH (FORMAT csv, DELIMITER E'\\t', HEADER)" >> "$RUN_DIR/run.log" 2>&1 || true
psql -d "$DBNAME" -c "\\copy (SELECT * FROM pg_stat_replication) TO '$RUN_DIR/pg_stat_replication.tsv' WITH (FORMAT csv, DELIMITER E'\\t', HEADER)" >> "$RUN_DIR/run.log" 2>&1 || true

# Server log tail (last 10k lines of today's log).
PG_LOG_DIR="/mnt/pgdata/main/log"
if [[ -d "$PG_LOG_DIR" ]]; then
  ls -t "$PG_LOG_DIR"/postgresql-*.log 2>/dev/null | head -1 | \
    xargs -r -I{} tail -n 10000 {} > "$RUN_DIR/postgresql.log.tail" || true
fi

# Snapshot of postgresql.conf and scenario metadata.
cp /etc/postgresql/18/main/postgresql.conf "$RUN_DIR/postgresql.conf" 2>/dev/null || true
cp /opt/bench/scenario.json                 "$RUN_DIR/scenario.json"  2>/dev/null || true

# -----------------------------------------------------------------------------
# 7. Hand-off to analysis.
# -----------------------------------------------------------------------------
# S3 post-snapshot — the delta is the object churn for this run.
if [[ -n "$S3_BUCKET" && "$S3_BUCKET" != "null" ]]; then
  log "S3 post-snapshot"
  if [[ "$S3_CLASS" == "express" ]]; then
    aws s3api list-objects-v2 --bucket "$S3_BUCKET" \
        --endpoint-url "$EXPRESS_ENDPOINT" --no-paginate \
        --query 'length(Contents || `[]`)' --output text \
        > "$RUN_DIR/s3_objects_post.txt" 2>/dev/null || echo 0 > "$RUN_DIR/s3_objects_post.txt"
  else
    aws s3api list-objects-v2 --bucket "$S3_BUCKET" --no-paginate \
        --query 'length(Contents || `[]`)' --output text \
        > "$RUN_DIR/s3_objects_post.txt" 2>/dev/null || echo 0 > "$RUN_DIR/s3_objects_post.txt"
  fi
  PRE="$(cat "$RUN_DIR/s3_objects_pre.txt")"
  POST="$(cat "$RUN_DIR/s3_objects_post.txt")"
  log "  post objects: $POST  (delta: $((POST - PRE)))"
fi

log "Run complete: $RUN_DIR"

# Surface a one-line headline so callers can quickly verify the run succeeded.
TPS_LINE="$(grep -E '^(tps|latency average)' "$RUN_DIR/pgbench_summary.log" || true)"
log "Headline:"
echo "$TPS_LINE" | tee -a "$RUN_DIR/run.log"

# -----------------------------------------------------------------------------
# 8. Upload run artifacts to the results bucket. bench-fetch.sh on the operator
#    pulls from there — no SSH/rsync round trip needed.
# -----------------------------------------------------------------------------
RESULTS_BUCKET="$(jq -r .results_bucket /opt/bench/scenario.json 2>/dev/null || true)"
if [[ -z "$RESULTS_BUCKET" || "$RESULTS_BUCKET" == "null" ]]; then
  # Fallback to s3_bucket if results_bucket isn't recorded (older scenario.json).
  RESULTS_BUCKET="$(jq -r .s3_bucket /opt/bench/scenario.json 2>/dev/null || echo '')"
fi
# Compress the big text logs before upload. pgbench per-worker logs (~95 MB
# each × 16) and iostat/vmstat/server-log tail all compress 4-6× with zstd.
# Small files (.tsv, .json, .conf) are skipped — header overhead would
# make them larger. --rm replaces the original with .zst in place.
log "Compressing large logs with zstd before upload"
find "$RUN_DIR" -type f \
    \( -name "pgbench.[0-9]*" -o -name "*.log" -o -name "*.log.tail" -o -name "*_samples.tsv" \) \
    -size +100k -print0 \
    | xargs -0 -r zstd --rm --threads=0 -q
BEFORE_SIZE="$(du -sh "$RUN_DIR" 2>/dev/null | awk '{print $1}')"
log "  post-compression run dir size: $BEFORE_SIZE"

if [[ -n "$RESULTS_BUCKET" ]]; then
  log "Uploading artifacts to s3://$RESULTS_BUCKET/results/$SCENARIO/$WORKLOAD/$TIMESTAMP/"
  aws s3 sync --quiet "$RUN_DIR/" \
      "s3://$RESULTS_BUCKET/results/$SCENARIO/$WORKLOAD/$TIMESTAMP/" \
      || log "WARNING: s3 sync failed (artifacts still local at $RUN_DIR)"
else
  log "No results bucket configured — artifacts remain local at $RUN_DIR"
fi

echo "$RUN_DIR"
