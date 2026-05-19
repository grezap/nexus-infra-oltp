/*
 * Phase 0.G.7 -- oltp-sqlserver-node per-engine Packer template variables.
 *
 * The template clones from the existing ws2025-desktop.vmx (baked by
 * nexus-infra-vmware Phase 0.B.5) + layers SQL Server 2022 Developer +
 * WSFC/iSCSI/MPIO features + firstboot pre-staging on top. This avoids
 * duplicating ~600 lines of Windows-from-ISO bootstrap (Autounattend +
 * 5-script Nexus baseline + sysprep) that already live in
 * nexus-infra-vmware/packer/ws2025-desktop/. The Windows baseline (OpenSSH
 * + nexusadmin authorized_keys + nftables analogue via Windows Firewall +
 * node_exporter) is inherited from the source VMX.
 *
 * Bake time projection: ~30 min (vs ~60 min if we built from ISO):
 *   - clone .vmx + power on + wait for OOBE complete: ~5 min
 *   - SQL Server 2022 silent install + config: ~18 min
 *   - WSFC + iSCSI + MPIO features: ~5 min
 *   - sysprep + shutdown: ~2 min
 *
 * Per memory/feedback_per_cluster_state_per_engine_template.md the
 * per-engine canon shape applies: one template per engine type, one
 * Terraform env per cluster. This template produces one .vmx that the 4
 * SQL nodes (sql-fci-1/2 + sql-ag-rep-1/2) clone from at terraform apply
 * time.
 *
 * Per ADR-0144: SQL Server uses MSDN Developer Edition (free, full
 * Enterprise features incl. AOAG sync replicas). The product key for the
 * WS2025-desktop OS layer is consumed during the ws2025-desktop bake; SQL
 * Server itself has no product key field for Developer Edition (the
 * license accept is via /IACCEPTSQLSERVERLICENSETERMS).
 */

variable "vm_name" {
  description = "Name of the bake-time VM + output dir name. Per-engine canon: matches template ID."
  type        = string
  default     = "oltp-sqlserver-node"
}

variable "output_directory" {
  description = "Where the baked .vmx + .vmdk land. Convention: H:\\VMS\\NexusPlatform\\_templates\\<template>\\."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/oltp-sqlserver-node"
}

variable "source_vmx" {
  description = "Path to the ws2025-desktop.vmx produced by nexus-infra-vmware Phase 0.B.5. The bake clones this VMX + layers SQL Server + WSFC features + firstboot pre-staging on top. Inherits OpenSSH + nexusadmin authorized_keys + Windows baseline."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/ws2025-desktop/ws2025-desktop.vmx"
}

variable "cpus" {
  description = "Bake-time vCPUs. SQL Server setup.exe parallelizes installer steps with cores; 4 vCPUs cuts install time noticeably. Steady-state vCPUs per vms.yaml (sqlserver cluster: 4) baked into vmx_data."
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "Bake-time RAM. SQL Server installer benefits from 4+ GB; steady-state per vms.yaml is 16 GB (FCI) / 12 GB (AG-replica) -- set at clone time by terraform via modules/vm if/when memory_mb resize lands (currently reserved-not-applied per modules/vm/README.md). 4 GB is the bake-time floor."
  type        = number
  default     = 4096
}

variable "disk_gb" {
  description = "Bake-time disk size (the VMDK from the source ws2025-desktop.vmx is inherited; this var only documents the steady-state per vms.yaml). Per vms.yaml sqlserver cluster: 200 GB for FCI nodes (SQL system DBs + tempdb local cache; user DBs live on iSCSI shared LUN), 200 GB for AG-replica nodes (full local copy of AG'd user DBs)."
  type        = number
  default     = 200
}

variable "admin_username" {
  description = "Local Administrator username baked into the source VMX via 99-sysprep's UserAccounts unattend block. The same nexusadmin used across the WS2025 fleet."
  type        = string
  default     = "nexusadmin"
}

variable "admin_password" {
  description = "Local Administrator password used by SSH provisioner to reach the baked VM during this layer. Bake-time only -- rotated by AD GPO + GMSA adoption post-domain-join. NEVER committed; passed via PKR_VAR_admin_password env or -var on packer build."
  type        = string
  default     = "nexus-packer-build-only"
  sensitive   = true
}

variable "ssh_timeout" {
  description = "How long to wait for OpenSSH on the cloned VM to come up after VMX clone + power on. The baked ws2025-desktop has OpenSSH service auto-start; OOBE completion + sshd binding takes ~3-5 min typically."
  type        = string
  default     = "30m"
}

variable "sql_iso_path" {
  description = "Local path to the SQL Server 2022 Developer Edition ISO (MSDN-keyed per ADR-0144). The bake mounts this ISO at D: via vmrun's addAttach + extracts setup.exe + runs silent install. ISO lives in H:\\VMS\\ISO\\ per memory/project_iso_directory.md."
  type        = string
  default     = "H:/VMS/ISO/SQLServer2022-x64-ENU-Dev.iso"
}

variable "sql_iso_checksum" {
  description = "SHA256 checksum of the SQL Server 2022 Developer Edition ISO. Lookup at https://www.microsoft.com/sql-server/sql-server-downloads or via Get-FileHash on the canonical MSDN-downloaded file. Format: 'sha256:<hex>'."
  type        = string
  default     = "sha256:000000000000000000000000000000000000000000000000000000000000PLACEHOLDER"
}

variable "sql_version" {
  description = "SQL Server major version. 2022 is the current canon (Always On enhancements + RegisterAllProvidersIP for multi-subnet AG demos; 2025 release is too new for portfolio-grade stability)."
  type        = string
  default     = "2022"
}

variable "sql_edition" {
  description = "SQL Server edition. Developer (free, full Enterprise features) per ADR-0144. Set to 'Evaluation' for an alternate 180-day rearm-able install -- not the canon path."
  type        = string
  default     = "Developer"
}

variable "sql_install_features" {
  description = "Comma-separated list of SQL Server features to install. SQLEngine (database engine) + FullText (for AG demos that exercise full-text indexes) is the minimum for FCI+AG. Adding 'Replication' enables transactional replication demos; 'AS' enables Analysis Services (out of scope for 0.G.7)."
  type        = string
  default     = "SQLEngine,FullText"
}

variable "sql_instance_name" {
  description = "SQL Server instance name. MSSQLSERVER is the default instance (one SQL Server per VM). For FCI clusters this is the canonical naming -- the FCI virtual server (sql-fci-cluster) presents a default instance as `sql-fci-cluster\\MSSQLSERVER`."
  type        = string
  default     = "MSSQLSERVER"
}
