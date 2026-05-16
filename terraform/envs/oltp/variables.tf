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

variable "vmrun_path" {
  type        = string
  default     = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
  description = "Absolute path to vmrun.exe (used by modules/vm)."
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + Redis client traffic on 6379)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- Redis Cluster bus (16379) + replication traffic. Static IP per hostname in oltp-node-firstboot.sh."
}

# ─── Per-VM toggles for the Redis cluster ─────────────────────────────────
variable "enable_redis_1" {
  type    = bool
  default = true
}
variable "enable_redis_2" {
  type    = bool
  default = true
}
variable "enable_redis_3" {
  type    = bool
  default = true
}
variable "enable_redis_4" {
  type    = bool
  default = true
}
variable "enable_redis_5" {
  type    = bool
  default = true
}
variable "enable_redis_6" {
  type    = bool
  default = true
}

# --- Per-cluster MAC variables ----------------------------------------------
# Allocated from the 0.G MAC pool :70-:88. Concrete `mac_<vm>` variables land
# per sub-phase as their cluster module blocks are added.
#
# Primary MACs MUST match nexus-infra-vmware/terraform/envs/foundation/
# role-overlay-gateway-oltp-reservations.tf's var.mac_oltp_redis_N_primary
# defaults -- dnsmasq dhcp-host reservations there pin these MACs to the
# canonical VMnet11 IPs (.81-.84/.87/.89). Secondary MACs are oltp-env-owned
# (VMnet10 is static-IP per firstboot; no DHCP server).
#
# Convention (per nexus-infra-kafka): fifth byte 0x00 = primary NIC, 0x01 =
# secondary NIC; sixth byte = VM id matched across both NICs.

variable "mac_redis_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:70"
  description = "redis-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.81."
}
variable "mac_redis_1_secondary" {
  type        = string
  default     = "00:50:56:3F:01:70"
  description = "redis-1 secondary NIC MAC (VMnet10). oltp-node-firstboot.sh assigns 192.168.10.81 statically."
}
variable "mac_redis_2_primary" {
  type    = string
  default = "00:50:56:3F:00:71"
}
variable "mac_redis_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:71"
}
variable "mac_redis_3_primary" {
  type    = string
  default = "00:50:56:3F:00:72"
}
variable "mac_redis_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:72"
}
variable "mac_redis_4_primary" {
  type    = string
  default = "00:50:56:3F:00:73"
}
variable "mac_redis_4_secondary" {
  type    = string
  default = "00:50:56:3F:01:73"
}
variable "mac_redis_5_primary" {
  type    = string
  default = "00:50:56:3F:00:74"
}
variable "mac_redis_5_secondary" {
  type    = string
  default = "00:50:56:3F:01:74"
}
variable "mac_redis_6_primary" {
  type    = string
  default = "00:50:56:3F:00:75"
}
variable "mac_redis_6_secondary" {
  type    = string
  default = "00:50:56:3F:01:75"
}

# ─── Per-overlay toggles for the Redis cluster (chunk 3c) ─────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "role-overlay-oltp-nftables-backplane.tf -- push the oltp-node nftables ruleset (whole-segment VMnet10 trust + Redis 6379 + cluster-bus 16379 on VMnet11)."
}

variable "enable_redis_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-redis-vault-agents.tf -- install nexus-vault-agent.service on all 6 redis nodes. Reads the per-host AppRole sidecars written by nexus-infra-vmware's security env."
}

variable "enable_redis_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_redis_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_redis_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_redis_4_vault_agent" {
  type    = bool
  default = true
}
variable "enable_redis_5_vault_agent" {
  type    = bool
  default = true
}
variable "enable_redis_6_vault_agent" {
  type    = bool
  default = true
}

variable "enable_redis_tls" {
  type        = bool
  default     = true
  description = "role-overlay-redis-tls.tf -- drop the Vault Agent PKI template that renders /etc/nexus-redis/tls/{server.crt,server.key,ca.crt} on each redis node. Default true. Redis 7.x boots TLS-only from cold start (no PLAINTEXT->mTLS flip needed -- certs are present before redis-server starts). Set false to skip the cert render (e.g. iterating on the redis-config overlay alone)."
}

variable "enable_redis_config" {
  type        = bool
  default     = true
  description = "role-overlay-redis-config.tf -- render /etc/nexus-redis/redis.conf per-node (cluster-announce-ip = VMnet11 IP, tls-port 6379, tls-cluster yes, cluster-config-file, appendonly yes), enable + start nexus-redis.service, verify per-node TLS PING. Default true."
}

variable "enable_redis_cluster_create" {
  type        = bool
  default     = true
  description = "role-overlay-redis-cluster-create.tf -- one-shot probe-then-create: detects cluster_state:ok via `cluster info` and no-ops if already formed; else runs `redis-cli --cluster create --tls --cacert ... redis-1:6379 ... redis-6:6379 --cluster-replicas 1 --cluster-yes` from redis-1, then asserts a cross-shard MSET/MGET round-trip. Default true."
}

# ─── Operator + timing ────────────────────────────────────────────────────

variable "oltp_node_user" {
  type        = string
  default     = "nexusadmin"
  description = "SSH username on every oltp-node clone."
}

variable "oltp_cluster_timeout_minutes" {
  type        = number
  default     = 20
  description = "Per-node readiness timeout (SSH echo + firstboot marker + service-active probe) in the bring-up overlays."
}

# ─── Phase 0.G.1 — Vault Agent + PKI cross-env coupling ───────────────────
#
# The Vault-side state (pki_int/roles/redis-server + 6 per-host AppRoles +
# JSON sidecars) is owned by nexus-infra-vmware's security env. Operator
# order:
#   1. nexus-infra-vmware: pwsh -File scripts/security.ps1 apply
#      (creates the 6 redis AppRole sidecars + the redis-server PKI role)
#   2. nexus-infra-oltp:   pwsh -File scripts/oltp.ps1 apply
#      (this env consumes the sidecars + CA bundle)

variable "vault_agent_version" {
  type        = string
  default     = "1.18.4"
  description = "Vault binary version to install on each redis node as nexus-vault-agent.service. Matches nexus-infra-vmware + nexus-infra-kafka + nexus-infra-swarm-nomad's vault_agent_version (canonical lab version)."
}

variable "vault_agent_redis_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 6 vault-agent-oltp-redis-<host>.json AppRole sidecars (written by nexus-infra-vmware security env's role-overlay-vault-agent-redis-approles.tf). Each carries role_id + secret_id + CA path + vault address. Mode 0700 owner-only via icacls."
}

variable "vault_pki_ca_bundle_path" {
  type        = string
  default     = "$HOME/.nexus/vault-ca-bundle.crt"
  description = "Path on the build host to the Vault PKI root+intermediate CA bundle (written by nexus-infra-vmware security env at 0.D.2). Each redis node's Vault Agent uses it to verify the vault server cert."
}

variable "vault_pki_redis_role_name" {
  type        = string
  default     = "redis-server"
  description = "Name of the Vault PKI role under pki_int/ that issues leaf certs for the 6-node Redis cluster. Must match var.vault_pki_redis_role_name in nexus-infra-vmware's security env."
}
