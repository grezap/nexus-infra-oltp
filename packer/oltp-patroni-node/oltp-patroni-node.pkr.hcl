/*
 * oltp-patroni-node -- PostgreSQL + Patroni cluster node template (Phase 0.G.4).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 3 clones: pg-primary, pg-replica-1, pg-replica-2 (.61/.62/.63). The Patroni
 * orchestrator (PyPI patroni[etcd3]) manages the PostgreSQL 17 lifecycle +
 * elects a leader via the 3-node etcd quorum (oltp-etcd-node template,
 * envs/oltp-patroni/ state).
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as oltp-redis/mongo/pxc/proxysql)
 *   - Default RAM: 2 GB at bake time (per memory/feedback_prefer_less_memory.md;
 *     steady-state 8 GB per vms.yaml is set at clone time by terraform vmrun-resize).
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service);
 *     ethernet1 = VMnet10 (streaming replication + Patroni REST cross-calls).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC for apt fetch, then
 *     `vmx_remove_ethernet_interfaces = true` strips it. PostgreSQL 17 from
 *     the PGDG apt repo (apt.postgresql.org); Patroni from PyPI via pip
 *     (apt's patroni lags; we need 4.x for etcd3 + improved switchover).
 *     The apt-shipped postgresql.service + postgresql@17-main.service are
 *     MASKED at bake -- Patroni owns the PG lifecycle (start/stop/promote/
 *     demote/initdb-rewind) and would race with the auto-start unit. The
 *     canonical unit (nexus-patroni.service) is delivered DISABLED.
 *   - Clone-time (terraform/modules/vm): scripts/configure-vm-nic.ps1 writes
 *     ethernet0 (VMnet11) + ethernet1 (VMnet10) post-clone.
 *   - First-boot (oltp-node-firstboot.service ExecStart): MAC-OUI-byte-5
 *     NIC discovery + IP-to-hostname mapping (cluster=patroni for .61/.62/.63;
 *     writes /etc/hosts + the VMnet10 static IP + /etc/nexus-patroni/node-
 *     identity.env).
 *   - Cluster bring-up (terraform/envs/oltp-patroni/role-overlay-*.tf):
 *     nftables-backplane -> patroni-vault-agents -> patroni-tls ->
 *     etcd-bootstrap (3-member quorum + auth enable + RBAC) ->
 *     patroni-bootstrap (initdb on pg-primary + start pg-replica-{1,2} as
 *     streaming replicas) -> haproxy-config (haproxy-pg :5432 LB + health
 *     probes against Patroni REST :8008/leader).
 *
 * Build:   cd packer/oltp-patroni-node; packer init .; packer build .
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

source "vmware-iso" "oltp-patroni-node" {
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
    "annotation"           = "oltp-patroni-node template (Phase 0.G.4) -- built by Packer; PostgreSQL ${var.pg_version} (PGDG apt) + Patroni ${var.patroni_version} (PyPI pip with etcd3 extras)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "oltp-patroni-node"
  sources = ["source.vmware-iso.oltp-patroni-node"]

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
      "ansible/roles/oltp_patroni",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "oltp_node_pg_version=${var.pg_version}",
      "--extra-vars", "oltp_node_patroni_version=${var.patroni_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- oltp-patroni-node post-install checks ---'",
      "test -x /usr/lib/postgresql/${var.pg_version}/bin/postgres",
      "test -x /usr/lib/postgresql/${var.pg_version}/bin/pg_ctl",
      "test -x /usr/lib/postgresql/${var.pg_version}/bin/initdb",
      "test -x /usr/bin/psql",
      "test -x /usr/local/bin/patroni",
      "test -x /usr/local/bin/patronictl",
      "test -x /usr/local/sbin/nexus-patronictl",
      "/usr/lib/postgresql/${var.pg_version}/bin/postgres --version",
      "/usr/local/bin/patroni --version 2>&1 | head -1",
      "systemctl cat nexus-patroni.service > /dev/null",
      "systemctl cat oltp-node-firstboot.service > /dev/null",
      "systemctl is-enabled oltp-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      # apt-shipped postgresql units MUST be masked -- Patroni owns the PG
      # lifecycle (initdb / start / promote / demote). An auto-starting
      # apt unit would race + bind 5432 on a stale datadir.
      "systemctl is-enabled postgresql.service             2>&1 | grep -qE '^(masked|disabled)$' || (echo 'ERROR: postgresql.service is not masked/disabled (apt-shipped; would race Patroni)' && exit 1)",
      "systemctl is-enabled postgresql@${var.pg_version}-main.service 2>&1 | grep -qE '^(masked|disabled|static)$' || (echo 'ERROR: postgresql@${var.pg_version}-main.service is not masked/disabled/static' && exit 1)",
      # Patroni's own data dir (used as PGDATA) must exist but be empty at
      # bake time -- Patroni will initdb here on the first leader.
      "sudo test -d /var/lib/nexus-patroni/data",
      "sudo test -z \"$(sudo ls -A /var/lib/nexus-patroni/data 2>/dev/null)\" || (echo 'ERROR: /var/lib/nexus-patroni/data not empty at bake time' && exit 1)",
      "id postgres",
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
