# Samba Active Directory

A self-contained Samba AD domain controller for development and lab use. One script provisions either **local Docker on your Mac** or a **remote EC2 instance** with Cloudflare DNS — same domain, users, and groups in both environments.

## Overview

| | Local (default) | EC2 |
|---|----------------|-----|
| **Command** | `sh scripts/provision.sh --action apply` | `sh scripts/provision.sh --action apply --env ec2` |
| **Where AD runs** | Docker on your Mac | Docker on AWS t3.micro (Ubuntu 22.04) |
| **LDAP URL** | `ldap://127.0.0.1:389` | `ldap://ldap.nrsh13-hadoop.com:389` |
| **Reachable from** | This Mac only | Anywhere (security group + DNS) |
| **Prerequisites** | Docker Desktop | AWS CLI, SSH key, Cloudflare API token |
| **Typical use** | Local dev / Kafka LDAP auth testing | Shared lab DC reachable by remote clients |

Both paths use the same `scripts/provision.sh` entry point. EC2 support files live under `ec2/` and are invoked automatically when `--env ec2` is set.

Run `sh scripts/provision.sh` with no arguments for built-in help.

---

## Quick start

### Local (Mac + Docker)

```bash
cp .env.example .env          # customize passwords if needed
sh scripts/provision.sh --action apply
```

### EC2 (AWS + Cloudflare)

```bash
# Prerequisites: AWS CLI configured, SSH key at ~/.ssh/id_rsa, Cloudflare token with DNS Edit
export CLOUDFLARE_API_TOKEN='your-token'
cp ec2/config.env.example ec2/config.env   # optional — defaults are fine for first run
sh scripts/provision.sh --action apply --env ec2
```

First EC2 apply takes about **5–8 minutes** (instance launch, Docker install, Samba provision, DNS).

---

## Prerequisites

### Local

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (running)
- `ldapsearch` for testing: `brew install openldap`
- Bash (script re-execs itself if invoked as `sh`)

### EC2

- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws sts get-caller-identity` works)
- SSH key pair (default: `~/.ssh/id_rsa` and `~/.ssh/id_rsa.pub`)
- [Cloudflare API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/) with **DNS Edit** on zone `nrsh13-hadoop.com`
- `rsync` (pre-installed on macOS)
- Export before apply: `export CLOUDFLARE_API_TOKEN='…'`

---

## Configuration

### Local — `.env`

Copy `.env.example` to `.env` (git-ignored). Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | `NRSH13-HADOOP` | NetBIOS domain name |
| `REALM` | `NRSH13-HADOOP.COM` | Kerberos realm |
| `DNS_DOMAIN` | `nrsh13-hadoop.com` | DNS domain |
| `ADMIN_PASS` | `Dummy@2929` | Domain Administrator password |
| `USER_NAME` / `USER2_NAME` | `768019` / `768020` | Test user accounts |
| `USER_PASS` / `USER2_PASS` | `Dummy@2929` | User passwords |
| `GROUP_NAME` | `A_HADOOP_ADMINS` | AD group |
| `SECOND_GROUP_NAME` | `A_Kafka_Users_Dev` | Second AD group |
| `CONTAINER_NAME` | `samba-ad-dc` | Docker container name |
| `CERT_DIR` | *(auto-detect)* | Optional TLS certs for LDAPS |

### EC2 — `ec2/config.env`

Auto-created from `ec2/config.env.example` on first run (git-ignored):

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `ap-southeast-2` | AWS region |
| `INSTANCE_TYPE` | `t3.micro` | EC2 instance type (free tier) |
| `PROJECT_NAME` | `samba-ad-dc` | Instance tag / resource prefix |
| `KEY_NAME` | `samba-ad-dc` | AWS key pair name |
| `SSH_USER` | `ubuntu` | SSH login user |
| `SSH_PUBLIC_KEY_FILE` | `~/.ssh/id_rsa.pub` | Public key to import |
| `SSH_PRIVATE_KEY_PATH` | `~/.ssh/id_rsa` | Private key for SSH/rsync |
| `ADMIN_SSH_CIDR` | *your public IP/32* | SSH ingress (auto-detected) |
| `LDAP_INGRESS_CIDR` | `0.0.0.0/0` | LDAP/LDAPS ingress |

### Cloudflare (EC2 only)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLOUDFLARE_API_TOKEN` | *(required)* | API token with DNS Edit |
| `CLOUDFLARE_ZONE_NAME` | `nrsh13-hadoop.com` | DNS zone |
| `CLOUDFLARE_LDAP_HOSTNAME` | `ldap.nrsh13-hadoop.com` | LDAP hostname (A record) |

---

## What gets provisioned

On **apply** (local or on the EC2 instance), the script:

1. Builds the Samba AD DC Docker image (`Dockerfile` — Debian + `samba-ad-dc`)
2. Starts the container via `docker-compose.yml`
3. Provisions the AD domain (`samba-tool domain provision`) if not already present
4. Optionally installs TLS certificates for LDAPS
5. Sets the Administrator password
6. Creates users **768019** and **768020**
7. Creates groups **A_HADOOP_ADMINS** and **A_Kafka_Users_Dev**, adds both users to both groups
8. Verifies LDAP with an internal `ldapsearch`

**Exposed ports** (local and EC2): 389 (LDAP), 636 (LDAPS), 88/464 (Kerberos), 139/445 (SMB).

---

## Test LDAP

### EC2 (from anywhere)

```bash
ldapsearch -LLL \
  -H ldap://ldap.nrsh13-hadoop.com:389 \
  -x \
  -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \
  -w 'Dummy@2929' \
  -b "DC=nrsh13-hadoop,DC=com" \
  "(sAMAccountName=768019)"
```

### Local (this Mac only)

```bash
ldapsearch -LLL \
  -H ldap://127.0.0.1:389 \
  -x \
  -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \
  -w 'Dummy@2929' \
  -b "DC=nrsh13-hadoop,DC=com" \
  "(sAMAccountName=768019)"
```

### Connection summary

| Setting | Value |
|---------|-------|
| **LDAP URL (EC2)** | `ldap://ldap.nrsh13-hadoop.com:389` |
| **LDAP URL (local)** | `ldap://127.0.0.1:389` |
| **LDAPS** | port 636 (when TLS certs are installed) |
| **Bind DN** | `CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com` |
| **Base DN** | `DC=nrsh13-hadoop,DC=com` |
| **Users base** | `CN=Users,DC=nrsh13-hadoop,DC=com` |
| **Administrator password** | `Dummy@2929` (change in `.env`) |
| **Test users** | `768019`, `768020` |

---

## Repository layout

```
active_directory/
├── scripts/
│   ├── provision.sh          # Single entry point (local + EC2)
│   └── terminal-colors.sh    # Shared logging helpers
├── ec2/
│   ├── provision-ec2.sh      # EC2 logic (sourced by provision.sh)
│   ├── config.env.example    # EC2 settings template
│   ├── state/instance.env    # Written after EC2 apply (git-ignored)
│   └── scripts/
│       ├── user-data.sh              # EC2 launch: Docker + swap
│       ├── sync-and-bootstrap.sh     # Rsync repo to instance
│       ├── remote-bootstrap.sh       # Runs local provision on EC2
│       └── setup-cloudflare-dns.sh   # DNS-only A record
├── docs/images/
│   └── architecture-diagram.png
├── Dockerfile                # Samba AD DC image
├── docker-compose.yml
├── .env.example              # Local settings template
└── README.md
```

---

## EC2 operations

### SSH to the instance

After apply, state is in `ec2/state/instance.env`:

```bash
source ec2/state/instance.env
ssh -i "$SSH_PRIVATE_KEY_PATH" "${SSH_USER}@${PUBLIC_IP}"
```
