# nexus-infra-oltp / terraform / envs / oltp-sqlserver / variables.tf
#
# Variables for the Phase 0.G.7 SQL Server FCI + AG cluster env. All
# enable_* toggles default to true (opt-out per memory/feedback_terraform_
# partial_apply_destroys_resources.md). Selective ops: pass -Vars enable_X=
# false to skip a specific resource on a partial-apply (full plan/apply
# still requires the var to be passed explicitly via the operator wrapper).

# ─── Per-VM enable toggles ────────────────────────────────────────────────

variable "enable_sql_fci_1" {
  description = "Toggle: clone + power on sql-fci-1 (FCI node 1; WSFC member; iSCSI initiator). Default true."
  type        = bool
  default     = true
}

variable "enable_sql_fci_2" {
  description = "Toggle: clone + power on sql-fci-2 (FCI node 2; WSFC member; iSCSI initiator). Default true."
  type        = bool
  default     = true
}

variable "enable_sql_ag_rep_1" {
  description = "Toggle: clone + power on sql-ag-rep-1 (AG async replica 1; WSFC member; local storage). Default true."
  type        = bool
  default     = true
}

variable "enable_sql_ag_rep_2" {
  description = "Toggle: clone + power on sql-ag-rep-2 (AG async replica 2; WSFC member; local storage). Default true."
  type        = bool
  default     = true
}

# ─── Per-stage enable toggles (selective ops) ─────────────────────────────

variable "enable_nftables_backplane" {
  description = "Toggle: verify Windows Firewall rules + VMnet10 backplane reachability between all 4 nodes. Default true (cheap probe; safe to skip if iterating later stages)."
  type        = bool
  default     = true
}

variable "enable_sqlserver_domain_join" {
  description = "Toggle: Add-Computer all 4 SQL nodes to nexus.lab + populate nexus-sql-cluster-members AD group. Requires dc-nexus reachable + nexusadmin EA membership. Default true. Set false to skip the domain-join step (e.g. iterating later stages on already-joined nodes)."
  type        = bool
  default     = true
}

variable "enable_sqlserver_vault_agents" {
  description = "Toggle: install nexus-vault-agent Windows service on all 4 SQL nodes (binary fetch + KV-templated config + service registration). Default true."
  type        = bool
  default     = true
}

variable "enable_sqlserver_tls" {
  description = "Toggle: render mTLS leaf certs to LocalMachine\\My on all 4 SQL nodes via Vault Agent templates. FCI nodes additionally get the FCI virtual server cert (IP-SAN .16); Listener cert (IP-SAN .17) imported on all 4. Default true."
  type        = bool
  default     = true
}

variable "enable_iscsi_attach" {
  description = "Toggle: on sql-fci-1/2 only -- start msiscsi service, Connect-IscsiTarget to nexus-gateway's tgt target, Initialize-Disk + New-Partition (sql-fci-1 only) or attach (sql-fci-2). Default true. Set false on AG-only iteration or when re-applying after FCI is already installed."
  type        = bool
  default     = true
}

variable "enable_wsfc_bootstrap" {
  description = "Toggle: New-Cluster sql-fci-cluster with all 4 nodes as members + Static IP 192.168.70.15 + Add-ClusterSharedVolume for the iSCSI LUN. Idempotent via Get-Cluster probe. Default true."
  type        = bool
  default     = true
}

variable "enable_fci_install" {
  description = "Toggle: re-run setup.exe with /ACTION=InstallFailoverCluster on sql-fci-1 (creates SQL Server FCI on the iSCSI CSV; VIP .16) + /ACTION=AddNode on sql-fci-2. Default true."
  type        = bool
  default     = true
}

variable "enable_ag_bootstrap" {
  description = "Toggle: CREATE AVAILABILITY GROUP nexus-ag with the FCI as primary + sql-ag-rep-1/2 as async secondaries; AG endpoints use AUTHENTICATION = CERTIFICATE per ADR-0027. Default true."
  type        = bool
  default     = true
}

variable "enable_ag_listener" {
  description = "Toggle: New-SqlAvailabilityGroupListener sql-ag-listener at 192.168.70.17 + import the Listener cert (CN sql-ag-listener.nexus.lab, IP-SAN .17) into LocalMachine\\My on all 4 nodes. Default true."
  type        = bool
  default     = true
}

# ─── MAC addresses for cloned NICs (4 nodes × 2 NICs = 8 MACs) ────────────
# Convention per nexus-infra-vmware foundation env's reservations: VMnet11
# primary NICs use 00:50:56:3F:00:86..89; VMnet10 secondary NICs use the
# same VM-id sixth byte with fifth byte 0x01 (per modules/vm convention).

variable "mac_sql_fci_1_primary" {
  description = "sql-fci-1 primary NIC (VMnet11). Pinned to .70.11 by foundation v6 dhcp-host reservation."
  type        = string
  default     = "00:50:56:3F:00:86"
}
variable "mac_sql_fci_1_secondary" {
  description = "sql-fci-1 secondary NIC (VMnet10 backplane). Static .10.11 set by firstboot.ps1."
  type        = string
  default     = "00:50:56:3F:01:86"
}
variable "mac_sql_fci_2_primary" {
  description = "sql-fci-2 primary NIC (VMnet11). Pinned to .70.12."
  type        = string
  default     = "00:50:56:3F:00:87"
}
variable "mac_sql_fci_2_secondary" {
  description = "sql-fci-2 secondary NIC (VMnet10 backplane). Static .10.12."
  type        = string
  default     = "00:50:56:3F:01:87"
}
variable "mac_sql_ag_rep_1_primary" {
  description = "sql-ag-rep-1 primary NIC (VMnet11). Pinned to .70.13."
  type        = string
  default     = "00:50:56:3F:00:88"
}
variable "mac_sql_ag_rep_1_secondary" {
  description = "sql-ag-rep-1 secondary NIC (VMnet10 backplane). Static .10.13."
  type        = string
  default     = "00:50:56:3F:01:88"
}
variable "mac_sql_ag_rep_2_primary" {
  description = "sql-ag-rep-2 primary NIC (VMnet11). Pinned to .70.14."
  type        = string
  default     = "00:50:56:3F:00:89"
}
variable "mac_sql_ag_rep_2_secondary" {
  description = "sql-ag-rep-2 secondary NIC (VMnet10 backplane). Static .10.14."
  type        = string
  default     = "00:50:56:3F:01:89"
}

# ─── Lab-wide knobs (mirrors patroni env's variables.tf) ──────────────────

variable "template_root" {
  description = "Root dir for Packer template outputs. Per memory/feedback_vmware_per_vm_folders.md the per-template subdir matches the template name."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates"
}

variable "vm_output_dir_root" {
  description = "Root dir for running VM instances (per-tier subdirs: 02-sqlserver, 03-kafka, 05-oltp, etc)."
  type        = string
  default     = "H:/VMS/NexusPlatform"
}

variable "vmrun_path" {
  description = "Absolute path to vmrun.exe on the build host."
  type        = string
  default     = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
}

variable "vnet_primary" {
  description = "Primary NIC's VMware network (lab service network)."
  type        = string
  default     = "VMnet11"
}

variable "vnet_secondary" {
  description = "Secondary NIC's VMware network (cluster backplane)."
  type        = string
  default     = "VMnet10"
}

variable "ad_domain_name" {
  description = "Active Directory domain for the SQL nodes to join. Matches the foundation env's forest (`nexus.lab`)."
  type        = string
  default     = "nexus.lab"
}

variable "ad_dc_ip" {
  description = "dc-nexus VMnet11 IP. Used for SSH-driven Add-Computer + AD group population. Per foundation env's local.dc_nexus_ip."
  type        = string
  default     = "192.168.70.240"
}

variable "ssh_username" {
  description = "SSH username for the SQL Server VMs. Matches Packer-baked Local Administrator user."
  type        = string
  default     = "nexusadmin"
}

variable "vault_pki_sqlserver_role" {
  description = "PKI role name at pki_int/ used by Vault Agent templates to issue mTLS leaf certs. Per security env's var.vault_pki_sqlserver_role_name."
  type        = string
  default     = "sqlserver-server"
}

variable "vault_ca_bundle_path" {
  description = "Build-host path to the Vault PKI root+intermediate CA bundle. Distributed to each SQL node's LocalMachine\\Root by the TLS overlay."
  type        = string
  default     = "~/.nexus/vault-ca-bundle.crt"
}

variable "sql_iso_path" {
  description = "Build-host absolute path to the SQL Server 2025 ISO. The fci-install overlay uploads it to C:/Windows/Temp/sqlserver.iso on each FCI node (sequential + size-verified + idempotent) BEFORE the InstallFailoverCluster/AddNode steps. The Packer bake removes the ISO post-install, so the FCI install must re-supply it -- automating this keeps the from-zero cold rebuild hands-off (no manual scp). Default matches memory/project_iso_directory.md (H:/VMS/ISO/)."
  type        = string
  default     = "H:/VMS/ISO/SqlServer2025EnterpriseDeveloperEdition.iso"
}

# ─── Stage versions (bump to trigger re-apply on a specific stage) ────────

variable "sqlserver_nftables_v" {
  description = "Win Firewall probe overlay version. Bump to re-run."
  type        = string
  default     = "1"
}
variable "sqlserver_domain_join_v" {
  description = "Domain-join overlay version. Bump to re-run."
  type        = string
  default     = "1"
}
variable "sqlserver_vault_agents_v" {
  description = "Vault Agent install overlay version. Bump to re-run."
  type        = string
  default     = "1"
}
variable "sqlserver_tls_v" {
  description = "TLS material render overlay version. Bump to re-run."
  type        = string
  default     = "3"
}
variable "iscsi_attach_v" {
  description = "iSCSI attach overlay version. Bump to re-run."
  type        = string
  default     = "1"
}
variable "wsfc_bootstrap_v" {
  description = "WSFC bootstrap overlay version. Bump to re-run."
  type        = string
  default     = "1"
}
variable "fci_install_v" {
  description = "FCI install overlay version. Bump to re-run."
  type        = string
  default     = "4"
}
variable "ag_bootstrap_v" {
  description = "AG bootstrap overlay version. Bump to re-run."
  type        = string
  default     = "7"
}
variable "ag_listener_v" {
  description = "AG Listener overlay version. Bump to re-run."
  type        = string
  default     = "3"
}
