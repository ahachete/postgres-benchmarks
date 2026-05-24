#!/usr/bin/env bash
# analysis-on-box.sh — driver for running a campaign's analysis on the
# in-region EC2 analysis workstation.
#
# Assumes:
#   - running as the `ubuntu` user, cwd is the repo root
#   - AWS CLI on PATH, instance IAM allows GetObject on the results bucket
#     and PutObject on the `analysis/` prefix
#   - nix-shell available (from the operator's Determinate Nix installer)
#   - the campaign manifest has already been uploaded to
#     s3://$BUCKET/manifests/$CAMPAIGN_NAME.tsv
#
# Required env:
#   BUCKET         — pgbench-results-<account>-<region>
#   CAMPAIGN_NAME  — e.g. campaign-blog-20260515T000848Z
#                    or  campaign-s3-20260516T171545Z
#
# Output:
#   s3://$BUCKET/analysis/$CAMPAIGN_NAME/{phase1,phase2,...}/...
#     (every PNG + summary .md / .csv produced by compare-scenarios)

set -euo pipefail

: "${BUCKET:?BUCKET env required}"
: "${CAMPAIGN_NAME:?CAMPAIGN_NAME env required (e.g. campaign-s3-20260516T171545Z)}"

CAMP="results/${CAMPAIGN_NAME}"
mkdir -p "$CAMP"

echo "==> Pulling manifest from s3://$BUCKET/manifests/$CAMPAIGN_NAME.tsv"
aws s3 cp "s3://$BUCKET/manifests/$CAMPAIGN_NAME.tsv" "$CAMP/manifest.tsv"

echo "==> Splitting S3 result paths by phase"
declare -A PHASES_SEEN=()
tail -n +2 "$CAMP/manifest.tsv" | while IFS=$'\t' read -r phase scenario workload start stop dur rc s3path; do
  if [ "$rc" != "0" ]; then
    echo "  SKIP rc=$rc: $phase $scenario $workload"
    continue
  fi
  ts=$(basename "${s3path%/}")
  dest="$CAMP/$phase/$scenario/$workload/$ts"
  mkdir -p "$dest"
  printf '  %s/%s/%s -> %s\n' "$phase" "$scenario" "$workload" "$dest"
  aws s3 sync "$s3path" "$dest" --quiet
done

echo "==> Total pulled:"
du -sh "$CAMP"

# Discover which phases actually have data (handles single-phase campaigns).
PHASES=()
for phase_dir in "$CAMP"/phase*; do
  [ -d "$phase_dir" ] || continue
  # Skip if no successful runs were synced into it.
  if [ -n "$(ls -A "$phase_dir" 2>/dev/null)" ]; then
    PHASES+=("$(basename "$phase_dir")")
  fi
done

if [ ${#PHASES[@]} -eq 0 ]; then
  echo "==> No phases with data found — nothing to analyse."
  exit 1
fi

# compare-scenarios is a uv-managed Python tool. Run it inside nix-shell so
# libstdc++ / zlib loader paths line up with the uv-installed wheels.
run_compare() {
  local phase="$1"
  echo "==> Running compare-scenarios on $phase"
  nix-shell --run "cd analysis && uv sync --quiet && uv run compare-scenarios ../$CAMP/$phase"
}

for phase in "${PHASES[@]}"; do
  run_compare "$phase"
done

# Blog-shaped cross-phase plots — only meaningful when both phase1 AND
# phase2 are present (i.e. the campaign covers single-node AND HA). Single-
# phase campaigns silently skip this step.
if [ -d "$CAMP/phase1" ] && [ -d "$CAMP/phase2" ]; then
  echo "==> Rendering blog-post-shaped plots (multi-phase campaign)"
  nix-shell --run "cd analysis && uv sync --quiet && uv run blog-plots ../$CAMP --out ../$CAMP/blog"
fi

echo "==> Uploading rendered plots + summaries to s3://$BUCKET/analysis/$CAMPAIGN_NAME/"
for phase in "${PHASES[@]}"; do
  aws s3 sync "$CAMP/$phase" "s3://$BUCKET/analysis/$CAMPAIGN_NAME/$phase/" \
      --exclude "*" --include "*.png" --include "*.md" --include "*.csv" \
      --include "*/runsum.json" --quiet
done
# Blog plots (if rendered).
if [ -d "$CAMP/blog" ]; then
  aws s3 sync "$CAMP/blog" "s3://$BUCKET/analysis/$CAMPAIGN_NAME/blog/" \
      --exclude "*" --include "*.png" --quiet
fi
# Also push the manifest itself for reference.
aws s3 cp "$CAMP/manifest.tsv" "s3://$BUCKET/analysis/$CAMPAIGN_NAME/manifest.tsv" --quiet

echo "==> Done. Pull plots locally with:"
echo "    aws s3 sync s3://$BUCKET/analysis/$CAMPAIGN_NAME/ ./results/$CAMPAIGN_NAME/analysis/"
