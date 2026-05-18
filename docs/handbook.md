# nexus-infra-oltp operator handbook

> **Status (Phase 0.G.1 + 0.G.2 + 0.G.3 + 0.G.3.5):** ✅ 0.G.1 (Redis) + 0.G.2 (MongoDB)
> **PROVEN cold-rebuildable (2026-05-17)**. 0.G.3 (Percona XtraDB Cluster +
> ProxySQL) scaffolding complete + 16 ratification transients documented in
> §3.x. **0.G.3.5 refactor in flight 2026-05-18**: monolithic
> `packer/oltp-node/` split into 4 per-engine Packer templates
> (`packer/oltp-{redis,mongo,pxc,proxysql}-node/`); monolithic
> `terraform/envs/oltp/` split into 3 per-cluster states
> (`terraform/envs/oltp-{redis,mongo,percona}/`) with per-cluster nftables
> overlays + per-cluster operator scripts (`scripts/oltp-{redis,mongo,percona}.ps1`).
> Per `memory/feedback_per_cluster_state_per_engine_template.md` — iteration
> loop shrinks from ~30 min (14-VM tree apply) to ~5-10 min per cluster
> (6/3/5 VMs). 0.G.3.5a (templates) + 0.G.3.5b (states + scripts) committed;
> 0.G.3.5c (live cold-rebuild + delete legacy + re-ratify Percona transient
> #16) is the next live step. Full destroy → apply → smoke cycle verified
> live for 0.G.1 + 0.G.2 against the legacy monolithic state; 0.G.3 + 0.G.3.5
> ratification status in §2.
>
> Follows the 9-section structure mandated by `feedback_handbook_standard.md`
> invariant 2 (canonical exemplar: [`nexus-infra-kafka/docs/handbook.md`](https://github.com/grezap/nexus-infra-kafka/blob/main/docs/handbook.md)).

## §0 Prerequisites

**What MUST be alive before applying anything in this repo.**

Cross-tier dependencies (in hard-ordering for cold-rebuild):

- **Foundation tier** ([`nexus-infra-vmware/envs/foundation`](https://github.com/grezap/nexus-infra-vmware)) — `nexus-gateway` providing DHCP + DNS via dnsmasq. The OLTP-tier dhcp reservations overlay is **v3 as of 0.G.3** (single-file marker, atomic replace):
  - **0.G.1** (Redis): 6 `dhcp-host` reservations pinning redis-1..6 MACs (`:70-:75`) to `.81/.82/.83/.84/.87/.89` (skip `.85/.86/.88` which belong to kafka).
  - **0.G.2** (Mongo): +3 mongo-1..3 MACs (`:76-:78`) to `.71/.72/.73`.
  - **0.G.3** (Percona + ProxySQL): +5 MACs (`:79-:7D`) pxc-node-1..3 → `.51/.52/.53` + proxysql-1..2 → `.54/.55`. The VIP `.50` is NOT a dhcp reservation -- it floats between proxysql-1/2 via VRRP/keepalived, configured per-node by the oltp env.
  - Owned by `terraform/envs/foundation/role-overlay-gateway-oltp-reservations.tf` (v3).
- **Security tier** ([`nexus-infra-vmware/envs/security`](https://github.com/grezap/nexus-infra-vmware)) — 3-node Vault HA + `vault-transit` auto-unseal. Per-cluster PKI + AppRole + KV state:
  - **0.G.1** (Redis): PKI role `redis-server` (90 d TTL, 21 allowed_domains) + 6 `nexus-agent-redis-N` policies + 6 AppRoles + 6 sidecars at `$HOME\.nexus\vault-agent-oltp-redis-redis-N.json`.
  - **0.G.2** (Mongo): PKI role `mongo-server` + 3 `nexus-agent-mongo-N` policies + 3 AppRoles + 3 sidecars (`vault-agent-oltp-mongo-mongo-N.json`) + 2 KV sticky-seeds (`nexus/oltp/mongo/keyfile` + `nexus/oltp/mongo/smoke-user-password`).
  - **0.G.3** (Percona + ProxySQL): PKI role `percona-server` (90 d TTL, 17 allowed_domains covering pxc-node-1..3 + proxysql-1..2 in bare + .nexus.lab + .percona.nexus.lab forms) + 5 `nexus-agent-pxc-N` + `nexus-agent-proxysql-N` policies (role-differentiated KV grants: PXC reads cluster/monitor/root, ProxySQL reads cluster/monitor/proxysql-admin) + 5 AppRoles + 5 sidecars (`vault-agent-oltp-percona-<host>.json`) + 4 KV sticky-seeds at `nexus/oltp/percona/{cluster,monitor,root,proxysql-admin}-password` (each 32-char hex).
  - Owned by `terraform/envs/security/role-overlay-vault-{pki-{redis,mongo,percona},agent-{redis,mongo,percona}-{policies,approles},mongo-{keyfile,smoke-user}-seed,percona-cluster-creds-seed}.tf`.

**Build-host tools** (pwsh-native per `feedback_build_host_pwsh_native.md` — no `make` required):

- PowerShell 7+ (`winget install --id Microsoft.PowerShell`)
- VMware Workstation Pro 25+ on `H:\`
- Terraform 1.9+
- Packer 1.11+ (1.15.1 tested)
- Ansible (consumed inside the VM by Packer's `ansible-local` provisioner; no local Ansible needed)
- An `ssh-agent` on the build host with the canonical lab SSH key loaded; the operator's `$HOME\.ssh\config` should resolve `redis-N.nexus.lab` via the gateway dnsmasq (or just SSH to IPs)

## §1 Phase walkthrough

### §1.1 Build the Packer template

```pwsh
cd packer\oltp-node
packer init .
packer build .
```

Bake time est. **~40-55 min wall-clock** on a typical lab host (Debian 13 base install + apt update + Redis 7.x + MongoDB 8.0 + **Percona 8.0 + ProxySQL 2.6 + keepalived** + Ansible roles + post-install cleanup -- 0.G.3 added Percona apt repo via `percona-release` + ProxySQL vendor repo + keepalived from Debian main). Disk footprint ~6 GB (Percona + xtrabackup add ~1 GB on top of the 0.G.2 baseline). ISO download cached under `packer_cache/` (unless `-var iso_url=H:/VMS/ISO/...` overrides to a local cache per `memory/project_iso_directory.md`).

Output: `H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx`.

Spot-check the built template before promoting to apply:

```pwsh
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' start H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx nogui
# Wait for boot, then SSH in with the build-time creds:
ssh nexusadmin@<dhcp-assigned-IP>      # password: nexus-packer-build-only
# Expected steady-state inside the template:
systemctl is-active nexus-redis.service             # -> inactive (DISABLED; gates on /etc/nexus-redis/redis.conf)
systemctl is-active nexus-mongo.service             # -> inactive (DISABLED; gates on /etc/nexus-mongo/mongod.conf)
systemctl is-active nexus-percona.service           # -> inactive (DISABLED; gates on /etc/nexus-percona/my.cnf -- 0.G.3)
systemctl is-active nexus-percona-bootstrap.service # -> inactive (DISABLED; only chunk 3c TF triggers this on pxc-node-1 for galera_new_cluster)
systemctl is-active nexus-proxysql.service          # -> inactive (DISABLED; gates on /etc/proxysql.cnf -- 0.G.3)
systemctl is-active oltp-node-firstboot.service     # -> inactive (only runs on a fresh clone, gated by /var/lib/oltp-node-firstboot-done)
systemctl is-enabled redis-server.service           # -> masked (apt-shipped unit defensively masked)
systemctl is-enabled mongod.service                 # -> masked
systemctl is-enabled mysql.service                  # -> masked (Percona apt-shipped; would auto-bootstrap a junk cluster)
systemctl is-enabled proxysql.service               # -> masked (vendor apt-shipped)
redis-server --version                              # -> Redis server v=8.0.x (Debian 13.5 ships Redis 8.0.2)
mongod --version                                    # -> db version v8.0.x
mysqld --version                                    # -> Ver 8.0.x (Percona Server)
xtrabackup --version                                # -> xtrabackup version 8.0.x (Percona; SST method)
proxysql --version                                  # -> ProxySQL 2.6.x
keepalived --version 2>&1 | head -1                 # -> Keepalived v2.x.x
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' stop H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx hard
```

### §1.2 Cross-env operator order

**Hard ordering** (each step gates the next; per `feedback_handbook_standard.md` invariant 1):

```
┌─ [build host] ────────────────────────────────────────────────────────────────┐
│ 1. nexus-infra-vmware\scripts\foundation.ps1 apply                            │
│      adds ALL OLTP-tier dnsmasq dhcp-host reservations on nexus-gateway:      │
│        v1 = 6 redis  (0.G.1)                                                   │
│        v2 = +3 mongo (0.G.2)                                                   │
│        v3 = +5 pxc/proxysql (0.G.3)  <- current marker                         │
│      (Single-file overlay; atomic replace on version bump.)                    │
│                                                                                │
│ 2. nexus-infra-vmware\scripts\security.ps1 apply                              │
│      writes per-cluster Vault state:                                           │
│        0.G.1: pki_int/roles/redis-server + 6 redis policies/AppRoles + 6 sidecars
│        0.G.2: pki_int/roles/mongo-server + 3 mongo policies/AppRoles + 3 sidecars
│               + 2 KV sticky-seeds (keyfile + smoke-user-password)              │
│        0.G.3: pki_int/roles/percona-server + 5 percona policies (role-diff'd  │
│               for PXC vs ProxySQL KV grants) + 5 AppRoles + 5 sidecars +      │
│               4 KV sticky-seeds (cluster + monitor + root + proxysql-admin)    │
│      (All toggles default true; no override needed for steady-state apply.)    │
│                                                                                │
│ 3a. nexus-infra-oltp\scripts\oltp-redis.ps1   apply  (6 VMs;  ~5  min)        │
│ 3b. nexus-infra-oltp\scripts\oltp-mongo.ps1   apply  (3 VMs;  ~5  min)        │
│ 3c. nexus-infra-oltp\scripts\oltp-percona.ps1 apply  (5 VMs;  ~10 min)        │
│      Each script drives its own per-cluster terraform state:                   │
│        envs/oltp-redis/   ← oltp-redis-node.vmx   (Packer-built per-engine)    │
│        envs/oltp-mongo/   ← oltp-mongo-node.vmx                                │
│        envs/oltp-percona/ ← oltp-pxc-node.vmx + oltp-proxysql-node.vmx         │
│      Per-cluster nftables overlays open only that cluster's ports — no cross-  │
│      cluster cascade (per memory/feedback_per_cluster_state_per_engine_template.md).
│                                                                                │
│      The 3 cluster applies are INDEPENDENT (no inter-cluster dep) — run in     │
│      any order, or in parallel terminals. Mongo+Percona apps will later        │
│      consume each other only at the app layer, not at the infra layer.         │
│                                                                                │
│      Legacy monolithic path (DEPRECATED — being removed in 0.G.3.5c):          │
│      nexus-infra-oltp\scripts\oltp.ps1 apply                                  │
│        Single-state apply across all 14 VMs. Cross-cluster cascade risk        │
│        (any version-bumped overlay forces unrelated cluster re-applies). Kept  │
│        until per-cluster envs are live-proven on 0.G.3.5c.                     │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Cannot reorder steps 1→2→3**: each cluster's `*_vault_agent` resource uses `filesha256()` on its sidecar JSON at plan time, so the security env MUST have written them first. A premature `oltp-* apply` fails fast at plan time with `Call to function "filesha256" failed: open ...vault-agent-oltp-{redis,mongo,percona}-<host>.json: The system cannot find the file specified`.

**Within step 3**: 3a/3b/3c are independent — terraform states don't reference each other. The only practical ordering is "Redis before apps" (Redis is the fastest + most-used cache; bring it up first so other smoke tests have something to point at).

### §1.3 Apply (numbered breakdown)

```pwsh
pwsh -File scripts\oltp.ps1 apply
```

The terraform apply produces ~23 resources in a single graph, ordered via `depends_on`:

| # | Resource | What it does |
|---|---|---|
| 1 | `module.redis_1..6.clone_vm` (×6) | `vmrun clone` from `oltp-node.vmx` → per-VM dir under `H:\VMS\NexusPlatform\05-oltp\<host>\`. |
| 2 | `module.redis_1..6.configure_nic` (×6) | Rewrites cloned .vmx with VMnet11 + VMnet10 MACs. |
| 3 | `module.redis_1..6.power_on` (×6) | `vmrun start`. firstboot runs inside the VM (NIC discovery → IP→role map → hostname → /etc/hosts → VMnet10 static → `node-identity.env` → marker). |
| 4 | `null_resource.oltp_nftables_backplane` (×1) | Pushes the inlined nftables ruleset to all 6 nodes + `nft -f`. Waits per-node on `/var/lib/oltp-node-firstboot-done`. |
| 5 | `null_resource.redis_vault_agent` (×6, `for_each`) | Installs Vault binary + 00-base.hcl + role-id/secret-id/CA bundle + nexus-vault-agent.service per node. Verifies token sink populated. |
| 6 | `null_resource.redis_tls` (×6, `for_each`) | Drops 60-template-redis-tls.hcl + redis-tls-split.sh per node, restarts vault-agent, runs split → server.crt + server.key + ca.crt rendered into `/etc/nexus-redis/tls/`. |
| 7 | `null_resource.redis_config` (×6, `for_each`) | Renders per-host redis.conf with `cluster-announce-ip = <VMnet11 IP>` → enables + restarts nexus-redis.service → verifies TLS PING returns PONG. |
| 8 | `null_resource.redis_cluster_create` (×1) | Probe → `cluster_state:ok` ⇒ no-op; else `redis-cli --cluster create --tls ... --cluster-replicas 1 --cluster-yes`. Then 5-axis health verify + 4-key cross-shard SET/GET round-trip. **0.G.1 exit gate.** |
| 9 | `module.mongo_{1,2,3}` + `null_resource.mongo_*` (0.G.2) | 3 VMs + 4 mongo overlays (vault-agents · tls · config · rs-initiate). RS bootstrap via `__system` cluster-auth + smoke-rw user created via RS URI auto-routing. **0.G.2 exit gate.** |
| 10 | `module.pxc_node_{1,2,3}` + `module.proxysql_{1,2}` + 6 percona overlays (0.G.3) | 5 VMs + per-host vault-agents + 3-file TLS split + my.cnf/wsrep.cnf render + galera-cluster-bootstrap (probe→bootstrap pxc-node-1→users→sequential SST joiners) + proxysql-config + keepalived VRRP VIP. **0.G.3 exit gate.** |

Wall-clock: ~10-15 min for 0.G.1 alone; ~20-30 min for the full 14-VM cold-rebuild (0.G.1 + 0.G.2 + 0.G.3 all enabled). Galera SST is the slowest single step (multi-GB transfer over VMnet10 backplane).

### §1.4 Verify the exit gate

```pwsh
pwsh -File scripts\oltp.ps1 smoke -Phase 0.G.1
```

Runs `scripts\smoke-0.G.1.ps1`: ~50 checks across 9 sections (reachability → firstboot → identity → vault-agent → TLS material → redis.conf → nexus-redis.service → TLS listener → cluster health + cross-shard round-trip). Each check echoes `[OK]/[FAIL]`; exits 1 on any failure, 0 on all-green.

Smoke is independent of apply — re-runnable any time against a stable cluster.

### §1.5 Iterating (selective ops)

Per `feedback_selective_provisioning.md` + `feedback_terraform_partial_apply_destroys_resources.md`: every toggle defaults to `true` (steady state). `-Vars` ONLY to opt-OUT.

```pwsh
# Skip the 3 sibling 0.G.* clusters (only Redis active in 0.G.1, but the
# toggles already exist for forward compat with 0.G.2-0.G.7):
pwsh -File scripts\oltp.ps1 apply -Vars enable_mongo=false,enable_percona=false,enable_patroni=false,enable_sql=false

# Iterate on just the cluster-create step (assumes all 6 nodes already up
# with TLS + nexus-redis.service active; useful when re-forming after a
# manual `CLUSTER RESET`):
pwsh -File scripts\oltp.ps1 apply -Vars enable_nftables_backplane=false,enable_redis_vault_agents=false,enable_redis_tls=false,enable_redis_config=false

# Bring up only redis-1/2/3 (no replicas; cluster will fail health gate
# but useful for debugging the master shards in isolation):
pwsh -File scripts\oltp.ps1 apply -Vars enable_redis_4=false,enable_redis_5=false,enable_redis_6=false,enable_redis_cluster_create=false

# Plan-only mode (safe dry run; useful to verify sidecar presence after
# security env re-apply):
pwsh -File scripts\oltp.ps1 plan

# Re-render just one node's redis.conf (e.g. after manual edit drift) --
# the oltp.ps1 wrapper does NOT pass through -target, so drop to terraform
# directly:
cd terraform\envs\oltp
terraform apply -auto-approve -target='null_resource.redis_config["redis-3"]'
cd -

# 0.G.2 -- Bring up only mongo (skip redis + later 0.G.* clusters):
pwsh -File scripts\oltp.ps1 apply -Vars enable_redis=false,enable_percona=false,enable_patroni=false,enable_sql=false

# 0.G.2 -- Skip the rs-initiate step (e.g. when forming the RS manually
# via mongosh for debugging):
pwsh -File scripts\oltp.ps1 apply -Vars enable_mongo_rs_initiate=false

# 0.G.3 -- Bring up only Percona/ProxySQL (skip redis + mongo + later clusters):
pwsh -File scripts\oltp.ps1 apply -Vars enable_redis=false,enable_mongo=false,enable_patroni=false,enable_sql=false

# 0.G.3 -- Bring up PXC nodes only, skip ProxySQL + VIP (useful for
# debugging Galera in isolation):
pwsh -File scripts\oltp.ps1 apply -Vars enable_proxysql_1=false,enable_proxysql_2=false,enable_proxysql_config=false,enable_keepalived_vip=false

# 0.G.3 -- Skip galera-cluster-bootstrap (e.g. when bootstrapping
# Galera manually via systemctl + mysql -e for debugging):
pwsh -File scripts\oltp.ps1 apply -Vars enable_galera_cluster_bootstrap=false

# 0.G.3 -- Skip keepalived VIP (PXC + ProxySQL up but apps hit
# proxysql-1 directly on .54 instead of VIP .50):
pwsh -File scripts\oltp.ps1 apply -Vars enable_keepalived_vip=false
```

### §1.6 Tear down

```pwsh
pwsh -File scripts\oltp.ps1 destroy
```

Destroy ordering is the reverse of apply (cluster-create destroy-time noop → redis_config stops service + removes redis.conf → redis_tls removes cert files + VA template → redis_vault_agent removes 00-base.hcl + creds + unit → nftables noop → module.vm stops + deletes VMs + per-VM dirs).

**Survives across destroy/apply cycles** (preserved for cold-rebuild idempotency per `feedback_cold_rebuild_stale_kv_tokens.md`):

- Gateway dnsmasq reservations (foundation env owns; not touched by oltp destroy)
- Security env's PKI role + AppRole sidecars on the build host
- The `oltp-node.vmx` Packer template (rebuild only if you bump Debian / Redis versions)

**Wiped by destroy**:

- The 6 per-VM dirs under `H:\VMS\NexusPlatform\05-oltp\` (full disk wipe via vmrun deleteVM)
- All cluster state (nodes.conf + AOF live inside the VMs)
- No Vault KV bootstrap-token cleanup needed for 0.G.1 (Redis Cluster has no equivalent to consul/nomad bootstrap tokens; the AppRole secret-ids rotate every security apply anyway)

### §1.7 Per-cluster scripts (Phase 0.G.3.5b)

Three wrappers around the per-cluster terraform states, each mirroring `scripts/oltp.ps1`'s verb shape (`apply | destroy | smoke | cycle | plan | validate`):

| Script | Env | Template(s) | Smoke | VMs | Apply wall-clock |
|---|---|---|---|---|---|
| `scripts/oltp-redis.ps1` | `terraform/envs/oltp-redis/` | `oltp-redis-node.vmx` | `smoke-0.G.1.ps1` | 6 | ~5 min |
| `scripts/oltp-mongo.ps1` | `terraform/envs/oltp-mongo/` | `oltp-mongo-node.vmx` | `smoke-0.G.2.ps1` | 3 | ~5 min |
| `scripts/oltp-percona.ps1` | `terraform/envs/oltp-percona/` | `oltp-pxc-node.vmx` + `oltp-proxysql-node.vmx` | `smoke-0.G.3.ps1` | 5 | ~10 min |

**Full per-cluster cold-rebuild** (post 0.G.3.5c — after legacy `envs/oltp/` deleted):

```pwsh
# Pre-flight: foundation + security envs applied per §0
# Pre-flight: 4 packer templates built (each ~7-8 min)
cd packer\oltp-redis-node    ; packer init . ; packer build .
cd ..\oltp-mongo-node        ; packer init . ; packer build .
cd ..\oltp-pxc-node          ; packer init . ; packer build .
cd ..\oltp-proxysql-node     ; packer init . ; packer build .
cd ..\..\

# Apply each cluster (independent — can run in parallel terminals)
pwsh -File scripts\oltp-redis.ps1   cycle    # destroy → apply → smoke
pwsh -File scripts\oltp-mongo.ps1   cycle
pwsh -File scripts\oltp-percona.ps1 cycle
```

**Per-cluster selective ops** (per `feedback_selective_provisioning.md` — every toggle defaults `true`; `-Vars` is opt-OUT):

```pwsh
# REDIS — 3-node primary set only, no replicas (debugging)
pwsh -File scripts\oltp-redis.ps1 apply -Vars enable_redis_4=false,enable_redis_5=false,enable_redis_6=false,enable_redis_cluster_create=false

# REDIS — re-iterate cluster-create step only (assumes 6 nodes already up)
pwsh -File scripts\oltp-redis.ps1 apply -Vars enable_nftables_backplane=false,enable_redis_vault_agents=false,enable_redis_tls=false,enable_redis_config=false

# MONGO — iterate rs.initiate() one-shot only (assumes 3 nodes + TLS rendered)
pwsh -File scripts\oltp-mongo.ps1 apply -Vars enable_nftables_backplane=false,enable_mongo_vault_agents=false,enable_mongo_tls=false,enable_mongo_config=false

# MONGO — skip rs-initiate (manual mongosh debug)
pwsh -File scripts\oltp-mongo.ps1 apply -Vars enable_mongo_rs_initiate=false

# PERCONA — PXC nodes only, skip ProxySQL + VIP (Galera debugging in isolation)
pwsh -File scripts\oltp-percona.ps1 apply -Vars enable_proxysql_1=false,enable_proxysql_2=false,enable_proxysql_config=false,enable_keepalived_vip=false

# PERCONA — re-iterate galera-cluster-bootstrap one-shot only
pwsh -File scripts\oltp-percona.ps1 apply -Vars enable_nftables_backplane=false,enable_percona_vault_agents=false,enable_percona_tls=false,enable_percona_config=false,enable_proxysql_config=false,enable_keepalived_vip=false

# PERCONA — skip galera bootstrap (manual mysqld + mysql -e debug)
pwsh -File scripts\oltp-percona.ps1 apply -Vars enable_galera_cluster_bootstrap=false

# PERCONA — PXC + ProxySQL up but no VIP (apps hit proxysql-1 directly on .54)
pwsh -File scripts\oltp-percona.ps1 apply -Vars enable_keepalived_vip=false
```

**Per-cluster destroy** is bounded to that cluster only — never touches the other 2:

```pwsh
pwsh -File scripts\oltp-percona.ps1 destroy   # tears down 5 percona VMs; redis + mongo untouched
```

This is the key win over the legacy monolithic `oltp.ps1 destroy` which would tear down all 14 VMs in one shot. **Per-cluster bound destroy = per-cluster bound iteration = ~5-10 min iteration loop vs ~30 min monolithic.**

## §2 Phase status

| Sub-phase | Cluster | TF | Packer | Smoke | Status | Closed |
|---|---|---|---|---|---|---|
| 0.G.1 | Redis Cluster (6 nodes) | `terraform/envs/oltp/` ✅ | `packer/oltp-node/` ✅ | `smoke-0.G.1.ps1` ✅ | ✅ PROVEN cold-rebuildable (2026-05-17) | 2026-05-17 |
| 0.G.2 | MongoDB RS (3 nodes) | `terraform/envs/oltp/` (mongo overlays) ✅ | `packer/oltp-node/` (extended with oltp_mongo role) ✅ | `smoke-0.G.2.ps1` ✅ | ✅ PROVEN warm + cold-rebuild (2026-05-17) | 2026-05-17 |
| 0.G.3 | Percona PXC + ProxySQL (5 nodes) | `terraform/envs/oltp/` (6 percona overlays) ✅ | `packer/oltp-node/` (extended with oltp_pxc + oltp_proxysql roles + 3 systemd units) ✅ | `scripts/smoke-0.G.3.ps1` ✅ | ⚠️ scaffolding complete + 16 ratification transients documented in §3.x; **live ratification deferred to Phase 0.G.3.5** (the monolithic oltp template + envs/oltp state proved too brittle; refactor splits into per-engine templates + per-cluster states per `memory/feedback_per_cluster_state_per_engine_template.md`) | 2026-05-18 (scaffolding); 0.G.3.5 follow-up |
| 0.G.3.5a | per-engine Packer template refactor (4 NEW) | — | `packer/oltp-{redis,mongo,pxc,proxysql}-node/` ✅ | inherits per-engine smoke | ✅ template sources committed; bake time ~7-8 min each (smaller than monolithic ~40-55 min); 0.G.3.5c is the live bake + cold-rebuild | 2026-05-18 (sources) |
| 0.G.3.5b | per-cluster Terraform state refactor (3 NEW) | `terraform/envs/oltp-{redis,mongo,percona}/` ✅ | reuses per-engine templates from 0.G.3.5a | inherits per-cluster smoke (`smoke-0.G.{1,2,3}.ps1`) | ✅ 3 envs scaffolded + `terraform init/validate/fmt -check` clean; 3 operator wrappers (`scripts/oltp-{redis,mongo,percona}.ps1`) ✅; live cycle deferred to 0.G.3.5c | 2026-05-18 (scaffolding) |
| 0.G.3.5c | live cold-rebuild + Percona transient #16 + delete legacy | reuses 0.G.3.5b states | rebuilds via 0.G.3.5a templates | smoke gates per cluster | pending: packer build ×4 → destroy legacy `envs/oltp/` → apply 3 per-cluster envs → smoke ×3 → re-ratify Percona xtrabackup SST → delete legacy `packer/oltp-node/` + `terraform/envs/oltp/` + `scripts/oltp.ps1` | — |
| 0.G.4 | Patroni + etcd + HAProxy (7 nodes) | TBD | NEW oltp-patroni-node + oltp-etcd-node + oltp-haproxy-node (per-engine pattern from 0.G.3.5a) | `smoke-0.G.4.ps1` | not started | — |
| 0.G.7 | SQL Server FCI + AG (4 ws2025 nodes) | TBD | NEW ws2025 template | `smoke-0.G.7.ps1` | not started | — |

(0.G.5 ClickHouse + 0.G.6 StarRocks belong to the sibling `nexus-infra-analytics` repo.)

## §3 Operator runbooks

### §3.1 Cold-rebuild canon

**Status: PROVEN (2026-05-17).** Cycle runs end-to-end with one well-known retry point (vmrun transient on `power_on`; see §3.x). The canonical sequence:

```pwsh
# 1. Tear down everything below this tier (preserves foundation + security state)
cd <repo-root>\workspace\nexus-infra-oltp
pwsh -File scripts\oltp.ps1 destroy

# 2. Re-apply (foundation + security stay live; this clones + brings up cold)
pwsh -File scripts\oltp.ps1 apply

# 3. Smoke
pwsh -File scripts\oltp.ps1 smoke -Phase 0.G.1
```

Wall-clock observed at ratification: destroy 30 s, apply 4 m 21 s (first attempt; redis-5 hit vmrun "Unknown error" — retry took another ~3 min), smoke 23 s. **Total ~8-12 min cold-rebuild** including the one retry. Fresh `packer build` (when the template doesn't exist or needs updating) adds ~7-8 min on top — see §1.1.

Operator ratification checklist — all 3 verified 2026-05-17:

- [x] Step 1 destroy: 38 resources destroyed; all 6 VMs gone from `H:\VMS\NexusPlatform\05-oltp\`; `terraform state list` empty.
- [x] Step 2 apply: returns exit 0 (after one retry on the vmrun transient — see §3.x row for `vmrun start ... .vmx: Error: Unknown error`); `terraform output redis_endpoints` shows all 6 nodes.
- [x] Step 3 smoke: all ~50 checks across 9 sections PASS; exit 0 with `ALL 0.G.1 SMOKE CHECKS PASSED` (`cluster_state:ok` + size=3 + known=6 + slots=16384 + 3 masters + 3 replicas + cross-shard SET/GET round-trip via `redis-cli -c`).

If a step fails (other than the documented vmrun transient that clears on retry), see §3.x below for the symptom→diagnosis→recovery table — 13 rows covering every transient surfaced during ratification.

### §3.2 Build host reboot recovery

Per `memory/feedback_vault_transit_boot_race_recovery.md`, the upstream vault cluster can lose its transit-seal on host reboot. Before any `oltp apply` after a build-host reboot, verify Vault is alive:

```pwsh
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1 smoke -Phase 0.D.5
# If vault is sealed: pwsh -File ..\nexus-infra-vmware\scripts\recover-vault-ha.ps1
```

### §3.x Apply-time recovery

| Symptom | Diagnosis | Recovery action |
|---|---|---|
| `packer build` fails immediately with `Download failed bad response code: 404` | Debian dropped the pinned point release the same day a newer one published (mirror only keeps the *current* point under `13.x.y/`). | Bump `var.iso_url` + `var.iso_checksum` in `packer/oltp-node/variables.pkr.hcl` to match `https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS`. Hit at 0.G.1 ratification 2026-05-17 when 13.4.0 → 13.5.0. |
| `terraform plan` fails with `filesha256() failed: ...vault-agent-oltp-redis-redis-N.json missing` | Security env not applied (or apply was partial). | Run `nexus-infra-vmware\scripts\security.ps1 apply` first. |
| `terraform apply` fails with `Module not installed` at module.redis_N | `.terraform/` directory missing (fresh clone or after a clean). | `oltp.ps1` now auto-runs `terraform init` when `.terraform/` is absent (added at 0.G.1 ratification 2026-05-17). For older script versions: `cd terraform\envs\oltp && terraform init`. |
| `vmrun start ... .vmx`: `Error: Unknown error` (apply fails at module.redis_N.power_on within seconds of start) | Transient VMware Workstation flake under rapid destroy→create churn or high VM count on the host. No specific diagnostic surfaces; vmrun's "Unknown error" is the catch-all. Affects 1-2 nodes per cold-rebuild cycle in observation. | Re-run `pwsh -File scripts\oltp.ps1 apply`. Terraform sees the failed power_on as tainted; the retry runs `vmrun start` again and almost always succeeds the second time (idempotent — the .vmx is already configure_nic'd). Hit on redis-5 at 0.G.1 ratification cold-rebuild 2026-05-17; cleared on retry. |
| Apply hangs on `[oltp-nftables] <ip>: waiting for SSH + firstboot marker...` for >20 min | Clone never finished firstboot (NIC discovery failure, hostname rename failure, or VMnet10 backplane misconfig). | SSH to `<ip>` with build-time creds; `sudo journalctl -u oltp-node-firstboot.service --no-pager`. Likely an unknown VMnet11 IP — check that the foundation dhcp-host reservation actually pinned the MAC to a known `.81/.82/.83/.84/.87/.89`. |
| Apply fails at `[redis-va redis-N] AppRole login appears to have failed (token sink empty)` | Vault is sealed, OR the sidecar has a stale role-id/secret-id (security env was re-applied but sidecars weren't). | `pwsh -File ..\nexus-infra-vmware\scripts\security.ps1 apply` to regenerate sidecars, then re-run `oltp.ps1 apply`. |
| Apply fails at `[redis-tls redis-N] cert files not rendered ... within 60s` | Vault Agent template syntax error (rare; per-host CN/SAN substitution), OR the PKI role's `allowed_domains` doesn't cover the requested CN, OR `/etc/vault-agent/ca-bundle.crt` is missing (Vault Agent didn't install). | `ssh nexusadmin@<ip>; sudo journalctl -u nexus-vault-agent.service -n 50`. Check for `template syntax error` or `403 access denied`. Re-apply security env's `vault_pki_redis_role` if `allowed_domains` was outdated. |
| Redis log spams `tlsv1 alert unknown ca` + smoke step 8 fails with `certificate verify failed` | `ca.crt` contains only the intermediate, not root+intermediate. OpenSSL strict X509 verify can't walk to a self-signed trust anchor with only the intermediate. | Fixed at `redis_tls_v=2` (split script now `cat $CA /etc/vault-agent/ca-bundle.crt > ca.crt`). Diagnosed at 0.G.1 ratification 2026-05-17. If you see this on an older overlay, bump `redis_tls_v` + re-apply. |
| Apply fails at `[redis-config redis-N] nexus-redis.service / TLS PING did not converge within 20 min` | nexus-redis.service crashlooping OR Redis is up but rejecting connections (TLS chain issue per row above; OR `protected-mode` on Redis 8.0+ blocking external-IP connections). | `ssh nexusadmin@<ip>; sudo journalctl -u nexus-redis.service -n 50; sudo tail -50 /var/log/nexus-redis/redis.log`. Check that `/etc/nexus-redis/tls/server.key` starts with `-----BEGIN PRIVATE KEY-----` (PKCS#8). Check `/etc/nexus-redis/redis.conf` has `protected-mode no` (Redis 8.0 default is `yes`; fixed at `redis_config_v=2`). |
| `[redis-cluster-create] cluster create did not report [OK] All 16384 slots covered` with `[ERR] ... DENIED Redis is running in protected mode` | Redis 8.0 default `protected-mode yes` refuses connections from non-loopback IPs when no `requirepass` is set. `redis-cli --cluster create` connects to each node via its VMnet11 IP. | Fixed at `redis_config_v=2` (`protected-mode no` added to rendered `redis.conf`). Defense-in-depth is preserved: nftables + tls-port + tls-auth-clients. Diagnosed at 0.G.1 ratification 2026-05-17. |
| Cluster forms with `4 masters + 2 replicas` instead of `3+3` (smoke step 9 master/replica count fails) | Cluster_create probe found `cluster_state:ok` and skipped create, but the cluster was left in a partial state by a prior interrupted apply (e.g. some `CLUSTER MEET` messages succeeded before a fatal error). | Manual recovery: SSH to each of the 6 nodes and run `sudo redis-cli -h 127.0.0.1 -p 6379 --tls --cacert /etc/nexus-redis/tls/ca.crt --cert /etc/nexus-redis/tls/server.crt --key /etc/nexus-redis/tls/server.key CLUSTER RESET HARD`. Then on redis-1 run `sudo redis-cli --tls ... --cluster create 192.168.70.81:6379 192.168.70.82:6379 192.168.70.83:6379 192.168.70.84:6379 192.168.70.87:6379 192.168.70.89:6379 --cluster-replicas 1 --cluster-yes`. (Future TF improvement: extend the cluster_create probe to also verify shape, not just state=ok.) Hit at 0.G.1 ratification 2026-05-17. |
| Apply fails at `cluster did not converge to (state=ok, size=3, known=6, slots=16384) within 20 min` | Cluster bus blocked between nodes. | Check nftables on each node: `sudo nft list ruleset | grep -E '6379|16379'`. The 3c overlay should have opened both ports. If missing, re-run `oltp.ps1 apply -- -target='null_resource.oltp_nftables_backplane'`. |
| smoke step 9 round-trip fails with `MOVED` but no follow-through | Client not in cluster mode (`-c` flag missing) OR slot table inconsistent. | Verify `redis-cli ... cluster slots` returns 3 ranges totaling 16384. If not, `redis-cli --cluster fix <ip>:6379 --tls --cacert ...`. |
| Harmless systemd warning `Unknown key 'StartLimitIntervalSec' in section [Service], ignoring` | `StartLimitIntervalSec`/`StartLimitBurst` were in `[Service]` instead of `[Unit]` in nexus-redis.service.j2. systemd ignores them (service still starts) but rate-limiting protection is disabled. | Fixed at 0.G.1 ratification 2026-05-17 -- moved both keys to `[Unit]`. Takes effect on the next Packer template rebuild + clone (existing clones keep the warning until rebuilt). |
| MongoDB `createUser` fails with `not authorized on admin to execute command { createUser ... }` even with `enableLocalhostAuthBypass: true` in mongod.conf | MongoDB 8.0 + `security.keyFile` + `security.authorization=enabled` DOES NOT activate the localhost-exception even when the bypass setParameter is set. The bypass parameter loads into config but the runtime check still requires auth. Confirmed via `getCmdLineOpts` (also blocked) and via testing both `--host 127.0.0.1` and `--host localhost`. | Use `__system` cluster auth instead: `sudo mongosh --tls ... --username __system --password $(sudo cat /etc/nexus-mongo/keyfile) --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256`. This is the keyFile-derived internal cluster user (root-equivalent privs). Per MongoDB docs, `__system` is "discouraged but supported" for operator use — acceptable for one-shot bootstrap. Wired into `role-overlay-mongo-rs-initiate.tf` v5+. Diagnosed at 0.G.2 ratification 2026-05-17. |
| `rs.status()` returns `Command replSetGetStatus requires authentication` | `rs.status()` requires the `replSetGetStatus` privilege, only granted to `clusterAdmin` / `clusterManager` / `__system` roles. The smoke-rw user (role `readWrite on nexus_smoke`) does not have it. | Use `__system` auth via keyFile (see row above) for any `rs.status()`/`rs.config()`/cluster-introspection call. Smoke gate + rs-initiate now thread `$sysAuthArgs` through all status probes. |
| `mongosh ... --eval` fails with `SyntaxError: Unexpected token (1:NN)` showing a malformed JSON object missing `$set` | Bash inside the SSH double-quoted command envelope is expanding `$set` as a shell variable (empty value), producing `{:{token:...}}`. PowerShell-side backtick-escaping `` `$set `` produces literal `$set` for PS, but bash then re-expands it. | Escape `$` for bash too: write `\\`$set` in the PS double-quoted string. PS emits `\$set`; bash sees the backslash, treats `$` as literal; mongosh receives `$set` correctly. Wired into rs-initiate v8 + smoke. Diagnosed at 0.G.2 ratification 2026-05-17. |
| `mongosh insertOne` fails with `MongoServerError: not primary` even though one member IS PRIMARY | RS can re-elect at any moment (incl. between mongod restarts during ratification). A single `--host mongo-N:27017` connection writes to that one node — fails if it's not currently PRIMARY. | Use RS connection URI: `mongodb://mongo-1:27017,mongo-2:27017,mongo-3:27017/<db>?replicaSet=nexus-rs`. mongosh discovers the topology + auto-routes writes to whichever member is currently PRIMARY. Wired into rs-initiate v6+ + smoke. |
| Idempotent write/read re-apply errors with `MongoServerError: E11000 duplicate key error collection: nexus_smoke...` | The smoke-key already exists from a prior apply/smoke run. Original retry logic checked for the literal string `'DuplicateKey'` (the codeName) which doesn't appear in MongoDB 8.0's error message text. | Match on `'E11000|duplicate key'` (the actual mongosh error message format in 8.0). On match: `updateOne` to refresh the token instead of `insertOne`. Wired into rs-initiate v8 + smoke. |
| Smoke section 9 (`rs.status() shows 1 PRIMARY`) FAILs even though the RS is genuinely healthy | PowerShell regex `(?m)^PRIMARY=1$` end-of-line anchor `$` matches before `\n` only — doesn't match before `\r\n` lines from SSH-piped output. The eval output IS correct; the regex just misses CRLF. | Use `(?m)^PRIMARY=1\s*$` (allow trailing whitespace incl. CR). Same fix applied across all 4 status-summary regexes in both rs-initiate and smoke. Wired into rs-initiate v2+ + smoke (initial fix at 0.G.2 first ratification 2026-05-17). |
| 0.G.3: `terraform validate` fails on percona TLS overlay with `Extra characters after interpolation expression` near `${1:-mysql}` in the bash split script | Terraform heredoc `<<-PWSH` interpolates `${...}` even inside PowerShell single-quoted here-strings. The bash positional-arg-with-default `${1:-mysql}` looks like a Terraform interpolation. | Escape as `$${1:-mysql}` per `memory/feedback_terraform_heredoc_powershell.md`. Caught at chunk 3b validate time 2026-05-17 (pre-ratification). |
| 0.G.3: ansible-lint CI fails on chunk 4 with 4 violations across the new oltp_pxc + oltp_proxysql roles | (a) `name[casing]` on "apt-get update" task names — must start uppercase; (b) `yaml[line-length]` on a 169-char filter chain inside a debug msg; (c) `no-handler` on the `when: percona_pin.changed` conditional cache-refresh task. | (a) "Apt-get update..." (capitalize). (b) Hoist the long expression to a `vars:` block on the task with `>-` folded scalar. (c) Drop the `when:` guard; run apt-get update unconditionally (cheap + idempotent + handlers run at end-of-play which is too late for the immediately-following install task). All 4 fixed at chunk 4 ratification 2026-05-17 (commit 90faabb). |

**0.G.3 ratification transients (2026-05-18)** — 16 distinct issues surfaced during the live ratification cycle on the monolithic `envs/oltp/` + `oltp-node.vmx` design. Each row below is a single fix. After 16 transients we PAUSED ratification + pivoted to the Phase 0.G.3.5 refactor (per `memory/feedback_per_cluster_state_per_engine_template.md`). The refactor splits into per-engine templates + per-cluster states; each transient fix below carries over to the refactored design (auth-mode-aware wrapper, bootstrap ordering, libaio1 bookworm fallback, etc. all stay):

| # | Symptom | Diagnosis | Recovery action |
|---|---|---|---|
| 1 | `packer build`: `the role 'oltp_pxc' was not found in /tmp/packer-provisioner-ansible-local/...` | The Packer ansible-local provisioner only uploads roles enumerated in the template's `role_paths` array. Chunk 4 added `oltp_pxc` + `oltp_proxysql` to the playbook's `roles:` list but NOT to `oltp-node.pkr.hcl`'s `role_paths`. | Add `ansible/roles/oltp_pxc` + `ansible/roles/oltp_proxysql` to `role_paths` in `oltp-node.pkr.hcl`. Add `pxc_version` + `proxysql_version` Packer vars + thread via `extra_arguments`. |
| 2 | `packer build`: `percona-release setup -y pxc-80` exits non-zero with "Specified repository is not supported for current operating system!" | The `percona-release` helper script checks `/etc/os-release` and refuses unsupported OSes BEFORE writing the source list. Debian 13 (trixie) isn't yet in Percona's allowlist. The trixie→bookworm `ansible.builtin.replace` task we shipped never runs because the source file doesn't get created. | Skip `percona-release setup` entirely; write `/etc/apt/sources.list.d/percona-pxc-80-release.list` manually, pinned to `bookworm` codename. Three sub-repo lines (pxc-80, tools, ps-80) all hardcoded. |
| 3 | `packer build`: `apt update` fails with `Reading "/etc/apt/trusted.gpg.d/percona-release.gpg": No such file or directory (os error 2)` — sqv signature verification rejects every Percona repo | The `percona-release` .deb package's postinst (which installs the GPG key) didn't reliably land it where modern apt+sqv expects on Debian 13. The key path varies across percona-release versions. | Don't run `dpkg -i percona-release.deb` (postinst tries the broken `percona-release setup`). Instead `dpkg-deb -x percona-release.deb extract-dir`; `find` the .gpg keyring inside; `install -m 0644 <found-key> /etc/apt/keyrings/percona.gpg`. Reference that path in the source list `signed-by=` attribute. |
| 4 | `packer build`: apt install `percona-xtradb-cluster-server` fails: `Depends: libaio1 (>= 0.3.93) but it is not installable; Depends: libldap-2.5-0 (>= 2.5.4) but it is not installable` | Debian 13's t64 transition renamed `libaio1` → `libaio1t64` and `libldap-2.5-0` → `libldap-2.6-0`. Sonames are ABI-incompatible, so the t64 variants don't satisfy the dep. Percona's bookworm-built packages still link against the bookworm soname. | Add `/etc/apt/sources.list.d/bookworm-percona-deps.list` with `deb http://deb.debian.org/debian bookworm main` + an apt-preferences pin that grants priority 990 to ONLY `libaio1` + `libldap-2.5-0` from bookworm (priority 100 default for the rest). Pre-install those 2 libs `apt install -y libaio1 libldap-2.5-0` BEFORE the Percona packages. |
| 5 | `packer build`: ProxySQL apt cache update fails with 404 on `https://repo.proxysql.com/ProxySQL/proxysql-2.6.x/debian/dists/bookworm/InRelease` | The ProxySQL repo isn't structured as Debian-archive-style (`dists/<codename>/`). It's a FLAT repo: `proxysql-2.6.x/<codename>/` directly contains `InRelease` + `Packages` + the .debs. The chunk 4 `deb ... debian/ bookworm main` URL points at a nonexistent path. | Use the flat-repo source line: `deb [arch=amd64 signed-by=...] https://repo.proxysql.com/ProxySQL/proxysql-2.6.x/bookworm/ ./` (codename `bookworm` is in the URL path; suite is literal `./`). |
| 6 | `packer build`: post-install shell exits 127 with `/tmp/script_NNNN.sh: line 13: mysqld: not found` | The Packer shell provisioner runs as a non-login shell where `/usr/sbin/` is NOT in PATH. `test -x /usr/sbin/mysqld` passes but bare `mysqld --version` fails because the binary isn't on the search path. | Use absolute paths in the post-install version probes: `/usr/sbin/mysqld --version`, `/usr/bin/xtrabackup --version`, `/usr/bin/proxysql --version`, `/usr/sbin/keepalived --version`. |
| 7 | `oltp apply`: nftables overlay v2→v3 bump (for percona ports) cascade-replaces `redis_cluster_create`; the noop destroy provisioner means the re-create then fails with `[ERR] Node 192.168.70.81:6379 is not empty. Either the node already knows other nodes (check with CLUSTER NODES) or contains some key in database 0.` | The chunk 3a nftables overlay's version-trigger change cascades down: `redis_vault_agent` → `redis_tls` → `redis_config` → `redis_cluster_create`. Each downstream resource's `nftables_id` trigger references the upstream id; terraform marks them all for replacement. The cluster_create destroy is intentionally a noop (can't safely destroy live cluster state mid-apply). The re-create can't form a new cluster on already-clustered nodes. | Manual recovery: SSH to all 6 redis nodes; `redis-cli ... CLUSTER RESET HARD` + `FLUSHALL`. Order matters: if masters have keys, RESET fails — run FLUSHALL first, then RESET. Then re-apply. **Root cause is monolithic state; the 0.G.3.5 refactor moves redis to its own state so percona changes can't trigger redis cascade.** |
| 8 | `oltp apply`: galera-bootstrap step 3 times out with `mysqld on pxc-node-1 didn't accept SELECT 1 within 20 min`; mysqld logs `[ERROR] [MY-011011] Failed to find valid data directory` | Percona apt's postinst initializes `/var/lib/mysql/` (the apt-default datadir). Our datadir is `/var/lib/nexus-percona/`. Without `--initialize-insecure --datadir=/var/lib/nexus-percona/`, mysqld can't find the system tables + crashes immediately. | Add an Ansible task to `oltp_pxc/tasks/main.yml`: run `mysqld --initialize-insecure --datadir=/var/lib/nexus-percona/ --user=mysql` with `creates: /var/lib/nexus-percona/mysql/general_log.CSM` (idempotent — skips if already initialized). For live re-runs on already-cloned VMs: SSH + `sudo find /var/lib/nexus-percona -mindepth 1 -delete` + `sudo -u mysql /usr/sbin/mysqld --initialize-insecure ...`. |
| 9 | `oltp apply`: galera-bootstrap proceeds but mysqld runs in standalone mode (`wsrep_load(): loading provider library 'none'`); no Galera | `/etc/nexus-percona/my.cnf` doesn't `!include /etc/nexus-percona/wsrep.cnf`. mysqld with `--defaults-file=/etc/nexus-percona/my.cnf` reads ONLY my.cnf; the wsrep_provider directive in the orphan wsrep.cnf is never loaded. | Add `!include /etc/nexus-percona/wsrep.cnf` at the end of my.cnf in chunk 3b's render. Bump `percona_config_v` to v2. |
| 10 | `oltp apply`: galera-bootstrap step 3 still failing; mysqld error `Can't get stat of '/etc/nexus-percona/wsrep.cn' (OS errno 2 - No such file or directory)` — the path is TRUNCATED (last `f` missing) | MySQL's `!include` parser strips the last character of every line under the assumption it's `\n`. If the file lacks a trailing LF (PowerShell here-string `@"..."@` consumes the LF before the closing `"@`), the last char of the last line gets eaten. | Add a blank line BEFORE the closing `"@` in the PowerShell here-string. Bump `percona_config_v` to v3. |
| 11 | `oltp apply`: chunk 3b percona-config step fails on `mysqld --validate-config` with `[Galera] gcs connect failed: Operation timed out` | On Percona XtraDB Cluster (vs vanilla MySQL), `--validate-config` doesn't just parse — it ACTIVATES the wsrep provider, including a Galera gcomm:// connection attempt to peers. Since the cluster isn't bootstrapped yet, the connect times out + validate-config returns non-zero. | REMOVE the validate-config step from chunk 3b entirely. Chunk 3c galera-bootstrap's `mysql -e 'SELECT 1'` probe + actual cluster formation are the real verification. Bump `percona_config_v` to v4. |
| 12 | `oltp apply`: galera-bootstrap fails with `Could not open state file for writing: '/var/lib/nexus-percona/grastate.dat': Permission denied (errno 13)` | Two compounding issues: (a) Debian 13's `/etc/apparmor.d/usr.sbin.mysqld` profile restricts mysqld writes to `/var/lib/mysql/` only — denies our custom datadir. (b) Stale `grastate.dat` + `galera.cache` from a previous crashed bootstrap attempt were owned by root:root (not mysql:mysql). | (a) Add Ansible task to disable AppArmor mysqld profile: `ln -sf /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/` + `apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld`. (b) For live recovery: `rm -f grastate.dat galera.cache gvwstate.dat` + `chown -R mysql:mysql /var/lib/nexus-percona/`. |
| 13 | `oltp apply`: galera-bootstrap step 3 silently retries forever; manual `sudo mysql --defaults-file=/etc/nexus-percona/my.cnf -BNe 'SELECT 1'` returns `Access denied for user 'root'@'localhost' (using password: NO)` | After chunk 3c step 4 `ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '<KV-password>'`, root has a password. Subsequent probes (step 3 of a re-apply, step 5+ user-create, step 9 Synced wait, verification probes) try sudo mysql with no `-p` flag → Access denied → `2>/dev/null` swallows the error → probe returns empty → retries forever. | Install `/usr/local/sbin/nexus-pxc-mysql` wrapper that tries password-from-KV-file FIRST (if it works, use it); falls back to passwordless (fresh-init case). Replace all 9 instances of `mysql --defaults-file=/etc/nexus-percona/my.cnf` in chunk 3c with `sudo /usr/local/sbin/nexus-pxc-mysql`. Bake the wrapper into the oltp_pxc Ansible role. Bump `galera_bootstrap_v` to v2. |
| 14 | `nexus-pxc-mysql` wrapper: after step 4 sets root password, wrapper picks password-mode (file exists from Vault Agent render) but root is still passwordless (fresh-init); auth fails | First version of the wrapper picked a single auth path based on whether the password file existed, not whether the password actually worked. Vault Agent renders the password file BEFORE the bootstrap dance ever runs, so the file always exists — but root may not have any password yet. | Wrapper does try-then-fallback: try password-protected mysql `SELECT 1`; if it succeeds, exec the actual command with the password; otherwise fall back to passwordless. |
| 15 | `oltp apply`: chunk 3c step 9 times out — `nexus-percona.service` on pxc-node-1 (regular mode, post-bootstrap-service-stop) enters systemd restart loop (`restart counter is at 27`); mysqld log: `No nodes coming from primary view, primary view is not possible` | Fundamental ordering bug. Chunk 3c originally: stop bootstrap.service → start regular nexus-percona.service on node-1 → wait Synced → start joiners. Regular service reads canonical `wsrep_cluster_address = gcomm://node-1,node-2,node-3` and tries to JOIN. With node-2/3 not yet started, no primary view forms; mysqld exits; systemd restart loops. | Reorder: KEEP nexus-percona-bootstrap.service running on node-1 → start joiners (2, 3) → wait all Synced (size 2 then 3) → rolling-restart node-1 from bootstrap.service to regular service (now it has peers + can join). Bump `galera_bootstrap_v` to v3. |
| 16 | `oltp apply`: galera-bootstrap step 8/9 (after v3 reorder) — joiner pxc-node-2 didn't reach Synced + size 2 within 20 min | Not yet root-caused. Likely xtrabackup-v2 SST failure (could be lib version on joiner, sst-auth.cnf format, donor selection, or other Galera-on-Debian-13 gotcha). | **NOT FIXED**. Stopped iterating at this point per `memory/feedback_per_cluster_state_per_engine_template.md` — the monolithic design's 30-min full-tree iteration loop made transient discovery untenable. Deferred to Phase 0.G.3.5 refactor where `envs/oltp-percona/` has a 5-VM apply (~5-10 min) so SST diagnosis becomes tractable. |

(Table grows as new transients surface during live cycles. The 0.G.3.5 refactor will rebuild the chunk 3c galera-bootstrap from scratch in the per-cluster state, applying all 16 lessons above. Smoke-0.G.3.ps1 is the regression test bed for the refactor.)
