#!/bin/bash
# Install cloudflared on EC2, configure LDAP TCP tunnel route, wait until HEALTHY.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/ec2/state/instance.env"

# shellcheck source=../../scripts/terminal-colors.sh
source "$REPO_ROOT/scripts/terminal-colors.sh"

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-3e691c68591ed154e625790a60361b78}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-8e89df70-60cb-4a37-a36e-1e5060dce023}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-ldap}"
ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-nrsh13-hadoop.com}"
LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"
LDAP_ORIGIN="${CLOUDFLARE_LDAP_ORIGIN:-tcp://localhost:389}"

usage() {
  print_module_header "EC2 — Cloudflare Tunnel (LDAP)"
  printf "${YELLOW}Synopsis${RESET}\n"
  usage_help_line "export CLOUDFLARE_API_TOKEN='…'"
  usage_help_line "EC2_PUBLIC_IP=x.x.x.x sh ec2/scripts/setup-cloudflare-tunnel.sh"
  printf "\n"
  printf "  ${H_CYAN}Prerequisite: Zero Trust tunnel '%s' created in Cloudflare UI${RESET}\n" "$TUNNEL_NAME"
  printf "  ${H_CYAN}TCP route: %s → localhost:389${RESET}\n\n" "$LDAP_HOSTNAME"
  exit 1
}

[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { log_error "CLOUDFLARE_API_TOKEN is not set"; usage; }

CONFIG_FILE="$REPO_ROOT/ec2/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$ACCOUNT_ID}"
  TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-$TUNNEL_ID}"
  TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-$TUNNEL_NAME}"
  ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-$ZONE_NAME}"
  LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-$LDAP_HOSTNAME}"
fi

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

resolve_ec2_host() {
  local host="${EC2_PUBLIC_IP:-}"
  if [[ -z "$host" && -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1091
    source "$STATE_FILE"
    host="${PUBLIC_IP:-}"
    SSH_USER="${SSH_USER:-ubuntu}"
    SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}"
  fi
  [[ -n "$host" ]] || { log_error "No EC2 public IP — set EC2_PUBLIC_IP or run apply first"; exit 1; }
  SSH_USER="${AD_EC2_SSH_USER:-${SSH_USER:-ubuntu}}"
  SSH_PRIVATE_KEY_PATH="${AD_EC2_SSH_PRIVATE_KEY:-${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"
  EC2_HOST="$host"
}

fetch_tunnel_token() {
  local response token
  log_info "Fetching connector token for tunnel ${TUNNEL_NAME} (${TUNNEL_ID})" >&2
  response=$(cf_api GET "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
  token=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))')
  [[ -n "$token" ]] || { log_error "Failed to fetch tunnel connector token"; exit 1; }
  printf '%s' "$token"
}

ensure_tunnel_route() {
  local payload

  log_step "Configuring tunnel TCP route: ${LDAP_HOSTNAME} → ${LDAP_ORIGIN}"

  payload=$(python3 -c 'import json,sys; print(json.dumps({"config":{"ingress":[{"hostname":sys.argv[1],"service":sys.argv[2],"originRequest":{}},{"service":"http_status:404"}]}}))' \
    "$LDAP_HOSTNAME" "$LDAP_ORIGIN")
  cf_api PUT "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "$payload" >/dev/null
  log_success "Tunnel ingress: ${LDAP_HOSTNAME} → ${LDAP_ORIGIN}"
  log_info "LDAP DNS is configured separately as DNS-only A record (proxied CNAME breaks LDAP)" >&2
}

install_cloudflared_on_ec2() {
  local token="$1"

  log_step "Installing cloudflared on ${SSH_USER}@${EC2_HOST}"
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
}

wait_for_tunnel_healthy() {
  local attempt status response
  log_step "Waiting for Cloudflare tunnel '${TUNNEL_NAME}' to become HEALTHY"
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

main() {
  local token
  resolve_ec2_host
  ensure_tunnel_route
  token="$(fetch_tunnel_token)"
  install_cloudflared_on_ec2 "$token"
  wait_for_tunnel_healthy
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
main
