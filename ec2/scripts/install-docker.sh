#!/bin/bash
# Install Docker on EC2 — used by user-data.sh and remote-bootstrap fallback.
set -euo pipefail

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
  exit 0
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

install -d -o ubuntu -g ubuntu /opt/active_directory
touch /var/lib/cloud/instance/user-data.done 2>/dev/null || true
