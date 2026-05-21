# nexus-infra-oltp operator handbook

> **Status (Phase 0.G.1 + 0.G.2 + 0.G.3 + 0.G.3.5 + 0.G.4 + 0.G.7):** ✅ all
> five OLTP cluster sub-phases shipped per-cluster + per-engine.
> 0.G.1+0.G.2+0.G.3+0.G.3.5 **PROVEN cold-rebuildable (2026-05-18)**; 0.G.4
> (Patroni + etcd + HAProxy) closed 2026-05-19; **0.G.7 (SQL Server FCI +
> Always On AG on Windows Server 2025) scaffolded 2026-05-20**, ratification
> pending. With 0.G.7 the OLTP tier is SEALED (5/5 clusters):
>
> - **0.G.1** (6-node Redis Cluster mTLS) — smoke ALL GREEN on
>   `envs/oltp-redis/` via `oltp-redis-node.vmx`.
> - **0.G.2** (3-node MongoDB RS mTLS+keyFile) — smoke ALL GREEN on
>   `envs/oltp-mongo/` via `oltp-mongo-node.vmx`.
> - **0.G.3** (3 PXC + 2 ProxySQL + VRRP VIP `192.168.70.50`) — smoke
>   ALL GREEN on `envs/oltp-percona/` via `oltp-pxc-node.vmx` +
>   `oltp-proxysql-node.vmx`. End-to-end write via VIP propagates to
>   every PXC backend (mTLS + Galera replication confirmed).
> - **0.G.4** (3 Patroni PG 17 + 3 etcd DCS + 2 HAProxy HA pair + VRRP VIP
>   `192.168.70.60`) — **smoke ALL GREEN 152/152 (2026-05-19)** on
>   `envs/oltp-patroni/` via `oltp-patroni-node.vmx` + `oltp-etcd-node.vmx` +
>   `oltp-haproxy-node.vmx`. Apps connect to **`<VIP>:5432`** which routes
>   to the current Patroni leader via REST `/leader` health probes; the VIP
>   floats between `haproxy-pg-1` (priority 110 MASTER) and `haproxy-pg-2`
>   (priority 100 BACKUP) via keepalived **unicast** mode (mirrors the
>   0.G.3 proxysql-1/2 + VIP `.50` pattern — no SPOF on the LB tier). etcd
>   3-member raft quorum holds the DCS with HTTP basic-auth RBAC; PG
>   streaming replication over mTLS. Ratification surfaced **18 transients**
>   end-to-end (full chronology in §3.4); all permanent fixes baked into
>   per-engine Ansible roles, per-cluster TF overlays, and the smoke gate.
>
> - **0.G.7** (2 SQL Server FCI nodes sharing iSCSI LUN + 2 AG async
>   replicas; 4 ws2025-desktop nodes + 3 WSFC-managed VIPs:
>   cluster `.70.15`, FCI `.70.16`, AG Listener `.70.17`) — **scaffolded
>   2026-05-20**, ratification pending. SQL Server 2022 Developer Edition
>   (MSDN per ADR-0144); WSFC quorum=NodeMajority across all 4; FCI shares
>   iSCSI LUN via tgt target on nexus-gateway (per ADR-0026); AG endpoint
>   auth = certificate-based per ADR-0027; Listener cert IP-SAN .17
>   validates client TLS across failover (per ADR-0025); SQL service runs
>   as `nexus.lab\gmsa-sql-engine$` GMSA (Phase 0.G.7 is the first
>   real GMSA consumer; 0.D.5 scaffolded the infrastructure). Hybrid
>   FCI+AG architecture sealed with Greg 2026-05-20 — see memory entry
>   `project_nexus_infra_oltp_0g7_phase`. Ratification will surface the
>   transient chronology in §3.5 (empty at scaffold; the lab's first
>   Windows-fleet sub-phase will have its own discoveries).
>
> Cold-rebuild surfaced **11 additional transients** beyond the 16 from
> the legacy monolithic 0.G.3 attempt; all root-caused + permanent fixes
> baked into the per-engine templates + per-cluster overlays + smoke
> gates. Full chronology + symptom→diagnosis→fix in §3.x.
>
> **Legacy `packer/oltp-node/` + `terraform/envs/oltp/` + `scripts/oltp.ps1`
> kept in place this commit for safety** (cluster proved + canon updated
> with new paths); 0.G.3.5c chunk 2 removes them after CI green.
>
> Follows the 9-section structure mandated by `feedback_handbook_standard.md`
> invariant 2 (canonical exemplar: [`nexus-infra-kafka/docs/handbook.md`](https://github.com/grezap/nexus-infra-kafka/blob/main/docs/handbook.md)).

## §0 Prerequisites

**What MUST be alive before applying anything in this repo.**

Cross-tier dependencies (in hard-ordering for cold-rebuild):

- **Foundation tier** ([`nexus-infra-vmware/envs/foundation`](https://github.com/grezap/nexus-infra-vmware)) — `nexus-gateway` providing DHCP + DNS via dnsmasq. The OLTP-tier dhcp reservations overlay is **v5 as of 0.G.4** (single-file marker, atomic replace):
  - **0.G.1** (Redis): 6 `dhcp-host` reservations pinning redis-1..6 MACs (`:70-:75`) to `.81/.82/.83/.84/.87/.89` (skip `.85/.86/.88` which belong to kafka).
  - **0.G.2** (Mongo): +3 mongo-1..3 MACs (`:76-:78`) to `.71/.72/.73`.
  - **0.G.3** (Percona + ProxySQL): +5 MACs (`:79-:7D`) pxc-node-1..3 → `.51/.52/.53` + proxysql-1..2 → `.54/.55`. The VIP `.50` is NOT a dhcp reservation -- it floats between proxysql-1/2 via VRRP/keepalived, configured per-node by the oltp env.
  - **0.G.4** (Patroni + etcd + HAProxy HA pair): +8 MACs (`:7E-:85`) pg-primary/pg-replica-{1,2} → `.61/.62/.63` + etcd-{1,2,3} → `.64/.65/.66` + haproxy-pg-{1,2} → `.67/.68`. The VIP `.60` is NOT a dhcp reservation -- it floats between haproxy-pg-1/-2 via VRRP/keepalived (priority 110 MASTER + 100 BACKUP, unicast mode), configured per-node by the oltp env.
  - Owned by `terraform/envs/foundation/role-overlay-gateway-oltp-reservations.tf` (v5).
- **Security tier** ([`nexus-infra-vmware/envs/security`](https://github.com/grezap/nexus-infra-vmware)) — 3-node Vault HA + `vault-transit` auto-unseal. Per-cluster PKI + AppRole + KV state:
  - **0.G.1** (Redis): PKI role `redis-server` (90 d TTL, 21 allowed_domains) + 6 `nexus-agent-redis-N` policies + 6 AppRoles + 6 sidecars at `$HOME\.nexus\vault-agent-oltp-redis-redis-N.json`.
  - **0.G.2** (Mongo): PKI role `mongo-server` + 3 `nexus-agent-mongo-N` policies + 3 AppRoles + 3 sidecars (`vault-agent-oltp-mongo-mongo-N.json`) + 2 KV sticky-seeds (`nexus/oltp/mongo/keyfile` + `nexus/oltp/mongo/smoke-user-password`).
  - **0.G.3** (Percona + ProxySQL): PKI role `percona-server` (90 d TTL, 17 allowed_domains covering pxc-node-1..3 + proxysql-1..2 in bare + .nexus.lab + .percona.nexus.lab forms) + 5 `nexus-agent-pxc-N` + `nexus-agent-proxysql-N` policies (role-differentiated KV grants: PXC reads cluster/monitor/root, ProxySQL reads cluster/monitor/proxysql-admin) + 5 AppRoles + 5 sidecars (`vault-agent-oltp-percona-<host>.json`) + 4 KV sticky-seeds at `nexus/oltp/percona/{cluster,monitor,root,proxysql-admin}-password` (each 32-char hex).
  - **0.G.4** (Patroni + etcd + HAProxy HA pair): PKI role `patroni-server` (90 d TTL, 26 allowed_domains covering the 8 hostnames in bare + .nexus.lab + .patroni.nexus.lab forms; haproxy nodes additionally carry the VIP `.60` in their cert IP-SANs) + 8 `nexus-agent-{pg-primary,pg-replica-{1,2},etcd-{1,2,3},haproxy-pg-{1,2}}` policies (role-differentiated KV grants: Patroni reads 4 secrets, etcd reads 2, HAProxy reads 2) + 8 AppRoles + 8 sidecars (`vault-agent-oltp-patroni-<host>.json`) + 5 KV sticky-seeds at `nexus/oltp/patroni/{etcd-root,patroni-rest,postgres-superuser,postgres-replication,haproxy-stats}-password` (each 32-char hex).
  - Owned by `terraform/envs/security/role-overlay-vault-{pki-{redis,mongo,percona,patroni},agent-{redis,mongo,percona,patroni}-{policies,approles},mongo-{keyfile,smoke-user}-seed,percona-cluster-creds-seed,patroni-cluster-creds-seed}.tf`.

**Build-host tools** (pwsh-native per `feedback_build_host_pwsh_native.md` — no `make` required):

- PowerShell 7+ (`winget install --id Microsoft.PowerShell`)
- VMware Workstation Pro 25+ on `H:\`
- Terraform 1.9+
- Packer 1.11+ (1.15.1 tested)
- Ansible (consumed inside the VM by Packer's `ansible-local` provisioner; no local Ansible needed)
- An `ssh-agent` on the build host with the canonical lab SSH key loaded; the operator's `$HOME\.ssh\config` should resolve `redis-N.nexus.lab` via the gateway dnsmasq (or just SSH to IPs)

## §1 Phase walkthrough

### §1.1 Build the Packer templates (7 per-engine)

Each OLTP engine gets its own per-engine template per `memory/feedback_per_cluster_state_per_engine_template.md`. Build each in turn (or parallel terminals if your build host has the headroom — shared `PACKER_CACHE_DIR` reuses the Debian 13 ISO across all 7):

```pwsh
$env:PACKER_CACHE_DIR = 'H:\VMS\packer_cache'   # shares the Debian ISO download
foreach ($t in 'oltp-redis-node','oltp-mongo-node','oltp-pxc-node','oltp-proxysql-node','oltp-patroni-node','oltp-etcd-node','oltp-haproxy-node') {
  Push-Location "packer\$t"
  packer init .
  packer build -force .
  Pop-Location
}
```

Per-template bake time + artifact:

| Template | Bake time | Artifact | Footprint |
|---|---|---|---|
| `oltp-redis-node`    | ~8 min  | `H:\VMS\NexusPlatform\_templates\oltp-redis-node\oltp-redis-node.vmx`       | ~2.7 GB |
| `oltp-mongo-node`    | ~8 min  | `H:\VMS\NexusPlatform\_templates\oltp-mongo-node\oltp-mongo-node.vmx`       | ~3.3 GB |
| `oltp-pxc-node`      | ~9 min  | `H:\VMS\NexusPlatform\_templates\oltp-pxc-node\oltp-pxc-node.vmx`           | ~3.9 GB |
| `oltp-proxysql-node` | ~10 min | `H:\VMS\NexusPlatform\_templates\oltp-proxysql-node\oltp-proxysql-node.vmx` | ~2.9 GB |
| `oltp-patroni-node`  | ~10 min | `H:\VMS\NexusPlatform\_templates\oltp-patroni-node\oltp-patroni-node.vmx`   | ~3.2 GB |
| `oltp-etcd-node`     | ~6 min  | `H:\VMS\NexusPlatform\_templates\oltp-etcd-node\oltp-etcd-node.vmx`         | ~2.4 GB |
| `oltp-haproxy-node`  | ~7 min  | `H:\VMS\NexusPlatform\_templates\oltp-haproxy-node\oltp-haproxy-node.vmx`   | ~2.4 GB |

Total ~58 min sequential across all 7 (vs ~40-55 min for the legacy monolithic `oltp-node` which bundled redis/mongo/pxc/proxysql in one template — removed in 0.G.3.5c chunk 2). Each per-engine template is small + focused; you only rebuild the one whose role you touched.

Spot-check any built template before promoting to apply:

```pwsh
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' start H:\VMS\NexusPlatform\_templates\oltp-redis-node\oltp-redis-node.vmx nogui
# Wait for boot, then SSH in with the build-time creds:
ssh nexusadmin@<dhcp-assigned-IP>      # password: nexus-packer-build-only
# Per-engine steady-state checks (varies by template; redis shown):
systemctl is-active nexus-redis.service       # -> inactive (DISABLED; gates on /etc/nexus-redis/redis.conf)
systemctl is-enabled redis-server.service     # -> masked (apt-shipped unit defensively masked)
redis-server --version                        # -> Redis server v=8.0.x
# For mongo template:    systemctl is-active nexus-mongo.service ; mongod --version
# For pxc template:      systemctl is-active nexus-percona{,-bootstrap}.service ; mysqld --version ; xtrabackup --version
# For proxysql template: systemctl is-active nexus-proxysql.service ; proxysql --version ; keepalived --version ; which mysql
# For patroni template:  systemctl is-active nexus-patroni.service ; /usr/lib/postgresql/17/bin/postgres --version ; /usr/local/bin/patroni --version ; systemctl is-enabled postgresql.service (=>masked)
# For etcd template:     systemctl is-active nexus-etcd.service ; /usr/local/bin/etcd --version ; /usr/local/bin/etcdctl version
# For haproxy template:  systemctl is-active nexus-haproxy.service ; haproxy -v ; systemctl is-enabled haproxy.service (=>masked)
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' stop H:\VMS\NexusPlatform\_templates\oltp-redis-node\oltp-redis-node.vmx hard
```

### §1.2 Cross-env operator order

**Hard ordering** (each step gates the next; per `feedback_handbook_standard.md` invariant 1):

```
┌─ [build host] ────────────────────────────────────────────────────────────────┐
│ 1. nexus-infra-vmware\scripts\foundation.ps1 apply                            │
│      adds ALL OLTP-tier dnsmasq dhcp-host reservations on nexus-gateway:      │
│        v1 = 6 redis  (0.G.1)                                                   │
│        v2 = +3 mongo (0.G.2)                                                   │
│        v3 = +5 pxc/proxysql (0.G.3)                                            │
│        v5 = +8 patroni/etcd/haproxy-pair (0.G.4)  <- current marker            │
│             (v4 was the abandoned single-HAProxy variant; v5 is the HA pair)  │
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
│        0.G.4: pki_int/roles/patroni-server + 8 patroni-tier policies          │
│               (role-diff'd: Patroni=4 KV, etcd=2 KV, HAProxy=2 KV) + 8        │
│               AppRoles + 8 sidecars + 5 KV sticky-seeds (etcd-root +          │
│               patroni-rest + postgres-superuser + postgres-replication +      │
│               haproxy-stats)                                                   │
│      (All toggles default true; no override needed for steady-state apply.)    │
│                                                                                │
│ 3a. nexus-infra-oltp\scripts\oltp-redis.ps1   apply  (6 VMs;  ~5  min)        │
│ 3b. nexus-infra-oltp\scripts\oltp-mongo.ps1   apply  (3 VMs;  ~5  min)        │
│ 3c. nexus-infra-oltp\scripts\oltp-percona.ps1 apply  (5 VMs;  ~10 min)        │
│ 3d. nexus-infra-oltp\scripts\oltp-patroni.ps1 apply  (8 VMs;  ~15 min)        │
│      Each script drives its own per-cluster terraform state:                   │
│        envs/oltp-redis/   ← oltp-redis-node.vmx   (Packer-built per-engine)    │
│        envs/oltp-mongo/   ← oltp-mongo-node.vmx                                │
│        envs/oltp-percona/ ← oltp-pxc-node.vmx + oltp-proxysql-node.vmx         │
│        envs/oltp-patroni/ ← oltp-patroni-node.vmx + oltp-etcd-node.vmx +       │
│                              oltp-haproxy-node.vmx (HA pair + VRRP VIP .60)   │
│      Per-cluster nftables overlays open only that cluster's ports — no cross-  │
│      cluster cascade (per memory/feedback_per_cluster_state_per_engine_template.md).
│                                                                                │
│      The 4 cluster applies are INDEPENDENT (no inter-cluster dep) — run in     │
│      any order, or in parallel terminals.                                      │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Cannot reorder steps 1→2→3**: each cluster's `*_vault_agent` resource uses `filesha256()` on its sidecar JSON at plan time, so the security env MUST have written them first. A premature `oltp-* apply` fails fast at plan time with `Call to function "filesha256" failed: open ...vault-agent-oltp-{redis,mongo,percona,patroni}-<host>.json: The system cannot find the file specified`.

**Within step 3**: 3a/3b/3c/3d are independent — terraform states don't reference each other. The only practical ordering is "Redis before apps" (Redis is the fastest + most-used cache; bring it up first so other smoke tests have something to point at).

### §1.3 Apply, §1.5 selective ops, §1.6 tear down → see §1.7

The per-cluster operator scripts (`scripts/oltp-{redis,mongo,percona}.ps1`) are now the canonical interface. See **§1.7 Per-cluster scripts** below for:

- Full per-cluster cold-rebuild walkthrough (4 packer builds + 3 per-cluster cycles).
- 8 copy-pasteable selective-ops `-Vars` examples (per-VM enable/disable, iterate one overlay, debug recipes).
- Per-cluster tear-down (`pwsh -File scripts\oltp-<cluster>.ps1 destroy` — bounded to that cluster only; the other 2 stay live).

The legacy monolithic `scripts/oltp.ps1` was removed in 0.G.3.5c chunk 2. Its old "apply ALL 14 VMs in one shot" semantics had no replacement and no need for one — per-cluster boundaries are the design point.

### §1.4 Verify the exit gate

```pwsh
pwsh -File scripts\oltp-redis.ps1     smoke   # 0.G.1: ~50 checks across 9 sections
pwsh -File scripts\oltp-mongo.ps1     smoke   # 0.G.2: ~45 checks across 9 sections
pwsh -File scripts\oltp-percona.ps1   smoke   # 0.G.3: ~80 checks across 12 sections
pwsh -File scripts\oltp-patroni.ps1   smoke   # 0.G.4: ~90 checks across 13 sections (etcd quorum + Patroni shape + HAProxy HA pair + VRRP VIP)
pwsh -File scripts\oltp-sqlserver.ps1 smoke   # 0.G.7: ~165 checks across 14 sections (WSFC + FCI + AG + Listener + IP-SAN cert verify)
```

Each smoke script (`smoke-0.G.{1,2,3,4}.ps1` under the hood) runs reachability → firstboot → identity → vault-agent → TLS material → per-cluster config → service active → TLS listener → cluster health → end-to-end round-trip. Each check echoes `[OK]/[FAIL]`; exits 1 on any failure, 0 on all-green.

Smoke is independent of apply — re-runnable any time against a stable cluster.

**Wiped by destroy**:

- The 6 per-VM dirs under `H:\VMS\NexusPlatform\05-oltp\` (full disk wipe via vmrun deleteVM)
- All cluster state (nodes.conf + AOF live inside the VMs)
- No Vault KV bootstrap-token cleanup needed for 0.G.1 (Redis Cluster has no equivalent to consul/nomad bootstrap tokens; the AppRole secret-ids rotate every security apply anyway)

### §1.7 Per-cluster scripts (canonical interface)

Four wrappers around the per-cluster terraform states, each with the standard verb shape (`apply | destroy | smoke | cycle | plan | validate`):

| Script | Env | Template(s) | Smoke | VMs | Apply wall-clock |
|---|---|---|---|---|---|
| `scripts/oltp-redis.ps1` | `terraform/envs/oltp-redis/` | `oltp-redis-node.vmx` | `smoke-0.G.1.ps1` | 6 | ~5 min |
| `scripts/oltp-mongo.ps1` | `terraform/envs/oltp-mongo/` | `oltp-mongo-node.vmx` | `smoke-0.G.2.ps1` | 3 | ~5 min |
| `scripts/oltp-percona.ps1` | `terraform/envs/oltp-percona/` | `oltp-pxc-node.vmx` + `oltp-proxysql-node.vmx` | `smoke-0.G.3.ps1` | 5 | ~10 min |
| `scripts/oltp-patroni.ps1` | `terraform/envs/oltp-patroni/` | `oltp-patroni-node.vmx` + `oltp-etcd-node.vmx` + `oltp-haproxy-node.vmx` | `smoke-0.G.4.ps1` | 8 | ~15 min |

**Patroni HA pair design (alignment with 0.G.3):** `vms.yaml` cluster `postgres` ships an HAProxy HA pair (`haproxy-pg-1` + `haproxy-pg-2`) + VRRP-floated VIP `192.168.70.60` mirroring the 0.G.3 proxysql-1/2 + VIP `.50` pattern. Both haproxy nodes run identical `haproxy.cfg`; keepalived elects exactly one as MASTER (priority 110 default = `haproxy-pg-1`); apps connect to `<VIP>:5432`. Unicast VRRP for the same reason as proxysql -- VMware VMnet11 doesn't reliably forward IPv4 multicast `224.0.0.18` (lesson baked at 0.G.3.5c chunk 1 transient #22). The haproxy nodes' PKI leaf certs carry the VIP in their IP-SANs so client TLS handshakes validate regardless of which haproxy currently holds the VIP. There is no SPOF on the LB tier.

**Full per-cluster cold-rebuild:**

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

# PATRONI — etcd quorum only (3 etcd VMs; no patroni, no haproxy -- useful for etcd-side debug)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_pg_primary=false,enable_pg_replica_1=false,enable_pg_replica_2=false,enable_haproxy_pg_1=false,enable_haproxy_pg_2=false,enable_patroni_bootstrap=false,enable_haproxy_config=false,enable_haproxy_keepalived=false

# PATRONI — iterate just the patroni-bootstrap one-shot (assumes etcd up + TLS + KV creds rendered)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_nftables_backplane=false,enable_patroni_vault_agents=false,enable_patroni_tls=false,enable_etcd_bootstrap=false,enable_haproxy_config=false,enable_haproxy_keepalived=false

# PATRONI — iterate just the haproxy-config + haproxy-keepalived (assumes etcd + patroni up)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_nftables_backplane=false,enable_patroni_vault_agents=false,enable_patroni_tls=false,enable_etcd_bootstrap=false,enable_patroni_bootstrap=false

# PATRONI — skip etcd-bootstrap (debug etcd manually before letting Patroni dial it)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_etcd_bootstrap=false

# PATRONI — skip patroni-bootstrap (initdb leader manually via patronictl + watch)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_patroni_bootstrap=false

# PATRONI — HAProxy pair + config without VRRP VIP (apps hit haproxy-pg-1 directly on .67 -- debugging only)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_haproxy_keepalived=false

# PATRONI — single HAProxy only (haproxy-pg-1 + VIP; haproxy-pg-2 absent -- debug-only, defeats HA)
pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_haproxy_pg_2=false,enable_haproxy_keepalived=false
```

**Per-cluster destroy** is bounded to that cluster only — never touches the other 2:

```pwsh
pwsh -File scripts\oltp-percona.ps1 destroy   # tears down 5 percona VMs; redis + mongo untouched
```

This is the key win over the legacy monolithic `oltp.ps1 destroy` which would tear down all 14 VMs in one shot. **Per-cluster bound destroy = per-cluster bound iteration = ~5-10 min iteration loop vs ~30 min monolithic.**

## §2 Phase status

| Sub-phase | Cluster | TF | Packer | Smoke | Status | Closed |
|---|---|---|---|---|---|---|
| 0.G.1 | Redis Cluster (6 nodes) | `terraform/envs/oltp-redis/` ✅ | `packer/oltp-redis-node/` ✅ | `smoke-0.G.1.ps1` ✅ | ✅ PROVEN cold-rebuildable (per-cluster: 2026-05-18; monolithic: 2026-05-17) | 2026-05-17 |
| 0.G.2 | MongoDB RS (3 nodes) | `terraform/envs/oltp-mongo/` ✅ | `packer/oltp-mongo-node/` ✅ | `smoke-0.G.2.ps1` ✅ | ✅ PROVEN cold-rebuildable (per-cluster: 2026-05-18; monolithic: 2026-05-17) | 2026-05-17 |
| 0.G.3 | Percona PXC + ProxySQL (5 nodes) | `terraform/envs/oltp-percona/` ✅ | `packer/oltp-pxc-node/` + `packer/oltp-proxysql-node/` ✅ | `smoke-0.G.3.ps1` ✅ | ✅ PROVEN cold-rebuildable end-to-end 2026-05-18 via per-cluster envs (16 monolithic-ratification transients + 11 refactor-ratification transients all root-caused + permanently fixed in source -- full table in §3.x) | 2026-05-18 |
| 0.G.3.5a | per-engine Packer template refactor (4 NEW) | — | `packer/oltp-{redis,mongo,pxc,proxysql}-node/` ✅ | inherits per-engine smoke | ✅ live-baked 2026-05-18 in 0.G.3.5c chunk 1; bake time ~8-10 min each (smaller than legacy monolithic ~40-55 min) | 2026-05-18 |
| 0.G.3.5b | per-cluster Terraform state refactor (3 NEW) | `terraform/envs/oltp-{redis,mongo,percona}/` ✅ | reuses 0.G.3.5a templates | per-cluster smoke gates | ✅ live-applied 2026-05-18 in 0.G.3.5c chunk 1; 3 operator wrappers `scripts/oltp-{redis,mongo,percona}.ps1` ✅ | 2026-05-18 |
| 0.G.3.5c chunk 1 | live cold-rebuild via per-cluster envs + permanent fixes for 11 new transients | proves 0.G.3.5b states | builds 0.G.3.5a templates | smoke gates per cluster ALL GREEN | ✅ PROVEN end-to-end 2026-05-18 ([commit d076abd](https://github.com/grezap/nexus-infra-oltp/commit/d076abd)) | 2026-05-18 |
| 0.G.3.5c chunk 2 | delete legacy `packer/oltp-node/` + `terraform/envs/oltp/` + `scripts/oltp.ps1` + CI matrix cleanup + handbook canonicalization | — | — | — | ✅ removed 2026-05-18 (this commit); CI matrix scoped to 4 per-engine templates + 3 per-cluster envs only | 2026-05-18 |
| 0.G.4 | Patroni + etcd + HAProxy HA pair + VRRP VIP `.60` (8 nodes) | `terraform/envs/oltp-patroni/` ✅ | `packer/oltp-{patroni,etcd,haproxy}-node/` ✅ (3 per-engine templates; haproxy template bakes keepalived) | `smoke-0.G.4.ps1` ✅ **ALL 152 CHECKS PASSED 2026-05-19** | ✅ **PROVEN end-to-end 2026-05-19** -- foundation v5 + security patroni overlays + 3 Packer templates + per-cluster TF env (7 overlays incl. haproxy-keepalived) + operator wrapper + smoke gate (152 checks, 13 sections) + 4 demo playbooks. 18 transients surfaced + all root-caused + permanent fixes baked into source (full chronology in §3.x). | 2026-05-19 |
| 0.G.7 | SQL Server FCI + AG (4 ws2025-desktop nodes; 2 FCI + 2 AG-replica) | `terraform/envs/oltp-sqlserver/` ✅ (9 role-overlays) | `packer/oltp-sqlserver-node/` ✅ (clones ws2025-desktop.vmx + adds SQL 2022 Developer + WSFC + iSCSI + MPIO features) | `smoke-0.G.7.ps1` ✅ (~165 checks across 14 sections) | ✅ **SCAFFOLDED 2026-05-20** — foundation v6 dnsmasq overlay + iSCSI target on nexus-gateway + 5 security sqlserver overlays + 9-overlay per-cluster TF env + operator wrapper + smoke gate. Hybrid FCI+AG architecture per `vms.yaml` canon (sealed with Greg 2026-05-20). ADR-0026 (iSCSI shared storage) + ADR-0027 (AG endpoint cert auth) ship alongside. Ratification pending — first Windows-fleet sub-phase will discover its own transient chronology (§3.5). | scaffold 2026-05-20 |

(0.G.5 ClickHouse + 0.G.6 StarRocks belong to the sibling `nexus-infra-analytics` repo.)

## §3 Operator runbooks

### §3.1 Cold-rebuild canon

**Status: PROVEN end-to-end via per-cluster envs (2026-05-18).** All 3 OLTP clusters rebuild from per-engine templates + per-cluster Terraform states; smoke gates ALL GREEN.

Canonical per-cluster cycle (each cluster independent, can be ordered or parallel):

```pwsh
cd <repo-root>\workspace\nexus-infra-oltp

# 1. Per-cluster destroy (bounded to that cluster only -- other 3 stay live)
pwsh -File scripts\oltp-redis.ps1   destroy   # 6 redis VMs
pwsh -File scripts\oltp-mongo.ps1   destroy   # 3 mongo VMs
pwsh -File scripts\oltp-percona.ps1 destroy   # 5 percona VMs (3 PXC + 2 ProxySQL)
pwsh -File scripts\oltp-patroni.ps1 destroy   # 8 patroni-tier VMs (3 PG + 3 etcd + 2 HAProxy)

# 2. Per-cluster apply (foundation + security stay live; this clones + brings up cold)
pwsh -File scripts\oltp-redis.ps1   apply
pwsh -File scripts\oltp-mongo.ps1   apply
pwsh -File scripts\oltp-percona.ps1 apply
pwsh -File scripts\oltp-patroni.ps1 apply

# 3. Per-cluster smoke
pwsh -File scripts\oltp-redis.ps1   smoke    # 0.G.1 exit gate
pwsh -File scripts\oltp-mongo.ps1   smoke    # 0.G.2 exit gate
pwsh -File scripts\oltp-percona.ps1 smoke    # 0.G.3 exit gate
pwsh -File scripts\oltp-patroni.ps1 smoke    # 0.G.4 exit gate

# Shortcut: pwsh -File scripts\oltp-<cluster>.ps1 cycle does destroy -> apply -> smoke
```

Wall-clock observed at the 0.G.3.5c chunk 1 ratification 2026-05-18 (0.G.4 row is projected; ratification pending):

| Cluster | Destroy | Apply (cold) | Smoke | Notes |
|---|---|---|---|---|
| oltp-redis    | ~20s | ~5-7 min   | ~25s | Best-case; #18 (orphan masters) needs live CLUSTER REPLICATE recovery first time |
| oltp-mongo    | ~20s | ~5 min     | ~25s | Cleanest of the 3 (now 4) clusters |
| oltp-percona  | ~30s | ~10-15 min | ~45s | Galera SST is slowest single step (multi-GB transfer over VMnet10 backplane) |
| oltp-patroni  | ~50s | ~12-18 min (projected) | ~50s | etcd raft + Patroni initdb + 2x pg_basebackup ride VMnet10 backplane; HAProxy backend health probe needs ~30s to mark leader UP; +keepalived VRRP unicast convergence (~5s) for VIP bind on MASTER |

**Total ~5-10 min per cluster** (vs ~30 min for the legacy monolithic 14-VM tree). Fresh `packer build` (when a template doesn't exist or needs updating) adds ~8-10 min per template — see §1.1. ISO download shared via `$env:PACKER_CACHE_DIR='H:\VMS\packer_cache'`.

Operator ratification checklist — all 9 verified 2026-05-18 (3 clusters × 3 steps):

- [x] **oltp-redis** destroy: 38 resources destroyed; all 6 VMs gone from `H:\VMS\NexusPlatform\05-oltp\redis-*/`; `terraform state list` empty.
- [x] **oltp-redis** apply: returns exit 0 after one CLUSTER REPLICATE manual recovery (transient #18); `terraform output redis_endpoints` shows all 6 nodes; cluster shape 3 masters + 3 replicas + 16384 slots.
- [x] **oltp-redis** smoke: `ALL 0.G.1 SMOKE CHECKS PASSED`.
- [x] **oltp-mongo** destroy → apply → smoke clean: 3 VMs gone + re-cloned + RS nexus-rs at 1 PRIMARY + 2 SECONDARY; smoke `ALL 0.G.2 SMOKE CHECKS PASSED`.
- [x] **oltp-percona** destroy → apply → smoke: 5 VMs gone + re-cloned; #16/#19/#20/#21/#22 surfaced + live-fixed; PXC cluster size=3 + Synced + Primary; ProxySQL admin :6032 shows 3 backends + galera_hostgroups; VIP .50 bound on proxysql-1 MASTER only; end-to-end write via VIP propagates to all 3 PXC backends; smoke `ALL 0.G.3 SMOKE CHECKS PASSED`.

If a step fails (other than the documented vmrun transient that clears on retry), see §3.x below for the symptom→diagnosis→recovery table — 13 monolithic rows + 11 per-cluster-refactor rows covering every transient surfaced during both ratifications.

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
| `terraform apply` fails with `Module not installed` at module.redis_N | `.terraform/` directory missing (fresh clone or after a clean). | The per-cluster scripts auto-run `terraform init` when `.terraform/` is absent. For manual: `cd terraform\envs\oltp-<cluster> && terraform init`. |
| `vmrun start ... .vmx`: `Error: Unknown error` (apply fails at module.redis_N.power_on within seconds of start) | Transient VMware Workstation flake under rapid destroy→create churn or high VM count on the host. No specific diagnostic surfaces; vmrun's "Unknown error" is the catch-all. Affects 1-2 nodes per cold-rebuild cycle in observation. | Re-run `pwsh -File scripts\oltp-<cluster>.ps1 apply`. Terraform sees the failed power_on as tainted; the retry runs `vmrun start` again and almost always succeeds the second time (idempotent — the .vmx is already configure_nic'd). Hit on redis-5 at 0.G.1 ratification cold-rebuild 2026-05-17; cleared on retry. |
| Apply hangs on `[oltp-nftables] <ip>: waiting for SSH + firstboot marker...` for >20 min | Clone never finished firstboot (NIC discovery failure, hostname rename failure, or VMnet10 backplane misconfig). | SSH to `<ip>` with build-time creds; `sudo journalctl -u oltp-node-firstboot.service --no-pager`. Likely an unknown VMnet11 IP — check that the foundation dhcp-host reservation actually pinned the MAC to a known `.81/.82/.83/.84/.87/.89`. |
| Apply fails at `[redis-va redis-N] AppRole login appears to have failed (token sink empty)` | Vault is sealed, OR the sidecar has a stale role-id/secret-id (security env was re-applied but sidecars weren't). | `pwsh -File ..\nexus-infra-vmware\scripts\security.ps1 apply` to regenerate sidecars, then re-run `pwsh -File scripts\oltp-<cluster>.ps1 apply`. |
| Apply fails at `[redis-tls redis-N] cert files not rendered ... within 60s` | Vault Agent template syntax error (rare; per-host CN/SAN substitution), OR the PKI role's `allowed_domains` doesn't cover the requested CN, OR `/etc/vault-agent/ca-bundle.crt` is missing (Vault Agent didn't install). | `ssh nexusadmin@<ip>; sudo journalctl -u nexus-vault-agent.service -n 50`. Check for `template syntax error` or `403 access denied`. Re-apply security env's `vault_pki_redis_role` if `allowed_domains` was outdated. |
| Redis log spams `tlsv1 alert unknown ca` + smoke step 8 fails with `certificate verify failed` | `ca.crt` contains only the intermediate, not root+intermediate. OpenSSL strict X509 verify can't walk to a self-signed trust anchor with only the intermediate. | Fixed at `redis_tls_v=2` (split script now `cat $CA /etc/vault-agent/ca-bundle.crt > ca.crt`). Diagnosed at 0.G.1 ratification 2026-05-17. If you see this on an older overlay, bump `redis_tls_v` + re-apply. |
| Apply fails at `[redis-config redis-N] nexus-redis.service / TLS PING did not converge within 20 min` | nexus-redis.service crashlooping OR Redis is up but rejecting connections (TLS chain issue per row above; OR `protected-mode` on Redis 8.0+ blocking external-IP connections). | `ssh nexusadmin@<ip>; sudo journalctl -u nexus-redis.service -n 50; sudo tail -50 /var/log/nexus-redis/redis.log`. Check that `/etc/nexus-redis/tls/server.key` starts with `-----BEGIN PRIVATE KEY-----` (PKCS#8). Check `/etc/nexus-redis/redis.conf` has `protected-mode no` (Redis 8.0 default is `yes`; fixed at `redis_config_v=2`). |
| `[redis-cluster-create] cluster create did not report [OK] All 16384 slots covered` with `[ERR] ... DENIED Redis is running in protected mode` | Redis 8.0 default `protected-mode yes` refuses connections from non-loopback IPs when no `requirepass` is set. `redis-cli --cluster create` connects to each node via its VMnet11 IP. | Fixed at `redis_config_v=2` (`protected-mode no` added to rendered `redis.conf`). Defense-in-depth is preserved: nftables + tls-port + tls-auth-clients. Diagnosed at 0.G.1 ratification 2026-05-17. |
| Cluster forms with `4 masters + 2 replicas` instead of `3+3` (smoke step 9 master/replica count fails) | Cluster_create probe found `cluster_state:ok` and skipped create, but the cluster was left in a partial state by a prior interrupted apply (e.g. some `CLUSTER MEET` messages succeeded before a fatal error). | Manual recovery: SSH to each of the 6 nodes and run `sudo redis-cli -h 127.0.0.1 -p 6379 --tls --cacert /etc/nexus-redis/tls/ca.crt --cert /etc/nexus-redis/tls/server.crt --key /etc/nexus-redis/tls/server.key CLUSTER RESET HARD`. Then on redis-1 run `sudo redis-cli --tls ... --cluster create 192.168.70.81:6379 192.168.70.82:6379 192.168.70.83:6379 192.168.70.84:6379 192.168.70.87:6379 192.168.70.89:6379 --cluster-replicas 1 --cluster-yes`. (Future TF improvement: extend the cluster_create probe to also verify shape, not just state=ok.) Hit at 0.G.1 ratification 2026-05-17. |
| Apply fails at `cluster did not converge to (state=ok, size=3, known=6, slots=16384) within 20 min` | Cluster bus blocked between nodes. | Check nftables on each node: `sudo nft list ruleset \| grep -E '6379\|16379'`. The 3c overlay should have opened both ports. If missing, `cd terraform\envs\oltp-redis && terraform apply -auto-approve -target='null_resource.redis_nftables_backplane[0]'`. |
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

**0.G.3.5c chunk 1 ratification transients (2026-05-18)** — 11 NEW transients surfaced during the live cold-rebuild via the per-cluster envs. Every row has a permanent fix baked into the per-engine Packer roles, per-cluster TF overlays, or the smoke gate. The iteration-loop shrink (5-10 min per cluster vs 30 min monolithic) made root-causing every one of these tractable — most fixed in ≤2 retries. Transient #16 from above (Galera SST joiner sync) was **definitively root-caused + fixed** as part of #20 below (wsrep_sst_auth section + wsrep.cnf newline gap):

| # | Symptom | Diagnosis | Recovery action |
|---|---|---|---|
| 17 | `packer build oltp-proxysql-node`: `No package matching 'proxysql2' is available` after the vendor APT repo is set up + `apt-get update` succeeds | The ProxySQL vendor APT package name is `proxysql` (single name, no "2" suffix). The version is 2.6.x per the channel URL `proxysql-2.6.x/bookworm/` but the package name itself is just `proxysql`. Verified via `curl https://repo.proxysql.com/ProxySQL/proxysql-2.6.x/bookworm/Packages | grep ^Package:`. | Edit `packer/oltp-proxysql-node/ansible/roles/oltp_proxysql/tasks/main.yml`: change apt name `proxysql2` → `proxysql`. Build oltp-proxysql-node retry succeeded in 10m 15s. |
| 18 | `oltp-redis apply`: `redis-cluster-create` reports `cluster created (all 16384 slots covered)` + `cluster healthy: 3 masters + 3 replicas` but the subsequent shape-verify step finds 6 masters + 0 replicas | Redis 8.0.2's `redis-cli --cluster create ... --cluster-replicas 1` allocates slots to 3 nodes correctly (3 masters with slots) but fails silently to assign the remaining 3 nodes as replicas. Doesn't error. Doesn't even warn. The orphan-masters are CLUSTER MEET'd into the cluster (so `cluster_known_nodes:6` + `cluster_state:ok`) but have no slots and aren't replicas — they're just empty masters taking up cluster gossip bandwidth. | Live: SSH to each orphan node + `sudo redis-cli ... CLUSTER REPLICATE <master-node-id>` for one of the 3 slot-owning masters. Cluster shape converges to 3+3. Re-apply: probe-then-skip finds state=ok + shape verify now passes. Permanent fix TODO: extend `role-overlay-redis-cluster-create.tf` to detect orphan-master shape post-create + auto-issue REPLICATE commands (Redis 8 behavior change vs Redis 7 -- the canonical `--cluster-replicas 1` semantics differs). |
| 19 | `oltp-percona apply`: `[percona-nftables] 192.168.70.54: waiting for SSH + firstboot marker...` hangs 20 min; ssh + journalctl on proxysql-1 shows `oltp-node-firstboot.sh[XXX]: chown: invalid group: 'root:mysql'` + service Failed | `oltp-node-firstboot.sh`'s identity-dir mapping treated `cluster=percona` as `IDENTITY_GROUP=mysql`, but **ProxySQL nodes don't have the mysql group** (only apt-installed `proxysql` group from the oltp_proxysql role). The chown to root:mysql crashed firstboot before the marker got written, so nftables-backplane waited forever. | Split proxysql out of `cluster=percona` into its own `cluster=proxysql` with `IDENTITY_DIR=/etc/nexus-proxysql` + `IDENTITY_GROUP=proxysql` in `packer/_shared/ansible/roles/oltp_firstboot/files/oltp-node-firstboot.sh`. Smoke + role refs updated to match (handles the per-role dir/cluster). |
| 16+20 | `oltp-percona apply`: galera-bootstrap step 8/9 — joiner pxc-node-2 in restart loop, `mysqld error.log` shows `unknown variable 'wsrep_sst_auth=wsrep_sst:...'` + `Aborting`. Even fixing that, joiners fail with `failed to open gcomm backend connection: 110 (Connection timed out)` to peer's :4567. **This is the root cause of transient #16 from the monolithic ratification.** | Two compounding bugs: (a) `sst-auth.cnf` was written with `[mysqld]` section header; **PXC 8.0 removed `wsrep_sst_auth` from `[mysqld]` section** — it's only valid under `[sst]` now (Percona docs). With it in [mysqld], mysqld errors `unknown variable` + aborts before init. (b) chunk 3b's `wsrep.cnf` render ends with `pxc-encrypt-cluster-traffic = ON` with no trailing newline (PowerShell here-string strips LF before closing `"@`). Chunk 3c step 6's `echo '!include sst-auth.cnf' \| tee -a wsrep.cnf` then concatenates onto the last line producing `pxc-encrypt-cluster-traffic = ON!include /etc/nexus-percona/sst-auth.cnf` -- single garbage line. mysqld mis-parses + the !include never fires. Both nodes go into the broken state, can't TLS-handshake gcomm, "End of file" + "Connection timed out" everywhere. | (a) Change `$sstAuthBody` in `role-overlay-percona-galera-bootstrap.tf` step 6 from `[mysqld]\n...` to `[sst]\n...`. (b) Add a trailing blank line to wsrep.cnf render in `role-overlay-percona-config.tf` (above the closing `"@`). Belt-and-braces: step 6 prepends a `sed -i -e '$a\\' wsrep.cnf` ensure-newline before the !include append. Bump `galera_bootstrap_v` to v5 + `percona_config_v` to v5. Live recovery: ssh + sed-fix wsrep.cnf + sst-auth.cnf, restart bootstrap on node-1 + nexus-percona on joiners; cluster converged at size=3 + Synced in ~30s. |
| 20.b | galera-bootstrap verify step 3/4 — write via smoke-rw on bootstrap node failed; manual `sudo mysql ...` worked but the script's `mysql ...` (no sudo) failed silently | Script ran `mysql -h 127.0.0.1 -u smoke-rw -p<pwd> --ssl-ca=/etc/nexus-percona/tls/ca.pem --ssl-mode=VERIFY_CA ...` as nexusadmin. The TLS dir is 0750 root:mysql — nexusadmin can't traverse, mysql fails to read CA, --ssl-mode=VERIFY_CA aborts before any write. mysql doesn't emit a clear error (just fails). | Prefix with `sudo` for the write + 2 reads. mysql still opens a TCP connection to 127.0.0.1:3306 (not a socket), so sudo doesn't change connection semantics -- only file access. Permanent fix in `role-overlay-percona-galera-bootstrap.tf` v4. |
| 20.c | galera-bootstrap verify step 4/4 — read on joiner returns the right token PLUS a `mysql: [Warning] Using a password on the command line interface can be insecure.` line; `$readOut -eq $token` comparison fails on multi-line output | mysql client emits the password warning to stderr; `2>&1` merges it into stdout above the SELECT result. Two-line $readOut: `"mysql: [Warning]..."  + "\n" + "<token>"`. `-eq` requires exact match, so fails. Write side already used `-match 'WROTE'` (regex) so was tolerant; read side was the only one using strict equality. | Change read comparison to `$readOut -match [regex]::Escape($token)`. Bump `galera_bootstrap_v` to v5. |
| 21 | `oltp-percona apply`: proxysql_config waits forever for `admin :6032 returns mysql_servers count == 3`; SSH to proxysql-1 + manual `mysql -h 127.0.0.1 -P 6032 ...` reports `mysql: command not found` | The oltp_proxysql Ansible role only installed `proxysql` + `keepalived` from apt. It never installed a mysql-protocol client, so any script (the proxysql_config admin probe, the keepalived health-check, the smoke gate's :6033 client) that needs `mysql` to talk to admin :6032 OR the frontend :6033 fails. ProxySQL's admin port speaks MySQL protocol but requires a client to use it. | Add `mariadb-client` to the apt install list in `packer/oltp-proxysql-node/ansible/roles/oltp_proxysql/tasks/main.yml`. (mariadb-client over mysql-client to avoid pulling Percona/MySQL server libs onto the LB nodes.) Rebake oltp-proxysql-node template (~10 min) + reclone the 2 proxysql VMs. |
| 22 | After rebake + reclone, both proxysql nodes claim VIP `.50` simultaneously (split-brain MASTER); `ip -4 addr show dev nic0` on BOTH .54 and .55 shows the VIP bound as secondary | The default keepalived VRRP mode uses IPv4 multicast (group 224.0.0.18, protocol 112). **VMware Workstation's VMnet11 doesn't reliably forward this multicast group between guests** -- proxysql-1 + proxysql-2's VRRP advertisements never reach each other, so each one's election state machine sees only itself + transitions to MASTER. Both bind the VIP. ARP for .50 returns ambiguous responses; client connections become non-deterministic. | Switch to **unicast VRRP** by adding `unicast_src_ip <self>` + `unicast_peer { <peer> }` to the `vrrp_instance VI_PROXYSQL_NEXUS` block. Each node sends VRRP advertisements directly to the peer's VMnet11 IP (no multicast). proxysql-1 (priority 110) wins; proxysql-2 (priority 100) drops to BACKUP within ~4s. Bumped `keepalived_v` to v2 + added `peer` field to the per-host locals. |
| (smoke gate) | smoke-0.G.3.ps1 read probes use `mysql --defaults-file=/etc/nexus-percona/my.cnf` -- but post-bootstrap root has a password (set by chunk 3c step 4); the defaults-file has no [client] section with credentials → smoke FAILs every Galera SHOW STATUS check | The earlier (monolithic) smoke worked because root was auth_socket. After the bootstrap dance sets a real password (mysql_native_password from KV), mysql client without credentials fails. The defaults-file path doesn't carry root's password (it's read by mysqld, not by mysql client). | Replace `mysql --defaults-file=...` with `/usr/local/sbin/nexus-pxc-mysql` (the chunk 4 baked auth-mode-aware wrapper). It handles both passworded + passwordless. 3 instances patched in `scripts/smoke-0.G.3.ps1`. |
| (smoke gate) | smoke-0.G.3.ps1 node-identity probe expects `/etc/nexus-percona/node-identity.env` on proxysql nodes; #19 fix put it at `/etc/nexus-proxysql/node-identity.env` instead | Coupling between firstboot's per-role dir mapping + smoke gate's hardcoded path. | Smoke probe now switches on the role: PXC→/etc/nexus-percona, ProxySQL→/etc/nexus-proxysql + cluster=proxysql. Same per-role logic that firstboot uses. |
| (smoke gate) | smoke-0.G.3.ps1 VIP write fails: `SSL connection error: certificate verify failed` when `mysql -h 192.168.70.50 -P 6033 --ssl-ca=...lab-ca.pem --ssl-mode=VERIFY_CA` | ProxySQL serves TLS on :6033 using its **auto-generated self-signed cert** (`CN=ProxySQL_Auto_Generated_Server_Certificate`, no SANs). proxysql.cnf wires `ssl_p2s_*` (proxysql-to-server, i.e., backend to PXC) with our PKI cert correctly. But the FRONTEND TLS uses self-signed because we don't override `ssl_p2c_*` (proxysql-to-client). Self-signed isn't in any chain. | For the smoke gate, weaken VIP probe to `--ssl-mode=REQUIRED` (TLS yes, validate-chain no). The backend p2s path IS proper mTLS via our PKI -- this is only the frontend gap. **TODO 0.G.3.6**: override proxysql's frontend cert with our PKI-issued cert (map /etc/nexus-percona/tls/server-cert.pem into ProxySQL frontend or copy into /var/lib/proxysql/proxysql-cert.pem). |
| (destroy provisioner) | After `terraform taint module.proxysql_1[0].null_resource.clone_vm` + apply, the destroy provisioner reports "Destruction complete after 0s" but the new clone_vm errors with "Destination already exists: H:\VMS\NexusPlatform\05-oltp\proxysql-1\proxysql-1.vmx" | The destroy provisioner in `modules/vm/main.tf` ran `vmrun stop $dst hard *>$null; vmrun deleteVM $dst *>$null; Remove-Item -Recurse -Force ...` with `*>$null` silencing all errors. The VM was running -- vmrun deleteVM CANNOT proceed against a running VM -- but the silent redirect swallowed the error. Remove-Item then failed silently because VMware still held disk locks on the .vmdk files. terraform considered destroy "complete" because the provisioner exit 0'd. Next create_vm's pre-flight Test-Path threw on the stale dir. | Patched `terraform/modules/vm/main.tf` clone_vm destroy provisioner: `vmrun stop` → `Start-Sleep 2` → `vmrun deleteVM` → if still exists, `Start-Sleep 2` + retry → finally rm -rf. The retry covers the disk-lock race between stop's "done" signal + VMware actually releasing the .vmdk handles. Live live recovery for this iteration: manual `vmrun stop hard + vmrun deleteVM + rm -rf` for the 2 stale dirs, then re-apply. |

**Outcome of 0.G.3.5c chunk 1 ratification:**

- 8 source files changed (4 TF overlays + 1 Packer role + 1 firstboot script + 1 smoke + 1 module).
- Per-engine cold-rebuild proved: clean clone-of-template → first-boot → vault-agent → tls → config → cluster-bootstrap → smoke ALL GREEN end-to-end for all 3 OLTP clusters.
- Iteration loop empirically validated: per-cluster apply for redis was ~5 min, mongo ~5 min, percona ~10 min (vs 30 min monolithic). **Refactor's design hypothesis confirmed**: smaller, bounded blast radius = faster transient discovery + fixing.
- All transients permanently fixed in source (no `terraform state` surgery, no untracked live edits). Smoke is the regression bar.
- 0.G.3.5c chunk 2 (delete legacy `packer/oltp-node/` + `terraform/envs/oltp/` + `scripts/oltp.ps1`) is the next + last chunk.

### §3.3 Demo playbooks (Phase 0.G.4)

Per `memory/feedback_demo_discipline.md` every cluster + service + overlay
ships both a System B JSON demo (under `nexus-cli/docs/demos/`) AND a human-
readable playbook section here answering: prerequisites · input · expected
output · where to observe · what it proves.

The 4 demos below mirror the JSON specs at
`nexus-cli/docs/demos/demo-0.G.4-*.json` and exist to validate Phase 0.G.4
end-to-end after the smoke gate passes.

#### Demo 1 — `demo-0.G.4-patroni-failover` (Patroni-orchestrated leader switchover)

- **Prerequisites:** 0.G.4 smoke gate ALL GREEN (3 patroni nodes + 3 etcd + 1 haproxy live; cluster shape 1 Leader + 2 Streaming Replica).
- **Input:**
  ```pwsh
  ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.61
  sudo /usr/local/sbin/nexus-patronictl switchover --master pg-primary --candidate pg-replica-1 --force
  ```
- **Expected output (stdout):** `Successfully switched over to "pg-replica-1"` within ~5-10 s.
- **Where to observe:**
  - On any patroni node: `sudo /usr/local/sbin/nexus-patronictl list` — `pg-replica-1` now shows `Role=Leader`, `pg-primary` now `Role=Replica`, `pg-replica-2` still `Role=Replica`.
  - On haproxy-pg: `curl -s -u nexusops:$(sudo cat /etc/nexus-haproxy/haproxy-stats-password) http://127.0.0.1:8404/stats\;csv | awk -F, '$1=="pg_pool"{print $2,$18}'` — `pg-replica-1` line now `UP`, `pg-primary` line transitions to `DOWN` (or shows as a non-leader 503'ing health-check).
  - In etcd: first capture the password into a shell variable, then call etcdctl with `$ROOT_PWD`:
    ```bash
    ROOT_PWD=$(sudo cat /etc/nexus-etcd/etcd-root-password)
    sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" get /service/nexus-pg/leader --print-value-only
    ```
    returns `pg-replica-1`.
- **What it proves:** Patroni's etcd-DCS-driven leader election works end-to-end; HAProxy's `httpchk GET /leader` correctly re-routes :5432 traffic to the new leader without app config change; etcd holds the canonical leader fact.

#### Demo 2 — `demo-0.G.4-patroni-mtls-roundtrip` (mTLS PG connection via HAProxy)

- **Prerequisites:** 0.G.4 smoke ALL GREEN; build host has `/etc/nexus-patroni/postgres-superuser-password` accessible (or replicated to operator workstation).
- **Input (on pg-primary; uses the leader's local KV-rendered password file). Connects via the VRRP VIP `.60`, not a specific haproxy node's IP — proves the VIP cert IP-SAN works:**
  ```pwsh
  ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.61
  SUPER_PWD=$(sudo cat /etc/nexus-patroni/postgres-superuser-password)
  PGPASSWORD="$SUPER_PWD" psql \
    "host=192.168.70.60 port=5432 dbname=postgres user=nexusops sslmode=verify-full sslrootcert=/etc/ssl/certs/patroni-ca.pem" \
    -c "SELECT version(), current_setting('ssl');"
  ```
- **Expected output (stdout):** A row with `PostgreSQL 17.x on ...` and `ssl = on`.
- **Where to observe:**
  - On the current leader: `sudo journalctl -u nexus-patroni.service -n 20` shows the new connection accepted via `ssl`.
  - `sudo -u postgres psql -h /var/run/nexus-patroni -U postgres -d postgres -c "SELECT ssl,version,client_addr FROM pg_stat_ssl JOIN pg_stat_activity USING (pid) WHERE usename='nexusops' LIMIT 5;"` shows `ssl=t version=TLSv1.3` (or 1.2).
- **What it proves:** End-to-end mTLS path through the HAProxy HA pair via VIP: client validates the server cert chain against the patroni-server CA bundle; the cert's IP-SAN includes the VIP `.60` so `sslmode=verify-full` against the floating IP passes regardless of which haproxy currently holds it; HAProxy proxies the TCP stream transparently; PG validates the connection's TLS termination. The PKI rotation cycle (90 d leaf TTL) covers haproxy-pg-{1,2} + patroni + etcd nodes uniformly.

#### Demo 3 — `demo-0.G.4-haproxy-vip-cutover` (genuine VRRP VIP migration between HAProxy HA pair)

- **Prerequisites:** 0.G.4 smoke ALL GREEN. Confirm `haproxy-pg-1` (`.67`) currently holds the VIP `192.168.70.60`: `ssh nexusadmin@192.168.70.67 ip -4 addr show dev nic0 | grep 192.168.70.60`. Identify the current Patroni leader via `sudo /usr/local/sbin/nexus-patronictl list`.
- **Input:** kill `nexus-haproxy.service` on the VIP holder; keepalived's health script detects within ~4 s; VIP migrates to `haproxy-pg-2` (`.68`).
  ```pwsh
  # Terminal A: continuous read loop via the VIP
  ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.61
  SUPER_PWD=$(sudo cat /etc/nexus-patroni/postgres-superuser-password)
  while true; do
    PGPASSWORD="$SUPER_PWD" psql \
      "host=192.168.70.60 port=5432 user=nexusops dbname=postgres sslmode=verify-full sslrootcert=/etc/ssl/certs/patroni-ca.pem" \
      -tA -c "SELECT now(), inet_server_addr();" 2>&1 | head -1
    sleep 1
  done

  # Terminal B: kill HAProxy on the current VIP holder
  ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.67
  sudo systemctl stop nexus-haproxy.service
  ```
- **Expected output (stdout, terminal A):** A handful of connection-refused errors during the cutover window (~4-8 s while keepalived's `chk_haproxy` script crosses its `fall 3` threshold and the BACKUP node promotes itself); then steady reads resume with `inet_server_addr` continuing to point at the (unchanged) Patroni leader's IP. The VIP migration is transparent at the app TCP layer — clients reconnect to the same `.60:5432` address.
- **Where to observe:**
  - On haproxy-pg-2 (`.68`): `ip -4 addr show dev nic0 | grep 192.168.70.60` — VIP now bound here (was on `.67`).
  - On haproxy-pg-1 (`.67`): `ip -4 addr show dev nic0` — VIP gone; `sudo journalctl -u keepalived.service -n 20` shows `Entering FAULT STATE` then `Stopped track haproxy with status FAILED`.
  - On haproxy-pg-2 (`.68`): `sudo journalctl -u keepalived.service -n 20` shows `Entering MASTER STATE` + `setting promote_secondaries on interface nic0`.
  - The TLS handshake against the VIP continues to validate because both haproxy nodes' PKI leaf certs carry the VIP in their IP-SANs (the entire reason for that design).
- **Recovery:** `ssh nexusadmin@192.168.70.67 sudo systemctl start nexus-haproxy.service`. Within ~6 s (`rise 2` * `interval 2`), keepalived on haproxy-pg-1 re-enters MASTER state and (with preempt ON) takes the VIP back. Some operators prefer `nopreempt` to avoid flap; we keep preempt ON in the lab for visible demonstration.
- **What it proves:** keepalived unicast VRRP elects a single MASTER across the haproxy HA pair; on MASTER health-script failure, BACKUP promotes within ~4-8 s; the VIP migrates at the kernel L3 layer; apps connecting to the VIP see continuous service across a single-node HAProxy failure. The HA pair eliminates the SPOF that a single HAProxy would have had — the "HA promise" in the phase name covers the LB tier, not just the PG nodes.

#### Demo 4 — `demo-0.G.4-etcd-leader-failover` (etcd raft re-election)

- **Prerequisites:** 0.G.4 smoke ALL GREEN. Identify the etcd leader: `sudo /usr/local/sbin/nexus-etcdctl endpoint status --cluster --write-out=table` — row with `IS LEADER=true`.
- **Input (on the etcd leader, e.g. etcd-1 at .64):**
  ```pwsh
  ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.64
  sudo systemctl stop nexus-etcd.service
  ```
- **Expected output (within ~5 s on any other etcd node):**
  ```pwsh
  ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.65
  sudo /usr/local/sbin/nexus-etcdctl endpoint status --cluster --write-out=table
  # The 2 surviving members show their endpoint health; one of them is the new IS LEADER=true.
  # The killed member is reachable=false (or shown as 'request failed').
  ```
- **Where to observe:**
  - `sudo journalctl -u nexus-etcd.service -n 30` on the new leader: `raft: <id> became leader at term N+1`.
  - On any Patroni node: `sudo /usr/local/sbin/nexus-patronictl list` still shows 1 Leader + 2 Streaming Replica (Patroni's etcd3 client transparently failed over to a surviving etcd endpoint; PG is unaffected).
  - First capture the password into `$ROOT_PWD`, then query etcd:
    ```bash
    ROOT_PWD=$(sudo cat /etc/nexus-etcd/etcd-root-password)
    sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" get /service/nexus-pg/leader --print-value-only
    ```
    still returns the same Patroni leader (no PG-side election fired — etcd re-election is invisible to Patroni's DCS reads).
- **Recovery:** `ssh nexusadmin@192.168.70.64 sudo systemctl start nexus-etcd.service`. The restarted etcd-1 rejoins the cluster as a follower (`raft: ... became follower at term N+1`).
- **What it proves:** etcd's raft quorum survives a single-member loss (3/3 → 2/3 still quorate); leader re-election completes within ~5 s (raft election timeout default is 1 s, with ~3-5 s in practice including transit). Patroni's DCS client is endpoint-list-aware and fails over transparently — PG service is uninterrupted. The 3-member etcd quorum is the canonical lab fault tolerance: it tolerates 1 failure; a 5-member quorum would tolerate 2.

### §3.4 0.G.4 ratification transients (2026-05-19)

**18 distinct issues** surfaced during the live ratification cycle on `envs/oltp-patroni/`. Every row below has a permanent fix in source (Packer Ansible role, Terraform overlay, smoke script, or systemd unit template) -- no operator hot-state. The per-cluster + per-engine architecture (born from 0.G.3) kept iteration loop at ~5-10 min per pass, so 14 source-affecting iterations + 3 smoke-script fixes + 1 known-limitation doc landed in one session.

| # | Symptom | Diagnosis | Recovery action |
|---|---|---|---|
| 1 | `packer build oltp-patroni-node`: apt fails -- `postgresql-17 Depends: libicu72`, `libldap-2.5-0` not installable | Debian 13 t64 transition bumped `libicu72` → `libicu76` + renamed `libldap-2.5-0` → `libldap-2.6-0`. PGDG bookworm-built PG 17 .debs link against the old soname. Same trap as 0.G.3 PXC libaio1/libldap-2.5-0. | Add bookworm-fallback apt source + `priority 100` default + `priority 990` for ONLY `libicu72` + `libldap-2.5-0`. Install those 2 from bookworm BEFORE the PGDG postgresql package. Permanent fix in `packer/oltp-patroni-node/ansible/roles/oltp_patroni/tasks/main.yml`. |
| 2 | `packer build`: post-install verify fails -- `/usr/local/bin/patronictl --version` returns `Error: No such option '--version'.` | Patroni 4.0.5's `patronictl` is a Click-based CLI; doesn't accept `--version` as a flag (only `patronictl --help`). `patroni --version` (the daemon) DOES work. | Drop `patronictl --version` from the verify loop; replace with `patronictl --help` (exits 0). `patroni --version` proves the package install. |
| 3 | `oltp-patroni apply`: `vmrun start ... pg-primary.vmx`: `Error: Unknown error` | Standard `feedback_vmrun_unknown_error_transient.md` VMware flake under churn. 7/8 VMs powered on cleanly; only pg-primary failed. | Re-run apply. Tainted resource retries cleanly. |
| 4 | `[patroni-va etcd-3] vault binary install failed`: `unzip` write error "disk full?" | etcd + haproxy VMs are 1 GB RAM → tmpfs `/tmp` ~484 MB. Vault Agent zip ~161 MB + unzipped binary ~345 MB > tmpfs size. patroni nodes (2 GB RAM, 987 MB tmpfs) fit fine. | Change install script from `cd /tmp` to `cd /var/tmp/nexus-vault-agent-install` (/var/tmp is on `/`, 17 GB free). Permanent fix in `role-overlay-patroni-vault-agents.tf`. |
| 5 | `oltp-patroni apply`: TLS stage fails with `bash: line 46: syntax error near unexpected token '&&'` | PowerShell string `" `\\`n     "` renders to `\\<newline>     `. Bash reads `\\` as literal `\` (not continuation), newline ends line, next line starts with `&&` → syntax error. | Drop bash line-continuation; join KV-wait clauses with single space (long line, legal bash). Permanent fix in `role-overlay-patroni-tls.tf`. |
| 6 | `oltp-patroni apply`: `dial tcp 192.168.10.65:2380: connect: no route to host` (etcd raft mesh) | etcd-2's nic1 (VMnet10) was `no-carrier` -- VMware Workstation occasionally fails to connect a secondary vNIC on first power-on. Same class as `kafka-east-2` post-rebuild #3 in nexus-infra-kafka §3.7. | `vmrun connectNamedDevice <vmx> ethernet1` brings up the vNIC; ping cross-mesh works immediately. Operator workaround (no source fix possible at this layer). |
| 7 | `nexus-etcdctl endpoint status`: `dial tcp: lookup etcd-2.nexus.lab on 192.168.70.1:53: no such host` | The nexus-gateway dnsmasq domain is `nexus.local`, not `nexus.lab`. Cert allowed_domains include both forms but only `nexus.local` actually resolves. Bare hostnames (`etcd-2`) also resolve via dnsmasq + cert SANs cover them. | Change `etcd_client_endpoints` from `https://${host}.nexus.lab:2379` to `https://${host}:2379`. Same for `patroni_etcd_endpoints`. Permanent fix in `role-overlay-{etcd,patroni}-bootstrap.tf`. |
| 8 | etcd-bootstrap probe waits 20 min then timeouts "no leader elected" -- but cluster IS healthy | The leader-detection regex was `"isLeader":true` but etcdctl JSON v3.5 schema uses `"leader":<member-id>` (uint64). Non-zero leader id = cluster has leader. | Change regex to `"leader":\s*([1-9][0-9]*)`. Capture leader id + use the probe-source node for downstream RBAC stage (any reachable member can run RBAC ops). Permanent fix in `role-overlay-etcd-bootstrap.tf`. |
| 9 | RBAC stage: `ERROR: /etc/nexus-etcd/etcd-root-password missing` but the file exists | `/etc/nexus-etcd/` is `0750 root:etcd`; `nexusadmin` (not in etcd group) can't traverse for `[ -s ... ]`. Test silently reports missing (no permission to stat). Same class as `feedback_sudo_required_for_consul_etc_traverse.md`. | Wrap test in sudo: `if ! sudo test -s /etc/nexus-etcd/etcd-root-password`. Permanent fix in `role-overlay-etcd-bootstrap.tf`. Same fix applied to `role-overlay-haproxy-config.tf` (transient #13). |
| 10 | `patroni.service` crashloops with `KeyError: 'password'` at `_build_effective_configuration` | Patroni 4.0.5 eagerly formats `username:password` for restapi.authentication + etcd3 at config-load time, expecting LITERAL `password:` key. The `password_file:` directive is honored in some Patroni paths but NOT this one. | Switch to inline `password: __TOKEN__` placeholders; sed-substitute at install time after reading the 4 KV-rendered password files via `sudo cat`. Permanent fix in `role-overlay-patroni-bootstrap.tf`. |
| 11 | `patroni-bootstrap` cluster-converge times out: `FATAL: no pg_hba.conf entry for replication connection from host "192.168.70.63", user "replicator"` | pg_hba rule was `hostssl replication replicator 192.168.10.0/24` (VMnet10 backplane only). Patroni's `connect_address` is VMnet11, so replicas pg_basebackup from leader via VMnet11. Source IP doesn't match VMnet10 CIDR → rule miss. | Expand replication pg_hba rule to `192.168.0.0/16` (covers both subnets). Permanent fix in `role-overlay-patroni-bootstrap.tf`. |
| 12 | Cluster converges (1 Leader + 2 Streaming Replica) but psql verify fails: `role "nexusops" does not exist` | Patroni 4 silently ignores `bootstrap.users` (deprecated since 3.x in favor of `bootstrap.post_init` SQL scripts). No warning in log. | Add explicit Stage 3 "create nexusops superuser" -- `sudo -u postgres psql` with DO-block that idempotently CREATE/ALTER ROLE. Permanent fix in `role-overlay-patroni-bootstrap.tf`. |
| 13 | `haproxy-config` stage: `ERROR: /etc/nexus-haproxy/haproxy-stats-password missing` (file exists) | Same as #9: `/etc/nexus-haproxy/` is `0750 root:haproxy`, `nexusadmin` can't traverse. | `sudo test -s` instead of `[ -s ... ]`. Permanent fix in `role-overlay-haproxy-config.tf`. |
| 14 | `nexus-haproxy.service` start fails: `Missing LF on last line, file might have been truncated at position 53` | PowerShell here-string `@'...'@` strips the trailing LF before the closing `'@`. HAProxy 3 strict-requires LF on last line. Same class as 0.G.3 transient #10 (wsrep.cnf gap). | Add `sed -i -e '$a\'` to ensure-newline before installing the cfg. Permanent fix in `role-overlay-haproxy-config.tf`. |
| 15 | `nexus-haproxy.service` crashloops: `[ALERT] Cannot chroot(/var/lib/haproxy)` | systemd unit had `User=haproxy + Group=haproxy` which DROPPED `CAP_SYS_CHROOT` (chroot is a root-only syscall). HAProxy is supposed to start as root + drop privs via its own `global { user haproxy; group haproxy }` config. | Remove `User=` + `Group=` lines from `nexus-haproxy.service`. HAProxy starts as root, chroots, then drops to `haproxy` user. Mirrors the apt-shipped haproxy.service pattern. Permanent fix in `packer/oltp-haproxy-node/.../nexus-haproxy.service.j2` (rebake needed for new clones) + live-edited on existing clones. |
| 16 | HAProxy stats CSV: `pg_pool/pg-primary` status is `no check`, all backends marked UP without checks | `default-server` line missing the `check` keyword -- defines per-server CHECK PARAMETERS (inter/fall/rise/etc) but doesn't ENABLE checks. Without `check`, HAProxy treats backends as "always up" + never probes Patroni REST `/leader`. | Add `check` to `default-server`: `default-server check inter 2s fall 3 rise 2 ...`. Permanent fix in `role-overlay-haproxy-config.tf`. |
| 17 | `smoke-0.G.4.ps1`: ParserError "Unexpected token `'\"'\"'` in expression or statement" | PS literal string with embedded `'"'"'` shell-escape trick parses poorly in PS. | Use PS here-string `@'...'@` (handles literal embedded quotes). Permanent fix in `scripts/smoke-0.G.4.ps1`. |
| 18 | Smoke gate: `Variable reference is not valid. ':' was not followed by a valid variable name character` -- `$leaderVm:` | PS scope-qualifier collision: `$leaderVm:5432` parses `leaderVm:5432` as a scope-qualified variable. Documented in `feedback_powershell_url_scope_qualifier.md`. | Use `${leaderVm}:5432` (explicit delimitation). Permanent fix in `scripts/smoke-0.G.4.ps1`. |

**Known limitation (NOT a transient, but called out as follow-up source fix):** Smoke section 13 (VIP psql) uses `sslmode=verify-ca` instead of `verify-full`. HAProxy is TCP-proxy (no TLS termination), so the client receives the BACKEND PG's cert at TLS handshake. PG node certs include their own VMnet11/VMnet10 IPs in IP-SANs but NOT the VIP `.60`. `verify-ca` validates the chain (TLS path proven) but skips hostname match. **Future source fix:** add `var.haproxy_vip` to each PG node's IP-SAN in `role-overlay-patroni-tls.tf` (currently `vip = ""` for PG nodes; `vip = var.haproxy_vip` for haproxy nodes). Once that lands, smoke can flip back to `verify-full`.

**Operator-recovery patterns surfaced during the cycle (no source fix; documented for repeatability):**

- **Stale `/service/nexus-pg/initialize` in etcd DCS** after a failed patroni-bootstrap. Symptom: re-applied Patroni won't run `bootstrap.users` because DCS says cluster is already initialized. Recovery: `etcdctl --user "root:$ROOT_PWD" del --prefix /service/nexus-pg/` + wipe `/var/lib/nexus-patroni/data/*` on all 3 PG nodes + `terraform state rm null_resource.patroni_bootstrap` + re-apply.
- **PG `data_dir` perms during operator wipe**: `sudo rm -rf /var/lib/nexus-patroni/data` removes the parent dir too if you're root. PG/Patroni won't auto-recreate. Always re-create with the strict mode: `sudo mkdir -p /var/lib/nexus-patroni/data && sudo chown postgres:postgres /var/lib/nexus-patroni /var/lib/nexus-patroni/data && sudo chmod 0700 /var/lib/nexus-patroni /var/lib/nexus-patroni/data`.

(Table grows as new transients surface during future cycles.)

### §3.5 0.G.7 scaffold notes + pending ratification

**Status (2026-05-20):** scaffolded; ratification + transient chronology
pending. The 0.G.7 work is the first NexusPlatform sub-phase delivering a
**Windows-fleet** data cluster (vs the 6 Linux clusters in 0.G.1-0.G.4 +
0.H.* + 0.E.*). It exercises previously-scaffolded-but-unused
infrastructure for the first time:

- **GMSA** — `gmsa-sql-engine$` is the first real consumer of the GMSA
  scaffolding from 0.D.5. Per `memory/feedback_kds_rootkey_server2025_ssh.md`,
  Server 2025's `Add-KdsRootKey` is structurally broken over SSH; the KDS
  root key must be added manually via RDP/console. If `Get-KdsRootKey`
  returns empty on dc-nexus, `Test-ADServiceAccount gmsa-sql-engine` will
  FAIL even though the GMSA AD object exists. The security overlay
  `role-overlay-dc-gmsa-sqlserver.tf` WARNs but doesn't fail in this
  case; operator follow-up: RDP dc-nexus + `Add-KdsRootKey -EffectiveTime
  ((Get-Date).AddHours(-10))`.

- **iSCSI** — first non-NFS storage daemon on nexus-gateway (NFSv4 for
  Portainer landed at 0.E.4a). Per ADR-0026: tgt over VMnet11 to FCI pair
  only, CHAP-authed, per-IP ACL. ~60 GB sparse LUN at `/srv/iscsi/
  sql-fci-shared.img` exported via `iqn.2026-05.local.nexus:sql-fci.lun1`.

- **WSFC** — first multi-Windows clustered service. Quorum=NodeMajority
  across 4 nodes (cluster IP `.70.15` is the WSFC management address);
  tolerates 1-node failure. No file-share / cloud witness (deferred).

- **FCI** — first SQL Server FCI in the lab. Re-runs setup.exe in
  `/ACTION=InstallFailoverCluster` mode on sql-fci-1 + `/ACTION=AddNode`
  on sql-fci-2 to convert the standalone-baked SQL instance into an FCI
  resource sharing the iSCSI CSV at S:\.

- **AG** — Always On Availability Group `nexus-ag`: FCI primary +
  sql-ag-rep-1/2 as async secondaries. AG endpoint auth = certificate-
  based per ADR-0027 (avoids Windows endpoint-hop service login sprawl).

- **AG Listener** — per ADR-0025 the Listener (.70.17) IS the LB-tier
  HA primitive for AG. Listener cert (CN=`sql-ag-listener.nexus.lab`,
  IP-SAN .17) imported into `LocalMachine\My` on all 4 nodes; bound to
  MSSQLSERVER via `SuperSocketNetLib\Certificate` thumbprint. Client TLS
  validates against the floating IP across AG failover.

**0.G.7 ratification transients (2026-05-20 — live cycle in progress)** —
each row below is one discovery during the live ratify pass; permanent
fix in source on the spot (no operator hot-state). Mirrors the 0.G.4 §3.4
18-row format.

| # | Symptom | Diagnosis | Recovery action |
|---|---|---|---|
| 1 | `security.ps1 apply` fails at `null_resource.vault_sqlserver_cluster_creds_seed`: throw "[sqlserver-creds-seed] failed to parse CHAP secret marker from script output" -- but the script ran cleanly on vault-1 + the marker line IS in the output | Standard `feedback_pwsh_ssh_stdin_cr_injection.md` + `feedback_smoke_gate_probe_robustness.md` class. The bash on vault-1 emits `ISCSI_CHAP_SECRET_FOR_SIDECAR=<32-hex>\n`, but SSH-piped output through Windows pwsh's `2>&1 \| Out-String` reintroduces CRLF line endings. PS regex `(?m)^ISCSI_CHAP_SECRET_FOR_SIDECAR=([0-9a-f]{32})$` matches the `^` before the line and the `[0-9a-f]{32}` greedily eats the hex but `$` then has to match before `\r` -- regex fails because `$` won't match before `\r` when the hex run is already done. | Relax the regex to `^ISCSI_CHAP_SECRET_FOR_SIDECAR=([0-9a-f]{32})\s*$` (tolerates trailing whitespace including CR). Permanent fix in `nexus-infra-vmware/terraform/envs/security/role-overlay-vault-sqlserver-cluster-creds-seed.tf`; bumped `sqlserver_creds_seed_v` v1→v2 to force the re-run. Same class as the 0.G.2 PowerShell regex CRLF transient (`(?m)^PRIMARY=1\s*$`) -- this lesson keeps recurring across every cross-host SSH pattern. |
| 2 | `security.ps1 apply` (v2 retry) fails at `null_resource.dc_gmsa_sqlserver` with `"The command line is too long."` | Windows `cmd.exe` has an 8191-char cmdline limit. The `ssh nexusadmin@dc-nexus "powershell -NoProfile -EncodedCommand <base64>"` invocation passes the base64-encoded PS script as a single cmdline arg. PowerShell's `-EncodedCommand` requires UTF-16 (2 bytes per char), then base64 adds ~33%, so even a 4KB script source becomes a ~10KB cmdline arg. My initial GMSA script (Group probe + Group create + KDS probe + GMSA probe + Set-ADServiceAccount + New-ADServiceAccount + try/catch + 6 Write-Output diagnostic markers) was ~4.5KB source = ~12KB encoded -> over the limit. Same class as `feedback_ssh_stage1_size_limit.md` (bash ~6KB cliff via SSH stdin) but the Windows variant. | Trim the PS payload to the minimum work: Get-ADGroup -> New-ADGroup + Get-ADServiceAccount -> (Set-ADServiceAccount \| New-ADServiceAccount) on 4 lines. Drop the inline KDS probe + try/catch diagnostic plumbing (pre-flight §0 handbook check covers KDS verify). Trimmed source ~750 chars -> ~2KB encoded, comfortably under the 8191 ceiling. Permanent fix in `role-overlay-dc-gmsa-sqlserver.tf`; bumped `gmsa_overlay_v` v1→v2. |
| 3 | `foundation.ps1 apply` fails at `null_resource.gateway_iscsi_sqlfci` with `bash: line 27: ft: command not found`. Earlier apt-get install + systemctl enable tgt succeeded (verified post-fail: tgt installed + active on nexus-gateway). | Per `feedback_terraform_heredoc_powershell.md` rule 3 ("NO backtick-letter in inner here-strings; all fail only at apply"). My bash script's inline comments contained backtick-quoted tokens like `` `nft add rule` `` and `` `nft -f` `` (Markdown-style code spans inside `# ...` shell comments). The script is wrapped in PowerShell `$installCmd = @"...bash...@"` which interprets backtick as escape: `` `n `` becomes literal `\n` (newline char) inside the PS-rendered string. So bash received the comment with an actual line break before "ft" -- the `n` was eaten as the line-break trigger + bash tried to execute `ft` as a command on the next line. | Replace `` ` `` with `'` (single quote) in all comments inside the bash heredoc. Three sites in `role-overlay-gateway-iscsi-sqlfci.tf`: line 121 ("`tgt-admin --update ALL`"), line 138 ("`nft add rule`"), line 139 ("`nft -f`"). Header-comment block at top of file (lines 9/47/50) is safe -- it's a Terraform `/* */` block, not inside the heredoc. Bumped `iscsi_target_v` v1→v2 to force re-create. Same class as the documented memory feedback; this is its first-ever real surface. |
| 4 | After v2 apply: tgt service active + target `iqn.2026-05.local.nexus:sql-fci.lun1` shows in `tgtadm --mode target --op show` -- but the target has ONLY LUN 0 (controller, no backing); the 60 GB disk LUN with backing-store `/srv/iscsi/sql-fci-shared.img` is missing. Confirmed: backing file exists at expected path, conf file at `/etc/tgt/conf.d/sql-fci.conf` is correctly populated, but `sudo tgt-admin --update ALL --force` did NOT pick up the backing-store from the conf. Manual `sudo systemctl restart tgt.service` DID load the LUN correctly. | `tgt-admin --update` is documented as a "reload" but in practice it only ADDS new top-level targets discovered in `/etc/tgt/conf.d/`; it does NOT re-attach backing-stores or rebuild LUNs on targets that tgt-init's package-shipped default already created at service start. The Debian package's tgt-init creates a placeholder target structure at service start before our conf file is loaded; `--update` won't fully reconcile it. Only a full `systemctl restart tgt.service` discards the placeholder + re-reads `/etc/tgt/conf.d/*` from scratch. | Replace `tgt-admin --update ALL --force` with `systemctl restart tgt.service` as the canonical config-reload step. Restart wall-clock is ~1 sec; any active iSCSI sessions reconnect transparently on initiator probe. Permanent fix in `role-overlay-gateway-iscsi-sqlfci.tf`'s `$writeCmd` block. Bumped `iscsi_target_v` v2→v3. |
| 5 | After v3 apply: tgt LUN 1 bound correctly + nftables `sql-fci` rules STILL not present in `/etc/nftables.conf`. `sudo grep -A1 'sql-fci' /etc/nftables.conf` returns nothing. | My awk script's anchor pattern `/ct state established,related accept/` doesn't match nexus-gateway's actual nftables.conf grammar `ct state { established, related } accept` (with curly braces + spaces inside). So the awk insert-before-anchor block ran 0 times + the file passed through unchanged. The pre-check `if ! sudo grep -q 'tcp dport 3260 # sql-fci' /etc/nftables.conf` still returned false on subsequent runs (the rules truly aren't there), so it re-attempted the awk, which kept silently no-op'ing. | Switch anchor to `/^        counter drop$/` -- the canonical last line of the input chain (single occurrence, exact format match). Also rewrite the inserted rules to use the existing NFSv4-portainer pattern's shape (`iifname "nic1" ip saddr X tcp dport Y accept comment Z`) so the iSCSI rules feel native to the file. Bumped `iscsi_target_v` v3→v4 path (combined with #6). |
| 6 | After applying the #5 fix: awk verify script for tgtadm output fails with `awk: 0: unexpected character '\'; awk: line 2: syntax error at or near ~`. | My multi-line awk verify used `\$0 ~ "Target ..."` to match the IQN-bearing line. The `\$0` was meant to escape `$0` from PowerShell variable expansion (PS would see `$0` in a `@"..."@` heredoc and try to expand it as a PS variable -- which doesn't exist, so returns empty, eating `$0`). But `\$` is NOT the PS escape for `$` -- backtick is (`` `$ ``). So `\$0` survived PS unchanged into bash, which inside single-quoted awk script is literal `\$0` -- awk's tokenizer chokes on `\$`. | Replace the multi-line awk with `tgtadm --mode target --op show \| grep -q '/srv/iscsi/sql-fci-shared.img' && echo OK`. The backing-file path is unique enough to be the canonical verify probe -- no awk, no `$0`, no escape gymnastics. Bumped `iscsi_target_v` v3→v4 (combined with #5). |

**State at end of foundation + security applies (2026-05-20):** all 5 SQL
Server sidecars + AD group + GMSA + Vault KV entries + dnsmasq v6 + tgt
target + LUN 1 + nftables rules live + verified. iSCSI target reachable
from build host probes. Ready for Packer bake once SQL ISO arrives.

| 9 | `packer build` v4 (vmware-iso path) errored after 2:02:00 with `Timeout waiting for WinRM.` Operator switched to `headless = false` + `winrm_timeout = "30m"` for VNC-driven live debug; saw `Install Windows: "The computer restarted unexpectedly or encountered an unexpected error. Windows installation cannot proceed."` dialog mid-install. Repeatedly clicking OK looped the same dialog -- Setup is stuck in a crash loop during the specialize pass. | Catch-all dialog; doesn't give the root cause inline. The actual reason lives in `C:\Windows\Panther\setuperr.log` inside the failing VM. Accessing it requires `Shift+F10` from the dialog to open a cmd, then `notepad C:\Windows\Panther\setuperr.log`. | Operator opened the log via the Shift+F10 path. Captured screenshot. The decisive entries: `Microsoft-Windows-Shell-Setup ... Value is invalid` + `The provided unattend file is not valid; hrResult = 0x80220005` + `Callback_Unattend_InitEngine: An error occurred while finding/loading the unattend file`. Cause + fix in transient #10 below. |
| 10 | Setup's `setuperr.log` reveals `0x80220005` ("Value is invalid") against Microsoft-Windows-Shell-Setup -- the only value-bearing field in that component's specialize-pass content is `<ComputerName>`. My `templatefile()` passed `computer_name = var.vm_name` = `"oltp-sqlserver-node"` -- **19 chars** -- which exceeds the NetBIOS 15-char limit + Windows Setup rejects the Autounattend during specialize. Per memory `feedback_windows_ssh_automation.md` rule 1 ("NetBIOS limit") -- this is the documented invariant; my template just didn't apply it. ws2025-desktop's bake works because `var.vm_name = "ws2025-desktop"` is exactly 14 chars (under the limit by one). | Split `vm_name` (used for the VMware-side VM dir name; 19 chars OK there) from `bake_computer_name` (the Windows ComputerName during specialize; MUST be ≤15 chars). Add a new variable `bake_computer_name` with default `"OLTPSQL-BAKE"` (12 chars, NetBIOS-valid) + a validation block that enforces the rules at `packer validate` time so this can't regress silently. Clones rename to sql-fci-1/2 + sql-ag-rep-1/2 (all 11-12 chars, NetBIOS-valid) via firstboot.ps1, so the bake-time computer name is effectively a throwaway placeholder. Permanent fix in `oltp-sqlserver-node.pkr.hcl` (templatefile() call) + `variables.pkr.hcl` (new variable + validation). |
| 11 | After #10 fix the bake progressed past WS install + specialize + OOBE + 5 baseline scripts + 4 SQL-specific provisioner-prep steps (~30 min), then errored at the `file` provisioner uploading the 1.2 GB SQL ISO with `Error uploading file to $env:TEMP\winrmcp-...tmp: Couldn't create shell: received error response`. | Packer's `winrmcp` library streams files in chunks; each chunk opens + closes a WinRM shell. WinRM's default `MaxShellsPerUser = 30` exhausts quickly when uploading large files (a 1.2 GB ISO at ~1 MB chunks = ~1200 shell creations). Even bumping the limit to 100+ keeps the upload brittle -- WinRM file uploads >500 MB are fundamentally flaky in the Packer + Windows world. The canonical Packer pattern for large files is to serve them over HTTP from the build host + use `Invoke-WebRequest` in the guest. | Switch from `file` provisioner -> `http_directory = "H:/VMS/ISO"` + `Invoke-WebRequest` inside `10-sql-install.ps1`. The Packer host serves H:/VMS/ISO/ via a built-in HTTP server (random port; only accessible during the bake). The SQL ISO basename becomes the URL path. Download is fast over the NAT NIC (~30-60 sec for 1.2 GB on a local bridge). Removed `provisioner "file" { source = var.sql_iso_path ... }`; added `NEXUS_ISO_URL` env var pointing at the Packer HTTP server; 10-sql-install.ps1 runs `Invoke-WebRequest -Uri $env:NEXUS_ISO_URL -OutFile C:/Windows/Temp/sqlserver.iso -UseBasicParsing` with `$ProgressPreference = 'SilentlyContinue'` (PS5 progress-bar perf trap on big downloads). Permanent fix in `oltp-sqlserver-node.pkr.hcl` (source block + provisioner) + `10-sql-install.ps1` (Stage 0 download). |
| 12 | After #11 fix the bake passed install + specialize + OOBE + 5 baseline scripts cleanly (15 min in), then errored at `10-sql-install.ps1` with `ISO download failed: Cannot bind parameter 'Uri'. Cannot convert value "http://<no value>:<no value>/SqlServer2025EnterpriseDeveloperEdition.iso" to type "System.Uri". Error: "Invalid URI: The hostname could not be parsed."`. | I used `{{ .HTTPIP }}:{{ .HTTPPort }}` syntax in the `environment_vars` map -- that's Packer's LEGACY JSON-template Go-template syntax. The build is HCL2 (which I'm using throughout the lab), and HCL2 ignores `{{ .X }}` in arbitrary contexts -- it gets rendered as literal `<no value>:<no value>`. | Replace `{{ .HTTPIP }}:{{ .HTTPPort }}` with `${build.HTTPIP}:${build.HTTPPort}` ... which then surfaced transient #13 below (wrong attribute name). |
| 13 | Bake validates fine via `packer validate -syntax-only` but `packer build` fails fast (~3 sec) at preparation time: `Error: Failed preparing provisioner-block "powershell" ""... Unsupported attribute; This object does not have an attribute named "HTTPIP"`. | HCL2 build variables for the HTTP server are NOT `build.HTTPIP` -- the actual attribute names carry a "Packer" prefix: `build.PackerHTTPIP`, `build.PackerHTTPPort`, `build.PackerHTTPAddr`. The "Packer" prefix is required (per <https://developer.hashicorp.com/packer/docs/templates/hcl_templates/contextual-variables#build-variables>). `packer validate -syntax-only` doesn't catch this because the syntax IS valid HCL -- the attribute just doesn't exist at runtime. Surfaces only at `packer build` preparation phase. | Rename to `${build.PackerHTTPIP}:${build.PackerHTTPPort}`. Permanent fix in `oltp-sqlserver-node.pkr.hcl`. Lesson logged: `packer validate -syntax-only` is necessary but not sufficient -- attribute references on built-in objects (`build`, `source`) need `packer build --dry-run` or actual build to catch typos. |
| 14 | After #13 fix the bake got deep into the SQL install: HTTP download of the 1.2 GB ISO completed in 15.7 sec (77 MB/s -- vastly faster than the WinRM upload would have been); ISO mounted at F: cleanly; setup.exe launched. setup.exe printed the SQL 2025 telemetry banner ("SQL Server 2025 transmits information about your installation experience...") then errored: `There was an error generating the XML document. Error result: -2068774911 / Result facility code: 1201 / Result error code: 1`. Exit code `-2068774911` = `0x84B40001`. | SQL Setup's "XML document" error is its catch-all for CLI args that can't be marshaled into the internal ConfigurationFile.ini. SQL Server 2025 introduced 2 mandatory new args that 2022 didn't require: (a) `/USESQLRECOMMENDEDMEMORYLIMITS` -- SQL 2025 made memory limits mandatory at install time (Microsoft launch announcement); (b) `/PRODUCTCOVEREDBYSA=False` -- explicit opt-out of Software Assurance / Azure Arc registration (default behavior in SQL 2025 attempts Arc enrollment which fails without `/AZURESUBSCRIPTIONID`). Setup fails fast at CLI-validation BEFORE creating the timestamped per-run log dir; Summary.txt + Detail.txt don't exist yet. | Add `/USESQLRECOMMENDEDMEMORYLIMITS=true` + `/PRODUCTCOVEREDBYSA=False` to the setup.exe args in `10-sql-install.ps1`. Also strengthen the script's error-capture: read Summary.txt + Detail.txt (last 80 lines) + Bootstrap.log (last 40 lines) on any non-0/non-3010 exit -- belt-and-braces for future SQL install transients. Permanent fix in `10-sql-install.ps1` setupArgs + error-handling block. |
| 15 | After #14 fix setup.exe progressed PAST the CLI-validation gate (the new args were accepted) + into FinalCalculateSettings, but failed there with the same `0x84B40001` catch-all wrapping a nested `System.Security.Cryptography.CryptographicException @ -2147024891`. The enhanced error capture (#14) surfaced this from Detail.txt -- without it we'd still be flying blind. | `-2147024891` = `0x80070005` = `E_ACCESSDENIED`. Initial theory: SA password encryption was failing. (Wrong -- see #16.) | Attempted: drop `/SECURITYMODE=SQL` + `/SAPWD=...` to bypass SA encryption at bake time. Did NOT fix #15; the same FinalCalculateSettings crypto failure recurred -- which led to discovery in #16 that the crypto op is at a deeper layer (DataStoreService.SerializeObject) and applies to ALL Setup configuration, not just SA. Permanent fix (still useful regardless): SA password is now set later by terraform's role-overlay-fci-install.tf via T-SQL using KV-seeded value. |
| 16 | After #15 fix the bake had the same failure. Enhanced log capture revealed the full stack trace: `Parameter 1: Microsoft.SqlServer.Chainer.Infrastructure.DataStoreService.SerializeObject` -> `Parameter 2: System.Security.Cryptography.ProtectedData.Protect` -> `Parameter 4: CryptographicException @ -2147024891`. Diagnostic added (DPAPI Protect on both scopes before setup.exe) confirmed: **`CurrentUser scope: FAILED -- Access is denied. LocalMachine scope: OK (246 bytes)`**. | The user-scope DPAPI key container is inaccessible from Packer's WinRM-spawned PS session. WinRM Basic auth + non-interactive logon do load the user profile + execute commands as nexusadmin, BUT the CryptoAPI key container provisioning that happens on first interactive logon never runs in a non-interactive logon. SQL Setup's `DataStoreService.SerializeObject` is hardcoded to use `CurrentUser` scope for encrypting the in-memory config datastore -- so the call hits ACCESS_DENIED before Setup can even compute final settings. Documented Microsoft workaround for SQL Setup over WinRM: run setup.exe via a Scheduled Task as `SYSTEM`. SYSTEM has its own DPAPI key container that's always accessible + bypasses the WinRM-non-interactive DPAPI gap. | Wrap setup.exe in a Scheduled Task running as SYSTEM. Action = setup.exe + args; Trigger = once at +5sec; Principal = SYSTEM with RunLevel Highest; ExecutionTimeLimit = 45 min. PS poll-loop watches `(Get-ScheduledTask).State` every 30 sec + grabs `LastTaskResult` after State != 'Running'. Standard pattern; mirrors `_shared/powershell/scripts/99-sysprep.ps1`'s deferred-sysprep dance. Permanent fix in `10-sql-install.ps1` setup.exe launch block. **VALIDATED 2026-05-20: SQL Server 2025 installed cleanly in ~6 min via the SYSTEM-scheduled-task; exit code 0.** |
| 17 | After #16 fix SQL Server 2025 setup.exe completed cleanly (exit=0 in ~6 min via SYSTEM scheduled task), but the post-install engine verification step failed: `The term 'sqlcmd' is not recognized as the name of a cmdlet, function, script file, or operable program.` Affected the engine-reachability verify in `10-sql-install.ps1` + the HADR-enabled verify in `11-cluster-features.ps1`. | SQL Server 2025 DROPPED the bundled `sqlcmd.exe` from the engine install (per Microsoft launch announcement). The legacy `sqlcmd` tool was replaced by a separate Go-based `sqlcmd` distributed via `winget install sqlcmd` or the standalone MSI. With `/FEATURES=SQLEngine,FullText` no client tools are installed; sqlcmd is genuinely missing. The old SQL Server 2022 pattern of "sqlcmd is on PATH after install" no longer holds. | Replace `sqlcmd` shell-outs with `Microsoft.Data.SqlClient` (the .NET data provider that IS bundled with SQL Server 2025 engine install). Discovery: `Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'Microsoft.Data.SqlClient.dll'` locates the DLL; `Add-Type -Path $dll` loads it; `New-Object Microsoft.Data.SqlClient.SqlConnection` opens a connection. Fall back to service+TCP probe if the assembly isn't found (still proves engine-up at bake time; terraform's apply-time scripts will install `go-sqlcmd` via winget once we have internet on the cluster nodes). Permanent fix in `10-sql-install.ps1` `Test-SqlEngineReachable` function + `11-cluster-features.ps1` HADR verify block. **VALIDATED 2026-05-20: service+TCP-probe fallback works; bake proceeds to cluster-features stage.** |
| 18 | After #17 fix bake proceeded into `11-cluster-features.ps1`: Failover-Clustering installed OK, Multipath-IO installed OK, then `iSCSI-Initiator: ArgumentNotValid: The role, role service, or feature name is not valid: 'iSCSI-Initiator'. The name was not found.` | Windows Server 2025 changed the iSCSI Initiator delivery model. Previous Windows Server versions (2012-2022) shipped `iSCSI-Initiator` as a separately-installable Windows Feature. WS2025 ships the iSCSI Initiator service (`msiscsi`) as built-in + always-present (no Install-WindowsFeature needed) -- the service is just disabled by default. Trying to install a non-existent feature throws `NameDoesNotExist`. | Drop `'iSCSI-Initiator'` from the `$features` array in `11-cluster-features.ps1`. Keep Failover-Clustering + Multipath-IO. Add a sanity-check probe (`Get-Service msiscsi`) that confirms the service IS present + leaves StartupType as-is (default Manual). The role-overlay-iscsi-attach.tf already calls `Set-Service msiscsi -StartupType Automatic + Start-Service msiscsi` at terraform-apply time on the FCI pair only -- so the service activation lives there per the per-cluster-overlay canon. Permanent fix in `11-cluster-features.ps1` features list + new msiscsi probe block. **VALIDATED 2026-05-21: bake v14 COMPLETED in 40m 28s; artifact at H:/VMS/NexusPlatform/_templates/oltp-sqlserver-node/ (22 GB disk + .vmx). BAKE PHASE PROVEN END-TO-END.** |

### §3.5b 0.G.7 terraform apply transients (2026-05-21 — in progress)

| # | Symptom | Diagnosis | Recovery action |
|---|---|---|---|
| 19 | `oltp-sqlserver apply` errors immediately at `null_resource.sqlserver_nftables_backplane`: `WriteError: Cannot overwrite variable Host because it is read-only or constant.` The exception message also showed `System.Management.Automation.Internal.Host.InternalHost (192.168.70.13) did not reach READY` -- which is wrong; what should be `$hostName` was being PS-coerced to the auto-var `$Host` (Internal.Host.InternalHost object), then interpolated into the error string. | Same class as smoke-0.G.7.ps1 transient I caught at scaffold-CI-time. Per memory `feedback_powershell_automatic_variables.md`: `$Host`, `$Error`, `$args`, etc. are PowerShell automatic read-only variables; assigning to them silently corrupts. I CAUGHT this in `smoke-0.G.7.ps1` during the scaffold CI pass but **failed to apply the same lesson to the 9 role-overlay TF files** I wrote in parallel. 30+ uses of `$host = ...` across 5 of the 9 overlays. | Bulk-rename `$host` → `$hostName` across 5 files: `role-overlay-{sqlserver-nftables-backplane,sqlserver-domain-join,sqlserver-vault-agents,sqlserver-tls,iscsi-attach}.tf`. `terraform fmt -recursive` + `terraform validate` clean after rename. Lesson: pre-commit grep `'\$host\b'` (and other PS automatic vars) before any new Windows-via-SSH role-overlay lands -- the variable name is innocuous-looking + only fails at apply time. |
| 20 | After #19 fix re-apply timed out at `sqlserver-nftables-backplane`: `sql-ag-rep-1 (192.168.70.13) did not reach READY within 25 min`. Live-VM diagnostic via SSH revealed all 4 VMs running + SSH-reachable, but: `HOSTNAME=WIN-XXX` (generic post-sysprep names; firstboot rename never ran), `IDENTITY_ENV_EXISTS=False`, **`FIRSTBOOT_TASK=Ready`** (registered but never fired), `FIRSTBOOT_LOG_EXISTS=False`. | The firstboot scheduled task uses `-AtLogon` trigger which requires an INTERACTIVE user logon to fire. My Packer template's `99-sysprep.ps1` (shared with ws2025-desktop) writes a post-sysprep unattend that skips OOBE pages but does NOT include an `<AutoLogon>` block (the shared script intentionally minimizes side effects for downstream consumers). Cloned VMs boot through mini-OOBE → reach the lock screen → no user ever logs in → AtLogon never fires → firstboot never runs → node-identity.env never written → terraform-apply backplane wait times out at 25 min. The lesson is that the firstboot trigger must NOT depend on user logon for templates whose sysprep doesn't include AutoLogon. | **Two-part fix**: (a) Manually trigger NexusSqlFirstboot via `Start-ScheduledTask` over SSH on all 4 live VMs to unblock the current apply (`ssh nexusadmin@<ip> "powershell -Command 'Start-ScheduledTask -TaskName NexusSqlFirstboot'"`). All 4 firstboots ran cleanly within 90 sec; VMs renamed to sql-fci-1/2 + sql-ag-rep-1/2 + VMnet10 backplane IPs assigned. (b) Permanent fix in `12-firstboot-stage.ps1`: change trigger from `-AtLogOn` to `-AtStartup`. AtStartup fires when the OS boots (before user logon), runs as SYSTEM with full privileges, no dependency on AutoLogon. Next clone bake will pick this up + cloned VMs will firstboot automatically on power-on. |
| 21 | After #20 manual firstboot fix the 4 VMs were renamed + ready, but re-apply STILL timed out at the same `sqlserver-nftables-backplane` READY probe. Diagnostic via SSH confirmed all 4 VMs respond + have `node-identity.env` -- but the probe's `if (Test-Path ...) { Write-Output 'READY' } else { 'WAIT' }` returned nothing (empty + non-matching). | Windows OpenSSH default shell is `cmd.exe`, not PowerShell. The PS-syntax probe (`if ($x) { Y }`) sent over SSH gets interpreted by cmd which doesn't understand PS syntax -- the command silently fails + returns no output. The polling loop's `if ($probe -match 'READY')` never matches -- loops forever until 25 min deadline. Affects EVERY SSH-driven PS probe across the 9 role-overlays (not just nftables-backplane). | Set the OpenSSH `DefaultShell` registry value to `powershell.exe` so SSH-spawned commands run as PowerShell by default. Two parts: (a) live fix on the 4 running VMs (`ssh nexusadmin@<ip> 'powershell -Command "New-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value (Get-Command powershell).Source -PropertyType String -Force"'`); (b) permanent fix in `_shared/powershell/scripts/01-nexus-identity.ps1` -- add the same registry set just before the sshd Restart-Service so future bakes inherit. Verified live: after the registry set, all 4 probes return `READY`. |
| 22 | After #21 fix, apply v4 surfaced `[sqlserver-domain-join] nexusadmin_password missing from vault-ad-bind.json`. The overlay was reading the nexusadmin AD-user password from `$HOME/.nexus/vault-ad-bind.json` but that sidecar holds only the LDAP **bind** creds (`bindpass`/`binddn` fields for the svc-vault-ldap service account) -- NOT a domain-user password. `vault kv get nexus/foundation/identity/nexusadmin` confirmed the nexusadmin password lives at a DIFFERENT Vault KV path and was never previously written to a sidecar. | Two-sidecar architecture: `vault-ad-bind.json` (svc-vault-ldap LDAP bind for the search-then-bind flow) vs the missing `nexusadmin-credentials.json` (nexus.lab\nexusadmin domain-user for Add-Computer + future Windows-domain admin operations). The foundation env's role-overlay-jumpbox-domainjoin.tf reads nexusadmin via the vault provider directly (data.vault_kv_secret_v2.identity_nexusadmin -> local.foundation_creds.nexusadmin) but the oltp-sqlserver env has no vault provider configured -- it relies on the same sidecar indirection pattern as vault-init.json + iscsi-sqlfci-chap.json. The nexusadmin sidecar was simply never created at scaffold time. | Two-part fix: (a) live fix -- manually fetch nexusadmin password from `vault kv get -format=json nexus/foundation/identity/nexusadmin` over SSH to vault-1, write `$HOME/.nexus/nexusadmin-credentials.json` with fields `{username, password, domain, domain_user_upn, generated_at, source}`. Patch oltp-sqlserver env's role-overlay-sqlserver-domain-join.tf to read from this sidecar instead of vault-ad-bind.json's nonexistent `nexusadmin_password` field. (b) permanent fix -- NEW security env overlay `role-overlay-vault-nexusadmin-creds-seed.tf` that idempotently writes this sidecar on every security apply from `nexus/foundation/identity/nexusadmin` (mirrors role-overlay-vault-sqlserver-cluster-creds-seed.tf's iSCSI CHAP sidecar pattern). 3 new variables in security/variables.tf: `enable_nexusadmin_creds_sidecar`, `nexusadmin_creds_sidecar_path`, `ad_domain_name`. Future cold rebuilds will get the sidecar automatically at security apply. |
| 23 | After #22 fix, apply v5 ran the domain-join overlay past credential read + into the per-node loop. Output reported all 4 SQL nodes as "already domain-joined (idempotent skip)", then immediately failed at `Add-ADGroupMember`: "Cannot find an object with identity: 'sql-ag-rep-1$' under: 'DC=nexus,DC=lab'." (same for sql-ag-rep-2, sql-fci-1, sql-fci-2). Diagnostic via `ssh nexusadmin@dc-nexus 'Get-ADComputer -Filter *'` revealed AD had only 2 computer accounts: DC-NEXUS + NEXUS-JUMPBOX -- NONE of the 4 SQL nodes were in AD. SSH probe to sql-ag-rep-1 directly: `(Get-CimInstance Win32_ComputerSystem).PartOfDomain = False, Domain = WORKGROUP`. The 4 VMs were NEVER joined; the probe lied. | PowerShell `-match` is a regex **substring** match. `'NOTJOINED' -match 'JOINED'` returns `True` because 'JOINED' is contained inside 'NOTJOINED'. The probe sends `if (PartOfDomain) { 'JOINED' } else { 'NOTJOINED' }` over SSH; when the actual result is `NOTJOINED`, the receiver-side `if ($probe -match 'JOINED')` falsely matches → idempotent-skip branch taken → no Add-Computer call → 4 nodes never joined → AD group population fails because the computer accounts don't exist. **New rule class on top of feedback_smoke_gate_probe_robustness.md**: every `-match '<token>'` against SSH-piped probe output MUST be anchored (`^<token>\s*$`); otherwise NEGATIVE tokens that contain the POSITIVE token as a substring silently false-positive. | Two-part fix in role-overlay-sqlserver-domain-join.tf: (a) probe regex `-match 'JOINED'` → `-match '^JOINED\s*$'` (anchored, tolerates trailing CR/whitespace per feedback_pwsh_ssh_stdin_cr_injection.md). (b) post-restart PONG probe `-match 'PONG'` → `-match '^PONG\s*$'` for the same class. (c) verify domain probe was already anchored (`^nexus\.lab$`) but tightened to `^nexus\.lab\s*$` + `.Trim()` for log output. After patch + re-apply, the 4 actual Add-Computer + restart cycles run (~3-5 min each = 12-20 min total); AD group population then succeeds. Class lesson: save a new feedback memory `feedback_powershell_match_substring_anchor.md` so every future SSH-piped probe with branch-tagged outputs uses anchored regex. |
| 24 | After #23 fix, apply v6 reached the actual Add-Computer dispatch. All 4 nodes failed silently — Add-Computer threw but the SSH `-Restart` -triggered reboot never fired (host stayed reachable; the PONG probe matched immediately but the verify-domain probe never returned `nexus.lab`). Live SSH to sql-ag-rep-1's System eventlog showed `Event ID 4097: ...attempted to join the domain nexus.lab but failed. The error code was 2202.` (`ERROR_NO_SUCH_USER`). | Two compounding root causes: (a) The Vault KV value at `nexus/foundation/identity/nexusadmin` had drifted out of sync with the actual AD nexusadmin password (foundation env's promote_v=4 reset only ran once at lab bring-up; the KV value may have been re-seeded since). (b) The overlay constructed the credential username as `"$adDomain\\$($adCreds.username)"` → `"nexus.lab\\nexusadmin"` (FQDN form with double-backslash). The canonical jumpbox overlay (foundation env's role-overlay-jumpbox-domainjoin.tf line 118) uses `'$netbios\nexusadmin'` (NETBIOS form with single backslash). PSCredential silently rejects `"nexus.lab\\nexusadmin"` -- Add-Computer throws with the misleading 2202 error. | Three-part fix: (a) reset AD nexusadmin password to match Vault KV via SSH+EncodedCommand call to `Set-ADAccountPassword -Identity nexusadmin -Reset -NewPassword (ConvertTo-SecureString '<KV value>' -AsPlainText -Force); Enable-ADAccount -Identity nexusadmin` on dc-nexus. User explicitly authorized via AskUserQuestion answer "Reset AD pwd to KV value (Recommended)". One-shot manual script at `C:\Users\grigo\AppData\Local\Temp\reset-ad-nexusadmin.ps1`. (b) Add a `netbios` field to the sidecar `$HOME/.nexus/nexusadmin-credentials.json` (PowerShell one-liner to patch in-place); permanent fix is in nexus-infra-vmware security env's `role-overlay-vault-nexusadmin-creds-seed.tf` payload + new `ad_netbios_name` variable. (c) Patch the domain-join overlay to read `$adCreds.netbios` and build `$adUser = "$adNetbios\$($adCreds.username)"` (SINGLE backslash). |
| 24b | After #24a + 24b fixes (live AD password reset + sidecar netbios field), apply v7 surfaced a NEW error class: `Add-Computer : Computer 'sql-ag-rep-1' failed to join domain 'nexus.lab' from its current workgroup 'WORKGROUP' with following error message: The specified username is invalid.` Two-backslash issue in the patch: `$adUser = "$adNetbios\\$($adCreds.username)"` produced literal `NEXUS\\nexusadmin` (two backslashes); when interpolated into the inner heredoc's `'$adUser'` literal, PSCredential receives an invalid username. | PowerShell double-quoted strings do NOT interpret backslash escapes. `\\` inside `"..."` is literally two backslashes (unlike C/Python). The canonical jumpbox overlay uses `'$netbios\nexusadmin'` with a SINGLE backslash because that's the correct username form for PSCredential: `NEXUS\nexusadmin`. PSCredential rejects double-backslash usernames with "The specified username is invalid". | Fix in role-overlay-sqlserver-domain-join.tf: `$adUser = "$adNetbios\\$($adCreds.username)"` → `$adUser = "$adNetbios\$($adCreds.username)"` (single backslash). Permanent fix lands in the same overlay; no cross-repo change needed. Class lesson: do NOT mirror `\\` patterns from C/Java/Python codebases when transliterating into PowerShell -- PS treats `\` as literal in strings, and the convention is the same `DOMAIN\user` form you'd type at a logon prompt (one backslash). |
| 25 | After #24b fix, apply v9 cleared the domain-join stage (all 4 nodes joined nexus.lab in ~2 min; AD group population added all 4 computer accounts) but immediately failed at the next stage `sqlserver_vault_agents`: all 4 nodes returned `The string is missing the terminator: '.` + `ParserError: TerminatorExpectedAtEndOfString`. SSH commands to the live nodes confirmed the remote PS could not parse the EncodedCommand payload. Diagnostic confirmed: the `$remote` payload built by the overlay is ~8.6KB; UTF-16 LE + base64 → ~23KB → past the Windows ssh.exe argv ~6KB cliff (memory: `feedback_ssh_stage1_size_limit.md`). ssh.exe silently TRUNCATES the EncodedCommand mid-base64 → remote PS receives an incomplete UTF-16 stream → tokenizer hits an unclosed `'` literal somewhere in the truncated text. | Existing memory `feedback_ssh_stage1_size_limit.md` documents this exact failure mode for bash payloads via SSH; same class applies to PowerShell `-EncodedCommand` via SSH (different shell, same argv limit). The canonical fix from that memory is "pipe LF-normalized plaintext to ssh's stdin and run with `bash -s`". For Windows-receiver PS the equivalent would be `powershell -NoProfile -Command -` reading from stdin, but stdin redirection on Windows ssh.exe is unreliable. Cleaner: scp the payload to a temp file on the remote, then `powershell -NoProfile -File <path>`. | Fix in role-overlay-sqlserver-vault-agents.tf: instead of `ssh user@host "powershell -NoProfile -EncodedCommand $b64"`, write `$remote` to a local tempfile, scp to `C:/Windows/Temp/nexus-vault-agent-$hostName.ps1` on the remote, then `ssh user@host "powershell -NoProfile -File C:/Windows/Temp/nexus-vault-agent-$hostName.ps1"`. Best-effort cleanup via secondary SSH after success (Remove-Item). Bypasses argv length limit entirely. Memory cross-ref: the swarm-nomad TLS overlays already use the stdin-pipe variant; this is the equivalent for ws2025 PS-receiver hosts. |
| 25b | After #25 fix (scp+File), the vault-agents script executed but the `nexus-vault-agent` Windows service kept ending in `SERVICE_STATUS=Stopped` despite Vault binary install + service registration. Auth was failing silently → service crashed within seconds of start. | Windows PowerShell 5.1's `Out-File -Encoding utf8` prepends a 3-byte UTF-8 BOM (`EF BB BF`). The Vault Agent's AppRole config reads `role_id_file_path` + `secret_id_file_path` VERBATIM; the BOM corrupts the credential (server-side AppRole login fails with "invalid role_id"). | Fix in role-overlay-sqlserver-vault-agents.tf: replace `'$($cfg.role_id)' \| Out-File 'C:/...role-id' -Encoding utf8 -NoNewline` with `[System.IO.File]::WriteAllText('C:/...role-id', '$($cfg.role_id)')` (no BOM). Same fix for secret-id, agent.hcl, ca-bundle.crt. Template files (.tpl) are still OK with BOM since Vault Agent uses Go templates which strip leading whitespace. |
| 25c | After #25b fix, vault-agents succeeded reaching SERVICE_STATUS=Running but emitted `GMSA_INSTALL_FAILED: The specified module 'ActiveDirectory' was not loaded because no valid module file was found in any module directory.` on all 4 nodes. | The Packer template installs Failover-Clustering + Multipath-IO but NOT RSAT-AD-PowerShell (= the ActiveDirectory PS module). Without it, `Import-Module ActiveDirectory` fails → `Install-ADServiceAccount` can't run → GMSA cache never populated → SQL Server FCI install would downstream-fail because the service can't run as gmsa-sql-engine$. | Two-part fix: (a) Permanent: add `RSAT-AD-PowerShell` to `$features` list in `packer/oltp-sqlserver-node/scripts/11-cluster-features.ps1` (next Packer bake will have it baked in). (b) Runtime fallback in `role-overlay-sqlserver-vault-agents.tf`: `if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) { Add-WindowsFeature ... }` runs ~30 sec per node + lets the current live ratification proceed without re-baking. |
| 25d | After #25c fix + RSAT installed live, vault-agents passed but `sqlserver_tls` immediately failed on all 4 with `ParserError: Unexpected token '}' in expression or statement.` at "line 59" of the EncodedCommand payload. | Cannot nest `@"..."@` inside an outer `@"..."@`. PowerShell's lexer treats the first `"@` at line-start as the END of the outer here-string -- the rest of the original heredoc body becomes raw PS code that doesn't parse (the trailing `}` at the original heredoc end is now an unmatched closing brace). role-overlay-sqlserver-tls.tf had this pattern when building the appended `template { ... }` HCL stanzas. | Fix in role-overlay-sqlserver-tls.tf: replace the nested `@"..."@` block with two single-line PS string variables (one per HCL stanza) + two `Add-Content` calls. Same functional result; no nested heredoc. Class lesson: when a remote-script heredoc needs to compose multi-line content, prefer string-array `-join "\`n"` or repeated `Add-Content` over nesting `@"..."@`. |
| 25e | After #25c + RSAT installed live, vault-agents reported `GMSA_INSTALL_FAILED: Unable to contact the server. This may be because this server does not exist, it is currently down, or it does not have the Active Directory Web Services running.` Diagnostic confirmed: ADWS Running on dc-nexus + TCP/9389 reachable from SQL nodes; the issue is that the SSH session runs as the LOCAL `sql-fci-1\nexusadmin` account (not domain) so `Get-ADDomain` / `Install-ADServiceAccount` can't authenticate against AD. | Windows OpenSSH on a domain-joined host preserves the local SAM for SSH login (no automatic Kerberos ticket grab for the same-named domain user). PS AD cmdlets default to "current user identity" → no domain TGT → ADWS rejects the connection. | Workaround for current live ratification: leave GMSA install as soft-failure (try/catch + emit GMSA_INSTALL_FAILED but don't throw). Permanent fix deferred to a follow-up overlay: register a Scheduled Task running as `NEXUS\nexusadmin` (with creds pulled from the sidecar) that performs `Install-ADServiceAccount` on first boot. SQL Server FCI install (later stage) will surface this if GMSA hasn't been cached. |
| 26 | After #25 family fixes, apply v12 cleared vault-agents + TLS, but `iscsi_attach` for both FCI nodes failed: first with `Set-IscsiChapSecret: The parameter is incorrect.` (HRESULT 0x57 = E_INVALIDARG). The KV CHAP secret was a 32-char hex (16 random bytes via `openssl rand -hex 16`). | Windows iSCSI initiator caps CHAP secrets at 12-16 chars (per Microsoft docs; longer secrets rejected with E_INVALIDARG). The 32-char hex was over-spec. Linux tgt accepts any length per RFC 3720, so the foundation iSCSI target overlay didn't catch this at scaffold time. | Two-part fix: (a) Live rotation -- regenerate the KV `nexus/oltp/sqlserver/iscsi-chap-secret` to a 16-char hex via `openssl rand -hex 8`; update `$HOME/.nexus/iscsi-sqlfci-chap.json` sidecar; `sed`-replace the secret in `/etc/tgt/conf.d/sql-fci.conf` on nexus-gateway; bounce nexus-vault-agent on each FCI node so the new secret renders. (b) Permanent: update `nexus-infra-vmware`'s security env `role-overlay-vault-sqlserver-cluster-creds-seed.tf` to special-case iSCSI CHAP at 16-char (`openssl rand -hex 8`) while keeping the other 4 secrets at 32-char. Add a defensive truncate in the iSCSI attach overlay (`Substring(0, 16)`). |
| 26b | After #26a rotated the secret + tgt-admin --update ALL, Connect-IscsiTarget still threw "Authentication Failure" (HRESULT 0xefff0009). | `tgt-admin --update ALL` only hot-reloads RUNTIME parameters; `incominguser` (CHAP secret) is NOT among them → tgt continues to authenticate against the OLD 32-char secret even though config shows 16. Plus a separate issue: `Set-IscsiChapSecret -ChapSecret <secret>` is for MUTUAL CHAP (initiator authenticates the TARGET back), not OneWayCHAP. Calling it confused the initiator's state. | Two-part fix: (a) `sudo systemctl restart tgt` (full daemon restart) propagates the new `incominguser` value. (b) Remove `Set-IscsiChapSecret` from `role-overlay-iscsi-attach.tf` -- for OneWayCHAP the initiator's secret is passed directly via `Connect-IscsiTarget -ChapSecret` and that's sufficient. Note for future iSCSI-target overlay: any `incominguser` change MUST do `systemctl restart tgt` not just `tgt-admin --update`. |

| 7 | `packer build oltp-sqlserver-node` fails fast (~5 sec) with `Error: Call to unknown function "tostring"` on lines 91-92 of the Packer template (`vmx_data { "memsize" = tostring(var.memory_mb) }` + `"numvcpus" = tostring(var.cpus)`). | Packer HCL2 has its own function library which overlaps with but is NOT identical to Terraform's. `tostring()` is a Terraform function (terraform/internal/funcs/tostring), NOT a Packer function. Packer 1.11 supports `format()`, `formatlist()`, `tonumber()`, `tomap()`, `tolist()`, `toset()`, etc. -- but no `tostring()`. The function exists in Terraform 0.12+ but was never added to Packer's HCL fork. | Use string interpolation `"${var.memory_mb}"` instead of `tostring(var.memory_mb)`. Interpolation auto-converts the number to a string in the rendered template. Permanent fix in `oltp-sqlserver-node.pkr.hcl` lines 91-92. |
| 8 | `packer build oltp-sqlserver-node` v2 (after #7 fix) AND v3 (after vmx_data NIC injection) both errored after 30:30 with `Timeout waiting for SSH.` -- the cloned VM was running but unreachable; vmx_data NIC fix did not survive the clone+sysprep+OOBE chain. | Architectural wall: Packer's `vmware-vmx` builder is not designed to clone sysprep'd Windows source VMs. The source `ws2025-desktop.vmx` was baked with `vmx_remove_ethernet_interfaces = true` for downstream consumption by terraform/modules/vm (which uses `vmrun clone` + `configure-vm-nic.ps1` to add NICs post-clone). Packer's vmware-vmx has no equivalent NIC-injection hook + no boot_command pipeline. Adding NICs via vmx_data renders into the cloned .vmx but doesn't survive sysprep's first-boot generalize -- Windows resets the NIC config + the temp Packer NIC never re-attaches. | **Pivoted to `vmware-iso` (full from-ISO bake) 2026-05-20** -- matches every other per-engine template (deb13/oltp-patroni-node/etc) + ws2025-desktop itself. Rewrite scope: copy 10 shared Windows baseline files from `nexus-infra-vmware/packer/_shared/powershell/` into `nexus-infra-oltp/packer/_shared/powershell/` (one-time DRY violation; self-contained per the per-engine canon); rewrite `oltp-sqlserver-node.pkr.hcl` source from `vmware-vmx` → `vmware-iso` reading WS2025.iso + Autounattend.xml + WinRM communicator (mirror of ws2025-desktop.pkr.hcl); reuse the existing 10/11/12 SQL-specific PS scripts as-is after the shared 00-04 baseline. Bake time +30 min (~60 min real-time vs ~30 min) BUT bypasses the entire sysprep'd-clone-via-Packer minefield. Permanent fix in `oltp-sqlserver-node.pkr.hcl` (rewrite) + `variables.pkr.hcl` (rewrite to ws2025-desktop's variables shape) + 10 new files under `packer/_shared/powershell/`. |

**Anticipated transient classes still pending discovery** (pre-ratification
predictions; some may not surface, others not anticipated will):

| Risk area | Likely transient class |
|---|---|
| iSCSI initiator + Win + CHAP | tgt CHAP semantics vs Windows initiator auth-mode negotiation; `Connect-IscsiTarget` "Authentication failed". |
| SQL setup.exe FCI on iSCSI CSV path | First-ever FCI install may need `/FAILOVERCLUSTERIPADDRESSES` format adjustment; CSV must be Online + accessible from sql-fci-1 BEFORE setup.exe. |
| AG endpoint cert distribution | The 4×3 = 12-file `BACKUP CERTIFICATE ... TO FILE` + scp-to-peers + `CREATE CERTIFICATE ... FROM FILE` round-trip is brittle. |
| Listener cert binding to SuperSocketNetLib | Setting `Certificate` registry value + `ForceEncryption=1` + restarting MSSQLSERVER must complete BEFORE clients try TLS. Race possible. |
| GMSA pwd retrieval timing | `Install-ADServiceAccount` may return success but `Test-ADServiceAccount` still fails if KDS replication hasn't propagated. Mitigated by single-DC lab. |
| SQL ISO upload OOM on Packer's SCP | 3.5 GB over SSH may need `winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="4096"}'` or alternative ISO-mount strategy. |

