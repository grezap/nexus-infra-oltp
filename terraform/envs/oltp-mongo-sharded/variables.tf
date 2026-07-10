# nexus-infra-oltp / terraform / envs / oltp-mongo-sharded / variables.tf

variable "template_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform\\_templates"
}

variable "vm_output_dir_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform"
}

variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}

variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}

variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles ───────────────────────────────────────────────────────
variable "enable_mongo_cfg_1" {
  type    = bool
  default = true
}
variable "enable_mongo_cfg_2" {
  type    = bool
  default = true
}
variable "enable_mongo_cfg_3" {
  type    = bool
  default = true
}
variable "enable_mongo_shard_1_1" {
  type    = bool
  default = true
}
variable "enable_mongo_shard_1_2" {
  type    = bool
  default = true
}
variable "enable_mongo_shard_1_3" {
  type    = bool
  default = true
}
variable "enable_mongo_shard_2_1" {
  type    = bool
  default = true
}
variable "enable_mongo_shard_2_2" {
  type    = bool
  default = true
}
variable "enable_mongo_shard_2_3" {
  type    = bool
  default = true
}
variable "enable_mongo_mongos_1" {
  type    = bool
  default = true
}
variable "enable_mongo_mongos_2" {
  type    = bool
  default = true
}

# ─── Per-VM MACs ─ MUST match foundation env's mac_oltp_mongo_*_primary defaults
variable "mac_mongo_cfg_1_primary" {
  type    = string
  default = "00:50:56:3F:00:C0"
}
variable "mac_mongo_cfg_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:8A"
}
variable "mac_mongo_cfg_2_primary" {
  type    = string
  default = "00:50:56:3F:00:C1"
}
variable "mac_mongo_cfg_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:8B"
}
variable "mac_mongo_cfg_3_primary" {
  type    = string
  default = "00:50:56:3F:00:C2"
}
variable "mac_mongo_cfg_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:8C"
}
variable "mac_mongo_shard_1_1_primary" {
  type    = string
  default = "00:50:56:3F:00:C3"
}
variable "mac_mongo_shard_1_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:8D"
}
variable "mac_mongo_shard_1_2_primary" {
  type    = string
  default = "00:50:56:3F:00:C4"
}
variable "mac_mongo_shard_1_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:8E"
}
variable "mac_mongo_shard_1_3_primary" {
  type    = string
  default = "00:50:56:3F:00:C5"
}
variable "mac_mongo_shard_1_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:8F"
}
variable "mac_mongo_shard_2_1_primary" {
  type    = string
  default = "00:50:56:3F:00:C6"
}
variable "mac_mongo_shard_2_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:90"
}
variable "mac_mongo_shard_2_2_primary" {
  type    = string
  default = "00:50:56:3F:00:C7"
}
variable "mac_mongo_shard_2_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:91"
}
variable "mac_mongo_shard_2_3_primary" {
  type    = string
  default = "00:50:56:3F:00:C8"
}
variable "mac_mongo_shard_2_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:92"
}
variable "mac_mongo_mongos_1_primary" {
  type    = string
  default = "00:50:56:3F:00:C9"
}
variable "mac_mongo_mongos_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:93"
}
variable "mac_mongo_mongos_2_primary" {
  type    = string
  default = "00:50:56:3F:00:CA"
}
variable "mac_mongo_mongos_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:94"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────

variable "enable_nftables_backplane" {
  type    = bool
  default = true
}

variable "enable_mongo_keyfile" {
  type        = bool
  default     = true
  description = "Distribute the shared keyFile (sourced from Vault KV nexus/oltp/mongo/keyfile) to all 11 sharded-mongo nodes."
}

variable "enable_mongo_config" {
  type        = bool
  default     = true
  description = "Render mongod.conf / mongos.conf on each node and start the engine (nexus-mongo.service / nexus-mongos.service)."
}

variable "enable_mongo_rs_initiate" {
  type        = bool
  default     = true
  description = "Initialize the 3 replica sets (config, shard-1, shard-2). Idempotent probe-then-init."
}

variable "enable_mongo_add_shards" {
  type        = bool
  default     = true
  description = "After all 3 RSes are healthy + mongos pair is up, run sh.addShard for shard-1 + shard-2 via mongos."
}

# ─── Phase 0.N.1 — wire mTLS toggles ──────────────────────────────────────
variable "enable_mongo_vault_agents" {
  type        = bool
  default     = true
  description = "0.N.1: install a per-host Vault Agent (nexus-vault-agent.service) on all 11 sharded-mongo nodes (reads the vault-agent-oltp-mongo-sharded-<host>.json sidecars from the security env)."
}

variable "enable_mongo_tls" {
  type        = bool
  default     = true
  description = "0.N.1: render per-host PKI leaf certs (server.pem + ca.crt) via the Vault Agent + enable requireTLS in mongod.conf/mongos.conf. Requires enable_mongo_vault_agents."
}

# ─── Operator / cross-env vars ────────────────────────────────────────────

variable "vault_agent_version" {
  type        = string
  default     = "1.18.5"
  description = "0.N.1: Vault Agent binary version installed on each sharded-mongo node (matches every prior tier)."
}

variable "vault_agent_mongo_sharded_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "0.N.1: build-host dir holding the 11 vault-agent-oltp-mongo-sharded-<host>.json AppRole sidecars (written by the security env)."
}

variable "vault_pki_mongo_sharded_role_name" {
  type        = string
  default     = "mongo-sharded-server"
  description = "0.N.1: PKI role under pki_int/ for the sharded-mongo leaf certs (created by the security env's role-overlay-vault-pki-mongo-sharded.tf)."
}

variable "oltp_node_user" {
  type    = string
  default = "nexusadmin"
}

variable "oltp_cluster_timeout_minutes" {
  type    = number
  default = 20
}

variable "vault_addr" {
  type        = string
  default     = "https://192.168.70.121:8200"
  description = "Vault address used by the keyfile-fetch step on the build host (sources nexus/oltp/mongo/keyfile)."
}

variable "vault_ca_bundle_path" {
  type    = string
  default = "~/.nexus/vault-ca-bundle.crt"
}

variable "vault_init_keys_path" {
  type        = string
  default     = "~/.nexus/vault-init.json"
  description = "Path to the Vault init keys JSON (provides the root token used by the build host to fetch the keyFile from KV)."
}
