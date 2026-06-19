#!/bin/bash
# Remove managed /etc/hosts block for LDAP hostname (Mac).
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

HOSTS_BEGIN="# BEGIN samba-ad-ec2"
HOSTS_END="# END samba-ad-ec2"

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
