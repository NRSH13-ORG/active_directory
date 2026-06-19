# EC2 provisioning — sourced by scripts/provision.sh when --env ec2.
# Helper scripts live in ec2/scripts/.

EC2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EC2_SCRIPTS="$EC2_ROOT/scripts"
STATE_DIR="$EC2_ROOT/state"
STATE_FILE="$STATE_DIR/instance.env"
CONFIG_FILE="$EC2_ROOT/config.env"

ec2_print_prerequisites_steps() {
  print_prerequisites_heading "AWS credentials · AWS CLI · rsync · SSH key · Cloudflare API token"

  printf "  ${H_RED}1.${RESET} Export AWS credentials:\n"
  banner_cmd "export AWS_ACCESS_KEY_ID='…'"
  banner_cmd "export AWS_SECRET_ACCESS_KEY='…'"
  printf "  ${H_RED}2.${RESET} Export Cloudflare API token:\n"
  banner_cmd "export CLOUDFLARE_API_TOKEN='…'"
  printf "  ${H_RED}3.${RESET} Verify AWS access:\n"
  banner_cmd "aws sts get-caller-identity"
  printf "  ${H_RED}4.${RESET} Deploy Samba AD on EC2 (t3.micro free tier):\n"
  banner_cmd "sh scripts/provision.sh --action apply --env ec2"
  printf "  ${H_RED}5.${RESET} Test LDAP from anywhere:\n"
  banner_cmd "ldapsearch -LLL -H ldap://ldap.nrsh13-hadoop.com:389 -x -D \"CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com\" -w 'Dummy@2929' -b \"DC=nrsh13-hadoop,DC=com\" \"(sAMAccountName=768019)\""
  printf "  ${H_RED}6.${RESET} Tear down EC2:\n"
  banner_cmd "sh scripts/provision.sh --action destroy --env ec2"
  printf "\n"
}

ec2_usage() {
  print_module_header "Samba Active Directory — EC2"

  printf "${YELLOW}Synopsis${RESET}\n"
  usage_help_line "sh scripts/provision.sh --action apply|destroy --env ec2"
  usage_synopsis_example "export AWS_ACCESS_KEY_ID='…' AWS_SECRET_ACCESS_KEY='…' CLOUDFLARE_API_TOKEN='…' && sh scripts/provision.sh --action apply --env ec2"
  usage_synopsis_example "sh scripts/provision.sh --action destroy --env ec2"
  printf "\n"

  printf "${YELLOW}Files${RESET}\n"
  printf "  ec2/config.env.example (copy to ec2/config.env and customize)\n"
  printf "  ec2/state/instance.env  (written after apply)\n\n"

  ec2_print_prerequisites_steps
  exit 1
}

ec2_print_action_header() {
  local action="$1"
  case "$action" in
    apply)   print_module_header "Samba Active Directory — EC2 apply" ;;
    destroy) print_module_header "Samba Active Directory — EC2 destroy" ;;
    *)       print_module_header "Samba Active Directory — EC2" ;;
  esac
}

ec2_assert_command() {
  local cmd="$1"
  local label="$2"
  local install_hint="${3:-}"

  command -v "$cmd" >/dev/null 2>&1 || {
    if [[ -n "$install_hint" ]]; then
      log_check_failed "${label} not found — ${install_hint}"
    else
      log_check_failed "${label} not found"
    fi
    ec2_usage
  }
  log_check_success "${label} is installed"
}

ec2_assert_ssh_key() {
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"
  [[ -f "$SSH_PRIVATE_KEY_PATH" ]] || {
    log_check_failed "SSH private key not found — expected at ${SSH_PRIVATE_KEY_PATH}"
    ec2_usage
  }
  log_check_success "SSH private key — ${SSH_PRIVATE_KEY_PATH}"
}

ec2_assert_aws_cli() {
  command -v aws >/dev/null 2>&1 || {
    log_check_failed "AWS CLI (aws) not found — install AWS CLI and re-run"
    ec2_usage
  }
  log_check_success "AWS CLI (aws) is installed"
}

ec2_assert_aws_credentials() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    log_check_success "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set"
    return 0
  fi
  if aws sts get-caller-identity >/dev/null 2>&1; then
    log_check_success "AWS credentials — valid session (aws sts get-caller-identity)"
    return 0
  fi
  log_check_failed "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are not set"
  ec2_usage
}

ec2_assert_cloudflare_token() {
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || {
    log_check_failed "CLOUDFLARE_API_TOKEN is not set"
    ec2_usage
  }
  log_check_success "CLOUDFLARE_API_TOKEN is set"
}

ec2_assert_prerequisites() {
  local action="${1:-}"

  print_prerequisites_heading "AWS credentials · AWS CLI · rsync · SSH key · Cloudflare API token"
  log_step "Prerequisites checks"

  ec2_assert_aws_cli
  ec2_assert_aws_credentials
  ec2_assert_command dig "dig"
  ec2_assert_command ldapsearch "ldapsearch" "install: brew install openldap"
  ec2_assert_command rsync "rsync"

  ec2_load_config

  case "$action" in
    apply|destroy)
      ec2_assert_ssh_key
      ;;
  esac

  case "$action" in
    apply)
      ec2_assert_cloudflare_token
      ;;
  esac
}

ec2_admin_pass() {
  local admin_pass="${ADMIN_PASS:-Dummy@2929}"
  if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    admin_pass="${ADMIN_PASS:-Dummy@2929}"
  fi
  printf '%s' "$admin_pass"
}

ec2_ldapsearch_query() {
  local host="$1" admin_pass="$2" user_filter="${3:-768019}"
  LDAPTIMEOUT=5 ldapsearch -LLL \
    -o nettimeout=5 \
    -H "ldap://${host}:389" \
    -x \
    -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \
    -w "$admin_pass" \
    -b "DC=nrsh13-hadoop,DC=com" \
    "(sAMAccountName=${user_filter})" 2>/dev/null | grep -q '^dn:'
}

ec2_load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "$EC2_ROOT/config.env.example" "$CONFIG_FILE"
    log_info "Created $CONFIG_FILE"
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  AWS_REGION="${AWS_REGION:-ap-southeast-2}"
  INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
  PROJECT_NAME="${PROJECT_NAME:-samba-ad-dc}"
  KEY_NAME="${KEY_NAME:-samba-ad-dc}"
  SSH_USER="${SSH_USER:-ubuntu}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}"
  LDAP_INGRESS_CIDR="${LDAP_INGRESS_CIDR:-0.0.0.0/0}"
  ADMIN_SSH_CIDR="${ADMIN_SSH_CIDR:-$(curl -fsS https://checkip.amazonaws.com)/32}"

  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE/#\~/$HOME}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"
  export AWS_DEFAULT_REGION="$AWS_REGION" AWS_REGION
}

ec2_save_state() {
  mkdir -p "$STATE_DIR"
  cat >"$STATE_FILE" <<EOF
INSTANCE_ID=${INSTANCE_ID}
PUBLIC_IP=${PUBLIC_IP}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
KEY_NAME=${KEY_NAME}
SSH_USER=${SSH_USER}
SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH}
AWS_REGION=${AWS_REGION}
EOF
}

ec2_load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"
}

ec2_ensure_key_pair() {
  local pub_key
  [[ -f "$SSH_PUBLIC_KEY_FILE" ]] || { log_error "SSH public key not found: $SSH_PUBLIC_KEY_FILE"; exit 1; }
  pub_key="$(tr -d '\n' <"$SSH_PUBLIC_KEY_FILE")"

  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    log_info "Key pair $KEY_NAME exists"
  else
    log_step "Creating key pair $KEY_NAME"
    aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "$pub_key" >/dev/null
    log_success "Key pair created"
  fi
}

ec2_ensure_security_group() {
  local vpc_id sg_name="$PROJECT_NAME-sg"
  vpc_id="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [[ "$vpc_id" != "None" && -n "$vpc_id" ]] || { log_error "No default VPC in $AWS_REGION"; exit 1; }

  SECURITY_GROUP_ID="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$sg_name" "Name=vpc-id,Values=$vpc_id" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

  if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" == "None" ]]; then
    log_step "Creating security group $sg_name"
    SECURITY_GROUP_ID="$(aws ec2 create-security-group \
      --group-name "$sg_name" \
      --description "Samba AD DC" \
      --vpc-id "$vpc_id" \
      --query 'GroupId' --output text)"
  fi

  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${ADMIN_SSH_CIDR},Description=SSH}]" 2>/dev/null || true
  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=389,ToPort=389,IpRanges=[{CidrIp=${LDAP_INGRESS_CIDR},Description=LDAP}]" 2>/dev/null || true
  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=636,ToPort=636,IpRanges=[{CidrIp=${LDAP_INGRESS_CIDR},Description=LDAPS}]" 2>/dev/null || true

  log_info "Security group: $SECURITY_GROUP_ID"
}

ec2_resolve_ami() {
  aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
}

ec2_find_running_instance() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$PROJECT_NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true
}

ec2_wait_for_instance() {
  log_info "Waiting for instance $INSTANCE_ID"
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || { log_error "No public IP"; exit 1; }
  log_success "Instance at $PUBLIC_IP"
}

ec2_wait_for_ssh() {
  local attempt
  log_info "Waiting for SSH ${SSH_USER}@${PUBLIC_IP}"
  for attempt in $(seq 1 36); do
    if ssh -i "$SSH_PRIVATE_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${SSH_USER}@${PUBLIC_IP}" "echo ready" >/dev/null 2>&1; then
      log_success "SSH ready"
      return 0
    fi
    sleep 5
  done
  log_error "SSH timeout"
  exit 1
}

ec2_ssh() {
  ssh -i "$SSH_PRIVATE_KEY_PATH" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "${SSH_USER}@${PUBLIC_IP}" "$@"
}

ec2_instance_docker_ready() {
  ec2_ssh 'command -v docker >/dev/null \
    && systemctl is-active --quiet docker \
    && docker info >/dev/null 2>&1' 2>/dev/null
}

ec2_wait_for_cloud_init_and_docker() {
  local attempt
  log_step "Waiting for cloud-init and Docker on ${PUBLIC_IP}"
  for attempt in $(seq 1 90); do
    if ec2_instance_docker_ready; then
      log_success "Docker ready on instance"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      log_info "Still waiting for cloud-init/Docker (${attempt}/90)..."
    fi
    sleep 10
  done

  log_warning "Docker not ready after 15 min — installing on instance via SSH"
  if ! ec2_ssh "sudo bash -s" <"$EC2_SCRIPTS/install-docker.sh"; then
    log_error "Failed to install Docker on instance"
    exit 1
  fi

  for attempt in $(seq 1 30); do
    if ec2_instance_docker_ready; then
      log_success "Docker ready on instance"
      return 0
    fi
    sleep 5
  done

  log_error "Docker not available on instance after install attempt"
  exit 1
}

ec2_sync_and_bootstrap() {
  log_step "Syncing repo and bootstrapping AD on ${PUBLIC_IP}"
  if ! AD_EC2_HOST="$PUBLIC_IP" \
    AD_EC2_SSH_USER="$SSH_USER" \
    AD_EC2_SSH_PRIVATE_KEY="$SSH_PRIVATE_KEY_PATH" \
    AD_EC2_REPO_ROOT="$ROOT_DIR" \
    bash "$EC2_SCRIPTS/sync-and-bootstrap.sh" apply; then
    log_error "Sync and bootstrap failed on ${PUBLIC_IP}"
    exit 1
  fi
  log_success "Sync and bootstrap complete"
}

ec2_resolve_ldap_host() {
  local host="$1"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$host"
    return 0
  fi
  dig +short "$host" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

ec2_ldapsearch_test() {
  local host="$1" admin_pass="$2" target

  target="$(ec2_resolve_ldap_host "$host")"
  [[ -n "$target" ]] || return 1
  ec2_ldapsearch_query "$target" "$admin_pass" "768019"
}

ec2_ldapsearch_test_hostname() {
  local host="$1" admin_pass="$2" user_filter="${3:-768019}"
  ec2_ldapsearch_query "$host" "$admin_pass" "$user_filter"
}

ec2_wait_for_ldap() {
  local host="$1"
  local label="${2:-LDAP}"
  local max_attempts="${3:-90}"
  local attempt admin_pass

  admin_pass="$(ec2_admin_pass)"

  log_info "Waiting for ${label} on ${host}:389"
  for attempt in $(seq 1 "$max_attempts"); do
    if ec2_ldapsearch_test "$host" "$admin_pass"; then
      log_success "${label} ready on ${host}"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      log_info "Still waiting for ${label} (${attempt}/${max_attempts})..."
    fi
    sleep 10
  done

  log_error "${label} not ready on ${host} after $((max_attempts * 10))s"
  return 1
}

ec2_verify_ldap_hostname() {
  local hostname="$1"
  local admin_pass attempt

  admin_pass="$(ec2_admin_pass)"
  log_step "End-to-end LDAP verify via hostname: ${hostname}:389"

  for attempt in $(seq 1 12); do
    if ec2_ldapsearch_test_hostname "$hostname" "$admin_pass" "768019" \
      && ec2_ldapsearch_test_hostname "$hostname" "$admin_pass" "768020"; then
      log_success "LDAP verified for users 768019 and 768020 via ${hostname}"
      return 0
    fi
    if (( attempt % 3 == 0 )); then
      log_info "Hostname LDAP not ready yet (${attempt}/12)..."
    fi
    sleep 5
  done

  log_error "LDAP via hostname ${hostname} failed after local DNS setup"
  return 1
}

ec2_finalize_networking() {
  local ldap_hostname="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"

  log_step "Setting up Cloudflare tunnel (cloudflared on EC2)"
  EC2_PUBLIC_IP="$PUBLIC_IP" \
  AD_EC2_SSH_USER="$SSH_USER" \
  AD_EC2_SSH_PRIVATE_KEY="$SSH_PRIVATE_KEY_PATH" \
  bash "$EC2_SCRIPTS/setup-cloudflare-tunnel.sh" || exit 1

  log_step "Setting up LDAP DNS (DNS-only A record → EC2)"
  EC2_PUBLIC_IP="$PUBLIC_IP" bash "$EC2_SCRIPTS/setup-cloudflare-dns.sh" || exit 1

  EC2_PUBLIC_IP="$PUBLIC_IP" CLOUDFLARE_LDAP_HOSTNAME="$ldap_hostname" \
    bash "$EC2_SCRIPTS/ensure-local-ldap-dns.sh" || exit 1

  ec2_verify_ldap_hostname "$ldap_hostname" || exit 1
}

ec2_print_test_commands() {
  log_step "Test LDAP from your Mac"

  cat <<'EOF'
ldapsearch -LLL \
  -H ldap://ldap.nrsh13-hadoop.com:389 \
  -x \
  -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \
  -w 'Dummy@2929' \
  -b "DC=nrsh13-hadoop,DC=com" \
  "(sAMAccountName=768019)"
EOF

  printf "\n${YELLOW}SSH${RESET}\n"
  banner_cmd "ssh -i ${SSH_PRIVATE_KEY_PATH} ${SSH_USER}@${PUBLIC_IP}"
  printf "\n"
}

ec2_print_cloudflare_verify() {
  local account_id="${CLOUDFLARE_ACCOUNT_ID:-3e691c68591ed154e625790a60361b78}"
  local tunnel_name="${CLOUDFLARE_TUNNEL_NAME:-ldap}"
  local ldap_host="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"

  log_step "Verify in Cloudflare Zero Trust"

  printf "${YELLOW}Connectors${RESET} — expect ${GREEN}HEALTHY${RESET}\n"
  printf "  ${H_CYAN}https://dash.cloudflare.com/${account_id}/one/networks/connectors${RESET}\n\n"

  printf "${YELLOW}Tunnel name${RESET}  ${H_GREEN}%s${RESET}\n" "$tunnel_name"
  printf "${YELLOW}Status${RESET}       ${GREEN}HEALTHY${RESET}\n"
  printf "${YELLOW}Route${RESET}        ${H_GREEN}%s → tcp://localhost:389${RESET}\n\n" "$ldap_host"

  printf "${YELLOW}LDAP DNS${RESET} — DNS-only A record → EC2 ${H_GREEN}${PUBLIC_IP}${RESET}\n"
  banner_cmd "dig +short ${ldap_host}"
  printf "\n"

  printf "${YELLOW}Local Mac${RESET} — /etc/hosts block ${CYAN}# BEGIN samba-ad-ec2${RESET}\n\n"
}

ec2_provision_ad() {
  ec2_wait_for_ssh
  ec2_wait_for_cloud_init_and_docker
  ec2_sync_and_bootstrap
  ec2_wait_for_ldap "$PUBLIC_IP" "LDAP (EC2 IP)" || exit 1
  ec2_finalize_networking
  ec2_print_test_commands
  ec2_print_cloudflare_verify
}

ec2_resolve_or_launch_instance() {
  INSTANCE_ID="$(ec2_find_running_instance)"
  if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
    log_info "Reusing instance $INSTANCE_ID — syncing repo and re-provisioning"
    PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
    [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || { log_error "No public IP on instance $INSTANCE_ID"; exit 1; }
    return 0
  fi

  log_step "Launching $INSTANCE_TYPE"
  INSTANCE_ID="$(aws ec2 run-instances \
    --image-id "$(ec2_resolve_ami)" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --user-data "file://${EC2_SCRIPTS}/user-data.sh" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}}]" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --query 'Instances[0].InstanceId' --output text)"
  ec2_wait_for_instance
}

ec2_action_apply() {
  ec2_load_config
  CLOUDFLARE_LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"
  export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TUNNEL_ID CLOUDFLARE_TUNNEL_NAME CLOUDFLARE_ZONE_NAME CLOUDFLARE_LDAP_HOSTNAME
  ec2_ensure_key_pair
  ec2_ensure_security_group

  ec2_resolve_or_launch_instance
  ec2_save_state
  ec2_provision_ad

  printf "\n"
  log_success "Samba Active Directory EC2 apply complete"
  printf "\n"
}

ec2_action_destroy() {
  ec2_load_config
  CLOUDFLARE_LDAP_HOSTNAME="${CLOUDFLARE_LDAP_HOSTNAME:-ldap.nrsh13-hadoop.com}"
  export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TUNNEL_ID CLOUDFLARE_TUNNEL_NAME CLOUDFLARE_ZONE_NAME CLOUDFLARE_LDAP_HOSTNAME
  if ec2_load_state && [[ -n "${INSTANCE_ID:-}" ]]; then
    log_step "Terminating instance $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" || true
    rm -f "$STATE_FILE"
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      bash "$EC2_SCRIPTS/cleanup-local-ldap-dns.sh" 2>/dev/null || true
    fi
    log_success "Samba Active Directory EC2 destroy complete"
  else
    log_warning "No instance in state file — nothing to destroy"
  fi
}
