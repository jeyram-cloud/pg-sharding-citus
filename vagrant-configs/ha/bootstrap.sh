#!/usr/bin/env bash
# Adopt the running Citus primaries into Patroni and clone a standby per group.
# Run from the pgcitus directory: ./vagrant-configs/ha/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

PRIMARIES=(citus01 citus02 citus03 citus04 citus05)
STANDBYS=(citus01b citus02b citus03b citus04b citus05b)
GROUPS_FILE="${ROOT}/vagrant-configs/ha/groups.tsv"

node_ip() {
  case "$1" in
    citus01) echo 192.168.32.163 ;;
    citus02) echo 192.168.32.164 ;;
    citus03) echo 192.168.32.165 ;;
    citus04) echo 192.168.32.166 ;;
    citus05) echo 192.168.32.167 ;;
    citus01b) echo 192.168.32.141 ;;
    citus02b) echo 192.168.32.142 ;;
    citus03b) echo 192.168.32.143 ;;
    citus04b) echo 192.168.32.144 ;;
    citus05b) echo 192.168.32.145 ;;
    *) echo "unknown node $1" >&2; return 1 ;;
  esac
}

partner_of() {
  case "$1" in
    citus01) echo citus01b ;;
    citus02) echo citus02b ;;
    citus03) echo citus03b ;;
    citus04) echo citus04b ;;
    citus05) echo citus05b ;;
    citus01b) echo citus01 ;;
    citus02b) echo citus02 ;;
    citus03b) echo citus03 ;;
    citus04b) echo citus04 ;;
    citus05b) echo citus05 ;;
    *) echo "unknown node $1" >&2; return 1 ;;
  esac
}

vip_of() {
  case "$1" in
    citus01|citus01b) echo 192.168.32.241 ;;
    citus02|citus02b) echo 192.168.32.242 ;;
    citus03|citus03b) echo 192.168.32.243 ;;
    citus04|citus04b) echo 192.168.32.244 ;;
    citus05|citus05b) echo 192.168.32.245 ;;
    *) echo "unknown node $1" >&2; return 1 ;;
  esac
}

vrid_of() {
  case "$1" in
    citus01|citus01b) echo 51 ;;
    citus02|citus02b) echo 52 ;;
    citus03|citus03b) echo 53 ;;
    citus04|citus04b) echo 54 ;;
    citus05|citus05b) echo 55 ;;
    *) echo "unknown node $1" >&2; return 1 ;;
  esac
}

etcd_member() {
  case "$1" in
    citus01|citus02|citus03) echo yes ;;
    *) echo no ;;
  esac
}

ssh_node() {
  local node="$1"
  shift
  vagrant ssh "${node}" -c "$*"
}

patronictl_on() {
  local node="$1"
  shift
  ssh_node "${node}" "sudo env PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin patronictl -c /etc/patroni.yml $*"
}

psql_on() {
  local node="$1"
  local sql="$2"
  printf '%s\n' "${sql}" | vagrant ssh "${node}" -c 'sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -tA -P pager=off'
}

wait_http() {
  local node="$1"
  local path="$2"
  local attempt body
  for attempt in $(seq 1 60); do
    # Standbys are tagged noloadbalance, so Patroni answers 503 on /replica
    # even while they are streaming. /patroni still reports the role.
    if [[ "${path}" == "/replica" ]]; then
      body="$(ssh_node "${node}" "curl -sf --max-time 2 http://127.0.0.1:8008/patroni" 2>/dev/null || true)"
      if printf '%s' "${body}" | grep -q '"role": "replica"' && printf '%s' "${body}" | grep -q '"replication_state": "streaming"'; then
        echo "${node}: replica is streaming"
        return 0
      fi
    elif ssh_node "${node}" "curl -sf --max-time 2 -o /dev/null http://127.0.0.1:8008${path}"; then
      echo "${node}: ${path} is ready"
      return 0
    fi
    echo "waiting for ${node} ${path} (${attempt}/60)"
    sleep 5
  done
  echo "${node} did not become ready at ${path}" >&2
  ssh_node "${node}" "sudo journalctl -u patroni -n 80 --no-pager" || true
  return 1
}

install_one() {
  local node="$1"
  local role="$2"
  local group_id="$3"
  local partner
  partner="$(partner_of "${node}")"
  echo "installing HA packages on ${node}"
  cat "${ROOT}/vagrant-configs/ha/install-node.sh" | vagrant ssh "${node}" -c \
    "sudo env NODE_NAME=${node} NODE_IP=$(node_ip "${node}") PARTNER_NAME=${partner} PARTNER_IP=$(node_ip "${partner}") VIP=$(vip_of "${node}") VRID=$(vrid_of "${node}") GROUP_ID=${group_id} ROLE=${role} ETCD_MEMBER=$(etcd_member "${node}") bash -s"
}

group_of_name() {
  local name="$1"
  awk -v n="${name}" '$1 == n { print $2; exit }' "${GROUPS_FILE}"
}

echo "reading Citus groups from citus01"
GROUP_ROWS=()
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  GROUP_ROWS+=("${line}")
done < <(psql_on citus01 "SELECT groupid || ' ' || nodename FROM pg_dist_node WHERE isactive AND noderole = 'primary' ORDER BY groupid;")
if [[ "${#GROUP_ROWS[@]}" -ne 5 ]]; then
  echo "expected 5 primary Citus nodes, got ${#GROUP_ROWS[@]}" >&2
  printf '%s\n' "${GROUP_ROWS[@]}" >&2
  exit 1
fi

: > "${GROUPS_FILE}"
for row in "${GROUP_ROWS[@]}"; do
  gid="${row%% *}"
  name="${row##* }"
  if [[ "${name}" == "citus01" && "${gid}" != "0" ]]; then
    echo "coordinator citus01 is group ${gid}, expected 0" >&2
    exit 1
  fi
  partner="$(partner_of "${name}")"
  printf '%s %s %s\n' "${name}" "${gid}" "${partner}" >> "${GROUPS_FILE}"
  printf '%s %s %s\n' "${partner}" "${gid}" "${name}" >> "${GROUPS_FILE}"
done
echo "group map:"
cat "${GROUPS_FILE}"

echo "copying Citus binaries from citus01"
b64="$(printf '%s\n' 'cd / && find usr/pgsql-19 -name "citus*" -print | tar -T - -czf - | base64 -w 0' | vagrant ssh citus01 -c 'sudo bash -s' | tr -d '\r' | awk 'length($0) > 1000 { line = $0 } END { print line }')"
if [[ "${#b64}" -lt 1000 ]]; then
  echo "Citus binary archive from citus01 is too small" >&2
  exit 1
fi
for node in "${STANDBYS[@]}"; do
  echo "installing Citus files on ${node}"
  printf '%s\n' "${b64}" | vagrant ssh "${node}" -c 'base64 -d | sudo tar -C / -xzf -'
  ssh_node "${node}" 'test -f /usr/pgsql-19/lib/citus.so && test -f /usr/pgsql-19/share/extension/citus.control'
done

for row in "${GROUP_ROWS[@]}"; do
  gid="${row%% *}"
  name="${row##* }"
  install_one "${name}" primary "${gid}"
  install_one "$(partner_of "${name}")" standby "${gid}"
done

echo "starting etcd on citus01 citus02 citus03"
for node in citus01 citus02 citus03; do
  ssh_node "${node}" 'sudo systemctl enable --now etcd'
done
for attempt in $(seq 1 30); do
  if ssh_node citus01 'curl -sf --max-time 2 http://127.0.0.1:2379/health | grep -q true'; then
    echo "etcd is healthy"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    echo "etcd did not become healthy" >&2
    ssh_node citus01 'sudo journalctl -u etcd -n 60 --no-pager' || true
    exit 1
  fi
  echo "waiting for etcd (${attempt}/30)"
  sleep 3
done

adopt_primary() {
  local node="$1"
  echo "adopting ${node} into Patroni"
  ssh_node "${node}" 'sudo systemctl disable --now postgresql-19 || true'
  if ssh_node "${node}" "curl -sf --max-time 2 -o /dev/null http://127.0.0.1:8008/primary"; then
    ssh_node "${node}" 'sudo systemctl enable patroni'
    echo "${node}: /primary is ready"
  else
    ssh_node "${node}" 'sudo systemctl enable --now patroni'
  fi
  if ! wait_http "${node}" /primary; then
    echo "Patroni did not adopt ${node}" >&2
    if ssh_node "${node}" 'systemctl is-active --quiet patroni'; then
      echo "patroni is still active on ${node}; leaving postgresql-19 disabled" >&2
    else
      echo "starting postgresql-19 on ${node}" >&2
      ssh_node "${node}" 'sudo systemctl disable --now patroni || true'
      ssh_node "${node}" 'sudo systemctl enable --now postgresql-19'
    fi
    exit 1
  fi
}

ensure_replicator() {
  local node="$1"
  # Adopting an existing data directory does not create this role. pg_basebackup needs it.
  psql_on "${node}" "DO \$body\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD 'Replicator@123'; ELSE ALTER ROLE replicator WITH LOGIN REPLICATION PASSWORD 'Replicator@123'; END IF; END \$body\$;"
}

for name in "${PRIMARIES[@]}"; do
  adopt_primary "${name}"
done

echo "keeping max_locks_per_transaction at 128 in every Citus group"
patronictl_on citus01 "edit-config pgcitus -p max_locks_per_transaction=128 --force -q" || true
for group_id in 0 1 2 3 4; do
  patronictl_on citus01 "edit-config pgcitus --group ${group_id} -p max_locks_per_transaction=128 --force -q"
done

for name in "${PRIMARIES[@]}"; do
  ensure_replicator "${name}"
done

# A paused Patroni will not start PostgreSQL after a restart, so this path
# reloads the member and restarts it only when its partner is not streaming.
for name in "${PRIMARIES[@]}" "${STANDBYS[@]}"; do
  if ! ssh_node "${name}" 'systemctl is-active --quiet patroni'; then
    continue
  fi
  if ssh_node "${name}" "sudo -u postgres psql -d postgres -tAc 'SHOW listen_addresses;'" | grep -q '10.0.2.15'; then
    continue
  fi
  partner="$(partner_of "${name}")"
  if ssh_node "${partner}" "curl -sf --max-time 2 http://127.0.0.1:8008/patroni" 2>/dev/null | grep -q '"replication_state": "streaming"'; then
    echo "${name} is missing the NAT listen address and ${partner} is streaming; leaving ${name} up"
    continue
  fi
  echo "restarting ${name} so PostgreSQL listens on the NAT address"
  ssh_node "${name}" 'sudo kill -HUP "$(systemctl show -p MainPID --value patroni)" || true'
  ssh_node "${name}" 'sudo systemctl restart patroni'
  if ssh_node "${name}" "curl -sf --max-time 2 -o /dev/null http://127.0.0.1:8008/primary"; then
    wait_http "${name}" /primary
  else
    wait_http "${name}" /replica
  fi
done

echo "checking the distributed tables before the standbys clone"
customers="$(psql_on citus01 "SELECT count(*) FROM customers;")"
customers="$(echo "${customers}" | tr -d '[:space:]')"
echo "customers=${customers}"
if [[ "${customers}" != "1000" ]]; then
  echo "expected 1000 customers after adoption, got ${customers}" >&2
  exit 1
fi
psql_on citus01 "SELECT CASE WHEN bool_and(shouldhaveshards) THEN 'yes' ELSE 'no' END FROM pg_dist_node WHERE isactive;" | tr -d '[:space:]' | grep -qx yes \
  || psql_on citus01 "SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', true) FROM pg_dist_node WHERE NOT shouldhaveshards;"

for name in "${STANDBYS[@]}"; do
  echo "cloning standby ${name}"
  ssh_node "${name}" 'sudo systemctl enable --now patroni'
  wait_http "${name}" /replica
done

echo "starting HAProxy and Keepalived"
for node in "${PRIMARIES[@]}" "${STANDBYS[@]}"; do
  ssh_node "${node}" 'sudo systemctl enable --now haproxy keepalived'
done

sleep 5
echo "VIP endpoints:"
for vip in citus01-vip citus02-vip citus03-vip citus04-vip citus05-vip; do
  server="$(ssh_node citus01 "sudo -u postgres psql -d postgres -h ${vip} -tAc 'SELECT inet_server_addr();'" | tr -d '[:space:]')"
  echo "${vip} -> ${server}"
  if [[ -z "${server}" ]]; then
    echo "${vip} did not answer" >&2
    exit 1
  fi
done

echo "planned switchover of citus05 to citus05b"
g5="$(group_of_name citus05)"
patronictl_on citus01 "switchover pgcitus --group ${g5} --leader citus05 --candidate citus05b --force"
wait_http citus05b /primary
wait_http citus05 /replica
customers="$(psql_on citus01 "SELECT count(*) FROM customers;" | tr -d '[:space:]')"
echo "customers after switchover=${customers}"
if [[ "${customers}" != "1000" ]]; then
  echo "customer count changed during switchover" >&2
  exit 1
fi

echo "switching citus05 back"
patronictl_on citus01 "switchover pgcitus --group ${g5} --leader citus05b --candidate citus05 --force"
wait_http citus05 /primary
wait_http citus05b /replica

echo "automatic failover: stop Patroni on citus05"
ssh_node citus05 'sudo systemctl stop patroni'
wait_http citus05b /primary
customers="$(psql_on citus01 "SELECT count(*) FROM customers;" | tr -d '[:space:]')"
echo "customers after failover=${customers}"
if [[ "${customers}" != "1000" ]]; then
  echo "customer count changed during failover" >&2
  exit 1
fi
echo "citus05b is the leader while citus05 is stopped"
ssh_node citus05 'sudo systemctl start patroni'
wait_http citus05 /replica
echo "switching leadership back to citus05"
patronictl_on citus01 "switchover pgcitus --group ${g5} --leader citus05b --candidate citus05 --force"
wait_http citus05 /primary
wait_http citus05b /replica
customers="$(psql_on citus01 "SELECT count(*) FROM customers;" | tr -d '[:space:]')"
echo "customers final=${customers}"
if [[ "${customers}" != "1000" ]]; then
  echo "customer count changed while restoring citus05" >&2
  exit 1
fi

echo "HA bootstrap complete"
patronictl_on citus01 "list pgcitus"
