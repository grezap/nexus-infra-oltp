/*
 * oltp-patroni-node -- Packer template variables (Phase 0.G.4)
 *
 * Mirrors oltp-pxc-node/variables.pkr.hcl shape, stripped of PXC vars and
 * adding pg_version + patroni_version (the only knob this template needs --
 * etcd + haproxy live in their own sibling templates).
 */

variable "vm_name" {
  type        = string
  default     = "oltp-patroni-node"
  description = "VM display name and output .vmx basename. Default `oltp-patroni-node` -- the template; per-clone names (pg-primary, pg-replica-1, pg-replica-2) are set by terraform/envs/oltp-patroni/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/oltp-patroni-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type    = string
  default = "H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso"
  # Local ISO from the lab canon dir (H:/VMS/ISO/, project_iso_directory). The
  # upstream mirror rotates point releases off iso-cd/ into archive within months
  # (13.5.0 already 404s there as of 2026-07), so a remote default breaks replay;
  # the checksum below still pins integrity. For a fresh host, fetch the ISO into
  # H:/VMS/ISO/ once (or override -var iso_url=<url> against the archive mirror).
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "pg_version" {
  type        = string
  default     = "17"
  description = "PostgreSQL major version installed via the PGDG vendor APT repo (apt.postgresql.org). Default 17 (current GA as of Phase 0.G.4). Changing this requires also updating the oltp_patroni Ansible role's apt source codename suffix (e.g. `bookworm-pgdg-17` -> `bookworm-pgdg-18`) and re-baking the template."
}

variable "patroni_version" {
  type        = string
  default     = "4.0.5"
  description = "Patroni version installed via PyPI (pip install 'patroni[etcd3]=={{ version }}'). Default 4.0.5 (current GA). Patroni 4.x is required for: improved etcd3 v3 API support (avoids v2 deprecation warnings), the new `patronictl reload` flow, and the watchdog hard-reboot fence. apt's patroni lags by 1-2 minor versions; pip is canonical."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU. Default 2 keeps bake time reasonable; steady-state 4 vCPU per vms.yaml is set at clone time by terraform vmrun-resize."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md. Steady-state 8 GB per vms.yaml is set at clone time."
}

variable "disk_gb" {
  type        = number
  default     = 60
  description = "Disk size in GB. Default 60 GB sized for PG WAL + data working set at lab scale. Growable single-file VMDK only consumes what it writes; larger workloads can resize at clone time."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
