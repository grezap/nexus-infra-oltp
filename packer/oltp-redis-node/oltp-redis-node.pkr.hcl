/*
 * oltp-redis-node -- NexusPlatform Redis Cluster node template (Phase 0.G.3.5+)
 *
 * Per-engine template per the 0.G.3.5 refactor (memory/feedback_per_cluster_
 * state_per_engine_template.md). Installs ONLY Redis -- mongo / pxc /
 * proxysql each get their own sibling template (oltp-mongo-node.vmx /
 * oltp-pxc-node.vmx / oltp-proxysql-node.vmx). Replaces the monolithic
 * oltp-node.vmx that bundled all engines together.
 *
 * Six instances of this template clone into the 05-oltp tier per
 * nexus-platform-plan/docs/infra/vms.yaml:
 *
 *   - 0.G.1: redis-1..6 (Redis Cluster, 3 masters + 3 replicas at .81-.84/.87/.89)
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as kafka-node + vault + deb13)
 *   - Default RAM: 2 GB (per memory/feedback_prefer_less_memory.md);
 *     per-cluster overrides via Terraform vmrun-resize at clone time.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service); ethernet1 =
 *     VMnet10 (cluster backplane -- reserved for future cluster-announce-
 *     bus-ip use; in 0.G.1 cluster bus runs on VMnet11).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time: single NAT NIC for apt fetch, then
 *     `vmx_remove_ethernet_interfaces = true` strips it. Apt-installed
 *     Redis (Debian apt main, 7.4.x or later). The apt-shipped
 *     redis-server.service is DISABLED + MASKED at bake; the canonical
 *     nexus-redis.service is delivered DISABLED. Template footprint ~2 GB
 *     (vs 6 GB monolithic).
 *   - Clone-time (terraform/modules/vm): scripts/configure-vm-nic.ps1
 *     writes ethernet0 (VMnet11) + ethernet1 (VMnet10) post-clone.
 *   - First-boot (oltp-node-firstboot.service ExecStart): MAC-OUI-byte-5
 *     NIC discovery (same pattern as kafka-node-firstboot.sh); maps the
 *     VMnet11 IP to canonical hostname + VMnet10 backplane IP + role
 *     (always 'redis' in this template) + cluster (always 'redis');
 *     writes /etc/hosts + the VMnet10 static IP; writes
 *     /etc/nexus-redis/node-identity.env for the Terraform overlays.
 *   - Cluster bring-up (terraform/envs/oltp-redis/role-overlay-*.tf):
 *     nftables-backplane -> redis-vault-agents -> redis-tls -> redis-
 *     config -> redis-cluster-create (one-shot exit gate).
 *
 * Build:   cd packer/oltp-redis-node; packer init .; packer build .
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

# ─── Source: Debian 13 netinst, VMware Workstation builder ────────────────
source "vmware-iso" "oltp-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64" # Workstation catalog lags; compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Single NAT NIC at build time -- Terraform's modules/vm attaches the real
  # dual-NIC config (VMnet11 + VMnet10) at clone time.
  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20" # WS 17+ hw version

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

  # Strip all ethernet*.* lines so Terraform's modules/vm can write the
  # dual-NIC config cleanly post-clone.
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "oltp-redis-node template (Phase 0.G.3.5+) -- built by Packer; Redis ${var.redis_version} (Debian apt main)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + Redis + apply shared roles + oltp_redis ─────────
build {
  name    = "oltp-node"
  sources = ["source.vmware-iso.oltp-node"]

  # Stage static config files the shared roles + oltp_redis role expect.
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

  # Apply the shared nexus_* roles + oltp_redis. Per-engine template:
  # ONLY oltp_redis here; mongo/pxc/proxysql each ship in sibling templates.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/oltp_firstboot",
      "ansible/roles/oltp_redis",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "oltp_node_redis_version=${var.redis_version}",
    ]
  }

  # Final sanity + cleanup.
  # Service-state checks only -- the Redis data dir is 0750 owned by the
  # redis user; nexusadmin can't traverse.
  provisioner "shell" {
    inline = [
      "echo '--- oltp-redis-node post-install checks ---'",
      "test -x /usr/bin/redis-server",
      "test -x /usr/bin/redis-cli",
      "redis-server --version",
      "redis-cli --version",
      # nexus-redis.service is INTENTIONALLY DISABLED at template time --
      # the template has no per-host identity yet. firstboot writes the
      # identity env file; Terraform role-overlay-redis-config.tf renders
      # redis.conf + enables the service per-host. `systemctl cat` exits 0
      # if the unit file exists in any lookup path regardless of state.
      "systemctl cat nexus-redis.service > /dev/null",
      "systemctl cat oltp-node-firstboot.service > /dev/null",
      "systemctl is-enabled oltp-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      # apt-shipped redis-server.service MUST be disabled + masked so a cold
      # boot does not race nexus-redis.service for port 6379. is-enabled on
      # a masked unit emits 'masked' to stdout AND exits non-zero (rc=1),
      # so we grep for 'masked' against the OR'd combined output.
      "systemctl is-enabled redis-server.service 2>&1 | grep -qE '^(masked|disabled)$' || (echo 'ERROR: redis-server.service is not masked/disabled' && exit 1)",
      "id redis",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*", # regenerated on first boot
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
