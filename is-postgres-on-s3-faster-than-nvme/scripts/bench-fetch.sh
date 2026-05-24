#!/usr/bin/env bash
# Pull benchmark artifacts back from S3 (where run.sh deposits them) into
# results/<campaign>/<scenario>/. Falls back to SSM-tunneled rsync only if
# explicitly requested with --via-ssm.

source "$(dirname "$0")/_lib.sh"

SCENARIO="${1:?usage: bench-fetch.sh <scenario> [--tag <campaign-tag>] [--clean-raw]}"
TAG=""
CLEAN_RAW=false

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    # --clean-raw: after HdrHistogram conversion + plots succeed, delete the
    # bulky pgbench.<pid>.<thread> raw log files (which can be 10+ GB on
    # mixed workloads). Keeps the compact .hgrm/.percentiles.json/iostat/etc.
    --clean-raw) CLEAN_RAW=true; shift ;;
    *) err "unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  TAG="$(date -u +%Y%m%dT%H%M%SZ)"
fi

require_tf
require aws

REGION="$(aws_region)"
BUCKET="$(results_bucket)"
DEST="$RESULTS_DIR/$TAG/$SCENARIO"
mkdir -p "$DEST"

info "==> Fetching benchmark artifacts from s3://$BUCKET/results/$SCENARIO/ → $DEST"
aws s3 sync --region "$REGION" \
    "s3://$BUCKET/results/$SCENARIO/" \
    "$DEST/"

# Decompress the per-run logs that run.sh compressed before upload.
# pgbench_log.py reads the raw `pgbench.<pid>.<thread>` format, so we
# need to materialize plain files locally before the analysis stage.
if command -v zstd >/dev/null 2>&1; then
  info "==> Decompressing zstd artifacts"
  find "$DEST" -type f -name "*.zst" -print0 \
      | xargs -0 -r zstd --decompress --rm --threads=0 -q || \
        warn "some .zst files failed to decompress — inspect $DEST"
else
  warn "zstd not installed locally — .zst files left compressed; install zstd to enable analysis."
fi

if ! command -v uv >/dev/null 2>&1; then
  warn "uv not installed locally — skipping HdrHistogram + plot generation."
  warn "Install from https://github.com/astral-sh/uv to enable analysis."
  info "==> Fetched (raw): $DEST"
  exit 0
fi

(cd "$REPO_ROOT/analysis" && uv sync) || { warn "uv sync failed"; exit 0; }

info "==> Compressing pgbench logs into HdrHistogram artifacts"
# Find every <run-ts>/ directory under the campaign and run pgbench-log-to-hdr.
find "$RESULTS_DIR/$TAG" -mindepth 3 -maxdepth 3 -type d | \
    while IFS= read -r run_dir; do
      (cd "$REPO_ROOT/analysis" && uv run pgbench-log-to-hdr "$run_dir") || \
        warn "  hdr conversion failed for $run_dir"
    done

info "==> Generating campaign comparison plots"
(cd "$REPO_ROOT/analysis" && uv run compare-scenarios "$RESULTS_DIR/$TAG") || \
    warn "compare-scenarios failed"

if [[ "$CLEAN_RAW" == true ]]; then
  info "==> --clean-raw: deleting bulky raw pgbench worker logs"
  # After analysis, the only "raw" artifacts worth keeping per run are the
  # compact .hgrm + .percentiles.json + .elapsed.csv + pg_stat_*.tsv + log
  # files. The pgbench.<pid>.<thread> per-worker dumps can be 10+ GB on
  # mixed; delete them since we can always re-fetch from S3.
  find "$DEST" -type f -regextype posix-extended \
      -regex '.*/pgbench\.[0-9]+(\.[0-9]+)?' -print -delete | wc -l \
      | xargs -I{} info "    deleted {} files"
fi

info "==> Fetched: $DEST"
