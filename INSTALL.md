# Install and setup

This page is the first-time path. It lists what you download yourself, what the virtual machines download, and the commands that turn those pieces into a running Citus cluster.

The lab was built on an Apple Silicon Mac with 48 GB of memory, VirtualBox 7.2, and Vagrant 2.4. The same `Vagrantfile` works on an Intel Mac. Plan for about 24 GB of RAM for the ten virtual machines and about 40 GB of free disk for the box, the VM disks, and the Citus build.

| Machine | Memory | CPUs | How many |
| --- | --- | --- | --- |
| Primary `citus01`–`citus05` | 2560 MB | 2 | 5 |
| Standby `citus01b`–`citus05b` | 2048 MB | 1 | 5 |

Vagrant starts the machines one at a time. The first run compiles Citus on each primary, so leave an hour or more for `vagrant up`.

## 1. Download the tools for the Mac

You install two programs on the host. Everything else is downloaded later by Vagrant or by the guest scripts.

### Option A: Homebrew

```bash
brew install --cask virtualbox
brew install --cask vagrant
```

Homebrew pages:

- VirtualBox: <https://formulae.brew.sh/cask/virtualbox>
- Vagrant: <https://formulae.brew.sh/cask/vagrant>

After a VirtualBox upgrade, macOS may ask you to approve the kernel extension in System Settings.

### Option B: installer packages

| Tool | Download | What to install |
| --- | --- | --- |
| VirtualBox 7.x | <https://www.virtualbox.org/wiki/Downloads> | macOS / Apple Silicon or macOS / Intel, matching your Mac |
| Vagrant | <https://developer.hashicorp.com/vagrant/install> | macOS amd64 or macOS arm64 package |

Apple Silicon uses the `macOS / Apple Silicon` VirtualBox build and the Vagrant `arm64` package. An Intel Mac uses the Intel builds.

Check the tools:

```bash
VBoxManage --version
vagrant --version
```

A `psql` client on the Mac is optional. `./pg_lab psql` uses the client inside `citus01`. To connect from the Mac itself:

```bash
brew install libpq
echo 'export PATH="$(brew --prefix libpq)/bin:$PATH"' >> ~/.zshrc
```

The Homebrew formula is <https://formulae.brew.sh/formula/libpq>. The full PostgreSQL formula also ships `psql`: <https://formulae.brew.sh/formula/postgresql@17>. Keep the Mac's own PostgreSQL off port 5432 if you want that port free. This lab reaches the VMs on `15432`–`15436`, `15442`–`15446`, and the virtual IPs `192.168.32.241`–`.245`.

## 2. Download this lab

### Option A: git

```bash
git clone https://github.com/jeyram-cloud/pg-sharding-citus.git
cd pg-sharding-citus
```

SSH, when your key is registered with GitHub:

```bash
git clone git@github.com:jeyram-cloud/pg-sharding-citus.git
cd pg-sharding-citus
```

### Option B: ZIP

Download <https://github.com/jeyram-cloud/pg-sharding-citus/archive/refs/heads/main.zip>, unzip it, and `cd` into `pg-sharding-citus-main`.

The ZIP and the clone contain the `Vagrantfile`, `pg_lab`, the guest scripts, and one sample dump in `backups/`. They do not contain the virtual machines. Those are created on your Mac in the next step.

## 3. Download the AlmaLinux box

`vagrant up` downloads this box the first time. You can download it first and see the progress on its own:

```bash
vagrant box add bento/almalinux-9
```

| Item | Where it comes from |
| --- | --- |
| Box name in the Vagrantfile | `bento/almalinux-9` |
| Catalog | <https://portal.cloud.hashicorp.com/vagrant/discover/bento/almalinux-9> |
| Guest OS | AlmaLinux 9, aarch64 on Apple Silicon, x86_64 on Intel |

Vagrant picks the provider `virtualbox` and the architecture of the Mac. The box is stored under `~/.vagrant.d/boxes`. Each VM disk is stored under `~/VirtualBox VMs/`.

## 4. Create the ten virtual machines

From the lab directory:

```bash
vagrant up
```

Vagrant creates this host-only network and these machines:

| Name | Address | PostgreSQL port on the Mac | First-boot install |
| --- | --- | --- | --- |
| citus01 | 192.168.32.163 | 15432 | PostgreSQL 19, compile Citus, initdb |
| citus02 | 192.168.32.164 | 15433 | same |
| citus03 | 192.168.32.165 | 15434 | same |
| citus04 | 192.168.32.166 | 15435 | same |
| citus05 | 192.168.32.167 | 15436 | same |
| citus01b | 192.168.32.141 | 15442 | PostgreSQL 19 packages only |
| citus02b | 192.168.32.142 | 15443 | packages only |
| citus03b | 192.168.32.143 | 15444 | packages only |
| citus04b | 192.168.32.144 | 15445 | packages only |
| citus05b | 192.168.32.145 | 15446 | packages only |

A finished primary prints `citus-pg19-install complete`. A finished standby prints `postgresql19 packages installed`. Then:

```bash
vagrant status
```

All ten lines say `running`.

Leave the old VM named `Citus_citus01` powered off. It uses `192.168.32.163`, the same address as this lab's coordinator.

## 5. What the guests download

You do not fetch these by hand. The scripts do it during `vagrant up` and `./pg_lab ha-init`.

### PostgreSQL 19

The guest installs the PGDG repository, then the PostgreSQL 19 testing repo. The stable `yum/19` directory was not published when this lab was built, so the script uses testing.

| Download | URL |
| --- | --- |
| PGDG repo RPM, Apple Silicon guest | <https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm> |
| PGDG repo RPM, Intel guest | <https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm> |
| aarch64 signing key | <https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-AARCH64-RHEL> |
| PostgreSQL 19 testing packages | <https://download.postgresql.org/pub/repos/yum/testing/19/redhat/> |

Packages installed on every node:

```text
postgresql19-server
postgresql19-contrib
```

Primaries also install `postgresql19-devel`, because Citus is compiled there.

The script tries these two directories and keeps the first one that serves `repodata/repomd.xml`:

```text
https://download.postgresql.org/pub/repos/yum/testing/19/redhat/rhel-9.7-aarch64
https://download.postgresql.org/pub/repos/yum/testing/19/redhat/rhel-9-aarch64
```

On an Intel guest the architecture in those URLs is `x86_64`. The minor version follows the guest's AlmaLinux version.

### Citus source

Primaries download one commit and build it with PostgreSQL 19's `pg_config`:

```text
https://github.com/citusdata/citus/archive/08479aca8b0d0d83640559f1a641b1d9ae5c2028.tar.gz
```

That commit is `08479aca` on Citus main (`Citus 15.0devel`). The build uses `PG_CONFIG=/usr/pgsql-19/bin/pg_config`, `./configure`, and `make with_llvm=no`. The guest also installs `perl-IPC-Run` from Alma CRB and `redhat-rpm-config`.

Standbys do not compile Citus. `ha-init` copies `citus.so` and the extension files from `citus01`.

### High availability packages

`./pg_lab ha-init` installs these inside the guests:

| Package | Source |
| --- | --- |
| `patroni` 4.1 or newer, and `patroni-etcd` | PGDG common repository |
| `etcd` | PGDG extras repository `pgdg-rhel9-extras` |
| `haproxy`, `keepalived` | AlmaLinux appstream |
| `python3-psycopg2` | AlmaLinux or PGDG |

Patroni 3.0.4 is also published in that repository. The install script asks for `patroni >= 4.1` so the Citus switchover code from Patroni 4 is the one that is installed.

## 6. Create the distributed tables

Run this once, after all five primaries are running. It registers the workers, creates `countries`, `customers`, and `orders`, and loads the demo rows. Running it again drops those three tables and loads them again.

```bash
cat vagrant-configs/citus-cluster.sh | vagrant ssh citus01 -c 'sudo bash -s'
```

Check the row counts:

```bash
chmod +x pg_lab
./pg_lab health
```

A healthy result is 5 countries, 1,000 customers, and 5,000 orders, with five active nodes in `pg_dist_node`.

The sample dump already in the repo is `backups/postgres-20261112-224800.sql`. It is a `pg_dump` of that demo database. `./pg_lab restore` knows how to load it and distribute the tables again.

## 7. Add standbys, etcd, HAProxy, and Keepalived

```bash
./pg_lab ha-init --yes
```

This adopts the existing data directories. It does not run `initdb` again on the primaries. It then:

1. Copies the Citus files onto the five standbys.
2. Starts a three-member etcd cluster on `citus01`, `citus02`, and `citus03`.
3. Hands each primary's data directory to Patroni.
4. Clones a streaming standby for every primary.
5. Starts HAProxy and Keepalived. Each group gets a virtual IP.
6. Switches `citus05` to `citus05b` and back, then stops Patroni on `citus05` long enough to prove automatic promotion.

When it finishes, leadership is back on `citus01` through `citus05`.

```bash
./pg_lab ha
./pg_lab psql -c 'SELECT count(*) FROM customers;'
```

Connect from the Mac:

```bash
psql -h 192.168.32.241 -p 5432 -U postgres
```

Password: `Postgres@123`. The replication role used by the standbys is `replicator` / `Replicator@123`.

`ha-init` is the one-time adoption. On a lab that has already been through it, use `./pg_lab start` to power the machines on again.

## 8. Later days

```bash
./pg_lab start
./pg_lab status
./pg_lab health
./pg_lab ha
```

`./pg_lab start` boots every VM, then waits for PostgreSQL. etcd answers only after two of `citus01`, `citus02`, and `citus03` are up, which is why the wait comes second.

Stop the whole lab:

```bash
./pg_lab stop --yes
```

That pauses Patroni, then halts the machines. The data stays on the VM disks.

## If a saved machine never opens SSH

VirtualBox sometimes resumes a saved VM with a dead network adapter. `vagrant up` then waits until `boot_timeout` (600 seconds) and reports that SSH never arrived.

For a machine stuck in `saved` state, drop the saved memory and cold-boot. The disk is kept:

```bash
VBoxManage list vms
VBoxManage discardstate <uuid-of-that-pgcitus-vm>
./pg_lab start
```

For a machine that says `running` but port 22 still times out, power it off from VirtualBox and run `./pg_lab start` again. PostgreSQL recovers its files on the way up.

## Setup order on one page

```text
brew install --cask virtualbox vagrant
git clone https://github.com/jeyram-cloud/pg-sharding-citus.git
cd pg-sharding-citus
vagrant box add bento/almalinux-9
vagrant up
cat vagrant-configs/citus-cluster.sh | vagrant ssh citus01 -c 'sudo bash -s'
./pg_lab ha-init --yes
./pg_lab health
./pg_lab ha
psql -h 192.168.32.241 -U postgres
```

The concept pictures and every `pg_lab` command are in [README.md](README.md). SQL practice is in [ARCHITECTURE.md](ARCHITECTURE.md).
