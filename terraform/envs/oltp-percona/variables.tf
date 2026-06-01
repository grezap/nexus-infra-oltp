# nexus-infra-oltp / terraform / envs / oltp-percona / variables.tf
# Per-cluster Percona XtraDB Cluster + ProxySQL state -- Phase 0.G.3.5b.

# --- Shared paths -----------------------------------------------------------

variable "template_root" {
  type        = string
  default     = "H:\\VMS\\NexusPlatform\\_templates"
  description = "Root directory of Packer-built .vmx templates."
}

variable "vm_output_dir_root" {
  type        = string
  default     = "H:\\VMS\\NexusPlatform"
  description = "Root directory under which per-VM clone subdirs live."
}

variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + MySQL 3306 + ProxySQL 6032/6033 + VRRP)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- Galera SST/IST runs here (ports 4444/4567/4568)."
}

# ─── PXC per-VM toggles + MACs ────────────────────────────────────────────

variable "enable_pxc_node_1" {
  type    = bool
  default = true
}
variable "enable_pxc_node_2" {
  type    = bool
  default = true
}
variable "enable_pxc_node_3" {
  type    = bool
  default = true
}

variable "mac_pxc_node_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:79"
  description = "pxc-node-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.51 (Galera bootstrap candidate)."
}
variable "mac_pxc_node_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:79"
}
variable "mac_pxc_node_2_primary" {
  type    = string
  default = "00:50:56:3F:00:7A"
}
variable "mac_pxc_node_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:7A"
}
variable "mac_pxc_node_3_primary" {
  type    = string
  default = "00:50:56:3F:00:7B"
}
variable "mac_pxc_node_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:7B"
}

# ─── ProxySQL per-VM toggles + MACs ───────────────────────────────────────

variable "enable_proxysql_1" {
  type    = bool
  default = true
}
variable "enable_proxysql_2" {
  type    = bool
  default = true
}

variable "mac_proxysql_1_primary" {
  type    = string
  default = "00:50:56:3F:00:7C"
}
variable "mac_proxysql_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:7C"
}
variable "mac_proxysql_2_primary" {
  type    = string
  default = "00:50:56:3F:00:7D"
}
variable "mac_proxysql_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:7D"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-percona-nftables-backplane.tf -- per-cluster ruleset (22 + 3306 + 6032 + 6033 + VRRP proto 112 + VMnet10 trust) pushed to all 5 percona-tier nodes."
}

variable "enable_percona_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-percona-vault-agents.tf."
}

variable "enable_pxc_node_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_pxc_node_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_pxc_node_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_proxysql_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_proxysql_2_vault_agent" {
  type    = bool
  default = true
}

variable "enable_percona_tls" {
  type        = bool
  default     = true
  description = "role-overlay-percona-tls.tf -- render 3-file TLS split + 3 KV cluster-creds per node."
}

variable "enable_percona_config" {
  type        = bool
  default     = true
  description = "role-overlay-percona-config.tf -- render /etc/nexus-percona/my.cnf + wsrep.cnf on the 3 PXC nodes."
}

variable "enable_galera_cluster_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-percona-galera-bootstrap.tf -- one-shot: bootstrap pxc-node-1, create wsrep_sst/clustercheck/smoke-rw users, start joiners 2+3 via SST, rolling-restart node-1 bootstrap.service -> nexus-percona.service. v3 bootstrap ordering per 0.G.3 ratification transient #15."
}

variable "enable_proxysql_config" {
  type        = bool
  default     = true
  description = "role-overlay-proxysql-config.tf -- render /etc/proxysql.cnf on the 2 ProxySQL nodes + start nexus-proxysql.service + verify 3-backend convergence."
}

variable "enable_keepalived_vip" {
  type        = bool
  default     = true
  description = "role-overlay-proxysql-keepalived.tf -- VRRP VIP $var.proxysql_vip (priority 110/100 for MASTER/BACKUP) between proxysql-1/proxysql-2 + check_proxysql.sh health script."
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

variable "vault_agent_percona_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 5 vault-agent-oltp-percona-<host>.json AppRole sidecars (3 PXC + 2 ProxySQL)."
}

variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}

variable "vault_pki_percona_role_name" {
  type    = string
  default = "percona-server"
}

variable "proxysql_vip" {
  type        = string
  default     = "192.168.70.50"
  description = "VRRP-floated VIP between the 2 ProxySQL nodes. Apps connect here on :6033."
}
