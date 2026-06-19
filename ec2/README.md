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
| `scripts/sync-and-bootstrap.sh` | Rsync repo to `/opt/active_directory` |
| `scripts/remote-bootstrap.sh` | Runs `scripts/provision.sh --action apply` on the instance |
| `scripts/setup-cloudflare-dns.sh` | DNS-only A record for `ldap.nrsh13-hadoop.com` |
