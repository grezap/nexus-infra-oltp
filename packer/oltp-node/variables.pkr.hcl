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
  default     = "oltp-node"
  description = "VM display name and output .vmx basename. Default `oltp-node` -- the template; per-clone names (redis-1..6, mongo-1/2/3, percona-1..5, patroni-N, etcd-N, haproxy-1) are set by terraform/envs/oltp/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/oltp-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/debian-13.4.0-amd64-netinst.iso"
  description = "Debian 13 netinst ISO. Same pin as nexus-infra-kafka/packer/kafka-node + nexus-infra-vmware/packer/{deb13,vault} + nexus-infra-swarm-nomad/packer/swarm-node. Override via `-var iso_url=H:/VMS/ISO/debian-13-amd64-netinst.iso` to consume the local cache per memory/project_iso_directory.md (operator's H:\\VMS\\ISO\\) -- Packer's content-addressed cache under packer_cache/ also avoids re-download across builds."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:0b813535dd76f2ea96eff908c65e8521512c92a0631fd41c95756ffd7d4896dc"
  description = "ISO checksum (literal sha256). Same hash as deb13/vault/swarm-node/kafka-node -- all pin Debian 13.4.0 netinst."
}

variable "redis_version" {
  type        = string
  default     = "apt-default"
  description = "Redis version source. `apt-default` (the default) installs Debian 13's bundled redis-server package (currently 7.4.x). To pin a specific upstream version, override to that version string and replace the apt task in ansible/roles/oltp_redis/tasks/main.yml with the redis vendor repo (packages.redis.io) -- not wired in 0.G.1 because the apt default is sufficient for the 6-node cluster (no Redis 7.2+-only features used)."
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
