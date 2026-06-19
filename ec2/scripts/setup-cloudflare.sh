#!/bin/bash
# Cloudflare tunnel (cloudflared on EC2) + DNS-only A record for LDAP.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/ec2/state/instance.env"
CONFIG_FILE="$REPO_ROOT/ec2/config.env"

# shellcheck source=../../scripts/terminal-colors.sh
source "$REPO_ROOT/scripts/terminal-colors.sh"

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-3e691c68591ed154e625790a60361b78}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-8e89df70-60cb-4a37-a36e-1e5060dce023}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-ldap}"
ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-nrsh13-hadoop.com}"
LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"
LDAP_ORIGIN="${CLOUDFLARE_LDAP_ORIGIN:-tcp://localhost:389}"

EC2_HOST=""
SSH_USER="${AD_EC2_SSH_USER:-ubuntu}"
SSH_PRIVATE_KEY_PATH="${AD_EC2_SSH_PRIVATE_KEY:-${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}}"

usage() {
  print_module_header "EC2 — Cloudflare (tunnel + DNS)"
  printf "${YELLOW}Synopsis${RESET}\n"
  usage_help_line "export CLOUDFLARE_API_TOKEN='…'"
  usage_help_line "EC2_PUBLIC_IP=x.x.x.x sh ec2/scripts/setup-cloudflare.sh [tunnel|dns|all]"
  printf "\n"
  exit 1
}

load_cloudflare_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$ACCOUNT_ID}"
    TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-$TUNNEL_ID}"
    TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-$TUNNEL_NAME}"
    ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-$ZONE_NAME}"
    LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-$LDAP_HOSTNAME}"
  fi
}

[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { log_error "CLOUDFLARE_API_TOKEN is not set"; usage; }
load_cloudflare_config

cf_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local response
  if [[ -n "$data" ]]; then
    response=$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4/${endpoint}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data")
  else
    response=$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4/${endpoint}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
  fi
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("success") else 1)' <<<"$response"
  printf '%s' "$response"
}

resolve_ec2_ip() {
  local ec2_ip="${EC2_PUBLIC_IP:-}"
  if [[ -z "$ec2_ip" && -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1091
    source "$STATE_FILE"
    ec2_ip="${PUBLIC_IP:-}"
    SSH_USER="${SSH_USER:-ubuntu}"
    SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}"
  fi
  [[ -n "$ec2_ip" ]] || { log_error "No EC2 public IP — run sh scripts/provision.sh --action apply --env ec2"; exit 1; }
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"
  EC2_HOST="$ec2_ip"
}

fetch_tunnel_token() {
  local response token
  log_info "Fetching connector token for tunnel ${TUNNEL_NAME} (${TUNNEL_ID})" >&2
  response=$(cf_api GET "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
  token=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))')
  [[ -n "$token" ]] || { log_error "Failed to fetch tunnel connector token"; exit 1; }
  printf '%s' "$token"
}

setup_tunnel() {
  local token payload

  resolve_ec2_ip

  log_step "Configuring tunnel TCP route: ${LDAP_HOSTNAME} → ${LDAP_ORIGIN}"
  payload=$(python3 -c 'import json,sys; print(json.dumps({"config":{"ingress":[{"hostname":sys.argv[1],"service":sys.argv[2],"originRequest":{}},{"service":"http_status:404"}]}}))' \
    "$LDAP_HOSTNAME" "$LDAP_ORIGIN")
  cf_api PUT "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "$payload" >/dev/null
  log_success "Tunnel ingress: ${LDAP_HOSTNAME} → ${LDAP_ORIGIN}"
  log_info "LDAP DNS is configured separately as DNS-only A record (proxied CNAME breaks LDAP)" >&2

  log_step "Installing cloudflared on ${SSH_USER}@${EC2_HOST}"
  token="$(fetch_tunnel_token)"
  if ! ssh -i "$SSH_PRIVATE_KEY_PATH" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    "${SSH_USER}@${EC2_HOST}" \
    bash -s "$token" <<'REMOTE'
set -euo pipefail
TUNNEL_TOKEN="$1"

if ! command -v cloudflared >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  cd "$tmp"
  curl -fsSL -o cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i cloudflared.deb
  rm -rf "$tmp"
fi

if systemctl is-enabled cloudflared >/dev/null 2>&1; then
  sudo cloudflared service uninstall 2>/dev/null || true
fi

sudo cloudflared service install "${TUNNEL_TOKEN}"
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

for _ in $(seq 1 30); do
  systemctl is-active --quiet cloudflared && exit 0
  sleep 2
done
echo "cloudflared service failed to start" >&2
exit 1
REMOTE
  then
    log_error "cloudflared install failed on ${EC2_HOST}"
    exit 1
  fi
  log_success "cloudflared service is active on EC2"

  log_step "Waiting for Cloudflare tunnel '${TUNNEL_NAME}' to become HEALTHY"
  local attempt status response
  for attempt in $(seq 1 90); do
    response=$(cf_api GET "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}")
    status=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("status","unknown"))')
    if [[ "$status" == "healthy" ]]; then
      log_success "Tunnel '${TUNNEL_NAME}' is HEALTHY"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      log_info "Tunnel status: ${status} (${attempt}/90)..." >&2
    fi
    sleep 10
  done
  log_error "Tunnel '${TUNNEL_NAME}' not HEALTHY after 15 minutes (last status: ${status})"
  exit 1
}

setup_dns() {
  local ec2_ip zone_id lookup record_id record_type payload
  local record_name="${LDAP_HOSTNAME%.${ZONE_NAME}}"
  [[ "$record_name" == "$LDAP_HOSTNAME" ]] && record_name="ldap"

  resolve_ec2_ip
  ec2_ip="$EC2_HOST"

  log_step "Updating Cloudflare DNS: ${LDAP_HOSTNAME} → ${ec2_ip} (DNS only)"

  zone_id="${CLOUDFLARE_ZONE_ID:-}"
  if [[ -z "$zone_id" ]]; then
    zone_id=$(cf_api GET "zones?name=${ZONE_NAME}&status=active" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0]["id"] if r else "")')
  fi
  [[ -n "$zone_id" ]] || { log_error "Zone not found: ${ZONE_NAME}"; exit 1; }

  lookup=$(cf_api GET "zones/${zone_id}/dns_records?name=${LDAP_HOSTNAME}")
  record_id=$(printf '%s' "$lookup" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0]["id"] if r else "")')
  record_type=$(printf '%s' "$lookup" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0]["type"] if r else "")')

  if [[ -n "$record_id" && "$record_type" != "A" ]]; then
    log_info "Removing ${record_type} record for ${LDAP_HOSTNAME} (LDAP requires DNS-only A record)"
    cf_api DELETE "zones/${zone_id}/dns_records/${record_id}" >/dev/null
    record_id=""
  fi

  payload=$(python3 -c 'import json,sys; print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"proxied":False,"ttl":120}))' \
    "$record_name" "$ec2_ip")

  if [[ -n "$record_id" ]]; then
    cf_api PUT "zones/${zone_id}/dns_records/${record_id}" "$payload" >/dev/null
    log_success "DNS updated: ${LDAP_HOSTNAME} → ${ec2_ip} (DNS only)"
  else
    cf_api POST "zones/${zone_id}/dns_records" "$payload" >/dev/null
    log_success "DNS created: ${LDAP_HOSTNAME} → ${ec2_ip} (DNS only)"
  fi
}

ACTION="${1:-all}"
[[ "${ACTION}" == "-h" || "${ACTION}" == "--help" ]] && usage

case "$ACTION" in
  tunnel)
    setup_tunnel
    ;;
  dns)
    setup_dns
    ;;
  all)
    setup_tunnel
    setup_dns
    ;;
  *)
    log_error "Unknown action: ${ACTION} (use tunnel|dns|all)"
    usage
    ;;
esac
