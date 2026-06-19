#!/bin/bash
set -euo pipefail

ACTION="${1:-apply}"

REPO_DIR="/opt/active_directory"
SSH_USER="${SUDO_USER:-ubuntu}"

cd "$REPO_DIR"

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

chown -R "${SSH_USER}:${SSH_USER}" "$REPO_DIR"

if ! groups "${SSH_USER}" | grep -q '\bdocker\b'; then
  usermod -aG docker "${SSH_USER}"
fi

systemctl is-active --quiet docker || systemctl start docker

case "$ACTION" in
  apply)
    sudo -u "${SSH_USER}" bash -lc "cd ${REPO_DIR} && sh scripts/provision.sh --action apply"
    ;;
  destroy)
    if [[ -d "$REPO_DIR" ]]; then
      sudo -u "${SSH_USER}" bash -lc "cd ${REPO_DIR} && sh scripts/provision.sh --action destroy" || true
    fi
    ;;
  *)
    echo "Usage: $0 apply|destroy" >&2
    exit 1
    ;;
esac
