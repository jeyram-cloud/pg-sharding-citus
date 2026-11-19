#!/usr/bin/env bash
# Run on citus01 after every node has PostgreSQL and Citus.
# Registers all five nodes as shard holders, then creates a reference table
# and two colocated distributed tables. With shard_count 5 and replication
# factor 1, each distributed table places one shard on every node.
set -euo pipefail

echo "==== citus-cluster on $(hostname -s) @ $(date) ===="

if [[ "$(hostname -s)" != "citus01" ]]; then
  echo "citus-cluster.sh runs on citus01" >&2
  exit 1
fi

psql_local() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres "$@"
}

wait_for_citus() {
  local host="$1"
  local attempt
  for attempt in $(seq 1 180); do
    if PGCONNECT_TIMEOUT=5 sudo -u postgres psql -h "$host" -p 5432 -d postgres -tAc \
      "SELECT extversion FROM pg_extension WHERE extname = 'citus'" 2>/dev/null | grep -q .; then
      echo "${host} is ready"
      return 0
    fi
    echo "waiting for Citus on ${host} (${attempt}/180)"
    sleep 20
  done
  echo "timed out waiting for Citus on ${host}" >&2
  return 1
}

mapfile -t WORKERS < <(awk '$2 ~ /^citus0[2-5]$/ { print $2 }' /etc/hosts | sort -u)
if [[ "${#WORKERS[@]}" -ne 4 ]]; then
  echo "expected citus02-citus05 in /etc/hosts, found: ${WORKERS[*]:-none}" >&2
  exit 1
fi

for host in citus01 "${WORKERS[@]}"; do
  wait_for_citus "$host"
done

psql_local -c "SELECT citus_set_coordinator_host('citus01', 5432);"

for host in "${WORKERS[@]}"; do
  exists="$(psql_local -tAc "SELECT count(*) FROM pg_dist_node WHERE nodename = '${host}' AND nodeport = 5432")"
  if [[ "${exists}" == "0" ]]; then
    psql_local -c "SELECT citus_add_node('${host}', 5432);"
  else
    echo "${host} is already in the cluster"
  fi
done

psql_local -c "SELECT citus_set_node_property('citus01', 5432, 'shouldhaveshards', true);"
psql_local -c "ALTER SYSTEM SET citus.shard_count = 5;"
psql_local -c "ALTER SYSTEM SET citus.shard_replication_factor = 1;"
psql_local -c "SELECT pg_reload_conf();"

shard_count="$(psql_local -tAc 'SHOW citus.shard_count;')"
if [[ "${shard_count}" != "5" ]]; then
  echo "citus.shard_count is ${shard_count}, expected 5" >&2
  exit 1
fi

psql_local <<'SQL'
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS countries;

CREATE TABLE countries (
    country_code char(2) PRIMARY KEY,
    country_name text NOT NULL
);
SELECT create_reference_table('countries');

INSERT INTO countries (country_code, country_name) VALUES
    ('US', 'United States'),
    ('IN', 'India'),
    ('UK', 'United Kingdom'),
    ('DE', 'Germany'),
    ('JP', 'Japan');

CREATE TABLE customers (
    customer_id  bigint PRIMARY KEY,
    email        text NOT NULL,
    country_code char(2) NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
SELECT create_distributed_table('customers', 'customer_id');

CREATE TABLE orders (
    order_id    bigint NOT NULL,
    customer_id bigint NOT NULL,
    amount      numeric(12,2) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, order_id)
);
SELECT create_distributed_table('orders', 'customer_id', colocate_with => 'customers');

ALTER TABLE customers
    ADD CONSTRAINT customers_country_fk
    FOREIGN KEY (country_code) REFERENCES countries (country_code);

ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fk
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id);

INSERT INTO customers (customer_id, email, country_code)
SELECT g,
       'customer' || g || '@example.com',
       (ARRAY['US','IN','UK','DE','JP'])[1 + (g % 5)]
FROM generate_series(1, 1000) g;

INSERT INTO orders (order_id, customer_id, amount)
SELECT g,
       1 + (g % 1000),
       round((10 + (g % 500))::numeric, 2)
FROM generate_series(1, 5000) g;
SQL

echo
echo "==== cluster nodes ===="
psql_local -c "SELECT nodeid, groupid, nodename, nodeport, isactive, shouldhaveshards, hasmetadata
               FROM pg_dist_node
               ORDER BY nodeid;"

echo
echo "==== shard placement ===="
psql_local -c "SELECT s.logicalrelid::text AS table_name,
                      p.shardid,
                      p.nodename,
                      p.shardstate
               FROM pg_dist_shard s
               JOIN pg_dist_shard_placement p USING (shardid)
               ORDER BY table_name, p.shardid, p.nodename;"

customer_nodes="$(psql_local -tAc "
SELECT count(DISTINCT p.nodename)
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p USING (shardid)
WHERE s.logicalrelid = 'customers'::regclass;
")"
order_nodes="$(psql_local -tAc "
SELECT count(DISTINCT p.nodename)
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p USING (shardid)
WHERE s.logicalrelid = 'orders'::regclass;
")"
country_nodes="$(psql_local -tAc "
SELECT count(DISTINCT p.nodename)
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p USING (shardid)
WHERE s.logicalrelid = 'countries'::regclass;
")"

echo "customers shards are on ${customer_nodes} nodes"
echo "orders shards are on ${order_nodes} nodes"
echo "countries replicas are on ${country_nodes} nodes"

if [[ "${customer_nodes}" != "5" || "${order_nodes}" != "5" || "${country_nodes}" != "5" ]]; then
  echo "expected every table on all 5 nodes" >&2
  exit 1
fi

echo
echo "==== row counts ===="
psql_local -c "SELECT count(*) AS customers FROM customers;"
psql_local -c "SELECT count(*) AS orders FROM orders;"
psql_local -c "SELECT count(*) AS countries FROM countries;"

echo "==== citus-cluster complete ===="
