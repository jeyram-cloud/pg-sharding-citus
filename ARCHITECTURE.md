# PostgreSQL 19 + Citus lab

The short picture of this lab, and an explanation of every `./pg_lab` command, is in [README.md](README.md).

Five AlmaLinux 9 virtual machines on VirtualBox hold the shards. Five more machines are their streaming standbys. Each one runs PostgreSQL 19rc2 and Citus 15.0devel. Applications connect to the coordinator virtual IP `192.168.32.241`. Citus splits distributed tables into shards and places one shard on every primary, including the coordinator.

PostgreSQL 19 is release candidate 2. General availability is planned for 19 November 2026. Citus 14.3 packages stop at PostgreSQL 18, so this lab builds the current Citus source that accepts PostgreSQL 19 (commit `08479aca`).

## Architecture

```text
                         this Mac
              psql -h 192.168.32.241 -U postgres
                              |
                              | virtual IP, kept on the current primary
                              v
        +----------------------------------------------+
        | group 0   citus01 primary   citus01b standby |
        | coordinator, catalog, router, and one shard  |
        +------+----------+----------+----------+------+
               |          |          |          |
     private network 192.168.32.0/24
               |          |          |          |
        +------v--+ +-----v---+ +----v----+ +---v-----+
        | group 1 | | group 2 | | group 3 | | group 4 |
        | citus02 | | citus03 | | citus04 | | citus05 |
        | + 02b   | | + 03b   | | + 04b   | | + 05b   |
        +---------+ +---------+ +---------+ +---------+
```

| Node | Role | Private IP | Port on this Mac | RAM |
| --- | --- | --- | --- | --- |
| citus01 | Coordinator primary and shard holder | 192.168.32.163 | 15432 | 2560 MB |
| citus02 | Worker primary | 192.168.32.164 | 15433 | 2560 MB |
| citus03 | Worker primary | 192.168.32.165 | 15434 | 2560 MB |
| citus04 | Worker primary | 192.168.32.166 | 15435 | 2560 MB |
| citus05 | Worker primary | 192.168.32.167 | 15436 | 2560 MB |
| citus01b–citus05b | Streaming standbys | 192.168.32.141–145 | 15442–15446 | 2048 MB |

`citus01` is group 0 in `pg_dist_node`. `citus_set_node_property(..., 'shouldhaveshards', true)` tells Citus to place shards there as well as on the four workers. `citus.shard_count` is 5 and `citus.shard_replication_factor` is 1, so each distributed table has five shards and each shard has one copy.

Two table kinds are already loaded in database `postgres`:

| Table | Kind | Distribution | What is stored |
| --- | --- | --- | --- |
| `countries` | Reference | One shard, copied to every node | 5 country rows on all 5 nodes |
| `customers` | Distributed | Hash of `customer_id` | 1,000 rows, one shard per node |
| `orders` | Distributed, colocated with `customers` | Hash of `customer_id` | 5,000 rows, on the same node as that customer |

Colocation means a customer and that customer's orders share the same shard. A join on `customer_id` runs locally on each node. The password for `postgres` is `Postgres@123`. On `192.168.32.0/24` the nodes use `trust`, so they connect to each other without a password. Firewalld is off and SELinux is permissive inside the VMs.

## Files

```text
pgcitus/
├── README.md                       concept, pictures, and every pg_lab command
├── ARCHITECTURE.md                 practice SQL and the HA layout
├── pg_lab                          host wrapper
├── Vagrantfile
└── vagrant-configs/
    ├── common-setup.sh             hosts, firewall, SELinux
    ├── citus-pg19-install.sh       PostgreSQL 19rc2 and the Citus build
    ├── citus-cluster.sh            register nodes and create the tables
    ├── ha/                         Patroni, etcd, HAProxy, Keepalived
    └── ops/                        scripts the wrapper runs on each guest
```

Vagrant starts the machines one at a time, so `citus-cluster.sh` is not a provisioner. Run it after all five nodes are up. Running it again drops `orders`, `customers`, and `countries` and loads the demo rows again.

## Start and connect

```bash
cd /Users/jey/pgcitus
vagrant status
vagrant up

# First time only, after all five show "running":
cat vagrant-configs/citus-cluster.sh | vagrant ssh citus01 -c 'sudo bash -s'

psql -h 127.0.0.1 -p 15432 -U postgres
```

Stop the lab with `vagrant halt`. Start it again with `vagrant up`. The data directory is on each VM disk, so the tables are still there after a halt.

## Practice 1: See the cluster

Run these on `citus01`.

```sql
SELECT version();
SELECT citus_version();

SELECT nodeid, groupid, nodename, nodeport, isactive, shouldhaveshards
FROM pg_dist_node
ORDER BY nodeid;
```

You should see PostgreSQL `19rc2`, Citus `15.0devel`, and five active nodes with `shouldhaveshards = t`.

## Practice 2: See where each shard lives

```sql
SELECT s.logicalrelid::text AS table_name,
       p.shardid,
       p.nodename
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p USING (shardid)
ORDER BY table_name, p.nodename;
```

`countries` is one shard id repeated on all five nodes. `customers` and `orders` each have five shard ids, one per node. Shard state `1` means the placement is finalized.

Count the customer rows on each node:

```sql
SELECT p.nodename, r.result AS customers
FROM run_command_on_shards('customers', $$SELECT count(*) FROM %s$$) r
JOIN pg_dist_shard_placement p ON p.shardid = r.shardid
ORDER BY p.nodename;
```

The five counts add up to 1,000. They are not equal, because hash placement does not split a small row set into perfect fifths.

## Practice 3: Insert a row and find its node

```sql
INSERT INTO customers (customer_id, email, country_code)
VALUES (5001, 'practice@example.com', 'IN');

SELECT customer_id, email
FROM customers
WHERE customer_id = 5001;

SELECT p.nodename, r.result
FROM run_command_on_shards(
        'customers',
        $$SELECT count(*) FROM %s WHERE customer_id = 5001$$
     ) r
JOIN pg_dist_shard_placement p ON p.shardid = r.shardid
WHERE r.result <> '0';
```

The `WHERE customer_id = 5001` filter is a router query. Citus hashes `5001` and opens only the shard that owns that hash. One node returns `1`. The other four return `0`.

## Practice 4: Read the plan

```sql
EXPLAIN (COSTS OFF)
SELECT email FROM customers WHERE customer_id = 5001;

EXPLAIN (COSTS OFF)
SELECT country_code, count(*)
FROM customers
GROUP BY country_code
ORDER BY country_code;
```

The first plan names a single shard, such as `customers_102009`, and one worker. The second plan is a distributed aggregate: each node counts its own shard, and `citus01` merges the five partial counts.

## Practice 5: Join a distributed table to a reference table

```sql
SELECT c.country_name, count(*) AS customers
FROM customers cu
JOIN countries c ON c.country_code = cu.country_code
GROUP BY c.country_name
ORDER BY c.country_name;
```

`countries` is present on every node, so each worker joins its customer shard to the local copy. No customer row has to move for the join.

Confirm the foreign key:

```sql
INSERT INTO customers (customer_id, email, country_code)
VALUES (5002, 'bad-country@example.com', 'ZZ');
```

That insert fails. `ZZ` is not in `countries`.

## Practice 6: Colocated orders

```sql
INSERT INTO orders (order_id, customer_id, amount)
VALUES (90001, 5001, 42.50);

SELECT cu.email, o.order_id, o.amount
FROM customers cu
JOIN orders o USING (customer_id)
WHERE cu.customer_id = 5001;

EXPLAIN (COSTS OFF)
SELECT cu.email, sum(o.amount) AS spent
FROM customers cu
JOIN orders o USING (customer_id)
GROUP BY cu.email
ORDER BY spent DESC
LIMIT 5;
```

The join stays on the worker that holds both shards. The plan shows colocated joins rather than a repartition of `orders` across the network.

This insert fails, because customer `999999` does not exist:

```sql
INSERT INTO orders (order_id, customer_id, amount)
VALUES (90002, 999999, 10.00);
```

## Practice 7: Look at a shard from a worker

From the Mac:

```bash
vagrant ssh citus02 -c "sudo -u postgres psql -d postgres -c \"\\dt public.*\""
```

On a worker you see local shard tables such as `customers_102010` and `orders_102015`, plus the `countries` copy. The names end in the shard id from Practice 2. Querying `customers` on the coordinator hides those physical names.

Pick the shard that Practice 2 placed on `citus02` and count it there:

```bash
vagrant ssh citus02 -c "sudo -u postgres psql -d postgres -c \
  \"SELECT count(*) FROM customers_102010;\""
```

Replace `102010` with the `customers` shard id whose `nodename` is `citus02`.

## Practice 8: Create your own distributed table

Still on `citus01`:

```sql
SHOW citus.shard_count;
SHOW citus.shard_replication_factor;

CREATE TABLE payments (
    customer_id bigint NOT NULL,
    payment_id  bigint NOT NULL,
    amount      numeric(12,2) NOT NULL,
    PRIMARY KEY (customer_id, payment_id)
);

SELECT create_distributed_table('payments', 'customer_id', colocate_with => 'customers');

INSERT INTO payments (customer_id, payment_id, amount)
SELECT 1 + (g % 1000), g, 15.00
FROM generate_series(1, 1000) g;

SELECT p.nodename, count(*) AS shards
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p USING (shardid)
WHERE s.logicalrelid = 'payments'::regclass
GROUP BY p.nodename
ORDER BY p.nodename;
```

`citus.shard_count` is 5, so `payments` gets one shard on every node. `colocate_with => 'customers'` puts payment shard boundaries on the same nodes as the customer shards. The primary key includes `customer_id` because Citus requires the distribution column in every unique constraint.

Drop it when you are done:

```sql
DROP TABLE payments;
```

## Practice 9: Clean up the rows you added

```sql
DELETE FROM orders WHERE order_id = 90001;
DELETE FROM customers WHERE customer_id IN (5001, 5002);
```

To restore the original 1,000 customers, 5,000 orders, and 5 countries, run the cluster script again. It drops those three tables and reloads them.

```bash
cd /Users/jey/pgcitus
cat vagrant-configs/citus-cluster.sh | vagrant ssh citus01 -c 'sudo bash -s'
```

## High availability

Each shard group is its own Patroni pair. `citus01` with `citus01b` is Citus group 0. `citus02` with `citus02b` is the next worker group, and the same pattern continues through `citus05`. All ten members share the Patroni scope `pgcitus`. etcd runs on `citus01`, `citus02`, and `citus03`, so one of those machines can be down and the rest still agree on who the leader is.

Applications keep using one address per group. Keepalived moves that address to the node Patroni currently calls the primary, and HAProxy on that address forwards only to the node whose Patroni health check says `/primary`.

| Group | Primary | Standby | Virtual IP |
| --- | --- | --- | --- |
| 0 coordinator | citus01 192.168.32.163 | citus01b 192.168.32.141 | 192.168.32.241 |
| worker | citus02 192.168.32.164 | citus02b 192.168.32.142 | 192.168.32.242 |
| worker | citus03 192.168.32.165 | citus03b 192.168.32.143 | 192.168.32.243 |
| worker | citus04 192.168.32.166 | citus04b 192.168.32.144 | 192.168.32.244 |
| worker | citus05 192.168.32.167 | citus05b 192.168.32.145 | 192.168.32.245 |

Patroni updates `pg_dist_node` when a worker changes roles, so the coordinator follows the new primary. A planned window uses `./pg_lab maint --yes --node citus05`, which switches that group to `citus05b` and then leaves `citus05` as the standby. Reboot and single-node stop do the same switch before the machine goes down. If the primary disappears without a planned switch, Patroni promotes the standby after its leader lock expires.

```bash
cd /Users/jey/pgcitus
vagrant up
./pg_lab ha-init --yes
./pg_lab ha
./pg_lab maint --yes --node citus05
```

`ha-init` is the one-time adoption. It keeps the existing data directories, starts Patroni, clones each standby, and checks that `customers` still has 1,000 rows through a switchover and a failover of `citus05`. Patroni's own support statement lists PostgreSQL through 18. This lab runs Patroni 4.1.5 against PostgreSQL 19rc2 and treats a successful `ha-init` as the proof that this cluster starts.

Patroni does not create roles when it adopts an existing data directory. `ha-init` creates `replicator` with password `Replicator@123` on each primary before the standby clone. Standby members are tagged `noloadbalance`, so Patroni leaves them out of `pg_dist_node` until one of them becomes the primary. That tag also makes `GET /replica` return 503 while the node is streaming. `./pg_lab` reads `GET /patroni` for the role. PostgreSQL listens on `127.0.0.1`, the VirtualBox NAT address `10.0.2.15`, and the host-only address, so the existing Mac port forwards keep working. `max_locks_per_transaction` stays at 128.

Connect to the coordinator through the stable address:

```bash
psql -h 192.168.32.241 -U postgres
```

The password is `Postgres@123`. Host ports `15442`–`15446` forward the standby PostgreSQL ports. Primaries use 2560 MB and standbys 2048 MB.

## pg_lab commands

Run these from `/Users/jey/pgcitus`. `citus01` is the coordinator. `citus02`, `citus03`, `citus04`, and `citus05` are the workers. Reboot, OS patch, database patch, and PostgreSQL restart visit the workers first and `citus01` last.

```bash
cd /Users/jey/pgcitus

./pg_lab help
./pg_lab status
./pg_lab health
./pg_lab precheck
./pg_lab precheck --node citus01
./pg_lab start
./pg_lab start --node citus03
./pg_lab stop --yes
./pg_lab stop --yes --node citus05
./pg_lab reboot --yes
./pg_lab reboot --yes --node citus02
./pg_lab reboot --dry-run
./pg_lab os-patch --yes
./pg_lab os-patch --yes --no-reboot
./pg_lab os-patch --yes --node citus04
./pg_lab os-patch --dry-run
./pg_lab db-patch --yes
./pg_lab db-patch --yes --node citus03
./pg_lab db-patch --dry-run
./pg_lab restart-db --yes
./pg_lab restart-db --yes --node citus02
./pg_lab restart-db --dry-run
./pg_lab backup
./pg_lab backup /tmp/pgcitus-backups
./pg_lab backups
./pg_lab restore --yes backups/postgres-YYYYMMDD-HHMMSS.sql
./pg_lab shards
./pg_lab activity
./pg_lab ha
./pg_lab ha-init --yes
./pg_lab switchover --yes --node citus05
./pg_lab maint --yes --node citus05
./pg_lab logs
./pg_lab logs --node citus02
./pg_lab logs --node citus02 200
./pg_lab psql
./pg_lab psql -c 'SELECT count(*) FROM customers;'
```

`--yes` skips the confirmation prompt. `--node citus02` limits the action to that machine. `--dry-run` prints the plan and changes nothing. `--no-reboot` lets `os-patch` install packages and leave the reboot for later.

`os-patch` updates AlmaLinux and leaves the `postgresql19` packages unchanged. `db-patch` updates only the `postgresql19` packages. When one of those RPMs changes, Citus is rebuilt from commit `08479aca` and PostgreSQL restarts through Patroni. `./pg_lab ha` shows the Patroni role of every node and the server behind each virtual IP. `./pg_lab maint --yes --node citus05` moves that shard to `citus05b`. `./pg_lab switchover --yes --node citus05b` moves it back. The same command list is printed by `./pg_lab help`.

Do not start the old powered-off VM `Citus_citus01` while this lab is running. It also uses `192.168.32.163`.
