#!/usr/bin/env bash
# Run as root on one node. Print one fact per line.
set -euo pipefail

. /etc/os-release

pgver="$(runuser -u postgres -- /usr/pgsql-19/bin/psql -d postgres -tAc 'SHOW server_version;' 2>/dev/null || echo down)"
citus="$(runuser -u postgres -- /usr/pgsql-19/bin/psql -d postgres -tAc "SELECT extversion FROM pg_extension WHERE extname = 'citus';" 2>/dev/null || echo down)"

echo "hostname=$(hostname -s)"
echo "os=${PRETTY_NAME}"
echo "kernel=$(uname -r)"
if systemctl is-active --quiet patroni; then
  echo "postgres=patroni"
else
  echo "postgres=$(systemctl is-active postgresql-19 || true)"
fi
echo "pgver=${pgver}"
echo "citus=${citus}"
echo "rpm=$(rpm -q postgresql19-server 2>/dev/null || echo none)"
echo "disk=$(df -hP / | awk 'NR==2 { print $4 " free" }')"
