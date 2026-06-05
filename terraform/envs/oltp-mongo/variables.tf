# nexus-infra-oltp / terraform / envs / oltp-mongo / variables.tf
# Per-cluster MongoDB state -- Phase 0.G.3.5b refactor.

# --- Shared paths -----------------------------------------------------------

variable "template_root" {
  type        = string
  description = "Root directory of Packer-built .vmx templates."
  default     = "H:\\VMS\\NexusPlatform\\_templates"
}

variable "vm_output_dir_root" {
  type        = string
  description = "Root directory under which per-VM clone subdirs live."
  default     = "H:\\VMS\\NexusPlatform"
}

variable "vmrun_path" {
  type        = string
  default     = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
  description = "Absolute path to vmrun.exe."
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + MongoDB TLS data on 27017)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane (reserved for future scale-out)."
}

# ─── Per-VM toggles ───────────────────────────────────────────────────────
variable "enable_mongo_1" {
  type    = bool
  default = true
}
variable "enable_mongo_2" {
  type    = bool
  default = true
}
variable "enable_mongo_3" {
  type    = bool
  default = true
}

# Per-VM MACs MUST match foundation env's mac_oltp_mongo_N_primary defaults.
variable "mac_mongo_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:76"
  description = "mongo-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.71 (initial PRIMARY for rs.initiate; RS re-elects after that)."
}
variable "mac_mongo_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:76"
}
variable "mac_mongo_2_primary" {
  type    = string
  default = "00:50:56:3F:00:77"
}
variable "mac_mongo_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:77"
}
variable "mac_mongo_3_primary" {
  type    = string
  default = "00:50:56:3F:00:78"
}
variable "mac_mongo_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:78"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-mongo-nftables-backplane.tf -- push per-cluster nftables ruleset (opens 22 + 27017 + VMnet10 trust) to the 3 mongo nodes."
}

variable "enable_mongo_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-mongo-vault-agents.tf."
}

variable "enable_mongo_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_mongo_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_mongo_3_vault_agent" {
  type    = bool
  default = true
}

variable "enable_mongo_tls" {
  type        = bool
  default     = true
  description = "role-overlay-mongo-tls.tf -- render server.pem (combined leaf+key) + ca.crt + keyfile + smoke-user-password."
}

variable "enable_mongo_config" {
  type        = bool
  default     = true
  description = "role-overlay-mongo-config.tf -- render mongod.conf + enable nexus-mongo.service."
}

variable "enable_mongo_rs_initiate" {
  type        = bool
  default     = true
  description = "role-overlay-mongo-rs-initiate.tf -- one-shot probe-then-init for the 3-member RS + smoke-rw user + write/read round-trip (0.G.2 exit gate)."
}

variable "enable_mongo_operator_user" {
  type        = bool
  default     = true
  description = "role-overlay-mongo-operator-user.tf -- idempotent createUser of the nexus-cluster-admin operator user (clusterMonitor + clusterManager) that the nexus-cli MongoAdapter authenticates as. Password read on-node via the node's own Vault Agent token from nexus/oltp/mongo/operator-password (never written to disk). Pre-req: nexus-infra-vmware/envs/security applied first (operator-password seeded + mongo-agent policy v3 grants read)."
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────

variable "oltp_node_user" {
  type    = string
  default = "nexusadmin"
}

variable "oltp_cluster_timeout_minutes" {
  type    = number
  default = 20
}

variable "vault_agent_version" {
  type    = string
  default = "1.18.5"
}

variable "vault_agent_mongo_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 3 vault-agent-oltp-mongo-<host>.json AppRole sidecars."
}

variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}

variable "vault_pki_mongo_role_name" {
  type    = string
  default = "mongo-server"
}
