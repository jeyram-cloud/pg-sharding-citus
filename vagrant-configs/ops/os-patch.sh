#!/usr/bin/env bash
# Run as root on one node. Apply AlmaLinux updates and leave PostgreSQL packages alone.
set -euo pipefail

echo "==== os-patch on $(hostname -s) @ $(date) ===="
echo "before_kernel=$(uname -r)"
rpm -q postgresql19-server || true

dnf install -y dnf-plugins-core
dnf update -y --exclude='postgresql19*'

set +e
needs-restarting -r
rc=$?
set -e

result="no"
if [[ "${rc}" -eq 1 ]]; then
  result="yes"
elif [[ "${rc}" -ne 0 ]]; then
  echo "needs-restarting failed with exit ${rc}" >&2
  exit 1
fi

echo "REBOOT_REQUIRED=${result}" | tee /var/tmp/pgcitus-os-patch.result
echo "after_kernel=$(uname -r)"
echo "==== os-patch packages applied on $(hostname -s) ===="
