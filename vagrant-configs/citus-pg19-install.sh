#!/usr/bin/env bash
# Install PostgreSQL 19 and build Citus on every node.
# PostgreSQL 19 is still a release candidate, published in the PGDG testing
# repository. Citus 14.3.0 rejects PostgreSQL 19. This commit is on Citus
# main, which accepts PostgreSQL 17, 18, and 19.
set -euo pipefail

CITUS_COMMIT="08479aca8b0d0d83640559f1a641b1d9ae5c2028"
PG_HOME="/usr/pgsql-19"
PGDATA="/var/lib/pgsql/19/data"
STAMP="${PG_HOME}/share/extension/.citus-build-commit"

echo "==== citus-pg19-install on $(hostname -s) @ $(date) ===="

ARCH="$(uname -m)"
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
VERSION_ID="${VERSION_ID:-9.7}"
MAJOR="${VERSION_ID%%.*}"
MINOR="${VERSION_ID#*.}"

dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${MAJOR}-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm"

if [[ "$ARCH" == "aarch64" ]]; then
  curl -fsSL -o /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL \
    https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-AARCH64-RHEL
  rpm --import /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL
  sed -i 's|PGDG-RPM-GPG-KEY-RHEL|PGDG-RPM-GPG-KEY-AARCH64-RHEL|g' /etc/yum.repos.d/pgdg*.repo
fi

# Package signatures stay on. Repository metadata checks fail on the aarch64
# PGDG repo, so turn those off.
sed -i -E 's/^[[:space:]]*repo_gpgcheck[[:space:]]*=.*/repo_gpgcheck=0/' /etc/yum.repos.d/pgdg*.repo || true

# PostgreSQL 19 is only in the testing repository. Disable every stock
# pgdg19 section so a missing stable directory cannot fail dnf, then add
# one testing repository that points at a directory which exists.
python3 - <<'PY'
from pathlib import Path

for path in Path("/etc/yum.repos.d").glob("*.repo"):
    lines = path.read_text().splitlines(keepends=True)
    sections = []
    current = []
    for line in lines:
        if line.startswith("[") and current:
            sections.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        sections.append(current)

    rewritten = []
    for section in sections:
        header = section[0].strip()
        if header.startswith("[pgdg19"):
            replaced = False
            new_section = []
            for line in section:
                if line.startswith("enabled="):
                    new_section.append("enabled=0\n")
                    replaced = True
                else:
                    new_section.append(line)
            if not replaced:
                new_section.insert(1, "enabled=0\n")
            section = new_section
        rewritten.extend(section)
    path.write_text("".join(rewritten))
PY

BASE=""
for candidate in \
  "https://download.postgresql.org/pub/repos/yum/testing/19/redhat/rhel-${MAJOR}.${MINOR}-${ARCH}" \
  "https://download.postgresql.org/pub/repos/yum/testing/19/redhat/rhel-${MAJOR}-${ARCH}"
do
  code="$(curl -fsSL -o /dev/null -w '%{http_code}' "${candidate}/repodata/repomd.xml" || true)"
  if [[ "$code" == "200" ]]; then
    BASE="$candidate"
    break
  fi
done

if [[ -z "$BASE" ]]; then
  echo "PostgreSQL 19 testing repository was not found for ${MAJOR}.${MINOR} ${ARCH}" >&2
  exit 1
fi

echo "Using PostgreSQL 19 packages from ${BASE}"

KEY_FILE="/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL"
if [[ "$ARCH" == "aarch64" ]]; then
  KEY_FILE="/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL"
fi

cat > /etc/yum.repos.d/pgdg19-testing-local.repo <<EOF
[pgdg19-testing-local]
name=PostgreSQL 19 testing for RHEL ${MAJOR}.${MINOR} - ${ARCH}
baseurl=${BASE}
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://${KEY_FILE}
EOF

dnf -qy module disable postgresql || true
if [[ "${1:-}" == "packages" || "${PG_ROLE:-}" == "packages" ]]; then
  dnf install -y postgresql19-server postgresql19-contrib
  systemctl disable --now postgresql-19 || true
  echo "==== postgresql19 packages installed on $(hostname -s) ===="
  exit 0
fi
dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb
dnf install -y perl-IPC-Run redhat-rpm-config
dnf install -y postgresql19-server postgresql19-contrib postgresql19-devel

if [[ "${FORCE_CITUS_REBUILD:-0}" == "1" ]]; then
  rm -f "${STAMP}"
fi

if [[ ! -f "${STAMP}" || "$(cat "${STAMP}")" != "${CITUS_COMMIT}" ]]; then
  rm -rf /usr/local/src/citus-build
  mkdir -p /usr/local/src/citus-build
  curl -fsSL -o /usr/local/src/citus-build/citus.tar.gz \
    "https://github.com/citusdata/citus/archive/${CITUS_COMMIT}.tar.gz"
  tar -xzf /usr/local/src/citus-build/citus.tar.gz -C /usr/local/src/citus-build
  srcdir="$(find /usr/local/src/citus-build -mindepth 1 -maxdepth 1 -type d | head -1)"
  cd "${srcdir}"
  if [[ ! -x "${PG_HOME}/bin/pg_config" ]]; then
    echo "pg_config is missing at ${PG_HOME}/bin/pg_config" >&2
    exit 1
  fi
  export PG_CONFIG="${PG_HOME}/bin/pg_config"
  export PATH="${PG_HOME}/bin:${PATH}"
  ./configure
  # PostgreSQL 19's PGXS install step calls llvm-lto. That binary is not in
  # AlmaLinux 9, and Citus does not need its own bitcode to shard tables.
  make -j"$(nproc)" with_llvm=no
  make install with_llvm=no
  echo "${CITUS_COMMIT}" > "${STAMP}"
else
  echo "Citus ${CITUS_COMMIT} is already installed"
fi

if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
  "${PG_HOME}/bin/postgresql-19-setup" initdb
fi

cat > "${PGDATA}/pg_hba.conf" <<'EOF'
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    all             all             192.168.32.0/24         trust
host    all             all             10.0.2.0/24             scram-sha-256
host    replication     all             192.168.32.0/24         trust
EOF
chown postgres:postgres "${PGDATA}/pg_hba.conf"
chmod 600 "${PGDATA}/pg_hba.conf"

cat > "${PGDATA}/citus.conf" <<'EOF'
listen_addresses = '*'
port = 5432
shared_preload_libraries = 'citus'
password_encryption = 'scram-sha-256'
max_connections = 100
shared_buffers = 512MB
work_mem = 16MB
maintenance_work_mem = 128MB
effective_cache_size = 2GB
wal_level = logical
max_wal_senders = 16
max_replication_slots = 16
hot_standby = on
citus.node_conninfo = 'sslmode=disable'
citus.shard_count = 5
citus.shard_replication_factor = 1
EOF
chown postgres:postgres "${PGDATA}/citus.conf"

if ! grep -q "^include 'citus.conf'" "${PGDATA}/postgresql.conf"; then
  echo "include 'citus.conf'" >> "${PGDATA}/postgresql.conf"
fi

if [[ -f /etc/patroni.yml ]]; then
  systemctl disable --now postgresql-19 || true
  echo "patroni owns PostgreSQL on $(hostname -s)"
else
  systemctl enable postgresql-19
  systemctl restart postgresql-19
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE EXTENSION IF NOT EXISTS citus;"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER postgres WITH PASSWORD 'Postgres@123';"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "SELECT version();"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'citus';"
fi

echo "==== citus-pg19-install complete on $(hostname -s) ===="
