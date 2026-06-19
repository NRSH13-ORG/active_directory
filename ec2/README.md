# EC2 support files

EC2 provisioning is handled by the main script — see the [root README](../README.md) for full documentation, architecture diagram, and troubleshooting.

```bash
export CLOUDFLARE_API_TOKEN='…'
sh scripts/provision.sh --action apply --env ec2
```

## Files in this folder

| Path | Purpose |
|------|---------|
| `provision-ec2.sh` | EC2 logic (sourced by `scripts/provision.sh`) |
| `config.env.example` | AWS/SSH settings — copied to `config.env` on first run |
| `state/instance.env` | Instance ID, IP, SSH details (written after apply) |
| `scripts/user-data.sh` | EC2 launch bootstrap (Docker + swap) |
| `scripts/bootstrap.sh` | Rsync repo to `/opt/ldap_platform_engineering` and run provision on instance |
| `scripts/setup-cloudflare.sh` | Cloudflare tunnel + DNS-only A record |
| `scripts/local-ldap-dns.sh` | Mac `/etc/hosts` and DNS cache for LDAP hostname |
