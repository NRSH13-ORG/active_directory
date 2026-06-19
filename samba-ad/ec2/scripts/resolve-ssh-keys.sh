#!/bin/bash
# Materialize an SSH key pair for EC2 access from env vars or config paths.
# Key content (preferred for CI): SSH_PRIVATE_KEY or BITBUCKET_SSH_PRIVATE_KEY
# Optional: SSH_PUBLIC_KEY — derived from private key when omitted.

resolve_ssh_private_material() {
  if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SSH_PRIVATE_KEY"
  elif [[ -n "${BITBUCKET_SSH_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$BITBUCKET_SSH_PRIVATE_KEY"
  fi
}

resolve_ssh_keys() {
  local material key_dir private_file public_file
  material="$(resolve_ssh_private_material)"
  key_dir="${SSH_KEY_DIR:-${HOME}/.ssh}"
  private_file="${SSH_PRIVATE_KEY_PATH:-${key_dir}/ec2_provision}"
  public_file="${SSH_PUBLIC_KEY_FILE:-${private_file}.pub}"

  private_file="${private_file/#\~/$HOME}"
  public_file="${public_file/#\~/$HOME}"

  if [[ -n "$material" ]]; then
    mkdir -p "$(dirname "$private_file")"
    chmod 700 "$(dirname "$private_file")"
    printf '%s\n' "$material" >"$private_file"
    chmod 600 "$private_file"
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
      printf '%s\n' "$SSH_PUBLIC_KEY" >"$public_file"
    else
      ssh-keygen -y -f "$private_file" >"$public_file"
    fi
    chmod 644 "$public_file"
    SSH_PRIVATE_KEY_PATH="$private_file"
    SSH_PUBLIC_KEY_FILE="$public_file"
    export SSH_PRIVATE_KEY_PATH SSH_PUBLIC_KEY_FILE
    return 0
  fi

  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_rsa}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE/#\~/$HOME}"

  if [[ -f "$SSH_PRIVATE_KEY_PATH" && ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
    ssh-keygen -y -f "$SSH_PRIVATE_KEY_PATH" >"$SSH_PUBLIC_KEY_FILE"
    chmod 644 "$SSH_PUBLIC_KEY_FILE"
  fi

  export SSH_PRIVATE_KEY_PATH SSH_PUBLIC_KEY_FILE
}
