#!/bin/bash
# Prepare a GitHub Actions runner for EC2 apply/destroy.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

EC2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_DIR="${HOME}/.ssh"
SSH_PRIVATE="${SSH_DIR}/ec2_provision"
SSH_PUBLIC="${SSH_DIR}/ec2_provision.pub"

log() { printf '%s\n' "$*"; }

log "Installing runner dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq ldap-utils dnsutils rsync curl python3

: "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY secret is required}"
: "${SSH_PUBLIC_KEY:?SSH_PUBLIC_KEY secret is required}"

log "Configuring SSH key pair"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
printf '%s\n' "$SSH_PRIVATE_KEY" >"$SSH_PRIVATE"
printf '%s\n' "$SSH_PUBLIC_KEY" >"$SSH_PUBLIC"
chmod 600 "$SSH_PRIVATE"
chmod 644 "$SSH_PUBLIC"

RUNNER_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
ADMIN_SSH_CIDR="${ADMIN_SSH_CIDR:-${RUNNER_IP}/32}"

log "Writing samba-ad/ec2/config.env (ADMIN_SSH_CIDR=${ADMIN_SSH_CIDR})"
cat >"$EC2_ROOT/config.env" <<EOF
AWS_REGION=${AWS_REGION:-ap-southeast-2}
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.micro}
PROJECT_NAME=${PROJECT_NAME:-samba-ad-dc}
KEY_NAME=${KEY_NAME:-samba-ad-dc}
SSH_USER=${SSH_USER:-ubuntu}
SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC}
SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE}
ADMIN_SSH_CIDR=${ADMIN_SSH_CIDR}
LDAP_INGRESS_CIDR=${LDAP_INGRESS_CIDR:-0.0.0.0/0}

CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID:-3e691c68591ed154e625790a60361b78}
CLOUDFLARE_TUNNEL_NAME=${CLOUDFLARE_TUNNEL_NAME:-ldap}
CLOUDFLARE_TUNNEL_ID=${CLOUDFLARE_TUNNEL_ID:-8e89df70-60cb-4a37-a36e-1e5060dce023}
CLOUDFLARE_ZONE_NAME=${CLOUDFLARE_ZONE_NAME:-nrsh13-hadoop.com}
CLOUDFLARE_LDAP_HOSTNAME=${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}
EOF

log "Verifying AWS credentials"
aws sts get-caller-identity

log "CI setup complete"
