#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# t3.micro (free tier) has 1 GiB RAM — swap helps Samba AD + Docker
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

apt-get update
apt-get install -y docker.io docker-compose-v2 ldap-utils rsync

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

install -d -o ubuntu -g ubuntu /opt/active_directory
