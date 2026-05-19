/*
 * oltp-etcd-node -- etcd cluster node template (Phase 0.G.4).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 3 clones: etcd-1, etcd-2, etcd-3 (.64/.65/.66). The etcd raft quorum
 * provides Patroni's distributed configuration store (DCS) for leader
 * election, cluster state, and configuration distribution.
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as siblings)
 *   - Default RAM: 1 GB at bake time (etcd is memory-light); steady-state 2 GB
 *     per vms.yaml is set at clone time by terraform vmrun-resize.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service);
 *     ethernet1 = VMnet10 (etcd peer raft 2380 + client API 2379 cross-mesh).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC for apt fetch. etcd binary
 *     downloaded from upstream GitHub releases (apt's etcd is too old --
 *     stuck at 3.4.x; we need 3.5+ for the gRPC v3 API Patroni 4 prefers).
 *     Binaries installed at /usr/local/bin/etcd + /usr/local/bin/etcdctl.
 *     The canonical unit (nexus-etcd.service) is delivered DISABLED.
 *   - Clone-time (terraform/modules/vm): writes ethernet0 + ethernet1 MAC.
 *   - First-boot (oltp-node-firstboot.service ExecStart): standard MAC OUI
 *     pattern; cluster=etcd for .64/.65/.66; writes /etc/nexus-etcd/node-
 *     identity.env.
 *   - Cluster bring-up (terraform/envs/oltp-patroni/role-overlay-*.tf):
 *     nftables-backplane -> patroni-vault-agents (etcd nodes get the same
 *     Vault Agent) -> patroni-tls -> etcd-bootstrap (renders etcd.conf
 *     with the 3-member initial-cluster string + starts nexus-etcd.service
 *     in parallel across all 3 -> waits for leader -> `etcdctl auth enable`
 *     for RBAC). Then patroni-bootstrap runs (which dials etcd for DCS).
 *
 * Build:   cd packer/oltp-etcd-node; packer init .; packer build .
 * See:     docs/handbook.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

source "vmware-iso" "oltp-etcd-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20"

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "oltp-etcd-node template (Phase 0.G.4) -- built by Packer; etcd ${var.etcd_version} (upstream GitHub release; static binary at /usr/local/bin/etcd)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "oltp-etcd-node"
  sources = ["source.vmware-iso.oltp-etcd-node"]

  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/oltp_firstboot",
      "ansible/roles/oltp_etcd",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "oltp_node_etcd_version=${var.etcd_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- oltp-etcd-node post-install checks ---'",
      "test -x /usr/local/bin/etcd",
      "test -x /usr/local/bin/etcdctl",
      "test -x /usr/local/bin/etcdutl",
      "test -x /usr/local/sbin/nexus-etcdctl",
      "/usr/local/bin/etcd --version | head -1",
      "/usr/local/bin/etcdctl version | head -1",
      "systemctl cat nexus-etcd.service > /dev/null",
      "systemctl cat oltp-node-firstboot.service > /dev/null",
      "systemctl is-enabled oltp-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "sudo test -d /var/lib/nexus-etcd",
      "id etcd",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
