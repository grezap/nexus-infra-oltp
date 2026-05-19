# nexus-infra-oltp / terraform / envs / oltp-patroni / main.tf
#
# Per-cluster Terraform state for the Patroni PostgreSQL HA + etcd DCS +
# HAProxy HA pair stack (Phase 0.G.4):
#   - 3 Patroni nodes (pg-primary/pg-replica-1/pg-replica-2) at .61-.63
#   - 3 etcd nodes (etcd-1/2/3) at .64-.66
#   - 2 HAProxy nodes (haproxy-pg-1/-2) at .67-.68
#   - VRRP-floated VIP `var.haproxy_vip` (default .60) between the haproxy pair
#
# HAProxy HA pair mirrors the 0.G.3 proxysql-1/2 + VIP .50 pattern (unicast
# VRRP because VMware VMnet11 doesn't reliably forward IPv4 multicast --
# lesson baked at 0.G.3.5c chunk 1 transient #22).
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env (gateway dhcp-host reservations
#      for the 8 patroni-tier MACs at .61-.68; v5 marker).
#   2. nexus-infra-vmware security env (PKI role patroni-server + 8
#      AppRoles + 5 KV sticky-seeds + 8 sidecars at $HOME\.nexus\
#      vault-agent-oltp-patroni-<host>.json).
#   3. Packer templates built:
#        H:\VMS\NexusPlatform\_templates\oltp-patroni-node\oltp-patroni-node.vmx
#        H:\VMS\NexusPlatform\_templates\oltp-etcd-node\oltp-etcd-node.vmx
#        H:\VMS\NexusPlatform\_templates\oltp-haproxy-node\oltp-haproxy-node.vmx
#
# Apply order within this env:
#   module.pg_* + module.etcd_* + module.haproxy_pg_{1,2}  (8 parallel clones)
#   -> null_resource.patroni_nftables_backplane
#   -> null_resource.patroni_vault_agent (for_each, 8 hosts)
#   -> null_resource.patroni_tls (for_each, 8 hosts; haproxy nodes carry the
#      VIP in their cert IP-SANs)
#   -> null_resource.etcd_bootstrap (one-shot: render etcd.conf.yml on the 3
#      etcd nodes + start nexus-etcd.service in parallel + wait for leader +
#      `etcdctl auth enable` for RBAC)
#   -> null_resource.patroni_bootstrap (one-shot: render patroni.yml on the
#      3 Patroni nodes + start nexus-patroni.service in parallel + wait for
#      one PRIMARY + 2 SECONDARY + `psql` round-trip)
#   -> null_resource.haproxy_config (for_each: render haproxy.cfg on BOTH
#      haproxy nodes + start nexus-haproxy.service)
#   -> null_resource.haproxy_keepalived (one-shot: render keepalived.conf
#      on both haproxy nodes -- haproxy-pg-1 priority 110 MASTER candidate,
#      haproxy-pg-2 priority 100 BACKUP -- start keepalived + verify VIP
#      bound on exactly one node)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Patroni module.vm blocks (3 PostgreSQL nodes) ────────────────────────

module "pg_primary" {
  source = "../../modules/vm"
  count  = var.enable_pg_primary ? 1 : 0

  vm_name           = "pg-primary"
  template_vmx_path = "${var.template_root}/oltp-patroni-node/oltp-patroni-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pg-primary"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pg_primary_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pg_primary_secondary
}

module "pg_replica_1" {
  source = "../../modules/vm"
  count  = var.enable_pg_replica_1 ? 1 : 0

  vm_name           = "pg-replica-1"
  template_vmx_path = "${var.template_root}/oltp-patroni-node/oltp-patroni-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pg-replica-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pg_replica_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pg_replica_1_secondary
}

module "pg_replica_2" {
  source = "../../modules/vm"
  count  = var.enable_pg_replica_2 ? 1 : 0

  vm_name           = "pg-replica-2"
  template_vmx_path = "${var.template_root}/oltp-patroni-node/oltp-patroni-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/pg-replica-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_pg_replica_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_pg_replica_2_secondary
}

# ─── etcd module.vm blocks (3 raft quorum members) ────────────────────────

module "etcd_1" {
  source = "../../modules/vm"
  count  = var.enable_etcd_1 ? 1 : 0

  vm_name           = "etcd-1"
  template_vmx_path = "${var.template_root}/oltp-etcd-node/oltp-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/etcd-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_etcd_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_etcd_1_secondary
}

module "etcd_2" {
  source = "../../modules/vm"
  count  = var.enable_etcd_2 ? 1 : 0

  vm_name           = "etcd-2"
  template_vmx_path = "${var.template_root}/oltp-etcd-node/oltp-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/etcd-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_etcd_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_etcd_2_secondary
}

module "etcd_3" {
  source = "../../modules/vm"
  count  = var.enable_etcd_3 ? 1 : 0

  vm_name           = "etcd-3"
  template_vmx_path = "${var.template_root}/oltp-etcd-node/oltp-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/etcd-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_etcd_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_etcd_3_secondary
}

# ─── HAProxy HA pair module.vm blocks (2 LB nodes) ────────────────────────

module "haproxy_pg_1" {
  source = "../../modules/vm"
  count  = var.enable_haproxy_pg_1 ? 1 : 0

  vm_name           = "haproxy-pg-1"
  template_vmx_path = "${var.template_root}/oltp-haproxy-node/oltp-haproxy-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/haproxy-pg-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_haproxy_pg_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_haproxy_pg_1_secondary
}

module "haproxy_pg_2" {
  source = "../../modules/vm"
  count  = var.enable_haproxy_pg_2 ? 1 : 0

  vm_name           = "haproxy-pg-2"
  template_vmx_path = "${var.template_root}/oltp-haproxy-node/oltp-haproxy-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/haproxy-pg-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_haproxy_pg_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_haproxy_pg_2_secondary
}
