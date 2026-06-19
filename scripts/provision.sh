#!/bin/bash
# Re-exec with bash when invoked as `sh provision.sh` (macOS /bin/sh does not support bash syntax).
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail
SECONDS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SAMBA_AD_DIR="$ROOT_DIR/samba-ad"
export SAMBA_AD_DIR ROOT_DIR

# shellcheck source=terminal-colors.sh
source "$SCRIPT_DIR/terminal-colors.sh"

print_prerequisites_steps() {
  print_prerequisites_heading "Docker Desktop · ldapsearch (brew install openldap)"

  printf "  ${H_RED}1.${RESET} Copy and customize environment variables:\n"
  banner_cmd "cp samba-ad/.env.example samba-ad/.env"
  printf "  ${H_RED}2.${RESET} Provision the Samba AD domain controller (local):\n"
  banner_cmd "sh scripts/provision.sh --action apply"
  printf "  ${H_RED}3.${RESET} Provision on EC2:\n"
  banner_cmd "export AWS_ACCESS_KEY_ID='…' AWS_SECRET_ACCESS_KEY='…' CLOUDFLARE_API_TOKEN='…' && sh scripts/provision.sh --action apply --env ec2"
  printf "  ${H_RED}4.${RESET} Tear down local containers:\n"
  banner_cmd "sh scripts/provision.sh --action destroy"
  printf "  ${H_RED}5.${RESET} Tear down EC2:\n"
  banner_cmd "sh scripts/provision.sh --action destroy --env ec2"
  printf "\n"
}

usage() {
  print_module_header "LDAP platform engineering"

  printf "${YELLOW}Synopsis${RESET}\n"
  usage_help_line "sh scripts/provision.sh --action apply|destroy [--env local|ec2]"
  usage_synopsis_example "sh scripts/provision.sh --action apply"
  usage_synopsis_example "export AWS_ACCESS_KEY_ID='…' AWS_SECRET_ACCESS_KEY='…' CLOUDFLARE_API_TOKEN='…' && sh scripts/provision.sh --action apply --env ec2"
  usage_synopsis_example "sh scripts/provision.sh --action destroy --env ec2"
  printf "\n"

  printf "${YELLOW}Environments${RESET}\n"
  printf "  local  (default)  Docker on this Mac\n"
  printf "  ec2               AWS t3.micro + Cloudflare tunnel\n\n"

  printf "${YELLOW}Files${RESET}\n"
  printf "  samba-ad/.env.example           (copy to samba-ad/.env for local)\n"
  printf "  samba-ad/docker-compose.yml\n"
  printf "  samba-ad/ec2/config.env.example (copy to samba-ad/ec2/config.env for EC2)\n"
  printf "  samba-ad/ec2/state/instance.env (written after EC2 apply)\n\n"

  print_prerequisites_steps
  exit 1
}

load_config() {
  if [[ -f "$SAMBA_AD_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SAMBA_AD_DIR/.env"
    set +a
  fi

  DATA_DIR="${DATA_DIR:-$SAMBA_AD_DIR/data}"
  CONFIG_DIR="${CONFIG_DIR:-$SAMBA_AD_DIR/config}"
  IMAGE_NAME="${IMAGE_NAME:-local-samba-ad-dc}"
  CONTAINER_NAME="${CONTAINER_NAME:-samba-ad-dc}"
  DOMAIN="${DOMAIN:-NRSH13-HADOOP}"
  REALM="${REALM:-NRSH13-HADOOP.COM}"
  DNS_DOMAIN="${DNS_DOMAIN:-nrsh13-hadoop.com}"
  ADMIN_PASS="${ADMIN_PASS:-Dummy@2929}"
  USER_NAME="${USER_NAME:-768019}"
  USER_PASS="${USER_PASS:-Dummy@2929}"
  USER2_NAME="${USER2_NAME:-768020}"
  USER2_PASS="${USER2_PASS:-Dummy@2929}"
  GROUP_NAME="${GROUP_NAME:-A_HADOOP_ADMINS}"
  SECOND_GROUP_NAME="${SECOND_GROUP_NAME:-A_Kafka_Users_Dev}"
  CERT_BASENAME="${CERT_BASENAME:-kafka-lab01.nrsh13-hadoop.com}"
  ROOT_CA_CERT="${ROOT_CA_CERT:-root-ca.crt}"

  DEFAULT_CERT_DIRS=(
    "/usr/nrsh13/GitHub/aws_confluent_kafka_setup/confluent_kafka_setup_secure/selfSignedCertificates"
    "/var/ssl/private"
  )

  if [[ -n "${CERT_DIR:-}" ]]; then
    CERT_DIR="${CERT_DIR}"
  else
    CERT_DIR=""
    for candidate in "${DEFAULT_CERT_DIRS[@]}"; do
      if [[ -d "$candidate" ]]; then
        CERT_DIR="$candidate"
        break
      fi
    done
  fi

  if [[ -z "${CERT_DIR:-}" ]]; then
    CERT_DIR="/usr/nrsh13/GitHub/aws_confluent_kafka_setup/confluent_kafka_setup_secure/selfSignedCertificates"
  fi

  local candidate
  for candidate in "${ROOT_CA_CERT:-root-ca.crt}" "ca.crt"; do
    if [[ -f "$CERT_DIR/$candidate" ]]; then
      ROOT_CA_CERT="$candidate"
      break
    fi
  done
}

resolve_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    log_error "docker compose command not found"
    exit 1
  fi
}

migrate_samba_storage() {
  local legacy_data="${ROOT_DIR}/samba-data"
  local legacy_config="${ROOT_DIR}/samba-config"
  local vol

  [[ -f "${DATA_DIR}/private/secrets.tdb" ]] && return 0

  if [[ -d "$legacy_data" ]]; then
    log_info "Migrating legacy ${legacy_data} → ${DATA_DIR}"
    mkdir -p "$DATA_DIR"
    cp -a "${legacy_data}/." "${DATA_DIR}/"
  fi

  if [[ -d "$legacy_config" && ! -d "${CONFIG_DIR}/smb.conf.d" ]]; then
    log_info "Migrating legacy ${legacy_config} → ${CONFIG_DIR}"
    mkdir -p "$CONFIG_DIR"
    cp -a "${legacy_config}/." "${CONFIG_DIR}/" 2>/dev/null || true
  fi

  for vol in samba-ad_samba-data ldap_platform_engineering_samba-data samba-data; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
      log_info "Migrating Docker volume ${vol} → ${DATA_DIR}"
      mkdir -p "$DATA_DIR"
      docker run --rm \
        -v "${vol}:/from:ro" \
        -v "${DATA_DIR}:/to" \
        alpine:3.20 \
        sh -c 'cp -a /from/. /to/' || true
      break
    fi
  done

  for vol in samba-ad_samba-config ldap_platform_engineering_samba-config samba-config; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
      if [[ ! -f "${CONFIG_DIR}/smb.conf" ]]; then
        log_info "Migrating Docker volume ${vol} → ${CONFIG_DIR}"
        mkdir -p "$CONFIG_DIR"
        docker run --rm \
          -v "${vol}:/from:ro" \
          -v "${CONFIG_DIR}:/to" \
          alpine:3.20 \
          sh -c 'cp -a /from/. /to/' || true
      fi
      break
    fi
  done
}

exec_container() {
  docker exec "$CONTAINER_NAME" bash -lc "$1"
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false
}

find_cert_key_pair() {
  local dir="$1"

  if [[ -f "$dir/$CERT_BASENAME.crt" && -f "$dir/$CERT_BASENAME.key" ]]; then
    return 0
  fi

  local certfile base keyfile
  for certfile in "$dir"/*.crt; do
    [[ -e "$certfile" ]] || continue
    base=$(basename "$certfile" .crt)
    if [[ "$base" == "root-ca" || "$base" == "ca" ]]; then
      continue
    fi
    if [[ -f "$dir/$base.key" ]]; then
      CERT_BASENAME="$base"
      log_info "Using cert/key pair: $CERT_BASENAME.crt and $CERT_BASENAME.key"
      return 0
    fi
  done

  for keyfile in "$dir"/*.key; do
    [[ -e "$keyfile" ]] || continue
    base=$(basename "$keyfile" .key)
    if [[ -f "$dir/$base.crt" ]]; then
      CERT_BASENAME="$base"
      log_info "Using cert/key pair: $CERT_BASENAME.crt and $CERT_BASENAME.key"
      return 0
    fi
  done

  return 1
}

install_tls_certs() {
  if [[ ! -d "$CERT_DIR" ]]; then
    log_warning "certificate directory $CERT_DIR does not exist"
    return 0
  fi

  if [[ -f "$CERT_DIR/$CERT_BASENAME.crt" && -f "$CERT_DIR/$CERT_BASENAME.key" ]]; then
    log_step "Installing TLS certs from $CERT_DIR"
    exec_container "mkdir -p /var/lib/samba/private/tls"
    docker cp "$CERT_DIR/$CERT_BASENAME.crt" "$CONTAINER_NAME":/var/lib/samba/private/tls/cert.pem
    docker cp "$CERT_DIR/$CERT_BASENAME.key" "$CONTAINER_NAME":/var/lib/samba/private/tls/key.pem
    if [[ -f "$CERT_DIR/$ROOT_CA_CERT" ]]; then
      docker cp "$CERT_DIR/$ROOT_CA_CERT" "$CONTAINER_NAME":/var/lib/samba/private/tls/ca.pem
    fi
    exec_container "chown root:root /var/lib/samba/private/tls/* 2>/dev/null || true"
    exec_container "chmod 0600 /var/lib/samba/private/tls/key.pem"
  else
    log_warning "expected cert/key not found in $CERT_DIR"
  fi
}

configure_samba_tls() {
  if ! docker exec "$CONTAINER_NAME" test -f /etc/samba/smb.conf >/dev/null 2>&1; then
    return 0
  fi

  log_info "Configuring Samba TLS settings"
  docker exec "$CONTAINER_NAME" bash -lc "sed -i '/^[[:space:]]*tls enabled/d;/^[[:space:]]*tls keyfile/d;/^[[:space:]]*tls certfile/d;/^[[:space:]]*tls cafile/d;/^[[:space:]]*ldap server require strong auth/d' /etc/samba/smb.conf"

  if docker exec "$CONTAINER_NAME" test -f /var/lib/samba/private/tls/cert.pem >/dev/null 2>&1 \
    && docker exec "$CONTAINER_NAME" test -f /var/lib/samba/private/tls/key.pem >/dev/null 2>&1; then
    docker exec "$CONTAINER_NAME" bash -lc "awk '/^\[global\]/{print; print \"    ldap server require strong auth = no\"; print \"    tls enabled = yes\"; print \"    tls certfile = /var/lib/samba/private/tls/cert.pem\"; print \"    tls keyfile = /var/lib/samba/private/tls/key.pem\"; print \"    tls cafile = /var/lib/samba/private/tls/ca.pem\"; next}1' /etc/samba/smb.conf > /tmp/smb.conf.new && mv /tmp/smb.conf.new /etc/samba/smb.conf"
  else
    docker exec "$CONTAINER_NAME" bash -lc "awk '/^\[global\]/{print; print \"    ldap server require strong auth = no\"; next}1' /etc/samba/smb.conf > /tmp/smb.conf.new && mv /tmp/smb.conf.new /etc/samba/smb.conf"
    log_warning "TLS cert/key pair unavailable, LDAPS will not be enabled"
  fi
}

provision_users_and_groups() {
  local user group

  for user in "$USER_NAME" "$USER2_NAME"; do
    if ! exec_container "samba-tool user list | grep -x '$user'" >/dev/null 2>&1; then
      log_step "Creating user $user"
      exec_container "samba-tool user create '$user' '$USER_PASS' --use-username-as-cn --must-change-at-next-login"
    else
      log_info "User $user exists"
    fi

    log_info "Setting password for $user"
    exec_container "samba-tool user setpassword '$user' --newpassword='$USER_PASS'"
  done

  for group in "$GROUP_NAME" "$SECOND_GROUP_NAME"; do
    if ! exec_container "samba-tool group list | grep -x '$group'" >/dev/null 2>&1; then
      log_step "Creating group $group"
      exec_container "samba-tool group add '$group'"
    else
      log_info "Group $group exists"
    fi
  done

  log_step "Adding users to groups"
  for group in "$GROUP_NAME" "$SECOND_GROUP_NAME"; do
    for user in "$USER_NAME" "$USER2_NAME"; do
      if exec_container "samba-tool group listmembers '$group' | grep -x '$user'" >/dev/null 2>&1; then
        log_info "User $user already in group $group"
      else
        log_info "Adding $user to $group"
        exec_container "samba-tool group addmembers '$group' '$user'"
      fi
    done
  done
}

print_sample_ldapsearch() {
  log_step "Sample ldapsearch command from the Mac host"

  cat <<EOF
Your Samba AD DC container is running as: $CONTAINER_NAME
LDAP host: localhost
Base DN: DC=nrsh13-hadoop,DC=com
Realm: $REALM
Password: $ADMIN_PASS

ldapsearch -LLL \\
  -H ldap://127.0.0.1:389 \\
  -x \\
  -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \\
  -w '$ADMIN_PASS' \\
  -b "DC=nrsh13-hadoop,DC=com" \\
  "(sAMAccountName=$USER_NAME)"

EOF
}

action_apply() {
  print_module_header "LDAP platform engineering — apply"

  load_config
  resolve_compose_cmd

  if [[ -d "$CERT_DIR" ]] && ! find_cert_key_pair "$CERT_DIR"; then
    log_warning "expected cert/key pair not found in $CERT_DIR"
  fi

  migrate_samba_storage
  mkdir -p "$DATA_DIR" "$CONFIG_DIR"

  log_step "Building Samba AD DC image"
  cd "$SAMBA_AD_DIR"
  docker build -t "$IMAGE_NAME" .

  log_step "Starting container with persistent Samba volume"
  cd "$SAMBA_AD_DIR"
  $COMPOSE_CMD down || true
  $COMPOSE_CMD up -d

  install_tls_certs

  if [[ "$(container_running)" != "true" ]]; then
    log_info "Waiting for container $CONTAINER_NAME to start"
    sleep 3
  fi

  if ! docker exec "$CONTAINER_NAME" test -f /var/lib/samba/private/secrets.tdb >/dev/null 2>&1; then
    log_step "Provisioning Samba AD domain $REALM"
    exec_container "rm -f /etc/samba/smb.conf"
    exec_container "samba-tool domain provision --use-rfc2307 --realm='$REALM' --domain='$DOMAIN' --adminpass='$ADMIN_PASS' --server-role=dc --dns-backend=SAMBA_INTERNAL"
  else
    log_info "Samba AD already provisioned"
  fi

  configure_samba_tls

  log_step "Setting Administrator password"
  exec_container "samba-tool user setpassword Administrator --newpassword='$ADMIN_PASS'"

  log_step "Restarting Samba"
  exec_container "pkill -f '^samba:' || true"
  exec_container "sleep 1 || true"

  log_step "Starting Samba AD DC"
  exec_container "nohup samba -i >/var/log/samba.log 2>&1 &"

  log_step "Waiting for LDAP (389)"
  exec_container "bash -lc 'for i in {1..30}; do echo > /dev/tcp/127.0.0.1/389 && exit 0; sleep 1; done; exit 1'"

  provision_users_and_groups

  log_step "LDAP test (connectivity check only)"
  if exec_container "ldapsearch -LLL -H ldap://localhost -x -D 'CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com' -w '$ADMIN_PASS' -b 'DC=nrsh13-hadoop,DC=com' '(sAMAccountName=$USER_NAME)'" >/dev/null 2>&1; then
    log_success "LDAP query successful"
  else
    log_error "LDAP query failed"
    exit 1
  fi

  print_sample_ldapsearch
  log_success "LDAP platform engineering apply complete"
}

action_destroy() {
  print_module_header "LDAP platform engineering — destroy"

  load_config
  resolve_compose_cmd

  log_step "Stopping containers and removing volumes"
  cd "$SAMBA_AD_DIR"
  $COMPOSE_CMD down -v

  log_success "LDAP platform engineering destroy complete"
}

ACTION=""
ENV="local"

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --action)
      shift
      ACTION="${1:-}"
      if [[ -z "$ACTION" ]]; then
        log_error "Missing value for --action (use apply|destroy)"
        usage
      fi
      ;;
    --env)
      shift
      ENV="${1:-}"
      if [[ -z "$ENV" ]]; then
        log_error "Missing value for --env (use local|ec2)"
        usage
      fi
      ;;
    -h|h|--help|help)
      usage
      ;;
    *)
      log_error "Invalid option: $1"
      usage
      ;;
  esac
  shift
done

if [[ -z "$ACTION" ]]; then
  usage
fi

if [[ ! "$ENV" =~ ^(local|ec2)$ ]]; then
  log_error "Invalid --env: $ENV (use local|ec2)"
  usage
fi

if [[ "$ENV" == "local" ]]; then
  if [[ ! "$ACTION" =~ ^(apply|destroy)$ ]]; then
    log_error "Invalid --action for local: $ACTION (use apply|destroy)"
    usage
  fi
  if [[ "$ACTION" == "apply" ]]; then
    action_apply
  else
    action_destroy
  fi
else
  # shellcheck source=../samba-ad/ec2/provision-ec2.sh
  source "$SAMBA_AD_DIR/ec2/provision-ec2.sh"

  if [[ ! "$ACTION" =~ ^(apply|destroy)$ ]]; then
    log_error "Invalid --action for ec2: $ACTION (use apply|destroy)"
    ec2_usage
  fi

  ec2_print_action_header "$ACTION"
  ec2_assert_prerequisites "$ACTION"

  case "$ACTION" in
    apply)
      ec2_action_apply || ec2_usage
      ;;
    destroy)
      ec2_action_destroy
      ;;
  esac
fi

duration=$SECONDS
printf "\nTotal script execution time: %02d:%02d:%02d\n\n" $((duration / 3600)) $((duration / 60 % 60)) $((duration % 60))
