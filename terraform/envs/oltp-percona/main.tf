# nexus-infra-oltp / terraform / envs / oltp-percona / main.tf
#
# Per-cluster Terraform state for the Percona XtraDB Cluster + ProxySQL
# stack: 3 PXC nodes (pxc-node-1/2/3 at .51-.53) + 2 ProxySQL nodes
# (proxysql-1/2 at .54-.55) + VRRP-floated VIP at .50.
# Phase 0.G.3.5b refactor split from the monolithic envs/oltp/.
#
# Carries forward ALL 16 transient fixes from 0.G.3 ratification (per
# memory/feedback_per_cluster_state_per_engine_template.md). The per-cluster
# scope means iteration loop drops from 30 min (full 14-VM tree apply) to
# 5-10 min (just the 5 percona VMs).
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env (gateway dhcp-host reservations
#      for the 5 percona-tier MACs at .51-.55).
#   2. nexus-infra-vmware security env (PKI role percona-server + 5
#      AppRoles + 4 KV sticky-seeds + 5 sidecars at $HOME\.nexus\
#      vault-agent-oltp-percona-<host>.json).
#   3. Packer templates built:
#        H:\VMS\NexusPlatform\_templates\oltp-pxc-node\oltp-pxc-node.vmx
#        H:\VMS\NexusPlatform\_templates\oltp-proxysql-node\oltp-proxysql-node.vmx
#
# Apply order within this env:
#   module.pxc_node_{1..3} + module.proxysql_{1,2}  (parallel clones)
#   -> null_resource.percona_nftables_backplane
#   -> null_resource.percona_vault_agent (for_each, 5 hosts)
#   -> null_resource.percona_tls (for_each, 5 hosts)
#   -> null_resource.percona_config (for_each, 3 PXC -- ProxySQL has no my.cnf)
#   -> null_resource.percona_galera_bootstrap (one-shot; bootstraps node-1
#      + creates wsrep_sst/clustercheck/smoke-rw users + starts joiners +
#      rolling-restarts node-1 from bootstrap.service to nexus-percona.service
#      per the v3 ordering fix from 0.G.3 ratification transient #15)
#   -> null_resource.proxysql_config (for_each, 2 hosts)
#   -> null_resource.proxysql_keepalived (for_each, 2 hosts -- VIP .50)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── PXC module.vm blocks (3 Galera nodes) ────────────────────────────────

module "pxc_node_1" {
  source = "../../modules/vm"
  count  = var.enable_pxc_node_1 ? 1 : 0

  vm_name           = "pxc-node-1"
  template_vmx_path = "${var.template_root}/oltp-pxc-node/oltp-pxc-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pxc-node-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pxc_node_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pxc_node_1_secondary
}

module "pxc_node_2" {
  source = "../../modules/vm"
  count  = var.enable_pxc_node_2 ? 1 : 0

  vm_name           = "pxc-node-2"
  template_vmx_path = "${var.template_root}/oltp-pxc-node/oltp-pxc-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pxc-node-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pxc_node_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pxc_node_2_secondary
}

module "pxc_node_3" {
  source = "../../modules/vm"
  count  = var.enable_pxc_node_3 ? 1 : 0

  vm_name           = "pxc-node-3"
  template_vmx_path = "${var.template_root}/oltp-pxc-node/oltp-pxc-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pxc-node-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pxc_node_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pxc_node_3_secondary
}

# ─── ProxySQL module.vm blocks (2 LB nodes) ───────────────────────────────

module "proxysql_1" {
  source = "../../modules/vm"
  count  = var.enable_proxysql_1 ? 1 : 0

  vm_name           = "proxysql-1"
  template_vmx_path = "${var.template_root}/oltp-proxysql-node/oltp-proxysql-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/proxysql-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_proxysql_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_proxysql_1_secondary
}

module "proxysql_2" {
  source = "../../modules/vm"
  count  = var.enable_proxysql_2 ? 1 : 0

  vm_name           = "proxysql-2"
  template_vmx_path = "${var.template_root}/oltp-proxysql-node/oltp-proxysql-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/proxysql-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_proxysql_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_proxysql_2_secondary
}
