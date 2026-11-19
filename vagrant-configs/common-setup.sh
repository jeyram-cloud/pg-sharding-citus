#!/usr/bin/env bash
# Base OS setup for every Citus node.
# Arguments: citus01=192.168.32.163 citus02=192.168.32.164 ...
set -euo pipefail

echo "==== common-setup on $(hostname -s) @ $(date) ===="

if [[ "$#" -lt 1 ]]; then
  echo "common-setup.sh: expected hostname=ip arguments" >&2
  exit 1
fi

if [[ "${BASE_ROLE:-full}" == "runtime" ]]; then
  dnf install -y chrony curl ca-certificates tar gzip which python3
else
  dnf install -y chrony curl ca-certificates tar gzip which python3 \
    gcc make flex bison readline-devel zlib-devel openssl-devel \
    libcurl-devel libzstd-devel lz4-devel libicu-devel krb5-devel \
    pam-devel libxml2-devel libxslt-devel
fi

systemctl disable --now firewalld || true
setenforce 0 || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
systemctl enable --now chronyd

cat > /etc/hosts <<'EOF'
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain
EOF

for pair in "$@"; do
  name="${pair%%=*}"
  ip="${pair##*=}"
  if [[ -z "$name" || -z "$ip" || "$name" == "$ip" ]]; then
    echo "common-setup.sh: bad host argument: $pair" >&2
    exit 1
  fi
  echo "${ip} ${name}" >> /etc/hosts
done

hostnamectl set-hostname "$(hostname -s)" || true

cat > /etc/sysctl.d/99-citus.conf <<'EOF'
vm.swappiness = 1
net.core.somaxconn = 4096
EOF
sysctl --system >/dev/null

ready=0
for _ in $(seq 1 30); do
  if ip -4 addr show | grep -q '192.168.32.'; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "private network 192.168.32.0/24 is not up" >&2
  ip -4 addr
  exit 1
fi

echo "==== common-setup complete on $(hostname -s) ===="
