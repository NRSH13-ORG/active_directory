# EC2 provisioning — sourced by scripts/provision.sh when --env ec2.
# Helper scripts live in ec2/scripts/.

EC2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EC2_SCRIPTS="$EC2_ROOT/scripts"
STATE_DIR="$EC2_ROOT/state"
STATE_FILE="$STATE_DIR/instance.env"
CONFIG_FILE="$EC2_ROOT/config.env"

ec2_print_prerequisites_steps() {
  print_prerequisites_heading "AWS CLI · rsync · SSH key · Cloudflare API token (DNS Edit)"

  printf "  ${H_RED}1.${RESET} Export Cloudflare API token:\n"
  banner_cmd "export CLOUDFLARE_API_TOKEN='…'"
  printf "  ${H_RED}2.${RESET} Deploy Samba AD on EC2 (t3.micro free tier):\n"
  banner_cmd "sh scripts/provision.sh --action apply --env ec2"
  printf "  ${H_RED}3.${RESET} Test LDAP from anywhere:\n"
  banner_cmd "ldapsearch -LLL -H ldap://ldap.nrsh13-hadoop.com:389 -x -D \"CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com\" -w 'Dummy@2929' -b \"DC=nrsh13-hadoop,DC=com\" \"(sAMAccountName=768019)\""
  printf "  ${H_RED}4.${RESET} Tear down EC2:\n"
  banner_cmd "sh scripts/provision.sh --action destroy --env ec2"
  printf "\n"
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

ec2_sync_and_bootstrap() {
  log_step "Syncing repo and bootstrapping AD"
  AD_EC2_HOST="$PUBLIC_IP" \
  AD_EC2_SSH_USER="$SSH_USER" \
  AD_EC2_SSH_PRIVATE_KEY="$SSH_PRIVATE_KEY_PATH" \
  AD_EC2_REPO_ROOT="$ROOT_DIR" \
  bash "$EC2_SCRIPTS/sync-and-bootstrap.sh" apply
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

ec2_action_apply() {
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    log_error "CLOUDFLARE_API_TOKEN is not set"
    return 1
  fi

  print_module_header "Samba Active Directory — EC2 apply"

  ec2_load_config
  ec2_ensure_key_pair
  ec2_ensure_security_group

  INSTANCE_ID="$(ec2_find_running_instance)"
  if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
    log_info "Reusing instance $INSTANCE_ID"
    PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  else
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
  fi

  ec2_save_state
  ec2_wait_for_ssh
  ec2_sync_and_bootstrap
  EC2_PUBLIC_IP="$PUBLIC_IP" bash "$EC2_SCRIPTS/setup-cloudflare-dns.sh"

  log_success "Samba Active Directory EC2 apply complete"
  ec2_print_test_commands
}

ec2_action_sync() {
  print_module_header "Samba Active Directory — EC2 sync"

  ec2_load_config
  ec2_load_state || { log_error "No state file — run apply first"; return 1; }
  ec2_wait_for_ssh
  ec2_sync_and_bootstrap
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    EC2_PUBLIC_IP="$PUBLIC_IP" bash "$EC2_SCRIPTS/setup-cloudflare-dns.sh"
  fi
  log_success "Sync complete"
}

ec2_action_destroy() {
  print_module_header "Samba Active Directory — EC2 destroy"

  ec2_load_config
  if ec2_load_state && [[ -n "${INSTANCE_ID:-}" ]]; then
    log_step "Terminating instance $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" || true
    rm -f "$STATE_FILE"
    log_success "Samba Active Directory EC2 destroy complete"
  else
    log_warning "No instance in state file — nothing to destroy"
  fi
}
