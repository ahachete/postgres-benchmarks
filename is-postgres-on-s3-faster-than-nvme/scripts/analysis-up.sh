#!/usr/bin/env bash
# Provision the analysis workstation. Idempotent — re-applies if state
# exists.  Pre-flight checks the persistent bucket is bootstrapped, since
# the analysis IAM policy looks it up by name.

source "$(dirname "$0")/_lib.sh"

REGION="${1:-us-east-2}"

require_tf
require_ssm

ANALYSIS_DIR="$TF_DIR/analysis"

if ! "$TF" -chdir="$TF_DIR/persistent" output -raw results_bucket >/dev/null 2>&1; then
  err "Persistent results bucket not found. Run 'make bootstrap' first."
  exit 1
fi

info "==> $TF init (analysis)"
"$TF" -chdir="$ANALYSIS_DIR" init -upgrade

info "==> $TF apply (analysis, region=$REGION use_spot=${USE_SPOT:-true})"
"$TF" -chdir="$ANALYSIS_DIR" apply -auto-approve \
    -var="region=$REGION" \
    -var="use_spot=${USE_SPOT:-true}"

INSTANCE=$("$TF" -chdir="$ANALYSIS_DIR" output -raw instance_id)
info "==> Analysis instance: $INSTANCE"

info "==> Waiting for SSM agent on $INSTANCE (and user_data to settle)"
# user_data takes ~3-5 min to install Nix + AWS CLI. SSM comes up first,
# then we wait for /var/log/user_data.done to appear.
for _ in $(seq 1 60); do
  STATE=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$INSTANCE" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo None)
  if [[ "$STATE" == "Online" ]]; then
    info "    SSM Online — waiting for user_data to finish (Nix install, ~3 min)"
    break
  fi
  sleep 5
done

# Poll the user_data sentinel.
for _ in $(seq 1 60); do
  CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["test -f /var/log/user_data.done && echo READY || echo PENDING"]' \
      --output text --query Command.CommandId 2>/dev/null || true)
  [ -z "$CMD_ID" ] && { sleep 5; continue; }
  sleep 3
  RESULT=$(aws ssm get-command-invocation --region "$REGION" \
      --instance-id "$INSTANCE" --command-id "$CMD_ID" \
      --query StandardOutputContent --output text 2>/dev/null | tr -d '[:space:]')
  if [[ "$RESULT" == "READY" ]]; then
    info "    user_data done."
    break
  fi
  printf '.'
  sleep 5
done
echo

info "==> Up: analysis instance ready"
info "    SSM: aws ssm start-session --region $REGION --target $INSTANCE"
info ""
info "Next steps:"
info "  make analysis-shell        # open an interactive SSM session"
info "  # inside the session:"
info "  sudo -i -u ubuntu"
info "  git clone <your-repo-url>"
info "  cd <repo>"
info "  nix-shell"
info "  cd analysis"
info "  aws s3 sync s3://$(${TF} -chdir=$TF_DIR/persistent output -raw results_bucket)/results/ \\"
info "      ../results/campaign-final/"
info "  uv run compare-scenarios ../results/campaign-final"
