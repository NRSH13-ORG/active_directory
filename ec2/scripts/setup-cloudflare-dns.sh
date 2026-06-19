#!/bin/bash
# Point ldap.<zone> DNS-only A record at the EC2 public IP (direct LDAP, no client cloudflared).
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/ec2/state/instance.env"

# shellcheck source=../../scripts/terminal-colors.sh
source "$REPO_ROOT/scripts/terminal-colors.sh"

ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-nrsh13-hadoop.com}"
LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"
RECORD_NAME="${LDAP_HOSTNAME%.${ZONE_NAME}}"
[[ "$RECORD_NAME" == "$LDAP_HOSTNAME" ]] && RECORD_NAME="ldap"

usage() {
  print_module_header "EC2 — Cloudflare DNS (LDAP)"
  printf "${YELLOW}Synopsis${RESET}\n"
  usage_help_line "export CLOUDFLARE_API_TOKEN='…'"
  usage_help_line "sh ec2/scripts/setup-cloudflare-dns.sh"
  printf "\n"
  printf "  ${H_CYAN}Creates/updates DNS-only A record: ${LDAP_HOSTNAME} → EC2 public IP${RESET}\n\n"
  exit 1
}

[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { log_error "CLOUDFLARE_API_TOKEN is not set"; usage; }

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

main() {
  local ec2_ip zone_id lookup record_id payload

  if [[ -n "${EC2_PUBLIC_IP:-}" ]]; then
    ec2_ip="$EC2_PUBLIC_IP"
  elif [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1091
    source "$STATE_FILE"
    ec2_ip="${PUBLIC_IP:-}"
  fi
  [[ -n "$ec2_ip" ]] || { log_error "No EC2 public IP — run sh scripts/provision.sh --action apply --env ec2"; exit 1; }

  log_step "Updating Cloudflare DNS: ${LDAP_HOSTNAME} → ${ec2_ip} (DNS only)"

  zone_id="${CLOUDFLARE_ZONE_ID:-}"
  if [[ -z "$zone_id" ]]; then
    zone_id=$(cf_api GET "zones?name=${ZONE_NAME}&status=active" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0]["id"] if r else "")')
  fi
  [[ -n "$zone_id" ]] || { log_error "Zone not found: ${ZONE_NAME}"; exit 1; }

  lookup=$(cf_api GET "zones/${zone_id}/dns_records?name=${LDAP_HOSTNAME}")
  record_id=$(printf '%s' "$lookup" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0]["id"] if r else "")')

  payload=$(python3 -c 'import json,sys; print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"proxied":False,"ttl":120}))' \
    "$RECORD_NAME" "$ec2_ip")

  if [[ -n "$record_id" ]]; then
    cf_api PUT "zones/${zone_id}/dns_records/${record_id}" "$payload" >/dev/null
    log_success "DNS updated: ${LDAP_HOSTNAME} → ${ec2_ip} (DNS only)"
  else
    cf_api POST "zones/${zone_id}/dns_records" "$payload" >/dev/null
    log_success "DNS created: ${LDAP_HOSTNAME} → ${ec2_ip} (DNS only)"
  fi

  log_step "Testing LDAP via ${LDAP_HOSTNAME}:389"
  if ldapsearch -LLL \
    -H "ldap://${LDAP_HOSTNAME}:389" \
    -x \
    -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \
    -w "${ADMIN_PASS:-Dummy@2929}" \
    -b "DC=nrsh13-hadoop,DC=com" \
    "(sAMAccountName=768019)" 2>/dev/null | grep -q '^dn:'; then
    log_success "Direct LDAP query succeeded"
  else
    log_warning "LDAP test failed — wait for DNS TTL (~2 min) or re-run sync on EC2"
  fi
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
main
