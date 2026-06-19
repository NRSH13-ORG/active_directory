#!/bin/bash
set -euo pipefail

ACTION="${1:-apply}"

REPO_DIR="/opt/active_directory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_DIR"

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

echo "Ensuring Docker is installed and running..."
bash "$SCRIPT_DIR/install-docker.sh"

chown -R ubuntu:ubuntu "$REPO_DIR"

echo "Provisioning Samba AD (this may take several minutes)..."
case "$ACTION" in
  apply)
    bash -lc "cd ${REPO_DIR} && sh scripts/provision.sh --action apply"
    ;;
  destroy)
    bash -lc "cd ${REPO_DIR} && sh scripts/provision.sh --action destroy" || true
    ;;
  *)
    echo "Usage: $0 apply|destroy" >&2
    exit 1
    ;;
esac

echo "Remote bootstrap finished successfully"
