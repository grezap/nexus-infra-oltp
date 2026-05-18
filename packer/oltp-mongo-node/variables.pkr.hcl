/*
 * oltp-node -- Packer template variables (Phase 0.G.1+)
 *
 * Mirrors nexus-infra-kafka/packer/kafka-node/variables.pkr.hcl pattern;
 * stripped of JDK + Kafka + Confluent vars (not needed for the Redis-only
 * 0.G.1 build), and adds redis_version for the apt-installed Redis.
 *
 * Per-cluster package pins land here as 0.G.2-0.G.7 ship (mongodb_version,
 * percona_version, postgresql_version, patroni_version, etcd_version,
 * haproxy_version, proxysql_version).
 */

variable "vm_name" {
  type        = string
  default     = "oltp-mongo-node"
  description = "VM display name and output .vmx basename. Default `oltp-mongo-node` -- the template; per-clone names (mongo-1/2/3) are set by terraform/envs/oltp-mongo/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/oltp-mongo-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
  description = "Debian 13.5.0 netinst ISO. NEWER point release than the canonical 13.4.0 used by nexus-infra-kafka/packer/kafka-node + nexus-infra-vmware/packer/{deb13,vault} + nexus-infra-swarm-nomad/packer/swarm-node -- bumped here at 0.G.1 ratification 2026-05-17 because the mirror dropped 13.4.0 the same day Debian published 13.5.0 (HTTP 404). The other templates' .pkr.hcl files will also need this bump the next time they get rebuilt; existing built artifacts in H:\\VMS\\NexusPlatform\\_templates\\ are frozen from when 13.4.0 was current and don't need touching. Override via `-var iso_url=H:/VMS/ISO/debian-13-amd64-netinst.iso` to consume the local cache per memory/project_iso_directory.md -- Packer's content-addressed cache under packer_cache/ also avoids re-download across builds."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst. Fetched from https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS at 0.G.1 ratification 2026-05-17."
}

variable "mongodb_version" {
  type        = string
  default     = "8.0"
  description = "MongoDB major version (X.Y) installed from the MongoDB vendor APT repo. Default 8.0 because MongoDB's 7.0 APT repo only goes through bookworm (Debian 12); the trixie (Debian 13) repo path is `mongodb-org/8.0`. Forcing 7.0 forward-compat onto trixie risks libstdc++ ABI mismatches. 8.0 is GA + supports trixie natively + is wire-compatible with 7.0 clients for our usage (rs.initiate / TLS / keyFile auth unchanged). Pin to specific X.Y.Z by passing -var mongodb_version=8.0.x at packer build time."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU. Default 2 matches the steady-state per-redis-node spec (vms.yaml lines 182-191). Future heavier oltp clusters (patroni 4 vCPU, percona 4 vCPU) get vmrun-resized at clone time via terraform/envs/oltp/."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md (Redis cluster nodes run comfortably at 2 GB in the lab). Other oltp clusters (patroni 4 GB, percona 4 GB, mongo 2 GB) get vmrun-resized at clone time."
}

variable "disk_gb" {
  type        = number
  default     = 40
  description = "Disk size in GB. Default 40 GB sized for the Redis AOF + persistence working set at lab scale. Growable single-file VMDK only consumes what it writes -- larger clusters (patroni's WAL etc.) can be resized at clone time without rebuilding the template."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
  # Build-time only. The 3c role-overlays do not change SSH; ed25519 key auth
  # is configured by the nexus_identity shared role at bake.
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
