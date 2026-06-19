#!/bin/bash
# Mac local LDAP DNS: flush cache, /etc/hosts block, or cleanup on destroy.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/terminal-colors.sh
source "$REPO_ROOT/scripts/terminal-colors.sh"

LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"
EC2_IP="${EC2_PUBLIC_IP:-}"
HOSTS_BEGIN="# BEGIN samba-ad-ec2"
HOSTS_END="# END samba-ad-ec2"

usage() {
  print_module_header "EC2 — local LDAP DNS (Mac)"
  usage_help_line "EC2_PUBLIC_IP=x.x.x.x sh ec2/scripts/local-ldap-dns.sh apply"
  usage_help_line "sh ec2/scripts/local-ldap-dns.sh cleanup"
  printf "\n"
  exit 1
}

flush_macos_dns_cache() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  log_info "Flushing macOS DNS cache"
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

flush_macos_dns_cache_quiet() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

wait_for_public_dns() {
  local attempt resolved
  log_step "Waiting for public DNS: ${LDAP_HOSTNAME} → ${EC2_IP}"
  for attempt in $(seq 1 36); do
    resolved="$(dig +short "@1.1.1.1" "$LDAP_HOSTNAME" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
    if [[ "$resolved" == "$EC2_IP" ]]; then
      log_success "Public DNS propagated (${LDAP_HOSTNAME} → ${EC2_IP})"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      log_info "Public DNS not ready yet (got: ${resolved:-none}, want: ${EC2_IP})..."
    fi
    sleep 5
  done
  log_error "Public DNS did not propagate to ${EC2_IP} within 3 minutes"
  exit 1
}

update_etc_hosts() {
  log_step "Updating /etc/hosts for ${LDAP_HOSTNAME} → ${EC2_IP}"
  sudo python3 - "$EC2_IP" "$LDAP_HOSTNAME" "$HOSTS_BEGIN" "$HOSTS_END" <<'PY'
import sys
ip, host, begin, end = sys.argv[1:5]
path = "/etc/hosts"
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
out, skip = [], False
for line in lines:
    stripped = line.strip()
    if stripped == begin:
        skip = True
        continue
    if stripped == end:
        skip = False
        continue
    if skip:
        continue
    if host in line and not stripped.startswith("#"):
        continue
    out.append(line)
out.extend([begin, f"{ip} {host}", end])
open(path, "w").write("\n".join(out) + "\n")
PY
  log_success "/etc/hosts updated"
}

wait_for_local_resolution() {
  local attempt resolved
  log_step "Verifying local resolution for ${LDAP_HOSTNAME}"
  flush_macos_dns_cache
  for attempt in $(seq 1 24); do
    if (( attempt > 1 && attempt % 3 == 0 )); then
      flush_macos_dns_cache_quiet
    fi
    resolved="$(dig +short "$LDAP_HOSTNAME" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
    if [[ "$resolved" == "$EC2_IP" ]]; then
      log_success "Local resolver: ${LDAP_HOSTNAME} → ${resolved}"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      log_info "Local DNS still stale (got: ${resolved:-none}, want: ${EC2_IP})..."
    fi
    sleep 5
  done
  log_error "Local hostname ${LDAP_HOSTNAME} does not resolve to ${EC2_IP}"
  exit 1
}

apply_local_dns() {
  [[ -n "$EC2_IP" ]] || { log_error "EC2_PUBLIC_IP is required"; usage; }

  if [[ "$(uname -s)" != "Darwin" ]]; then
    log_info "Skipping local DNS setup (not macOS)"
    wait_for_public_dns
    return 0
  fi

  log_step "Local DNS setup (sudo required once for /etc/hosts)"
  if ! sudo -n true 2>/dev/null; then
    log_info "Enter your Mac password when prompted (updates /etc/hosts + DNS cache)"
    sudo -v
  fi

  wait_for_public_dns
  flush_macos_dns_cache
  update_etc_hosts
  flush_macos_dns_cache
  wait_for_local_resolution
}

cleanup_local_dns() {
  [[ "$(uname -s)" == "Darwin" ]] || exit 0

  if ! sudo -n true 2>/dev/null; then
    sudo -v
  fi

  sudo python3 - "$HOSTS_BEGIN" "$HOSTS_END" <<'PY'
import sys
begin, end = sys.argv[1:3]
path = "/etc/hosts"
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    sys.exit(0)
out, skip = [], False
for line in lines:
    stripped = line.strip()
    if stripped == begin:
        skip = True
        continue
    if stripped == end:
        skip = False
        continue
    if skip:
        continue
    out.append(line)
open(path, "w").write("\n".join(out) + ("\n" if out else ""))
PY
}

ACTION="${1:-apply}"
[[ "${ACTION}" == "-h" || "${ACTION}" == "--help" ]] && usage

case "$ACTION" in
  apply)
    apply_local_dns
    ;;
  cleanup)
    cleanup_local_dns
    ;;
  *)
    log_error "Unknown action: ${ACTION} (use apply|cleanup)"
    usage
    ;;
esac
