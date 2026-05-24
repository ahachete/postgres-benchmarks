#!/usr/bin/env bash
# analysis-run.sh — end-to-end orchestration of a campaign's analysis on the
# in-region EC2 analysis workstation.
#
# Usage:
#   scripts/analysis-run.sh <campaign-name>
# e.g.:
#   scripts/analysis-run.sh campaign-s3-20260516T171545Z
#
# Steps (all idempotent):
#   1. Upload the local campaign manifest to s3://bucket/manifests/<campaign>.tsv
#   2. Tarball the analysis/scripts/shell.nix code, upload to s3://bucket/code/
#   3. `make analysis-up` (idempotent — re-applies tofu if state exists)
#   4. Wait for SSM agent on the analysis instance to come Online (with retry).
#      A common failure mode is `aws ssm` saying "instance not available" when
#      run too soon after analysis-up returns; this script polls until SSM
#      describe-instance-information reports PingStatus=Online before sending
#      any command.
#   5. SSM-exec scripts/analysis-on-box.sh on the box.
#   6. Poll the SSM command until Success/Failed/TimedOut; stream stdout tail.
#   7. Pull the rendered plots locally to results/<campaign>/analysis/.
#   8. `make analysis-down` (optional via NO_TEARDOWN=1 env).
#
# Required: CAMPAIGN_NAME (positional), AWS_PROFILE, inside nix-shell.

set -euo pipefail

CAMPAIGN_NAME="${1:?usage: $0 <campaign-name>, e.g. campaign-s3-20260516T171545Z}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Default to on-demand for the analysis pipeline. A 60-minute compare-scenarios
# job is painful to lose to a spot interruption — we did once, on
# Server.SpotInstanceTermination ~30 min into a run. On-demand premium for
# this single c7i.4xlarge: ~$0.55/hr × ~1hr = ~$0.55/run. Override with
# `USE_SPOT=true bash scripts/analysis-run.sh …` if you want to gamble.
export USE_SPOT="${USE_SPOT:-false}"

if ! tofu -chdir=terraform/persistent output -raw results_bucket >/dev/null 2>&1; then
  echo "✗ Persistent results bucket not found. Run 'make bootstrap' first." >&2
  exit 1
fi
BUCKET="$(tofu -chdir=terraform/persistent output -raw results_bucket)"
REGION="${REGION:-us-east-2}"

CAMP_DIR="results/$CAMPAIGN_NAME"
[ -f "$CAMP_DIR/manifest.tsv" ] || {
  echo "✗ Local manifest not found at $CAMP_DIR/manifest.tsv" >&2
  exit 1
}

log() { printf '%s [analysis-run] %s\n' "$(date -Iseconds)" "$*"; }

log "Campaign:    $CAMPAIGN_NAME"
log "Bucket:      $BUCKET"
log "Region:      $REGION"

# 1. Upload manifest --------------------------------------------------------
log "==> [1/8] Upload manifest"
aws s3 cp "$CAMP_DIR/manifest.tsv" "s3://$BUCKET/manifests/$CAMPAIGN_NAME.tsv"

# 2. Build + upload code tarball -------------------------------------------
log "==> [2/8] Build + upload analysis code tarball"
TARBALL="/tmp/repo-analysis-$$.tar.gz"
trap 'rm -f "$TARBALL"' EXIT
tar -czf "$TARBALL" \
    --exclude='.git' --exclude='.terraform' \
    --exclude='terraform/terraform.tfstate*' \
    --exclude='ansible/.collections' --exclude='ansible/inventory.json' \
    --exclude='analysis/.venv' --exclude='analysis/**/__pycache__' \
    --exclude='results' \
    analysis scripts shell.nix
aws s3 cp "$TARBALL" "s3://$BUCKET/code/repo-analysis.tar.gz"

# 3. Bring up analysis box -------------------------------------------------
log "==> [3/8] make analysis-up"
make analysis-up

INSTANCE="$(tofu -chdir=terraform/analysis output -raw instance_id)"
log "    instance: $INSTANCE"

# 4. Wait for SSM agent to actually be Online -------------------------------
# `make analysis-up` already waits for SSM PingStatus=Online and for the
# user_data sentinel — but defensive re-poll here in case the previous step
# returned just before the agent registered (the "instance not available"
# class of errors we hit manually).
log "==> [4/8] Confirm SSM agent is Online"
for i in $(seq 1 60); do
  STATE=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$INSTANCE" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo None)
  if [ "$STATE" = "Online" ]; then
    log "    SSM Online (took ${i} polls)"
    break
  fi
  sleep 5
done
if [ "$STATE" != "Online" ]; then
  log "    ✗ SSM agent never came Online after 5 minutes"
  exit 1
fi

# 5. SSM-exec the on-box analysis driver -----------------------------------
log "==> [5/8] SSM-exec analysis-on-box.sh"
SCRIPT="sudo -i -u ubuntu bash <<'INNER'
set -euo pipefail
cd /home/ubuntu
rm -rf repo-analysis
mkdir repo-analysis && cd repo-analysis
aws s3 cp s3://$BUCKET/code/repo-analysis.tar.gz .
tar xzf repo-analysis.tar.gz
chmod +x scripts/analysis-on-box.sh
BUCKET=$BUCKET CAMPAIGN_NAME=$CAMPAIGN_NAME bash scripts/analysis-on-box.sh
INNER"

PARAMS=$(jq -n --arg cmd "$SCRIPT" '{commands:[$cmd], executionTimeout:["7200"]}')
CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript \
    --parameters "$PARAMS" \
    --output text --query Command.CommandId)
log "    SSM command-id: $CMD_ID"

# 6. Poll until done --------------------------------------------------------
log "==> [6/8] Poll until SSM run completes (executionTimeout 2h)"
while :; do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" \
      --instance-id "$INSTANCE" --command-id "$CMD_ID" \
      --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
    *) log "    status=$STATUS"; sleep 30 ;;
  esac
done
log "    final status: $STATUS"
log "    stdout (tail 40):"
aws ssm get-command-invocation --region "$REGION" --instance-id "$INSTANCE" \
    --command-id "$CMD_ID" --query StandardOutputContent --output text | tail -40

if [ "$STATUS" != "Success" ]; then
  log "    stderr (tail 40):"
  aws ssm get-command-invocation --region "$REGION" --instance-id "$INSTANCE" \
      --command-id "$CMD_ID" --query StandardErrorContent --output text | tail -40 >&2
  log "✗ On-box analysis driver failed; NOT tearing down so you can inspect."
  exit 1
fi

# 7. Pull rendered plots locally -------------------------------------------
log "==> [7/8] Pull plots locally"
mkdir -p "$CAMP_DIR/analysis"
aws s3 sync "s3://$BUCKET/analysis/$CAMPAIGN_NAME/" "$CAMP_DIR/analysis/"
log "    local artifacts:"
find "$CAMP_DIR/analysis" -type f | sort

# 8. Tear down analysis box (skippable) ------------------------------------
if [ "${NO_TEARDOWN:-0}" = "1" ]; then
  log "==> [8/8] Skipping make analysis-down (NO_TEARDOWN=1 set)"
else
  log "==> [8/8] make analysis-down"
  make analysis-down
fi

log "Done."
