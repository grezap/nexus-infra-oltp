# nexus-infra-oltp / terraform / envs / oltp / variables.tf
#
# `enable_<cluster>` toggle scaffolding -- defaults to `true` per
# `feedback_selective_provisioning.md` + `feedback_terraform_partial_apply_destroys_resources.md`
# (defaults reflect steady state; operators opt OUT explicitly via -Vars).
#
# Per-cluster MAC + IP defaults land in this file as each sub-phase ships,
# pinned to nexus-platform-plan/docs/infra/vms.yaml. MAC range allocated for
# 0.G in the 0.G.0 DRY audit: 00:50:56:3F:00:70 through :88 (25 contiguous;
# existing reservations stop at :6E kafka).

# --- Shared paths -----------------------------------------------------------

variable "template_root" {
  type        = string
  description = "Root directory of Packer-built .vmx templates."
  default     = "H:\\VMS\\NexusPlatform\\_templates"
}

variable "vm_output_dir_root" {
  type        = string
  description = "Root directory under which per-VM clone subdirs live (per `feedback_vmware_per_vm_folders.md`)."
  default     = "H:\\VMS\\NexusPlatform"
}

# --- Per-cluster enable toggles --------------------------------------------
# Default true == included in steady-state apply. Pass -Vars enable_X=false to
# opt out; see scripts/oltp.ps1 examples for the canonical command shapes.

variable "enable_redis" {
  type        = bool
  description = "Bring up the Redis Cluster (6 VMs, 3 primaries + 3 replicas)."
  default     = true
}

variable "enable_mongo" {
  type        = bool
  description = "Bring up the MongoDB replica set (3 VMs)."
  default     = true
}

variable "enable_percona" {
  type        = bool
  description = "Bring up Percona XtraDB Cluster + ProxySQL (5 VMs: 3 PXC + 2 ProxySQL)."
  default     = true
}

variable "enable_patroni" {
  type        = bool
  description = "Bring up PostgreSQL Patroni + etcd + HAProxy (7 VMs: 3 PG + 3 etcd + 1 HAProxy)."
  default     = true
}

variable "enable_sql" {
  type        = bool
  description = "Bring up SQL Server FCI + AG (4 ws2025-desktop VMs: 2 FCI + 2 AG replicas)."
  default     = true
}

# --- Per-cluster MAC variables ----------------------------------------------
# Allocated from the 0.G MAC pool :70-:88. Concrete `mac_<vm>` variables land
# per sub-phase as their cluster module blocks are added.
