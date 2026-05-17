# nexus-infra-oltp / terraform / envs / oltp / main.tf
#
# OLTP data tier env -- Phase 0.G of nexus-platform-plan. Composes one `module.vm`
# block per cluster node + per-cluster role overlays. Body populates as each
# sub-phase ships (Redis 0.G.1, Mongo 0.G.2, Percona 0.G.3, Patroni 0.G.4, SQL
# FCI/AG 0.G.7).
#
# Cross-env prerequisite (hard): nexus-infra-vmware's security env MUST have
# written the per-node AppRole sidecars to $HOME\.nexus\vault-agent-oltp-<host>.json
# BEFORE plan time; this env reads them via filesha256() in the
# role-overlay-*-vault-agents.tf overlays.
#
# Provider, modules, and per-cluster module blocks land per sub-phase. This
# scaffold-only state intentionally has no resources -- `terraform plan` against
# this file returns "No changes" until the first cluster is wired up.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# Provider note: modules/vm drives vmrun.exe directly via local-exec on
# null_resource (same pattern as nexus-infra-kafka envs/kafka). No
# vmware-desktop / hashicorp-local providers needed at this layer.

# ─── Phase 0.G.1 — Redis Cluster (6 nodes: 3 masters + 3 replicas) ────────
# Per nexus-platform-plan/docs/infra/vms.yaml (cluster: redis, phase: 0.G).
# Dual-NIC: VMnet11 service (DHCP via nexus-gateway dnsmasq dhcp-host
# reservations -> .81-.84/.87/.89 owned by nexus-infra-vmware foundation) +
# VMnet10 cluster backplane (static per-hostname IP set by
# oltp-node-firstboot.sh; Redis Cluster bus runs on the backplane).

module "redis_1" {
  source = "../../modules/vm"
  count  = var.enable_redis && var.enable_redis_1 ? 1 : 0

  vm_name           = "redis-1"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_1_secondary
}

module "redis_2" {
  source = "../../modules/vm"
  count  = var.enable_redis && var.enable_redis_2 ? 1 : 0

  vm_name           = "redis-2"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_2_secondary
}

module "redis_3" {
  source = "../../modules/vm"
  count  = var.enable_redis && var.enable_redis_3 ? 1 : 0

  vm_name           = "redis-3"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_3_secondary
}

module "redis_4" {
  source = "../../modules/vm"
  count  = var.enable_redis && var.enable_redis_4 ? 1 : 0

  vm_name           = "redis-4"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-4"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_4_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_4_secondary
}

module "redis_5" {
  source = "../../modules/vm"
  count  = var.enable_redis && var.enable_redis_5 ? 1 : 0

  vm_name           = "redis-5"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-5"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_5_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_5_secondary
}

module "redis_6" {
  source = "../../modules/vm"
  count  = var.enable_redis && var.enable_redis_6 ? 1 : 0

  vm_name           = "redis-6"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-6"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_6_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_6_secondary
}

# ─── Phase 0.G.2 — MongoDB Replica Set (3 nodes: PRIMARY + 2 SECONDARY) ──
# Per nexus-platform-plan/docs/infra/vms.yaml (cluster: mongo, phase: 0.G).
# Dual-NIC: VMnet11 service (DHCP via nexus-gateway dnsmasq dhcp-host
# reservations → .71/.72/.73 owned by nexus-infra-vmware foundation env
# v2 marker) + VMnet10 cluster backplane (static per-hostname IP set by
# oltp-node-firstboot.sh; reserved for future cross-RS replication if
# needed).

module "mongo_1" {
  source = "../../modules/vm"
  count  = var.enable_mongo && var.enable_mongo_1 ? 1 : 0

  vm_name           = "mongo-1"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mongo_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mongo_1_secondary
}

module "mongo_2" {
  source = "../../modules/vm"
  count  = var.enable_mongo && var.enable_mongo_2 ? 1 : 0

  vm_name           = "mongo-2"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mongo_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mongo_2_secondary
}

module "mongo_3" {
  source = "../../modules/vm"
  count  = var.enable_mongo && var.enable_mongo_3 ? 1 : 0

  vm_name           = "mongo-3"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mongo_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mongo_3_secondary
}

# ─── Phase 0.G.3 — Percona XtraDB Cluster + ProxySQL (5 nodes) ───────────
# 3 PXC (Galera-replicated MySQL data plane) + 2 ProxySQL (connection pool
# + LB with VRRP-floated VIP 192.168.70.50). Per nexus-platform-plan/docs/
# infra/vms.yaml (cluster: percona, phase: 0.G).
# Dual-NIC: VMnet11 service (DHCP via nexus-gateway dnsmasq dhcp-host
# reservations → .51-.55 owned by nexus-infra-vmware foundation env v3
# marker) + VMnet10 cluster backplane (static per-hostname IP set by
# oltp-node-firstboot.sh; Galera SST/IST replication runs on the
# backplane to keep multi-GB SST traffic off the service NIC).

module "pxc_node_1" {
  source = "../../modules/vm"
  count  = var.enable_percona && var.enable_pxc_node_1 ? 1 : 0

  vm_name           = "pxc-node-1"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pxc-node-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pxc_node_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pxc_node_1_secondary
}

module "pxc_node_2" {
  source = "../../modules/vm"
  count  = var.enable_percona && var.enable_pxc_node_2 ? 1 : 0

  vm_name           = "pxc-node-2"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pxc-node-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pxc_node_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pxc_node_2_secondary
}

module "pxc_node_3" {
  source = "../../modules/vm"
  count  = var.enable_percona && var.enable_pxc_node_3 ? 1 : 0

  vm_name           = "pxc-node-3"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pxc-node-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pxc_node_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pxc_node_3_secondary
}

module "proxysql_1" {
  source = "../../modules/vm"
  count  = var.enable_percona && var.enable_proxysql_1 ? 1 : 0

  vm_name           = "proxysql-1"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/proxysql-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_proxysql_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_proxysql_1_secondary
}

module "proxysql_2" {
  source = "../../modules/vm"
  count  = var.enable_percona && var.enable_proxysql_2 ? 1 : 0

  vm_name           = "proxysql-2"
  template_vmx_path = "${var.template_root}/oltp-node/oltp-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/proxysql-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_proxysql_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_proxysql_2_secondary
}
