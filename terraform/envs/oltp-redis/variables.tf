# nexus-infra-oltp / terraform / envs / oltp-redis / variables.tf
#
# Per-cluster Redis state -- Phase 0.G.3.5b refactor (memory/feedback_per_
# cluster_state_per_engine_template.md). Only redis-relevant vars + shared
# infra vars (template_root / vm_output_dir_root / vmrun / vnets / ssh user /
# Vault Agent + PKI cross-env coupling).

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

variable "vmrun_path" {
  type        = string
  default     = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
  description = "Absolute path to vmrun.exe (used by modules/vm)."
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + Redis TLS data on 6379)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- replication traffic. Static IP per hostname in oltp-node-firstboot.sh."
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

# Per-VM MACs MUST match nexus-infra-vmware foundation env's
# mac_oltp_redis_N_primary defaults (dhcp-host reservations pin those MACs
# to .81/.82/.83/.84/.87/.89 on VMnet11).

variable "mac_redis_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:70"
  description = "redis-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.81 (shard 1 primary)."
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

# ─── Per-overlay toggles for the Redis cluster ────────────────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-redis-nftables-backplane.tf -- push the per-cluster nftables ruleset to the 6 redis nodes (opens 22 + 6379 + 16379 + VMnet10 whole-segment trust)."
}

variable "enable_redis_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-redis-vault-agents.tf -- install nexus-vault-agent.service on all 6 redis nodes."
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
  description = "role-overlay-redis-tls.tf -- drop Vault Agent PKI template that renders /etc/nexus-redis/tls/{server.crt,server.key,ca.crt}."
}

variable "enable_redis_config" {
  type        = bool
  default     = true
  description = "role-overlay-redis-config.tf -- render /etc/nexus-redis/redis.conf per-node + enable nexus-redis.service."
}

variable "enable_redis_cluster_create" {
  type        = bool
  default     = true
  description = "role-overlay-redis-cluster-create.tf -- probe-then-create the Redis Cluster + 4-key cross-shard SET/GET round-trip (0.G.1 exit gate)."
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────

variable "oltp_node_user" {
  type        = string
  default     = "nexusadmin"
  description = "SSH user on every oltp-redis-node clone (set by Packer preseed)."
}

variable "oltp_cluster_timeout_minutes" {
  type        = number
  default     = 20
  description = "Generous timeout for slow per-node convergence steps (firstboot wait, vault-agent install, TLS render, cluster formation)."
}

variable "vault_agent_version" {
  type        = string
  default     = "1.18.5"
  description = "Vault Agent version installed by role-overlay-redis-vault-agents.tf."
}

variable "vault_agent_redis_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 6 vault-agent-oltp-redis-redis-N.json AppRole sidecars (written by nexus-infra-vmware security env's role-overlay-vault-agent-redis-approles.tf)."
}

variable "vault_pki_ca_bundle_path" {
  type        = string
  default     = "$HOME/.nexus/vault-ca-bundle.crt"
  description = "Vault PKI CA bundle on the build host (written by nexus-infra-vmware security env's PKI distribute step)."
}

variable "vault_pki_redis_role_name" {
  type        = string
  default     = "redis-server"
  description = "Name of the Vault PKI role under pki_int/ that issues leaf certs for the 6 Redis nodes. Must match var.vault_pki_redis_role_name in nexus-infra-vmware's security env."
}
