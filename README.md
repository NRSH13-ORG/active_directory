# Samba Active Directory Local Setup

Local Samba Active Directory Domain Controller on your Mac (Docker).

## Overview

- Domain: `nrsh13-hadoop.com` · NetBIOS: `NRSH13-HADOOP` · Realm: `NRSH13-HADOOP.COM`
- Users: `768019`, `768020` (members of `A_HADOOP_ADMINS` and `A_Kafka_Users_Dev`)
- Passwords and names are configurable via `.env` (see `.env.example`)

## Setup

**Prerequisites:** Docker Desktop, `ldapsearch` (`brew install openldap`)

```bash
git clone git@github.com:NRSH13-ORG/active_directory.git
cd active_directory

cp .env.example .env   # optional — edit passwords as needed

sh scripts/provision.sh --action apply
sh scripts/provision.sh --action destroy   # tear down containers and volumes
```

Copy `.env.example` to `.env` and customize before apply. Never commit `.env`.

## Verify locally

Use `127.0.0.1` when testing on the Mac where Docker is running:

```bash
ldapsearch -LLL \
  -H ldap://127.0.0.1:389 \
  -x \
  -D "CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com" \
  -w 'Dummy@2929' \
  -b "DC=nrsh13-hadoop,DC=com" \
  "(sAMAccountName=768019)"
```

Replace `Dummy@2929` with your `ADMIN_PASS` from `.env`.

## Remote access (EKS, EC2, AKS)

AD runs on your Mac. Remote clients must **not** use `127.0.0.1` — that points to themselves.

Use `ldap://ldap.nrsh13-hadoop.com:389` from outside the Mac. That hostname is in Cloudflare DNS and resolves to Cloudflare edge IPs, **not** your Mac. A proxied DNS record alone does not forward LDAP.

To reach AD from outside you need one of:

- **Cloudflare Tunnel (`cloudflared`)** on the Mac — TCP route `ldap.nrsh13-hadoop.com` → `localhost:389` (this is the usual setup)
- VPN into your network, then use the Mac's LAN IP
- `/etc/hosts` on each client → Mac IP (same LAN only)

For local testing with the DNS name, add to `/etc/hosts`:

```
127.0.0.1 ldap.nrsh13-hadoop.com
```

Allow inbound LDAP (389/636) through the macOS firewall if connecting over the network.

## App connection details

| Setting | Value |
|---------|-------|
| LDAP URL | `ldap://ldap.nrsh13-hadoop.com:389` |
| LDAPS URL | `ldaps://ldap.nrsh13-hadoop.com:636` (when TLS certs configured) |
| Bind DN | `CN=Administrator,CN=Users,DC=nrsh13-hadoop,DC=com` |
| Base DN | `CN=Users,DC=nrsh13-hadoop,DC=com` |
| User filter | `(&(objectClass=user)(sAMAccountName={username}))` |
| Admin group | `memberof=CN=A_HADOOP_ADMINS,CN=Users,DC=nrsh13-hadoop,DC=com` |

Optional LDAPS: set `CERT_DIR`, `CERT_BASENAME`, and `ROOT_CA_CERT` in `.env`, then re-run apply.
