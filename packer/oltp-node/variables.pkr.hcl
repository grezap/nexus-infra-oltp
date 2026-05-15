# nexus-infra-oltp / packer / oltp-node / variables.pkr.hcl
#
# Build-time variables for the oltp-node Packer template. Mirrors the
# nexus-infra-kafka/packer/kafka-node/variables.pkr.hcl pattern; per-role
# package versions get added per cluster sub-phase.

variable "iso_url" {
  type        = string
  description = "Path to the Debian 13 netinst ISO (per `project_iso_directory.md`)."
  default     = "H:/VMS/ISO/debian-13-amd64-netinst.iso"
}

variable "iso_checksum" {
  type        = string
  description = "SHA256 of the Debian 13 netinst ISO; matches the Debian project's published checksum."
  # Populate with the actual checksum when 0.G.1 ships; for now this scaffold
  # is intentionally non-buildable.
  default     = "TBD"
}

variable "vm_name" {
  type    = string
  default = "oltp-node"
}

variable "output_directory" {
  type    = string
  default = "H:/VMS/NexusPlatform/_templates/oltp-node"
}

variable "memory_mb" {
  type        = number
  description = "Default RAM for clones from this template. Per `feedback_prefer_less_memory.md`, baked at the lab-sized lower end (2 GB Redis/Mongo node, 4 GB Patroni/Percona node; per-role overrides via Terraform -var). Updated per cluster sub-phase."
  default     = 2048
}

variable "cpus" {
  type    = number
  default = 2
}

variable "disk_size_mb" {
  type    = number
  default = 40000
}

# TODO 0.G.1+: per-role package pins land here:
#   variable "redis_version"       { default = "7.4.x" }
#   variable "mongodb_version"     { default = "7.0.x" }
#   variable "percona_version"     { default = "8.0.x" }
#   variable "postgresql_version"  { default = "16" }
#   variable "patroni_version"     { default = "4.0.x" }
#   variable "etcd_version"        { default = "3.5.x" }
#   variable "haproxy_version"     { default = "2.8.x" }
#   variable "proxysql_version"    { default = "2.7.x" }
