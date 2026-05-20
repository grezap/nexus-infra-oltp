/*
 * Phase 0.G.7 -- oltp-sqlserver-node per-engine Packer template variables.
 *
 * Mirrors nexus-infra-vmware/packer/ws2025-desktop/variables.pkr.hcl shape
 * since this template builds end-to-end from the WS2025 ISO (vmware-iso
 * builder) following the same product_source = "evaluation" | "msdn"
 * contract. Then layers SQL Server 2025 + WSFC/iSCSI/MPIO features on top.
 *
 * Bake time projection: ~60 min real-time:
 *   - vmware-iso install of WS2025 from ISO (Autounattend-driven): ~25 min
 *   - 5 shared Nexus baseline scripts (identity + network + firewall +
 *     observability + windows-baseline): ~10 min
 *   - SQL Server 2025 silent install (1.2 GB ISO upload + setup.exe): ~18 min
 *   - WSFC + iSCSI + MPIO features + firewall + HADR enable: ~5 min
 *   - 99-sysprep + shutdown: ~2 min
 *
 * Per ADR-0144: SQL Server uses MSDN Enterprise Developer Edition (free,
 * full Enterprise features). Product key for the WS2025 OS layer also
 * comes from MSDN per the same ADR.
 */

variable "vm_name" {
  description = "Name of the bake-time VM + output dir name. Per-engine canon: matches template ID. 19 chars -- fine for VMware-side identity (VMware VM names have no NetBIOS limit), but NOT used as the Windows ComputerName during install (which is bake_computer_name)."
  type        = string
  default     = "oltp-sqlserver-node"
}

variable "bake_computer_name" {
  description = "Windows ComputerName for the BAKE-TIME VM only. MUST be <=15 chars (NetBIOS limit; per memory/feedback_windows_ssh_automation.md). Clones rename to sql-fci-1/2/sql-ag-rep-1/2 (all 11-12 chars + NetBIOS-valid) via firstboot.ps1 at clone time, so this value is effectively a throwaway placeholder. Setup.exe REJECTS the Autounattend if ComputerName > 15 chars (hrResult 0x80220005). Transient #10 at 0.G.7 ratify 2026-05-20."
  type        = string
  default     = "OLTPSQL-BAKE"

  validation {
    condition     = length(var.bake_computer_name) <= 15 && can(regex("^[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]$", var.bake_computer_name))
    error_message = "The bake_computer_name must be 2-15 chars, alphanumeric + hyphens only, starting with a letter and ending with letter or digit (NetBIOS rules)."
  }
}

variable "output_directory" {
  description = "Where the baked .vmx + .vmdk land. Convention: H:\\VMS\\NexusPlatform\\_templates\\<template>\\."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/oltp-sqlserver-node"
}

# ─── Windows licensing / ISO selection ─────────────────────────────────────
# Same product_source contract as ws2025-desktop. WS2025 ISO is shared; only
# the install.wim image_name + product_key differ between editions.
#   product_source = "evaluation" -> "Windows Server 2025 Standard Evaluation (Desktop Experience)"
#   product_source = "msdn"        -> "Windows Server 2025 Standard (Desktop Experience)"

variable "product_source" {
  description = "Activation path: 'evaluation' (public) or 'msdn' (owner). Per ADR-0144."
  type        = string
  default     = "evaluation"

  validation {
    condition     = contains(["evaluation", "msdn"], var.product_source)
    error_message = "The product_source variable must be either 'evaluation' or 'msdn'."
  }
}

variable "iso_path_evaluation" {
  description = "Absolute path to Windows Server 2025 *Evaluation* ISO on the build host."
  type        = string
  default     = "H:/VMS/ISO/WindowsServer2025Evaluation.iso"
}

variable "iso_checksum_evaluation" {
  description = "SHA256 of the Evaluation ISO. Same as ws2025-desktop's (shared ISO)."
  type        = string
  default     = "sha256:7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"
}

variable "iso_path_msdn" {
  description = "Absolute path to Windows Server 2025 *retail/MSDN* ISO on the build host."
  type        = string
  default     = "H:/VMS/ISO/WindowsServer2025.iso"
}

variable "iso_checksum_msdn" {
  description = "SHA256 of the MSDN/retail ISO. Same as ws2025-desktop's (shared ISO)."
  type        = string
  default     = "sha256:2d099c70de0317197b6f3906d957504f656ef8b05ba6e1e92a17ff963d5cdf89"
}

variable "bootstrap_keys_file" {
  description = <<-EOT
    Pre-Phase-0.D fallback for product_source=msdn: absolute path to an
    NTFS-ACL-locked JSON file mapping template name -> {key, edition}. The
    JSON must contain a "ws2025-desktop" entry with a "key" field (this
    template reuses the WS2025 Desktop install.wim image, hence sharing
    the same MSDN key entry). Ignored when product_source = evaluation.
    Example: C:/Users/<owner>/.nexus/secrets/windows-keys.json
  EOT
  type        = string
  default     = ""
}

# ─── Hardware ──────────────────────────────────────────────────────────────
# Same defaults as ws2025-desktop (Desktop Experience footprint), bumped up
# slightly because SQL setup likes ≥4 GB during the install. Steady-state
# per vms.yaml is 16 GB (FCI) / 12 GB (AG-replica) -- set at clone time.

variable "cpus" {
  description = "Bake-time vCPUs. SQL Server installer parallelizes steps with cores; 4 cuts install time."
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "Bake-time RAM (MB). 6 GB matches ws2025-desktop + leaves headroom for SQL install."
  type        = number
  default     = 6144
}

variable "disk_gb" {
  description = "Bake-time disk size (GB). 80 GB matches ws2025-desktop + leaves room for SQL binaries + tempdb."
  type        = number
  default     = 80
}

# ─── Credentials (build-time only; rotated to GMSA in cluster bring-up) ────

variable "admin_username" {
  description = "Local Administrator username. Same nexusadmin used across the WS2025 fleet."
  type        = string
  default     = "nexusadmin"
}

variable "admin_password" {
  description = "Local Administrator password (build-time). Same default as ws2025-desktop. Rotated to GMSA-managed at WSFC + FCI install time."
  type        = string
  default     = "NexusPackerBuild!1"
  sensitive   = true
}

variable "winrm_timeout" {
  description = "WinRM timeout for the bake. WS2025 OOBE + first-boot can take 10-15 min; 30m for debug iteration (fails fast); flip back to 2h once the bake works end-to-end."
  type        = string
  default     = "30m"
}

# ─── SQL Server install knobs ──────────────────────────────────────────────

variable "sql_iso_path" {
  description = "Local path to the SQL Server 2025 Enterprise Developer Edition ISO (MSDN per ADR-0144). Mounted via Mount-DiskImage at bake time. Decision sealed 2026-05-20 -- SQL 2025 picked over 2022 to align with WS2025 OS + leverage newest AG sync-commit + columnstore + Iceberg lakehouse-native query."
  type        = string
  default     = "H:/VMS/ISO/SqlServer2025EnterpriseDeveloperEdition.iso"
}

variable "sql_iso_checksum" {
  description = "SHA256 of the SQL Server 2025 ISO. Computed via Get-FileHash on the MSDN download 2026-05-20."
  type        = string
  default     = "sha256:f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851"
}

variable "sql_version" {
  description = "SQL Server major version. 2025 is the canon (Enterprise Developer Edition free + full feature set incl. AOAG + Iceberg lakehouse-native query)."
  type        = string
  default     = "2025"
}

variable "sql_edition" {
  description = "SQL Server edition. SQL 2025 ships as 'Enterprise' Developer Edition (free for dev/test; full Enterprise features). Per ADR-0144."
  type        = string
  default     = "Enterprise"
}

variable "sql_install_features" {
  description = "Comma-separated SQL Server features to install. SQLEngine + FullText is the minimum for FCI+AG. 'Replication' enables tx-rep demos; 'AS' enables Analysis Services (out of scope for 0.G.7)."
  type        = string
  default     = "SQLEngine,FullText"
}

variable "sql_instance_name" {
  description = "SQL Server instance name. MSSQLSERVER is the default instance. For FCI clusters this is canonical -- the FCI virtual server (sql-fci-cluster) presents a default instance as `sql-fci-cluster\\MSSQLSERVER`."
  type        = string
  default     = "MSSQLSERVER"
}
