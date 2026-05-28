# nexus-infra-oltp / terraform / envs / oltp-mongo-sharded / main.tf
#
# Phase 0.N -- MongoDB sharded cluster (separate from the 0.G.2 RS).
# Topology (ADR-0040):
#   3 config-server RS members (named "config")          -> .74/.75/.76 (port 27019)
#   2 shard RSes x 3 members each (named "shard-1" / "shard-2")
#     shard-1: .77/.78/.79                                                  (port 27018)
#     shard-2: .80/.56/.57                                                  (port 27018)
#   2 mongos query routers (stateless; round-robin DNS)  -> .58/.59 (port 27017)
#
# Reuses the oltp-mongo-node Packer template (extended in Phase 0.N to include
# mongodb-org-mongos). Auth: shared keyFile across the entire sharded cluster
# (sourced from Vault KV at nexus/oltp/mongo/keyfile -- same as 0.G.2 RS for
# operational simplicity; the 0.N.1 enhancement adds a dedicated sharded
# keyFile + mTLS per-host certs).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Config-server RS members ────────────────────────────────────────────
module "mongo_cfg_1" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_cfg_1 ? 1 : 0
  vm_name           = "mongo-cfg-1"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-cfg-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_cfg_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_cfg_1_secondary
}
module "mongo_cfg_2" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_cfg_2 ? 1 : 0
  vm_name           = "mongo-cfg-2"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-cfg-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_cfg_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_cfg_2_secondary
}
module "mongo_cfg_3" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_cfg_3 ? 1 : 0
  vm_name           = "mongo-cfg-3"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-cfg-3"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_cfg_3_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_cfg_3_secondary
}

# ─── Shard-1 RS members ──────────────────────────────────────────────────
module "mongo_shard_1_1" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_shard_1_1 ? 1 : 0
  vm_name           = "mongo-shard-1-1"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-shard-1-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_shard_1_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_shard_1_1_secondary
}
module "mongo_shard_1_2" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_shard_1_2 ? 1 : 0
  vm_name           = "mongo-shard-1-2"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-shard-1-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_shard_1_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_shard_1_2_secondary
}
module "mongo_shard_1_3" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_shard_1_3 ? 1 : 0
  vm_name           = "mongo-shard-1-3"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-shard-1-3"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_shard_1_3_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_shard_1_3_secondary
}

# ─── Shard-2 RS members ──────────────────────────────────────────────────
module "mongo_shard_2_1" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_shard_2_1 ? 1 : 0
  vm_name           = "mongo-shard-2-1"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-shard-2-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_shard_2_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_shard_2_1_secondary
}
module "mongo_shard_2_2" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_shard_2_2 ? 1 : 0
  vm_name           = "mongo-shard-2-2"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-shard-2-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_shard_2_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_shard_2_2_secondary
}
module "mongo_shard_2_3" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_shard_2_3 ? 1 : 0
  vm_name           = "mongo-shard-2-3"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-shard-2-3"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_shard_2_3_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_shard_2_3_secondary
}

# ─── mongos query routers ────────────────────────────────────────────────
module "mongo_mongos_1" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_mongos_1 ? 1 : 0
  vm_name           = "mongo-mongos-1"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-mongos-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_mongos_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_mongos_1_secondary
}
module "mongo_mongos_2" {
  source            = "../../modules/vm"
  count             = var.enable_mongo_mongos_2 ? 1 : 0
  vm_name           = "mongo-mongos-2"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-mongos-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_mongo_mongos_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_mongo_mongos_2_secondary
}

# ─── Cluster topology metadata (used by overlays) ────────────────────────
locals {
  # All cluster nodes: hostname -> {role, vmnet11, vmnet10, port, rs_name}
  # role: "configsvr" | "shardsvr" | "mongos"
  # rs_name: "config" | "shard-1" | "shard-2" | "" (mongos)
  sharded_nodes = {
    "mongo-cfg-1"     = { role = "configsvr", vmnet11 = "192.168.70.74", vmnet10 = "192.168.10.74", port = 27019, rs_name = "config" }
    "mongo-cfg-2"     = { role = "configsvr", vmnet11 = "192.168.70.75", vmnet10 = "192.168.10.75", port = 27019, rs_name = "config" }
    "mongo-cfg-3"     = { role = "configsvr", vmnet11 = "192.168.70.76", vmnet10 = "192.168.10.76", port = 27019, rs_name = "config" }
    "mongo-shard-1-1" = { role = "shardsvr", vmnet11 = "192.168.70.77", vmnet10 = "192.168.10.77", port = 27018, rs_name = "shard-1" }
    "mongo-shard-1-2" = { role = "shardsvr", vmnet11 = "192.168.70.78", vmnet10 = "192.168.10.78", port = 27018, rs_name = "shard-1" }
    "mongo-shard-1-3" = { role = "shardsvr", vmnet11 = "192.168.70.79", vmnet10 = "192.168.10.79", port = 27018, rs_name = "shard-1" }
    "mongo-shard-2-1" = { role = "shardsvr", vmnet11 = "192.168.70.80", vmnet10 = "192.168.10.80", port = 27018, rs_name = "shard-2" }
    "mongo-shard-2-2" = { role = "shardsvr", vmnet11 = "192.168.70.56", vmnet10 = "192.168.10.56", port = 27018, rs_name = "shard-2" }
    "mongo-shard-2-3" = { role = "shardsvr", vmnet11 = "192.168.70.57", vmnet10 = "192.168.10.57", port = 27018, rs_name = "shard-2" }
    "mongo-mongos-1"  = { role = "mongos", vmnet11 = "192.168.70.58", vmnet10 = "192.168.10.58", port = 27017, rs_name = "" }
    "mongo-mongos-2"  = { role = "mongos", vmnet11 = "192.168.70.59", vmnet10 = "192.168.10.59", port = 27017, rs_name = "" }
  }

  # Per-host enabled gate (mirrors the 11 module.* count gates).
  sharded_host_enabled = {
    "mongo-cfg-1"     = var.enable_mongo_cfg_1
    "mongo-cfg-2"     = var.enable_mongo_cfg_2
    "mongo-cfg-3"     = var.enable_mongo_cfg_3
    "mongo-shard-1-1" = var.enable_mongo_shard_1_1
    "mongo-shard-1-2" = var.enable_mongo_shard_1_2
    "mongo-shard-1-3" = var.enable_mongo_shard_1_3
    "mongo-shard-2-1" = var.enable_mongo_shard_2_1
    "mongo-shard-2-2" = var.enable_mongo_shard_2_2
    "mongo-shard-2-3" = var.enable_mongo_shard_2_3
    "mongo-mongos-1"  = var.enable_mongo_mongos_1
    "mongo-mongos-2"  = var.enable_mongo_mongos_2
  }

  sharded_nodes_active = {
    for host, spec in local.sharded_nodes : host => spec
    if local.sharded_host_enabled[host]
  }

  # Filtered by role for per-overlay use.
  config_nodes = {
    for host, spec in local.sharded_nodes_active : host => spec
    if spec.role == "configsvr"
  }
  shard_1_nodes = {
    for host, spec in local.sharded_nodes_active : host => spec
    if spec.rs_name == "shard-1"
  }
  shard_2_nodes = {
    for host, spec in local.sharded_nodes_active : host => spec
    if spec.rs_name == "shard-2"
  }
  mongos_nodes = {
    for host, spec in local.sharded_nodes_active : host => spec
    if spec.role == "mongos"
  }

  # configDB connection string used by mongos: "config/cfg-1:27019,cfg-2:27019,cfg-3:27019"
  config_db_uri = format(
    "config/%s",
    join(",", [
      for host, spec in local.config_nodes : "${spec.vmnet11}:${spec.port}"
    ])
  )
}
