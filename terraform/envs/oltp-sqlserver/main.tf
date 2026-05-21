# nexus-infra-oltp / terraform / envs / oltp-sqlserver / main.tf
#
# Per-cluster Terraform state for SQL Server FCI + Always On AG (Phase 0.G.7):
#   - 2 FCI nodes (sql-fci-1/2) at .11/.12  -- WSFC FCI pair sharing iSCSI LUN
#   - 2 AG replica nodes (sql-ag-rep-1/2) at .13/.14 -- async AG secondaries
#   - 3 WSFC-managed VIPs (NOT terraform-managed): cluster .15, FCI .16,
#     Listener .17. Floating via WSFC role-migration semantics; client TLS
#     handshakes validate via cert IP-SAN (per ADR-0025 the AG Listener IS the
#     LB-tier HA primitive; cert IP-SAN is the canonical wire-validation for
#     floating VIPs).
#
# Architecture: hybrid FCI + AG (canon per vms.yaml, sealed 2026-05-20 -- see
# memory/project_nexus_infra_oltp_0g7_phase.md). sql-fci-1/2 form a 2-node FCI
# sharing an iSCSI LUN from nexus-gateway; sql-ag-rep-1/2 hold async AG
# replicas of the user databases. WSFC quorum spans all 4 nodes (node-majority,
# tolerates 1 failure).
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env v6 (gateway dhcp-host reservations
#      for the 4 sqlserver MACs at .11-.14 + iSCSI target on .70.1).
#   2. nexus-infra-vmware security env (PKI role sqlserver-server + 4 AppRoles
#      + 5 KV sticky-seeds + 4 sidecars at $HOME\.nexus\vault-agent-oltp-
#      sqlserver-<host>.json + nexus-sql-cluster-members AD group + gmsa-sql-
#      engine$ GMSA).
#   3. Packer template built:
#        H:\VMS\NexusPlatform\_templates\oltp-sqlserver-node\oltp-sqlserver-node.vmx
#      (derives from ws2025-desktop.vmx; bakes SQL 2022 Developer + WSFC +
#      iSCSI + MPIO features + firstboot pre-staging at C:\ProgramData\nexus\sql\)
#
# Apply order within this env:
#   module.sql_fci_{1,2} + module.sql_ag_rep_{1,2}  (4 parallel clones via vmrun)
#   -> null_resource.sqlserver_nftables_backplane  (verify Win Firewall + VMnet10 reachability)
#   -> null_resource.sqlserver_domain_join          (Add-Computer all 4 to nexus.lab + add to nexus-sql-cluster-members)
#   -> null_resource.sqlserver_vault_agents         (install nexus-vault-agent Windows service on all 4)
#   -> null_resource.sqlserver_tls                  (render mTLS leaf certs to LocalMachine\My via Vault Agent templates)
#   -> null_resource.iscsi_attach                   (FCI pair only: Connect-IscsiTarget + Initialize-Disk + Add-ClusterSharedVolume)
#   -> null_resource.wsfc_bootstrap                 (New-Cluster sql-fci-cluster with 4 nodes + Static IP .15)
#   -> null_resource.fci_install                    (FCI pair only: setup.exe /ACTION=InstallFailoverCluster on sql-fci-1 + /ACTION=AddNode on sql-fci-2; VIP .16)
#   -> null_resource.ag_bootstrap                   (CREATE AVAILABILITY GROUP nexus-ag with FCI as primary + 2 async replicas; AUTHENTICATION = CERTIFICATE per ADR-0027)
#   -> null_resource.ag_listener                    (New-SqlAvailabilityGroupListener at .17 + import listener cert into LocalMachine\My on all 4)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── FCI pair module.vm blocks (2 nodes sharing iSCSI LUN) ────────────────

module "sql_fci_1" {
  source = "../../modules/vm"
  count  = var.enable_sql_fci_1 ? 1 : 0

  vm_name           = "sql-fci-1"
  template_vmx_path = "${var.template_root}/oltp-sqlserver-node/oltp-sqlserver-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/02-sqlserver/sql-fci-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_sql_fci_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sql_fci_1_secondary
}

module "sql_fci_2" {
  source = "../../modules/vm"
  count  = var.enable_sql_fci_2 ? 1 : 0

  vm_name           = "sql-fci-2"
  template_vmx_path = "${var.template_root}/oltp-sqlserver-node/oltp-sqlserver-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/02-sqlserver/sql-fci-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_sql_fci_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sql_fci_2_secondary
}

# ─── AG async replica module.vm blocks (2 standalone SQL instances) ───────

module "sql_ag_rep_1" {
  source = "../../modules/vm"
  count  = var.enable_sql_ag_rep_1 ? 1 : 0

  vm_name           = "sql-ag-rep-1"
  template_vmx_path = "${var.template_root}/oltp-sqlserver-node/oltp-sqlserver-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/02-sqlserver/sql-ag-rep-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_sql_ag_rep_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sql_ag_rep_1_secondary
}

module "sql_ag_rep_2" {
  source = "../../modules/vm"
  count  = var.enable_sql_ag_rep_2 ? 1 : 0

  vm_name           = "sql-ag-rep-2"
  template_vmx_path = "${var.template_root}/oltp-sqlserver-node/oltp-sqlserver-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/02-sqlserver/sql-ag-rep-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_sql_ag_rep_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_sql_ag_rep_2_secondary
}

# ─── Computed maps used across the role-overlays ──────────────────────────

locals {
  # All 4 nodes with their VMnet11 service IPs + VMnet10 backplane IPs +
  # role (fci vs ag-replica). Consumed by every role-overlay for-each loops.
  sql_nodes = {
    "sql-fci-1"    = { vmnet11 = "192.168.70.11", vmnet10 = "192.168.10.11", role = "fci" }
    "sql-fci-2"    = { vmnet11 = "192.168.70.12", vmnet10 = "192.168.10.12", role = "fci" }
    "sql-ag-rep-1" = { vmnet11 = "192.168.70.13", vmnet10 = "192.168.10.13", role = "ag-replica" }
    "sql-ag-rep-2" = { vmnet11 = "192.168.70.14", vmnet10 = "192.168.10.14", role = "ag-replica" }
  }

  # FCI pair subset (consumes iSCSI + becomes the FCI virtual server owner).
  fci_nodes = { for k, v in local.sql_nodes : k => v if v.role == "fci" }

  # Domain identity facts.
  ad_domain        = "nexus.lab"
  ad_join_user     = "nexus.lab\\nexusadmin"
  wsfc_cluster_ip  = "192.168.70.15"
  fci_virtual_ip   = "192.168.70.16"
  ag_listener_ip   = "192.168.70.17"
  fci_cluster_name = "sql-fci-cluster"
  ag_listener_name = "sql-ag-listener"
  ag_name          = "nexus-ag"

  # Sidecar JSON path on the build host (written by security env's
  # role-overlay-vault-agent-sqlserver-approles.tf).
  vault_agent_sidecar_dir = pathexpand("~/.nexus")

  # Pre-expanded build-host CA bundle path -- avoids needing PS-side `~`
  # resolution downstream (PS has no `pathexpand` function, and ~ doesn't
  # auto-expand in Test-Path on Windows pwsh in non-interactive contexts).
  vault_ca_bundle_path_expanded = pathexpand(var.vault_ca_bundle_path)
}
