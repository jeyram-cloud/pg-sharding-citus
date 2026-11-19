#!/usr/bin/env bash
# Run as root on one node. Update PostgreSQL 19 packages only.
# The host wrapper rebuilds Citus and restarts PostgreSQL when the RPM changes.
set -euo pipefail

echo "==== db-patch on $(hostname -s) @ $(date) ===="

before="$(rpm -qa 'postgresql19*' | sort | tr '\n' ' ')"
echo "before_rpms=${before}"

dnf update -y 'postgresql19*'

after="$(rpm -qa 'postgresql19*' | sort | tr '\n' ' ')"
echo "after_rpms=${after}"

if [[ "${before}" == "${after}" ]]; then
  echo "PG_PATCH_RESULT=UNCHANGED" | tee /var/tmp/pgcitus-db-patch.result
else
  echo "PG_PATCH_RESULT=CHANGED" | tee /var/tmp/pgcitus-db-patch.result
fi

echo "==== db-patch package step done on $(hostname -s) ===="
