/*
 * oltp-haproxy-node -- HAProxy LB node template (Phase 0.G.4).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 2 clones: haproxy-pg-1 (.67, keepalived MASTER candidate) + haproxy-pg-2
 * (.68, keepalived BACKUP) forming an HA pair with VRRP-floated VIP .60.
 * Both nodes run identical haproxy.cfg routing app traffic on :5432 to the
 * current Patroni leader via Patroni REST :8008/leader as the health probe
 * (HTTP 200 only on the leader; 503 on replicas + paused standbys). Stats UI
 * on :8404 with HTTP basic auth (KV-seeded password). Mirrors the 0.G.3
 * proxysql-1/2 + VIP .50 pattern; same unicast VRRP for the same reason
 * (VMware VMnet11 doesn't reliably forward IPv4 multicast 224.0.0.18 --
 * lesson from 0.G.3.5c chunk 1 transient #22).
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as siblings)
 *   - Default RAM: 1 GB at bake time; steady-state 2 GB per vms.yaml.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service); ethernet1 =
 *     VMnet10 (Patroni REST health probes against pg-* nodes ride the
 *     backplane for cleaner latency observability).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC; HAProxy 3.0 (LTS) from
 *     haproxy.debian.net (the project-maintained Debian backport repo
 *     providing newer LTS than Debian trixie's apt main). The apt-shipped
 *     haproxy.service is MASKED; we deliver nexus-haproxy.service DISABLED.
 *   - First-boot: cluster=haproxy for .67/.68; writes /etc/nexus-haproxy/
 *     node-identity.env.
 *   - Cluster bring-up (terraform/envs/oltp-patroni/role-overlay-*.tf):
 *     after etcd + Patroni are up, haproxy-config renders /etc/nexus-
 *     haproxy/haproxy.cfg + starts nexus-haproxy.service on BOTH nodes;
 *     then haproxy-keepalived renders /etc/keepalived/keepalived.conf
 *     (per-host priority + unicast peer) + starts keepalived; VIP .60
 *     binds on the MASTER (haproxy-pg-1, priority 110).
 *
 * Build:   cd packer/oltp-haproxy-node; packer init .; packer build .
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

source "vmware-iso" "oltp-haproxy-node" {
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
    "annotation"           = "oltp-haproxy-node template (Phase 0.G.4) -- built by Packer; HAProxy ${var.haproxy_version} (haproxy.debian.net backport)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "oltp-haproxy-node"
  sources = ["source.vmware-iso.oltp-haproxy-node"]

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
      "ansible/roles/oltp_haproxy",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "oltp_node_haproxy_version=${var.haproxy_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- oltp-haproxy-node post-install checks ---'",
      "test -x /usr/sbin/haproxy",
      "test -x /usr/sbin/keepalived",
      "/usr/sbin/haproxy -v | head -1",
      "/usr/sbin/keepalived --version 2>&1 | head -1",
      "systemctl cat nexus-haproxy.service > /dev/null",
      "systemctl cat oltp-node-firstboot.service > /dev/null",
      "systemctl is-enabled oltp-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      # apt-shipped haproxy.service MUST be masked -- it auto-starts against
      # /etc/haproxy/haproxy.cfg (which we don't render); our canonical
      # service points at /etc/nexus-haproxy/haproxy.cfg.
      "systemctl is-enabled haproxy.service 2>&1 | grep -qE '^(masked|disabled)$' || (echo 'ERROR: haproxy.service is not masked/disabled' && exit 1)",
      # apt-shipped keepalived.service must be disabled (not masked) -- the
      # terraform haproxy-keepalived overlay enables it after rendering
      # /etc/keepalived/keepalived.conf with per-host MASTER/BACKUP config.
      "systemctl is-enabled keepalived.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: keepalived.service is not disabled at bake' && exit 1)",
      "id haproxy",
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
