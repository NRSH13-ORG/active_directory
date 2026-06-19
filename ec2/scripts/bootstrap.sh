#!/bin/bash
# EC2 bootstrap: rsync repo from Mac, or run Samba provision on the instance.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

install_docker() {
  export DEBIAN_FRONTEND=noninteractive

  if ! swapon --show | grep -q /swapfile; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  if command -v docker >/dev/null 2>&1 \
    && systemctl is-active --quiet docker 2>/dev/null \
    && docker info >/dev/null 2>&1; then
    return 0
  fi

  apt-get update
  apt-get install -y docker.io docker-compose-v2 ldap-utils rsync

  systemctl enable docker
  systemctl start docker

  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done

  docker info >/dev/null 2>&1 || { echo "Docker failed to start" >&2; exit 1; }

  if getent group docker >/dev/null 2>&1 && id ubuntu >/dev/null 2>&1; then
    usermod -aG docker ubuntu 2>/dev/null || true
  fi

  install -d -o ubuntu -g ubuntu /opt/ldap_platform_engineering
  touch /var/lib/cloud/instance/user-data.done 2>/dev/null || true
}

remote_bootstrap() {
  local action="${1:-apply}"
  local repo_dir="/opt/ldap_platform_engineering"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  cd "$repo_dir"

  if [[ ! -f .env ]]; then
    cp .env.example .env
  fi

  echo "Ensuring Docker is installed and running..."
  install_docker

  if [[ -d /opt/active_directory ]]; then
    echo "Removing legacy install path /opt/active_directory"
    (cd /opt/active_directory && docker compose down 2>/dev/null) || true
    rm -rf /opt/active_directory
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx 'samba-ad-dc'; then
    echo "Removing stale samba-ad-dc container (prior compose project)"
    docker rm -f samba-ad-dc || true
  fi

  chown -R ubuntu:ubuntu "$repo_dir"

  echo "Provisioning Samba AD (this may take several minutes)..."
  case "$action" in
    apply)
      bash -lc "cd ${repo_dir} && sh scripts/provision.sh --action apply"
      ;;
    destroy)
      bash -lc "cd ${repo_dir} && sh scripts/provision.sh --action destroy" || true
      ;;
    *)
      echo "Usage: $0 --remote apply|destroy" >&2
      exit 1
      ;;
  esac

  echo "Remote bootstrap finished successfully"
}

mac_sync_and_bootstrap() {
  local action="${1:-apply}"
  local host="${AD_EC2_HOST:-}"
  local user="${AD_EC2_SSH_USER:-ubuntu}"
  local key="${AD_EC2_SSH_PRIVATE_KEY:-${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}}"
  local repo_root="${AD_EC2_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

  key="${key/#\~/$HOME}"

  [[ -n "$host" ]] || { echo "AD_EC2_HOST is required" >&2; exit 1; }
  [[ -f "$key" ]] || { echo "SSH private key not found: $key" >&2; exit 1; }

  ssh_cmd() {
    ssh -i "$key" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "${user}@${host}" "$@"
  }

  ssh_cmd "sudo install -d -o ${user} -g ${user} /opt/ldap_platform_engineering"

  echo "Syncing repo to ${host}..."
  rsync -az --delete \
    --exclude '.git/' \
    --exclude '.env' \
    --exclude 'samba-data/' \
    --exclude 'samba-config/' \
    --exclude 'ec2/terraform/' \
    --exclude 'ec2/config.env' \
    --exclude 'ec2/state/instance.env' \
    -e "ssh -i ${key} -o StrictHostKeyChecking=accept-new" \
    "${repo_root}/" "${user}@${host}:/opt/ldap_platform_engineering/"

  echo "Running remote bootstrap on ${host}..."
  ssh_cmd "sudo bash /opt/ldap_platform_engineering/ec2/scripts/bootstrap.sh --remote ${action}"
}

usage() {
  echo "Usage:" >&2
  echo "  AD_EC2_HOST=x.x.x.x $0 [apply|destroy]     # from Mac — rsync + remote provision" >&2
  echo "  $0 --remote [apply|destroy]                  # on EC2 instance" >&2
  echo "  $0 --remote --docker-only                    # on EC2 — install Docker only" >&2
  exit 1
}

case "${1:-}" in
  --remote)
    shift
    if [[ "${1:-}" == "--docker-only" ]]; then
      install_docker
      exit 0
    fi
    remote_bootstrap "${1:-apply}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    mac_sync_and_bootstrap "${1:-apply}"
    ;;
esac
