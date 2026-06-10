# nexus-infra-oltp / terraform / envs / oltp-patroni / variables.tf
# Per-cluster Patroni PG HA + etcd DCS + HAProxy LB state -- Phase 0.G.4.

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
  description = "Service network (mgmt + PG 5432 + Patroni REST 8008 + etcd client 2379 + HAProxy 5432/8404)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- streaming replication + etcd raft 2380 + Patroni REST cross-calls."
}

# ─── Patroni per-VM toggles + MACs ────────────────────────────────────────

variable "enable_pg_primary" {
  type    = bool
  default = true
}
variable "enable_pg_replica_1" {
  type    = bool
  default = true
}
variable "enable_pg_replica_2" {
  type    = bool
  default = true
}

variable "mac_pg_primary_primary" {
  type        = string
  default     = "00:50:56:3F:00:7E"
  description = "pg-primary VMnet11 NIC MAC. dnsmasq dhcp-host pins this to 192.168.70.61 (Patroni candidate leader)."
}
variable "mac_pg_primary_secondary" {
  type    = string
  default = "00:50:56:3F:01:7E"
}
variable "mac_pg_replica_1_primary" {
  type    = string
  default = "00:50:56:3F:00:7F"
}
variable "mac_pg_replica_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:7F"
}
variable "mac_pg_replica_2_primary" {
  type    = string
  default = "00:50:56:3F:00:80"
}
variable "mac_pg_replica_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:80"
}

# ─── etcd per-VM toggles + MACs ───────────────────────────────────────────

variable "enable_etcd_1" {
  type    = bool
  default = true
}
variable "enable_etcd_2" {
  type    = bool
  default = true
}
variable "enable_etcd_3" {
  type    = bool
  default = true
}

variable "mac_etcd_1_primary" {
  type    = string
  default = "00:50:56:3F:00:81"
}
variable "mac_etcd_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:81"
}
variable "mac_etcd_2_primary" {
  type    = string
  default = "00:50:56:3F:00:82"
}
variable "mac_etcd_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:82"
}
variable "mac_etcd_3_primary" {
  type    = string
  default = "00:50:56:3F:00:83"
}
variable "mac_etcd_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:83"
}

# ─── HAProxy HA pair per-VM toggles + MACs ────────────────────────────────
# Two nodes: haproxy-pg-1 (keepalived MASTER candidate, priority 110) and
# haproxy-pg-2 (BACKUP, priority 100). VRRP-floated VIP `var.haproxy_vip`
# (default 192.168.70.60). Mirrors the 0.G.3 proxysql-1/2 + VIP .50 shape.

variable "enable_haproxy_pg_1" {
  type    = bool
  default = true
}
variable "enable_haproxy_pg_2" {
  type    = bool
  default = true
}

variable "mac_haproxy_pg_1_primary" {
  type    = string
  default = "00:50:56:3F:00:84"
}
variable "mac_haproxy_pg_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:84"
}
variable "mac_haproxy_pg_2_primary" {
  type    = string
  default = "00:50:56:3F:00:85"
}
variable "mac_haproxy_pg_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:85"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-patroni-nftables-backplane.tf -- per-cluster ruleset (22 + 5432 + 8008 + 2379 + 2380 + 8404 + VMnet10 trust) pushed to all 7 patroni-tier nodes."
}

variable "enable_patroni_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-patroni-vault-agents.tf (all 7 hosts -- patroni + etcd + haproxy each get their own Vault Agent)."
}

variable "enable_pg_primary_vault_agent" {
  type    = bool
  default = true
}
variable "enable_pg_replica_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_pg_replica_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_etcd_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_etcd_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_etcd_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_haproxy_pg_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_haproxy_pg_2_vault_agent" {
  type    = bool
  default = true
}

variable "enable_patroni_tls" {
  type        = bool
  default     = true
  description = "role-overlay-patroni-tls.tf -- render 3-file TLS split + per-role KV creds on all 7 nodes."
}

variable "enable_etcd_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-etcd-bootstrap.tf -- one-shot: render etcd.conf.yml on the 3 etcd nodes, start nexus-etcd.service in parallel, wait for leader, `etcdctl auth enable` for RBAC."
}

variable "enable_patroni_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-patroni-bootstrap.tf -- one-shot: render patroni.yml on the 3 Patroni nodes, start nexus-patroni.service in parallel, wait for one PRIMARY + 2 SECONDARY + psql round-trip."
}

variable "enable_patroni_operator_user" {
  type        = bool
  default     = true
  description = "role-overlay-patroni-operator-user.tf -- one-shot idempotent CREATE ROLE nexus-cluster-admin (the dedicated least-priv PostgreSQL operator role the nexus-cli v0.6.3 PatroniAdapter authenticates as). Password lives ONLY in Vault KV (nexus/oltp/patroni/operator-password); read on the leader via the node's own Vault Agent token, never to disk. Mirrors the 0.G.2 mongo + 0.G.3 percona operator-user overlays. Pre-req: nexus-infra-vmware security env applied (operator-password seeded + patroni agent policy v3 grants read)."
}

variable "enable_haproxy_config" {
  type        = bool
  default     = true
  description = "role-overlay-haproxy-config.tf -- render /etc/nexus-haproxy/haproxy.cfg on BOTH haproxy nodes + start nexus-haproxy.service + verify :5432 routes to current Patroni leader via REST /leader health probe."
}

variable "enable_haproxy_keepalived" {
  type        = bool
  default     = true
  description = "role-overlay-haproxy-keepalived.tf -- VRRP VIP $var.haproxy_vip (priority 110/100 for MASTER/BACKUP) between haproxy-pg-1 + haproxy-pg-2 + check_haproxy.sh health script. Mirrors the 0.G.3 proxysql-keepalived overlay; unicast mode (VMware VMnet11 multicast doesn't forward reliably -- baked lesson from 0.G.3.5c chunk 1 transient #22)."
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

variable "vault_agent_patroni_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 7 vault-agent-oltp-patroni-<host>.json AppRole sidecars (3 patroni + 3 etcd + 1 haproxy)."
}

variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}

variable "vault_pki_patroni_role_name" {
  type    = string
  default = "patroni-server"
}

variable "patroni_scope" {
  type        = string
  default     = "nexus-pg"
  description = "Patroni cluster scope (etcd key prefix /service/<scope>/ + DCS namespace). All 3 Patroni nodes share this; etcd-side stores leader lease + history under /service/nexus-pg/."
}

variable "haproxy_vip" {
  type        = string
  default     = "192.168.70.60"
  description = "VRRP-floated VIP between the 2 HAProxy nodes (haproxy-pg-1 MASTER candidate at priority 110, haproxy-pg-2 BACKUP at priority 100). Apps connect here on :5432; HAProxy routes to current Patroni leader. Mirrors the 0.G.3 proxysql_vip .50 pattern."
}
