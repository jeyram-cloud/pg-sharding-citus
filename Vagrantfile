# -*- mode: ruby -*-
# vi: set ft=ruby :

# PostgreSQL 19 + Citus, with a streaming standby for every shard group.
#
#   citus01   192.168.32.163  coordinator primary     VIP 192.168.32.241
#   citus01b  192.168.32.141  coordinator standby
#   citus02   192.168.32.164  worker primary          VIP 192.168.32.242
#   citus02b  192.168.32.142  worker standby
#   citus03   192.168.32.165  worker primary          VIP 192.168.32.243
#   citus03b  192.168.32.143  worker standby
#   citus04   192.168.32.166  worker primary          VIP 192.168.32.244
#   citus04b  192.168.32.144  worker standby
#   citus05   192.168.32.167  worker primary          VIP 192.168.32.245
#   citus05b  192.168.32.145  worker standby
#
# Host ports 15432-15436 and 15442-15446 forward each guest's PostgreSQL port.
# Primaries use 2560 MB and standbys 2048 MB so ten VMs fit on this Mac.
#
# Vagrant brings machines up one at a time, so cluster join is not a
# provisioner. After the five primaries exist:
#   cat vagrant-configs/citus-cluster.sh | vagrant ssh citus01 -c 'sudo bash -s'
# After the standbys exist:
#   ./pg_lab ha-init --yes

NODES = [
  ["citus01", "192.168.32.163", 15432],
  ["citus02", "192.168.32.164", 15433],
  ["citus03", "192.168.32.165", 15434],
  ["citus04", "192.168.32.166", 15435],
  ["citus05", "192.168.32.167", 15436],
].freeze

STANDBYS = [
  ["citus01b", "192.168.32.141", 15442],
  ["citus02b", "192.168.32.142", 15443],
  ["citus03b", "192.168.32.143", 15444],
  ["citus04b", "192.168.32.144", 15445],
  ["citus05b", "192.168.32.145", 15446],
].freeze

VIPS = [
  ["citus01-vip", "192.168.32.241"],
  ["citus02-vip", "192.168.32.242"],
  ["citus03-vip", "192.168.32.243"],
  ["citus04-vip", "192.168.32.244"],
  ["citus05-vip", "192.168.32.245"],
].freeze

Vagrant.configure("2") do |config|
  config.vm.box = "bento/almalinux-9"
  config.ssh.username = "vagrant"
  config.vm.box_check_update = false
  config.vm.boot_timeout = 600
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 2560
    vb.cpus = 2
    vb.gui = false
  end

  host_args = NODES.map { |name, ip, _port| "#{name}=#{ip}" }
  standby_host_args = (NODES + STANDBYS).map { |name, ip, _port| "#{name}=#{ip}" } +
                      VIPS.map { |name, ip| "#{name}=#{ip}" }

  NODES.each do |name, ip, host_port|
    config.vm.define name, primary: name == "citus01" do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip
      node.vm.network "forwarded_port",
                      guest: 5432,
                      host: host_port,
                      host_ip: "127.0.0.1",
                      auto_correct: false

      node.vm.provision "shell",
                        path: "vagrant-configs/common-setup.sh",
                        args: host_args
      node.vm.provision "shell",
                        path: "vagrant-configs/citus-pg19-install.sh"
    end
  end

  STANDBYS.each do |name, ip, host_port|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip
      node.vm.network "forwarded_port",
                      guest: 5432,
                      host: host_port,
                      host_ip: "127.0.0.1",
                      auto_correct: false

      node.vm.provider "virtualbox" do |vb|
        vb.memory = 2048
        vb.cpus = 1
        vb.gui = false
      end

      node.vm.provision "shell",
                        path: "vagrant-configs/common-setup.sh",
                        args: standby_host_args,
                        env: { "BASE_ROLE" => "runtime" }
      node.vm.provision "shell",
                        path: "vagrant-configs/citus-pg19-install.sh",
                        args: ["packages"]
    end
  end
end
