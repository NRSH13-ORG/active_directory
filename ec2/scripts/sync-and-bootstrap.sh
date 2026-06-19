#!/bin/bash
set -euo pipefail

ACTION="${1:-apply}"

HOST="${AD_EC2_HOST:-}"
USER="${AD_EC2_SSH_USER:-ubuntu}"
KEY="${AD_EC2_SSH_PRIVATE_KEY:-${SSH_PRIVATE_KEY_FILE:-$HOME/.ssh/id_rsa}}"
REPO_ROOT="${AD_EC2_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

KEY="${KEY/#\~/$HOME}"

[[ -n "$HOST" ]] || { echo "AD_EC2_HOST is required" >&2; exit 1; }
[[ -f "$KEY" ]] || { echo "SSH private key not found: $KEY" >&2; exit 1; }

wait_for_ssh() {
  local attempt
  for attempt in $(seq 1 30); do
    if ssh -i "$KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "${USER}@${HOST}" "echo ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for SSH on ${HOST}" >&2
  exit 1
}

wait_for_ssh

ssh -i "$KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  "${USER}@${HOST}" "sudo install -d -o ${USER} -g ${USER} /opt/active_directory"

rsync -az --delete \
  --exclude '.git/' \
  --exclude '.env' \
  --exclude 'samba-data/' \
  --exclude 'samba-config/' \
  --exclude 'ec2/terraform/.terraform/' \
  --exclude 'ec2/terraform/*.tfstate' \
  --exclude 'ec2/terraform/*.tfstate.*' \
  -e "ssh -i ${KEY} -o StrictHostKeyChecking=accept-new" \
  "${REPO_ROOT}/" "${USER}@${HOST}:/opt/active_directory/"

ssh -i "$KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  "${USER}@${HOST}" "sudo bash /opt/active_directory/ec2/scripts/remote-bootstrap.sh ${ACTION}"
