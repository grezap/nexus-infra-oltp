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

# ─── Phase 0.G.2 — MongoDB Replica Set (3 nodes) ──────────────────────────
# Per nexus-platform-plan/docs/infra/vms.yaml (cluster: mongo, phase: 0.G).
# Per-VM toggles + MACs + overlay toggles. Primary MACs MUST match
# nexus-infra-vmware foundation env's mac_oltp_mongo_N_primary defaults
# (the dhcp-host reservations pin those MACs to .71/.72/.73 on VMnet11).

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

variable "mac_mongo_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:76"
  description = "mongo-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.71."
}
variable "mac_mongo_1_secondary" {
  type        = string
  default     = "00:50:56:3F:01:76"
  description = "mongo-1 secondary NIC MAC (VMnet10). oltp-node-firstboot.sh assigns 192.168.10.71 statically."
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

# ─── Per-overlay toggles for the Mongo cluster (chunk 3c) ─────────────────

variable "enable_mongo_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-mongo-vault-agents.tf -- install nexus-vault-agent.service on all 3 mongo nodes. Reads the per-host AppRole sidecars written by nexus-infra-vmware's security env."
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
  description = "role-overlay-mongo-tls.tf -- drop the Vault Agent PKI template that renders /etc/nexus-mongo/{server.pem,ca.crt} + the keyFile template that renders /etc/nexus-mongo/keyfile from Vault KV (nexus/oltp/mongo/keyfile sticky-seed). Default true."
}

variable "enable_mongo_config" {
  type        = bool
  default     = true
  description = "role-overlay-mongo-config.tf -- render /etc/nexus-mongo/mongod.conf per-node (bind_ip_all + net.tls.mode=requireTLS + replication.replSetName=nexus-rs + security.keyFile + cluster announce IP). Default true."
}

variable "enable_mongo_rs_initiate" {
  type        = bool
  default     = true
  description = "role-overlay-mongo-rs-initiate.tf -- one-shot probe-then-init: detect via `mongosh --eval rs.status()` whether the RS exists; if not, run rs.initiate({_id:'nexus-rs', members:[mongo-1, mongo-2, mongo-3]}) from mongo-1; assert rs.status() shows 1 PRIMARY + 2 SECONDARY. Default true."
}

# ─── Phase 0.G.2 — Mongo Vault Agent + PKI cross-env coupling ─────────────

variable "vault_agent_mongo_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 3 vault-agent-oltp-mongo-<host>.json AppRole sidecars (written by nexus-infra-vmware security env's role-overlay-vault-agent-mongo-approles.tf)."
}

variable "vault_pki_mongo_role_name" {
  type        = string
  default     = "mongo-server"
  description = "Name of the Vault PKI role under pki_int/ that issues leaf certs for the 3-node MongoDB Replica Set. Must match var.vault_pki_mongo_role_name in nexus-infra-vmware's security env."
}

# ─── Phase 0.G.3 — Percona XtraDB Cluster + ProxySQL ──────────────────────
# Per-VM toggles + MACs + overlay toggles. Primary MACs MUST match
# nexus-infra-vmware foundation env's mac_oltp_{pxc_N,proxysql_N}_primary
# defaults (the dhcp-host reservations pin those MACs to .51-.55 on VMnet11).

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
variable "enable_proxysql_1" {
  type    = bool
  default = true
}
variable "enable_proxysql_2" {
  type    = bool
  default = true
}

variable "mac_pxc_node_1_primary" {
  type        = string
  default     = "00:50:56:3F:00:79"
  description = "pxc-node-1 primary NIC MAC (VMnet11). dnsmasq dhcp-host pins this to 192.168.70.51. The Galera bootstrap node (`wsrep_cluster_address=gcomm://` flips here on first apply, then back to the full peer list on subsequent applies)."
}
variable "mac_pxc_node_1_secondary" {
  type        = string
  default     = "00:50:56:3F:01:79"
  description = "pxc-node-1 secondary NIC MAC (VMnet10). oltp-node-firstboot.sh assigns 192.168.10.51 statically -- Galera SST/IST replication runs on the backplane to keep multi-GB transfers off the service NIC."
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

# ─── Per-overlay toggles for the Percona cluster (chunks 3b/3c/3d) ───────

variable "enable_percona_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-percona-vault-agents.tf -- install nexus-vault-agent.service on all 5 nodes (3 PXC + 2 ProxySQL). Reads the per-host AppRole sidecars written by nexus-infra-vmware's security env (vault-agent-oltp-percona-<host>.json)."
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
  description = "role-overlay-percona-tls.tf (chunk 3b) -- drop the Vault Agent PKI template that renders /etc/nexus-percona/{server.pem,client.pem,ca.crt} + KV templates that render the 4 cluster creds (cluster-password, monitor-password, root-password, proxysql-admin-password) from Vault KV (nexus/oltp/percona/* sticky-seeds). Default true."
}

variable "enable_percona_config" {
  type        = bool
  default     = true
  description = "role-overlay-percona-config.tf (chunk 3b) -- render /etc/nexus-percona/my.cnf + /etc/nexus-percona/wsrep.cnf per PXC node (wsrep_provider, wsrep_cluster_address full peer list on VMnet10 backplane, wsrep_node_name, wsrep_sst_method=xtrabackup-v2, MySQL TLS on 3306, performance_schema tuning for 8 GB RAM). Default true."
}

variable "enable_galera_cluster_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-percona-galera-bootstrap.tf (chunk 3c) -- one-shot probe-then-bootstrap: detect via `mysql -e \"SHOW STATUS LIKE 'wsrep_cluster_size'\"` whether the cluster is already formed; if not, run `galera_new_cluster` on pxc-node-1 + create wsrep_sst/clustercheck/root users + start mysql.service on pxc-node-2 + pxc-node-3 to join via SST. Assert wsrep_cluster_size=3 + wsrep_local_state_comment=Synced on all 3. Default true."
}

variable "enable_proxysql_config" {
  type        = bool
  default     = true
  description = "role-overlay-proxysql-config.tf (chunk 3d) -- render /etc/proxysql.cnf per ProxySQL node (mysql_servers pointing at all 3 PXC nodes, mysql_galera_hostgroups with writer/reader/backup-writer/offline-soft splits, mysql_users for app + monitor, admin-admin_credentials from KV nexus/oltp/percona/proxysql-admin-password). Default true."
}

variable "enable_keepalived_vip" {
  type        = bool
  default     = true
  description = "role-overlay-proxysql-keepalived.tf (chunk 3d) -- install + configure keepalived on both ProxySQL nodes with VRRP between them (instance id 51, virtual_ipaddress 192.168.70.50/24, advert_int 1, priority 110 on proxysql-1 / 100 on proxysql-2, authentication via cluster-password KV). Health script checks ProxySQL is serving on :6033 before claiming MASTER. Default true."
}

# ─── Phase 0.G.3 — Percona Vault Agent + PKI cross-env coupling ──────────

variable "vault_agent_percona_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 5 vault-agent-oltp-percona-<host>.json AppRole sidecars (3 PXC + 2 ProxySQL), written by nexus-infra-vmware security env's role-overlay-vault-agent-percona-approles.tf."
}

variable "vault_pki_percona_role_name" {
  type        = string
  default     = "percona-server"
  description = "Name of the Vault PKI role under pki_int/ that issues leaf certs for the 3 PXC + 2 ProxySQL nodes. Must match var.vault_pki_percona_role_name in nexus-infra-vmware's security env."
}

variable "proxysql_vip" {
  type        = string
  default     = "192.168.70.50"
  description = "VRRP-floated virtual IP that lands on whichever ProxySQL node is currently keepalived MASTER. Apps connect to this VIP on :6033 (ProxySQL's MySQL frontend). Per nexus-platform-plan/docs/infra/vms.yaml percona.virtual_ips.proxysql_vip."
}
