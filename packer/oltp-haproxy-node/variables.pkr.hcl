/*
 * oltp-haproxy-node -- Packer template variables (Phase 0.G.4)
 */

variable "vm_name" {
  type    = string
  default = "oltp-haproxy-node"
}

variable "output_directory" {
  type    = string
  default = "H:/VMS/NexusPlatform/_templates/oltp-haproxy-node"
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
  type    = string
  default = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
}

variable "haproxy_version" {
  type        = string
  default     = "3.0"
  description = "HAProxy LTS series. Installed via the project-maintained haproxy.debian.net backport repo (vbernat's debian packages). Default 3.0 (current LTS as of Phase 0.G.4). The repo path encodes the major+minor (`haproxy-3.0`); bumping requires updating the apt source line."
}

variable "cpus" {
  type    = number
  default = 1
}

variable "memory_mb" {
  type    = number
  default = 1024
}

variable "disk_gb" {
  type    = number
  default = 20
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
