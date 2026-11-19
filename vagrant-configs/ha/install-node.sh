#!/usr/bin/env bash
# Install etcd (on the three quorum nodes), Patroni, HAProxy, and Keepalived.
# Does not start Patroni. The host bootstrap starts services in order.
set -euo pipefail

NODE_NAME="${NODE_NAME:?}"
NODE_IP="${NODE_IP:?}"
PARTNER_NAME="${PARTNER_NAME:?}"
PARTNER_IP="${PARTNER_IP:?}"
VIP="${VIP:?}"
VRID="${VRID:?}"
GROUP_ID="${GROUP_ID:?}"
ROLE="${ROLE:?}"
ETCD_MEMBER="${ETCD_MEMBER:?}"

PGDATA="/var/lib/pgsql/19/data"
PATRONI_BIN=""

echo "==== ha install ${NODE_NAME} role=${ROLE} group=${GROUP_ID} ===="

cat > /etc/hosts <<'EOF'
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain
192.168.32.163 citus01
192.168.32.164 citus02
192.168.32.165 citus03
192.168.32.166 citus04
192.168.32.167 citus05
192.168.32.141 citus01b
192.168.32.142 citus02b
192.168.32.143 citus03b
192.168.32.144 citus04b
192.168.32.145 citus05b
192.168.32.241 citus01-vip
192.168.32.242 citus02-vip
192.168.32.243 citus03-vip
192.168.32.244 citus04-vip
192.168.32.245 citus05-vip
EOF
hostnamectl set-hostname "${NODE_NAME}" || true

cat > /etc/sysctl.d/99-pgcitus-ha.conf <<'EOF'
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl --system >/dev/null

dnf install -y haproxy keepalived curl python3 python3-psycopg2

enable_patroni_repo() {
  if rpm -q patroni >/dev/null 2>&1 && command -v patroni >/dev/null 2>&1; then
    return 0
  fi
  # pgdg-common also publishes Patroni 3.0.4. Pin 4.1 so Citus switchover uses the current release.
  dnf install -y 'patroni >= 4.1' 'patroni-etcd >= 4.1' || true
  if command -v patroni >/dev/null 2>&1; then
    return 0
  fi
  dnf install -y python3-pip
  pip3 install --disable-pip-version-check 'patroni[etcd]>=4.0.4'
}

enable_patroni_repo
PATRONI_BIN="$(command -v patroni)"
echo "patroni binary: ${PATRONI_BIN}"
"${PATRONI_BIN}" --version

# Patroni 4 uses the python3.12 etcd module from the patroni-etcd RPM.
python3.12 -c 'import etcd' >/dev/null 2>&1 || true

if [[ "${ETCD_MEMBER}" == "yes" ]]; then
  if ! command -v etcd >/dev/null 2>&1; then
    dnf install -y --enablerepo=pgdg-rhel9-extras etcd
  fi
  id etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/etcd --shell /sbin/nologin etcd
  mkdir -p /var/lib/etcd/pgcitus
  chown etcd:etcd /var/lib/etcd /var/lib/etcd/pgcitus
  ETCD_BIN="$(command -v etcd)"
  cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd for pgcitus
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=etcd
Group=etcd
ExecStart=${ETCD_BIN} \\
  --name ${NODE_NAME} \\
  --data-dir /var/lib/etcd/pgcitus \\
  --listen-peer-urls http://${NODE_IP}:2380 \\
  --listen-client-urls http://${NODE_IP}:2379,http://127.0.0.1:2379 \\
  --initial-advertise-peer-urls http://${NODE_IP}:2380 \\
  --advertise-client-urls http://${NODE_IP}:2379 \\
  --initial-cluster citus01=http://192.168.32.163:2380,citus02=http://192.168.32.164:2380,citus03=http://192.168.32.165:2380 \\
  --initial-cluster-token pgcitus-ha \\
  --initial-cluster-state new
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi

if [[ "${ROLE}" == "primary" && ! -s "${PGDATA}/PG_VERSION" ]]; then
  echo "primary ${NODE_NAME} has no PostgreSQL data directory" >&2
  exit 1
fi
if [[ "${ROLE}" == "standby" && ! -s "${PGDATA}/PG_VERSION" ]]; then
  rm -rf "${PGDATA}"
  mkdir -p /var/lib/pgsql/19
  chown postgres:postgres /var/lib/pgsql /var/lib/pgsql/19
fi

# VirtualBox NAT is 10.0.2.15 on every guest. Vagrant forwards the Mac ports there.
LISTEN_HOSTS="127.0.0.1,10.0.2.15,${NODE_IP}"

NOLOAD="false"
if [[ "${ROLE}" == "standby" ]]; then
  NOLOAD="true"
fi

mkdir -p /etc/patroni
cat > /etc/patroni.yml <<EOF
scope: pgcitus
namespace: /service/
name: ${NODE_NAME}

log:
  level: INFO

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_NAME}:8008

etcd3:
  hosts:
    - citus01:2379
    - citus02:2379
    - citus03:2379

bootstrap:
  dcs:
    ttl: 40
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 100
        max_prepared_transactions: 200
        shared_buffers: 256MB
        work_mem: 16MB
        maintenance_work_mem: 128MB
        effective_cache_size: 1GB
        wal_level: logical
        wal_log_hints: "on"
        max_wal_senders: 16
        max_replication_slots: 16
        hot_standby: "on"
        wal_keep_size: 256MB
        max_locks_per_transaction: 128
        password_encryption: scram-sha-256
        shared_preload_libraries: citus
        citus.node_conninfo: "sslmode=disable"
        citus.shard_count: 5
        citus.shard_replication_factor: 1
  initdb:
    - encoding: UTF8
    - data-checksums

citus:
  group: ${GROUP_ID}
  database: postgres

postgresql:
  listen: ${LISTEN_HOSTS}:5432
  connect_address: ${NODE_NAME}:5432
  data_dir: ${PGDATA}
  bin_dir: /usr/pgsql-19/bin
  pgpass: /var/lib/pgsql/pgpass
  authentication:
    replication:
      username: replicator
      password: "Replicator@123"
    superuser:
      username: postgres
      password: "Postgres@123"
  parameters:
    unix_socket_directories: "/var/run/postgresql,/tmp"
  pg_hba:
    - local all all peer
    - local replication all peer
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host replication replicator 192.168.32.0/24 scram-sha-256
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all 192.168.32.0/24 trust
    - host all all 10.0.2.0/24 scram-sha-256
  callbacks:
    on_start: /usr/local/bin/pgcitus-vip-notify
    on_stop: /usr/local/bin/pgcitus-vip-notify
    on_role_change: /usr/local/bin/pgcitus-vip-notify

tags:
  nofailover: false
  noloadbalance: ${NOLOAD}
  failover_priority: 1
EOF
chown root:postgres /etc/patroni.yml
chmod 640 /etc/patroni.yml

cat > /usr/local/bin/pgcitus-wait-etcd <<'EOF'
#!/bin/bash
for _ in $(seq 1 40); do
  curl -sf --max-time 2 http://192.168.32.163:2379/health >/dev/null && exit 0
  curl -sf --max-time 2 http://192.168.32.164:2379/health >/dev/null && exit 0
  curl -sf --max-time 2 http://192.168.32.165:2379/health >/dev/null && exit 0
  sleep 2
done
echo "etcd is not healthy" >&2
exit 1
EOF
chmod 755 /usr/local/bin/pgcitus-wait-etcd

cat > /usr/local/bin/pgcitus-is-primary <<'EOF'
#!/bin/bash
curl -sf --max-time 2 http://127.0.0.1:8008/primary >/dev/null
EOF
chmod 755 /usr/local/bin/pgcitus-is-primary
chown root:root /usr/local/bin/pgcitus-is-primary

cat > /usr/local/bin/pgcitus-vip-notify <<'EOF'
#!/bin/bash
systemctl kill -s HUP keepalived >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 /usr/local/bin/pgcitus-vip-notify

cat > /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA (${NODE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStartPre=/usr/local/bin/pgcitus-wait-etcd
ExecStart=${PATRONI_BIN} /etc/patroni.yml
Restart=on-failure
RestartSec=5
TimeoutStartSec=0
TimeoutStopSec=90
LimitNOFILE=65536
RuntimeDirectory=postgresql
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

IFACE="$(ip -4 -o addr show | awk -v ip="${NODE_IP}" '$4 ~ "^" ip "/" { print $2; exit }')"
if [[ -z "${IFACE}" ]]; then
  echo "could not find the interface for ${NODE_IP}" >&2
  ip -4 addr
  exit 1
fi

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    maxconn 200
    log stdout format raw local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30m
    timeout server 30m
    timeout check 3s
    log global

frontend pg_vip
    bind ${VIP}:5432
    default_backend pg_primary

backend pg_primary
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
    server ${NODE_NAME} ${NODE_IP}:5432 check port 8008
    server ${PARTNER_NAME} ${PARTNER_IP}:5432 check port 8008
EOF
haproxy -c -f /etc/haproxy/haproxy.cfg

cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id ${NODE_NAME}
    script_user root
    enable_script_security
}
vrrp_script chk_pg_primary {
    script "/usr/local/bin/pgcitus-is-primary"
    interval 2
    timeout 3
    weight 50
    rise 2
    fall 2
}
vrrp_instance VI_${NODE_NAME} {
    state BACKUP
    interface ${IFACE}
    virtual_router_id ${VRID}
    priority 100
    advert_int 1
    unicast_src_ip ${NODE_IP}
    unicast_peer {
        ${PARTNER_IP}
    }
    authentication {
        auth_type PASS
        auth_pass pgcitus
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_pg_primary
    }
}
EOF
keepalived -t -f /etc/keepalived/keepalived.conf

systemctl daemon-reload
echo "==== ha install complete on ${NODE_NAME} ===="
