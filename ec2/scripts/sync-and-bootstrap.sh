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

ssh_cmd() {
  ssh -i "$KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "${USER}@${HOST}" "$@"
}

ssh_cmd "sudo install -d -o ${USER} -g ${USER} /opt/active_directory"

echo "Syncing repo to ${HOST}..."
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

echo "Running remote bootstrap on ${HOST}..."
ssh_cmd "sudo bash /opt/active_directory/ec2/scripts/remote-bootstrap.sh ${ACTION}"
