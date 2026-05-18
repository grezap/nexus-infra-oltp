# nexus-infra-oltp / terraform / envs / oltp-redis / main.tf
#
# Per-cluster Terraform state for the Redis Cluster (6 nodes: 3 masters +
# 3 replicas at .81-.84/.87/.89). Phase 0.G.3.5b refactor split from the
# monolithic envs/oltp/ per memory/feedback_per_cluster_state_per_engine_
# template.md.
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env applied (dnsmasq dhcp-host
#      reservations for the 6 redis MACs).
#   2. nexus-infra-vmware security env applied (per-host AppRole sidecars
#      at $HOME\.nexus\vault-agent-oltp-redis-redis-N.json).
#   3. Packer template built: H:\VMS\NexusPlatform\_templates\oltp-redis-node\
#      oltp-redis-node.vmx (Phase 0.G.3.5a).
#
# Apply order within this env:
#   module.redis_{1..6}  (clone + power on; firstboot runs inside)
#   -> null_resource.redis_nftables_backplane
#   -> null_resource.redis_vault_agent (for_each)
#   -> null_resource.redis_tls (for_each)
#   -> null_resource.redis_config (for_each)
#   -> null_resource.redis_cluster_create (one-shot exit gate)
#
# Wall-clock: ~10-15 min cold apply (most of it per-node SSH polling).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Redis Cluster module.vm blocks (6 nodes) ─────────────────────────────
# Per nexus-platform-plan/docs/infra/vms.yaml (cluster: redis, phase: 0.G).
# Dual-NIC: VMnet11 service (DHCP via nexus-gateway dnsmasq dhcp-host
# reservations -> .81-.84/.87/.89) + VMnet10 cluster backplane (static
# per-hostname IP set by oltp-node-firstboot.sh).

module "redis_1" {
  source = "../../modules/vm"
  count  = var.enable_redis_1 ? 1 : 0

  vm_name           = "redis-1"
  template_vmx_path = "${var.template_root}/oltp-redis-node/oltp-redis-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_1_secondary
}

module "redis_2" {
  source = "../../modules/vm"
  count  = var.enable_redis_2 ? 1 : 0

  vm_name           = "redis-2"
  template_vmx_path = "${var.template_root}/oltp-redis-node/oltp-redis-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_2_secondary
}

module "redis_3" {
  source = "../../modules/vm"
  count  = var.enable_redis_3 ? 1 : 0

  vm_name           = "redis-3"
  template_vmx_path = "${var.template_root}/oltp-redis-node/oltp-redis-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_3_secondary
}

module "redis_4" {
  source = "../../modules/vm"
  count  = var.enable_redis_4 ? 1 : 0

  vm_name           = "redis-4"
  template_vmx_path = "${var.template_root}/oltp-redis-node/oltp-redis-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-4"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_4_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_4_secondary
}

module "redis_5" {
  source = "../../modules/vm"
  count  = var.enable_redis_5 ? 1 : 0

  vm_name           = "redis-5"
  template_vmx_path = "${var.template_root}/oltp-redis-node/oltp-redis-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-5"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_5_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_5_secondary
}

module "redis_6" {
  source = "../../modules/vm"
  count  = var.enable_redis_6 ? 1 : 0

  vm_name           = "redis-6"
  template_vmx_path = "${var.template_root}/oltp-redis-node/oltp-redis-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/redis-6"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_redis_6_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_redis_6_secondary
}
