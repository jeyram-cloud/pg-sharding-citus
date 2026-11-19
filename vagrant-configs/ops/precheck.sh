#!/usr/bin/env bash
# Run as root on one node. Exit 0 when the node can take a reboot or a patch.
set -euo pipefail

echo "precheck $(hostname -s)"

if systemctl is-active --quiet patroni; then
  echo "postgres_service=patroni"
elif systemctl is-active --quiet postgresql-19; then
  echo "postgres_service=postgresql-19"
else
  echo "neither patroni nor postgresql-19 is active" >&2
  systemctl --no-pager --lines=20 status patroni postgresql-19 || true
  exit 1
fi

runuser -u postgres -- /usr/pgsql-19/bin/pg_isready -q

free_kb="$(df -Pk / | awk 'NR==2 { print $4 }')"
echo "free_kb=${free_kb}"
if [[ "${free_kb}" -lt 1000000 ]]; then
  echo "less than 1 GB free on /" >&2
  exit 1
fi

echo "precheck_ok $(hostname -s)"
