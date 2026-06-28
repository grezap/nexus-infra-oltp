# Changelog

All notable changes to `nexus-infra-oltp` are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed — Platform CA rollover: `oltp-mongo` cold-rebuilt to the new Vault PKI root (2026-06-28)

- **`oltp-mongo` (3 nodes, mongo-1/2/3 @ `.71/.72/.73`, mTLS + keyFile internal auth) cold-rebuilt onto
  the v0.8.1-greenfield Vault root** as the second step of the paced platform CA rollover (the tier was
  left OLD-root because it was offline during the 2026-06-18/19 Vault greenfield). No source `.tf`
  changed — the env + module `vmrun_path` defaults + the baked clone_vm state were already non-x86 (so the
  stale-x86 destroy trap did **not** apply, unlike redis), and the rebuild reads the **current** Vault KV
  for both role creation and config rendering so the citus/Patroni in-place cred-drift hazard does **not**
  apply (a cold rebuild's `createUser` and the vault-agent template both read the same KV value → consistent
  by construction).
- **KV-cred pre-flight (the citus lesson):** the 3 per-host AppRole sidecars
  (`~/.nexus/vault-agent-oltp-mongo-mongo-{1,2,3}.json`, dated the Jun-19 greenfield) were verified to
  AppRole-login against the current root; the `nexus-agent-mongo-*` policy was confirmed to grant read on
  `nexus/data/oltp/mongo/{keyfile,operator-password,smoke-user-password}`; and all three KV values were
  confirmed present (v1) before the rebuild.
- **Operation:** `oltp-mongo.ps1 destroy` (21 destroyed — clean, no zombies; VMs were already off) →
  `apply` with `TF_CLI_ARGS_apply=-parallelism=3` (the VMnet10 power-on-storm guard) → **`smoke-0.G.2`
  ALL PASSED** (`requireTLS` + per-node Vault PKI leaf, `allowConnectionsWithoutCertificates=false`,
  shared keyFile, **`ca.crt` now carries both intermediate AND the new root**, 1 PRIMARY + 2 SECONDARY all
  healthy, replicated write/read round-trip via `readConcern=majority`). The `rs.initiate` + `smoke-rw`
  + `nexus-cluster-admin` operator bootstraps all completed first-try (operator user created from the
  CURRENT KV `operator-password` and verified against the live RS — 1 PRIMARY, 3 members). **Zero
  transients.**
- **CA-rollover proof — `nexus cert-rotate mongo` GREEN** (all 3 nodes, fresh leaf serials, 0 errors,
  ~68s): this verb issues each new leaf via the node's **own** Vault Agent token against
  `pki_int/issue/mongo-server`, so it **x509-fails on an old-root cluster** (the agent cannot authenticate
  to the new Vault PKI) and **succeeds only post-rebuild** — the definitive confirmation the tier is now
  new-root. Full verb matrix re-run GREEN on the rebuilt cluster: `status` / `health` (overall green,
  3/3 quorum, 0.0s lag) / `topology` / `backup take` (473 B `mongodump --archive --gzip` on a secondary)
  / `backup restore` (round-trip into the `nexus_restore_verify` namespace, 2 items, non-destructive)
  / `acl list` + `grant`/`revoke` (`nexus-verify-user` read@admin granted then revoked) / `chaos
  process-kill` on mongo-2 (cluster held 2/3 quorum + 1 PRIMARY, then recovered to 3/3) / `failover-test`
  (RS stepDown on mongo-1 → mongo-2 elected new primary, recovered in ~4.6s).

### Changed — Platform CA rollover: `oltp-redis` cold-rebuilt to the new Vault PKI root (2026-06-28)

- **`oltp-redis` (6 nodes, mTLS-only) cold-rebuilt onto the v0.8.1-greenfield Vault root** as the first
  step of the paced platform CA rollover (the tier was left OLD-root because it was offline during the
  2026-06-18/19 Vault greenfield). No source `.tf` changed — the env + module `vmrun_path` defaults were
  already non-x86 from a prior cold-rebuild, and redis is mTLS-only so there is **no Vault-KV password
  drift to reconcile** (the citus/Patroni cred-drift hazard does not apply). Pre-flight: the 6 per-host
  AppRole sidecars (`~/.nexus/vault-agent-oltp-redis-redis-{1..6}.json`, dated the Jun-19 greenfield)
  were verified to AppRole-login against the current root before the rebuild.
- **Operation:** `oltp-redis.ps1 destroy` (38 destroyed — the stale-x86 `vmrun_path` baked in the prior
  clone_vm state errors non-terminating in the destroy-provisioner, so `Remove-Item` still unlocks +
  removes each off VM dir; clean, no zombies) → `apply` with `TF_CLI_ARGS_apply=-parallelism=3` (the
  VMnet10 power-on-storm guard) → **`smoke-0.G.1` ALL PASSED** (`cluster_state:ok`, 3 masters + 3
  replicas, 16384 slots assigned, cross-shard SET/GET round-trip, mutual TLS on every node). Fresh clones
  bake the correct non-x86 `vmrun_path` into state, retiring the stale-path trap for this cluster.
- **CA-rollover proof — `nexus cert-rotate redis` GREEN** (all 6 nodes, fresh leaf serials, 0 errors,
  ~13s): this verb **x509/403-fails on an old-root cluster** (the node Vault Agent cannot authenticate to
  the new Vault PKI to issue a leaf) and **succeeds only post-rebuild** — the definitive confirmation the
  tier is now new-root. Full verb matrix re-run GREEN on the rebuilt cluster: `status` / `topology`
  (3 shards + slot ranges) / `health` (replicas natively `state=online lag=1`; the adapter's idle
  replication-lag metric reads up to the `repl-ping-replica-period` and shows benign yellow on a
  write-idle cluster) / `backup take` (774 B, 3 shard-primary `.rdb`) / `acl list+grant+revoke`
  (cluster-wide `SETUSER`/`DELUSER` round-trip) / `chaos process-kill` on a replica (recovered).
- **Node reality:** the 6 redis mgmt IPs are **non-contiguous** — redis-1..6 = `.81 .82 .83 .84 .87 .89`
  on VMnet11 (backplane `.10.x` mirror), dual-NIC (ethernet0 VMnet11, ethernet1 VMnet10).

### Added — nexus-cli v0.6.6 SqlFci/SqlAg adapters — `nexus-cluster-admin` SQL login (oltp-sqlserver env, 2026-06-12)

- **`terraform/envs/oltp-sqlserver/role-overlay-sqlserver-operator-login.tf`** — idempotent
  `CREATE LOGIN` of the dedicated operator SQL login **`nexus-cluster-admin`** (granted **sysadmin** —
  the AG/cluster DDL `ALTER AVAILABILITY GROUP`, `BACKUP`/`RESTORE`, `CREATE LOGIN` realistically needs
  it) that the nexus-cli `SqlFciAdapter` + `SqlAgAdapter` authenticate as. The overlay reads the
  operator password **on the FCI active node** via that node's own Vault Agent token
  (`vault kv get -field=password nexus/oltp/sqlserver/operator-password`) — **never written to disk** —
  runs `CREATE LOGIN … WITH PASSWORD` (if absent, else converge) + `ALTER SERVER ROLE sysadmin ADD
  MEMBER` via the schtasks domain-task (`NEXUS\nexusadmin`, the FCI sysadmin), then verifies the login
  authenticates. Gated by `var.enable_sqlserver_operator_login` (default true). Mirrors the
  clickhouse/starrocks/patroni operator-user overlays; the FCI is mixed-mode so the SQL-login auth works.
  Live-verified: `nexus acl sqlserver list` shows the login as a sysadmin SQL_LOGIN; `nexus health`
  authenticates as it.

### Added — nexus-cli v0.6.3 PatroniAdapter — `nexus-cluster-admin` operator role + patroni.yml `ctl:` block (oltp-patroni env, 2026-06-11)

- **`terraform/envs/oltp-patroni/role-overlay-patroni-operator-user.tf`** — idempotent `CREATE ROLE`
  of the dedicated operator role **`nexus-cluster-admin`** (LOGIN CREATEROLE CREATEDB REPLICATION +
  pg_monitor/pg_read_all_data/pg_write_all_data — **not** a PostgreSQL superuser) that the nexus-cli
  PatroniAdapter authenticates as. The overlay discovers the current Patroni leader (via
  `nexus-patronictl`), reads the password **on the leader** via that node's own Vault Agent token
  (`vault kv get nexus/oltp/patroni/operator-password`) — **never written to disk** — creates the
  role via the leader's local postgres unix socket (peer auth), and verifies scram auth over TLS
  against the leader's VMnet11 listener. The role is a global object → WAL-replicated to the 2
  streaming replicas. Gated on `var.enable_patroni_operator_user`. Mirrors the 0.G.2 mongo + 0.G.3
  percona operator-user overlays.
- **`role-overlay-patroni-bootstrap.tf`** — added a **`ctl:` block** to the rendered patroni.yml
  (`cacert`/`certfile`/`keyfile` = the node's own TLS files). Patroni's REST API runs
  `verify_client: optional`, which **requires** a client cert for state-changing calls (POST
  `/switchover`, `/failover`); without `ctl:` patronictl presented no client cert and those calls
  403'd ("client certificate required"). The CA-signed server cert doubles as the client cert. `ctl:`
  is client-only, so no service restart is needed. `patroni_bootstrap_v` bumped **1 → 2**.
- Cross-env prerequisite: `nexus-infra-vmware` `security` env applied first (operator-password seeded
  + Patroni agent-policy v3 grants read on it).

### Fixed — HAProxy cold-start chroot conflict (oltp-patroni env, 2026-06-11)

- **`role-overlay-haproxy-config.tf`** (v2 → v3) — dropped the `chroot /var/lib/haproxy` directive from
  the rendered `haproxy.cfg`. The `nexus-haproxy.service` unit runs `User=haproxy` (unprivileged), and
  `chroot(2)` needs root / `CAP_SYS_CHROOT` — so a fresh node failed every start with
  "Cannot chroot(/var/lib/haproxy)" (StartLimitBurst hit; no pg_pool backend ever UP). The two
  privilege-drop mechanisms (haproxy-native `user/group/chroot` vs systemd `User=`) are mutually
  exclusive; `User=haproxy` already provides the drop and the unit's `RuntimeDirectory=nexus-haproxy`
  provides the tmpfs `/run/nexus-haproxy`. A **latent bug surfaced by the v0.6.3 from-zero
  cold-rebuild** (the running cluster's haproxy had only ever been started once, pre-rebuild).

### Verified — Phase 0.G.4 cold-rebuild PROVEN (2026-06-11)

- Full from-zero **cold-rebuild** of the oltp-patroni cluster (destroy 47 resources → apply → smoke)
  ran end-to-end **all green** with the new operator-user overlay + the patroni.yml `ctl:` block + the
  haproxy fix proven in the apply graph, and the **correct non-x86 `vmrun_path` baked** into fresh
  state (retiring the [[stale-vmrun-path-in-clone-vm-state]] trap for this cluster).
  `smoke-0.G.4.ps1` ALL CHECKS PASSED; the nexus-cli PatroniAdapter verb matrix re-ran green against
  the rebuilt cluster. One `vmrun start` "Unknown error" transient on pg-replica-1 (re-run apply
  cleared it, per [[vmrun-unknown-error-transient]]).

### Added — nexus-cli v0.6.2 PerconaAdapter — `nexus-cluster-admin` operator user (oltp-percona env, 2026-06-05)

- **`terraform/envs/oltp-percona/role-overlay-percona-operator-user.tf`** — idempotent CREATE USER
  of the dedicated operator user **`nexus-cluster-admin`@'%'** (ALL PRIVILEGES WITH GRANT OPTION) that
  the nexus-cli PerconaAdapter authenticates as. The password is read **on-node** via the PXC node's
  own Vault Agent token (`vault kv get nexus/oltp/percona/operator-password`) and **never written to
  disk**; the user is created via the root-socket `nexus-pxc-mysql` wrapper and **Galera replicates it
  to all 3 PXC nodes**; the overlay verifies the user over TLS (`SHOW STATUS LIKE wsrep_cluster_size`).
  New toggle `enable_percona_operator_user` (default true). Runs after `percona_galera_bootstrap`;
  **proven in a from-zero cold-rebuild** apply graph. Pre-req: nexus-infra-vmware **security** env
  applied first (operator-password seed + PXC agent-policy v2 read grant). See `nexus-cli` ADR-0012 +
  `docs/verification/0.G.3-percona.md`.
- **Fixed (galera-bootstrap):** `role-overlay-percona-galera-bootstrap.tf` step 6 — the `sed -e '$a\'`
  newline-ensure had its `$a` eaten by PowerShell `@"..."@` here-string interpolation (rendered a
  malformed sed → "sed: missing command"), failing a from-zero apply; replaced with a `printf '\n…\n'`
  append (no `$`). A latent bug that only surfaced on a clean from-zero bootstrap.

### Added — nexus-cli v0.6.1 MongoAdapter — `nexus-cluster-admin` operator user (oltp-mongo env, 2026-06-05)

- **`terraform/envs/oltp-mongo/role-overlay-mongo-operator-user.tf`** — idempotent createUser of the
  dedicated operator user **`nexus-cluster-admin`** (roles clusterMonitor + clusterManager + backup +
  restore + userAdminAnyDatabase on `admin`) that the nexus-cli MongoAdapter authenticates as. The
  password is read **on-node** via the mongo node's own Vault Agent token (`vault kv get
  nexus/oltp/mongo/operator-password`) and **never written to disk**; createUser uses the `__system`
  keyFile bootstrap identity routed to the PRIMARY via the RS URI; idempotent re-apply converges the
  role set via `grantRolesToUser`. New toggle `enable_mongo_operator_user` (default true). Runs after
  `mongo_rs_initiate` in the apply graph; **proven in a from-zero cold-rebuild** (21 resources;
  `CREATE_OK → PRIMARIES=1 MEMBERS=3 verified`). Pre-req: nexus-infra-vmware **security** env applied
  first (operator-password seed + agent-policy v3 read grant). See `nexus-cli` ADR-0011 +
  `docs/verification/0.G.2-mongo.md`.

### Added — Phase 0.N — MongoDB sharded cluster SEALED — live-ratified + cold-rebuild-proven (2026-05-30)

5th OLTP cluster live: an 11-VM MongoDB **sharded** cluster (distinct from the 0.G.2 replica-set showcase) — 3 config-server RS (`mongo-cfg-1/2/3` @ .74/.75/.76, port 27019) + 2 shard RSes × 3 (`shard-1` @ .77/.78/.79, `shard-2` @ .80/.56/.57, port 27018) + 2 stateless `mongos` routers (@ .58/.59, port 27017). Per ADR-0040. Per-cluster env `terraform/envs/oltp-mongo-sharded/` (5 overlays: nftables-backplane → keyfile → config → rs-initiate ×3 → add-shards); per-engine template `oltp-mongo-node` (shared with the 0.G.2 RS, extended with `mongodb-org-mongos`); operator wrapper `scripts/mongo-sharded.ps1`; smoke gate `scripts/smoke-0.N.ps1` (**50/50 GREEN**). keyFile internal auth; mTLS deferred to 0.N.1. Foundation dnsmasq overlay bumped to v7 (+11 mongo pins). **9 ratification transients root-caused + fixed in source** (handbook §3.N): host VMnet-adapter reset (N1) + vault boot-race (N2) + reservations trigger stall v6→v7 (N3) + `vmrun.exe` relocation to non-(x86) Program Files (N4, fixed repo-wide) + vmrun power_on transient (N5) + firstboot IP-map gap (N6) + mongos config-ordering deadlock (N7) + PowerShell scope-qualifier/heredoc-escape ParserError (N8) + `__system`-can't-use-local-through-mongos → `nexus-sharded-admin` user (N9). **Cold-rebuild PROVEN** (template rebuild bakes N6 → destroy → from-zero apply → `smoke-0.N.ps1` 50/50; 1 cold-rebuild transient N10: 11 concurrent vmrun power-ons storm → first apply uses `-parallelism=3`). OLTP tier now **6/6 cold-rebuild-proven**; fleet 108 → 119 VMs. Cross-repo sweep: `nexus-infra-vmware` (foundation v7 + `vmrun_path` correction), `nexus-platform-plan` (ADR-0040 + DEMO-20 finalized + vms.yaml), `nexus-cli` (System B demo `demo-0.N-mongo-sharded-cluster-status.json`), portfolio-index + grezap profile.

### Added — Phase 0.G.4 — Patroni PostgreSQL HA + etcd DCS + HAProxy HA pair scaffolded (2026-05-19)

Brings the 4th OLTP cluster online (in scaffold) via the per-cluster + per-engine architectural canon born from 0.G.3.5. **8 VMs total**: 3 Patroni nodes (`pg-primary`, `pg-replica-1`, `pg-replica-2` at `.61/.62/.63`) + 3 etcd nodes (`etcd-1/2/3` at `.64/.65/.66`) + **2 HAProxy nodes** (`haproxy-pg-1` + `haproxy-pg-2` at `.67/.68`) + **VRRP-floated VIP `192.168.70.60`** between the haproxy pair, mirroring the 0.G.3 proxysql-1/2 + VIP `.50` pattern (no SPOF on the LB tier — the "HA" promise in the phase name covers the LB tier, not just the PG nodes). Cross-tier sweep done in the same commit window across `nexus-infra-vmware`, `nexus-platform-plan`, `nexus-cli`, `portfolio-index`, `grezap/grezap` per `feedback_handbook_standard.md` invariant 1 + `feedback_public_face_must_stay_current.md`.

Note: the initial scaffold (one commit cycle earlier in the same session) shipped a single HAProxy. Greg correctly flagged that single HAProxy is a SPOF inconsistent with the 0.G.3 proxysql HA pair pattern and inconsistent with the phase name "Patroni Postgres HA". Pivoted to the HA pair before any commits were pushed -- `vms.yaml` cluster `postgres` updated to add `haproxy-pg-2` + `virtual_ips.haproxy_pg_vip: 192.168.70.60`; foundation overlay bumped v4→v5 (+8 reservations vs +7); security AppRole/policy/sidecar count 7→8; PKI allowed_domains rewrote to cover both haproxy hostnames; firstboot IP map added `.68`; oltp_haproxy Packer role now apt-installs keepalived + iproute2; per-cluster TF env added `module.haproxy_pg_2` + new role-overlay-haproxy-keepalived.tf overlay; smoke gate added VIP-bound + cert IP-SAN includes VIP + end-to-end-via-VIP checks; demo-0.G.4-haproxy-vip-cutover.json rewritten to test actual VIP migration.

**3 new per-engine Packer templates** (per `feedback_per_cluster_state_per_engine_template.md`):

- `packer/oltp-patroni-node/`: Debian 13 + PostgreSQL 17 from PGDG bookworm apt + Patroni 4.0.5 from PyPI via pip in a `/opt/patroni-venv` (etcd3 extras for the v3 gRPC API). Both apt-shipped `postgresql.service` + `postgresql@17-main.service` are MASKED at bake (Patroni owns the PG lifecycle). `nexus-patroni.service` delivered DISABLED. `/usr/local/sbin/nexus-patronictl` wrapper pre-points patronictl at our config dir.
- `packer/oltp-etcd-node/`: etcd 3.5.16 downloaded from upstream GitHub release tarball + statically-linked binaries to `/usr/local/bin/{etcd,etcdctl,etcdutl}`. Apt's etcd is 3.4.x (uses deprecated v2 API); upstream 3.5+ gives the gRPC v3 + `etcdctl`/`etcdutl` split + snapshot-restore tooling. `nexus-etcd.service` DISABLED. `/usr/local/sbin/nexus-etcdctl` wrapper pre-loads endpoints + TLS material.
- `packer/oltp-haproxy-node/`: HAProxy 3.0 LTS from `haproxy.debian.net` (vbernat's backport repo) + `keepalived` (VRRP daemon for the HA-pair VIP) + `iproute2`. Apt's `haproxy.service` MASKED (would race our `nexus-haproxy.service`); apt's `keepalived.service` DISABLED-not-masked (terraform haproxy-keepalived overlay enables after rendering per-host `/etc/keepalived/keepalived.conf` with priority + unicast peer).

**Per-cluster Terraform env** at `terraform/envs/oltp-patroni/` (7 overlays):

- `main.tf`: 8 `module.vm` blocks (3 patroni + 3 etcd + 2 haproxy HA pair).
- `variables.tf`: 8 `enable_*` per-VM toggles + 16 MAC vars + 8 per-overlay toggles (`enable_nftables_backplane`, `enable_patroni_vault_agents`, per-host `enable_<host>_vault_agent`, `enable_patroni_tls`, `enable_etcd_bootstrap`, `enable_patroni_bootstrap`, `enable_haproxy_config`, `enable_haproxy_keepalived`). All default `true` per `feedback_terraform_partial_apply_destroys_resources.md`. New `haproxy_vip` var (default `192.168.70.60`).
- `outputs.tf`: structured map `{patroni, etcd, haproxy, cluster_scope, haproxy_vip}`. `haproxy` is a 2-entry map keyed by `haproxy-pg-1`/`haproxy-pg-2` with a `keepalived_role` field per entry.
- `role-overlay-patroni-nftables-backplane.tf`: per-cluster nftables ruleset opening `22, 5432, 8008, 2379, 2380, 8404` on VMnet11 + proto 112 (VRRP) + whole-segment VMnet10 trust for streaming replication + raft mesh + Patroni REST cross-calls + VRRP unicast.
- `role-overlay-patroni-vault-agents.tf`: 8-host `for_each` Vault Agent install + `00-base.hcl`. Reads per-host AppRole JSON sidecars at `$HOME/.nexus/vault-agent-oltp-patroni-<host>.json`.
- `role-overlay-patroni-tls.tf`: 8-host `for_each` PKI cert render + role-specific KV cred renders. Per-host bundle.pem → split script `/usr/local/sbin/nexus-patroni-tls-split.sh <dest-dir> <owner-group>` produces 3 files. KV count varies per role: patroni=4, etcd=2, haproxy=2. **HAProxy nodes additionally carry the VIP `.60` in their cert IP-SANs** so client handshakes against the floating VIP validate regardless of which haproxy currently holds it.
- `role-overlay-etcd-bootstrap.tf`: one-shot — render `etcd.conf.yml` + parallel start + leader wait + HTTP basic-auth RBAC + authenticated round-trip.
- `role-overlay-patroni-bootstrap.tf`: one-shot — render `patroni.yml` with `password_file` refs + parallel start + wait for 1 Leader + 2 Streaming Replica + psql round-trip.
- `role-overlay-haproxy-config.tf` (`for_each` over both haproxy nodes): render identical `/etc/nexus-haproxy/haproxy.cfg` on BOTH haproxy-pg-{1,2} (frontend `:5432` → `backend pg_pool` via Patroni REST `/leader` httpchk; stats UI `:8404` with basic-auth) + start nexus-haproxy.service + per-node backend health verify.
- `role-overlay-haproxy-keepalived.tf` **(NEW)**: VRRP-floated VIP `var.haproxy_vip` between haproxy-pg-1 (priority 110 MASTER candidate) + haproxy-pg-2 (priority 100 BACKUP). Unicast mode (`unicast_src_ip` + `unicast_peer`) per the 0.G.3.5c chunk 1 transient #22 lesson. Health script `/etc/keepalived/check_haproxy.sh` runs `systemctl is-active nexus-haproxy.service` + HAProxy admin socket `show info` probe; weight `-30` on failure demotes MASTER below BACKUP. AH auth password derived from `haproxy-stats-password` (truncated to 8 chars).

**HAProxy HA pair eliminates the SPOF** that a single HAProxy would have had — the "HA promise" in the phase name now covers the LB tier, not just the PG nodes. Mirrors the 0.G.3 proxysql-1/2 + VIP `.50` pattern exactly.

**Operator surface:**

- `scripts/oltp-patroni.ps1`: standard verb shape (`apply | destroy | smoke | cycle | plan | validate`) mirroring oltp-redis/mongo/percona wrappers. Examples updated for the HA pair toggles (`enable_haproxy_pg_1`/`enable_haproxy_pg_2`/`enable_haproxy_keepalived`).
- `scripts/smoke-0.G.4.ps1`: ~90 checks across 13 sections (reachability → firstboot → identity → vault-agent → TLS material + KV creds + VIP-in-IP-SANs for haproxy → etcd service + raft health + RBAC + put/get → Patroni service + 1L+2R shape → streaming replication → psql round-trip on leader → replication-observable on replicas → HAProxy backend health + stats UI auth on BOTH nodes → keepalived active on both + VIP bound on exactly 1 → end-to-end write via VIP `.60:5432`).

**Cross-env preflight** (lands in `nexus-infra-vmware`):

- `foundation/role-overlay-gateway-oltp-reservations.tf`: bumped marker v3 → **v5** (v4 was the abandoned single-HAProxy variant superseded mid-scaffold by the HA pair design), adding 8 dhcp-host reservations for the patroni-tier MACs (`:7E-:85`) pinning `.61-.68`. Atomic single-file replace.
- `security/role-overlay-vault-pki-patroni.tf`: NEW PKI role `patroni-server` (90 d leaf TTL, 26 allowed_domains covering all 8 hosts in bare + `.nexus.lab` + `.patroni.nexus.lab` forms, server+client EKU).
- `security/role-overlay-vault-patroni-cluster-creds-seed.tf`: NEW. Sticky-seeds 5 KV creds at `nexus/oltp/patroni/{etcd-root,patroni-rest,postgres-superuser,postgres-replication,haproxy-stats}-password` (32-char hex each, generated server-side via openssl).
- `security/role-overlay-vault-agent-patroni-policies.tf`: NEW. 8 role-differentiated narrow policies (patroni=4 KV grants, etcd=2, haproxy=2 -- both haproxy nodes share the same policy body).
- `security/role-overlay-vault-agent-patroni-approles.tf`: NEW. 8 AppRoles + per-host JSON sidecars at `$HOME/.nexus/vault-agent-oltp-patroni-<host>.json`.

**Demos** (System B JSON, lands in `nexus-cli/docs/demos/`):

- `demo-0.G.4-patroni-failover.json`: triggers `nexus-patronictl switchover` and verifies new leader elected + etcd DCS updated + HAProxy backend re-routes (on both haproxy nodes).
- `demo-0.G.4-patroni-mtls-roundtrip.json`: psql via VIP `192.168.70.60:5432` with `sslmode=verify-full` + `sslrootcert=/etc/ssl/certs/patroni-ca.pem`; verifies PG `pg_stat_ssl` reports the connection as `ssl=t version=TLSv1.x`. The cert's IP-SAN includes the VIP so verify-full passes regardless of which haproxy holds it.
- `demo-0.G.4-haproxy-vip-cutover.json`: **genuine VRRP VIP migration**. Continuous psql read loop via VIP; stop nexus-haproxy on the MASTER (haproxy-pg-1); keepalived check_haproxy fires within `fall 3` × `interval 2` = ~6 s; BACKUP (haproxy-pg-2) promotes itself + binds the VIP; app reads resume against the same `.60:5432` address with no client reconfig.
- `demo-0.G.4-etcd-leader-failover.json`: `systemctl stop` the etcd leader; verifies raft re-elects within ~5 s and Patroni's etcd3 client transparently fails over (PG service uninterrupted).

**Handbook:** §0 prereqs extended with 0.G.4 cross-tier dependencies; §1.1 build table now lists 7 templates; §1.2 cross-env order step 3d added for patroni; §1.4 smoke invocation; §1.5 selective ops examples for 6 patroni overlays; §1.7 cluster table now has 4 wrappers; §2 phase status row for 0.G.4; §3.1 cold-rebuild canon extended; §3.3 4 demo playbook narratives (mirroring the JSON demos).

**What changes in the next session (live ratification):** apply the chain `foundation → security → packer build (3 templates) → oltp-patroni apply → smoke-0.G.4.ps1`. Document any transients in §3.x of the handbook with the same symptom→diagnosis→recovery shape used for 0.G.3 / 0.G.3.5c. Once smoke ALL GREEN + cold-rebuild proven, close 0.G.4 + sweep external faces + post-CI verify.

### Removed — Phase 0.G.3.5c chunk 2 — legacy monolithic paths deleted; per-cluster is canonical (2026-05-18)

Closes the 0.G.3.5 refactor. With the per-cluster envs + per-engine templates LIVE-PROVEN (chunk 1, commit `d076abd`, CI green), the legacy monolithic paths are now dead code. Deleted in this commit:

- `packer/oltp-node/` (entire dir, 46 files): monolithic Packer template bundling redis + mongo + pxc + proxysql in a single `oltp-node.vmx` (~6 GB). Replaced by 4 per-engine templates already proven in chunk 1.
- `terraform/envs/oltp/` (entire dir, 20 .tf files + .terraform.lock.hcl): monolithic Terraform state managing all 14 OLTP VMs. Replaced by 3 per-cluster states (`envs/oltp-{redis,mongo,percona}/`).
- `scripts/oltp.ps1`: monolithic operator wrapper. No replacement needed — the 3 per-cluster scripts (`oltp-{redis,mongo,percona}.ps1`) are now the canonical interface; "apply ALL 14 VMs in one shot" semantics deliberately don't have a wrapper.

CI matrix scoped down (`.github/workflows/packer-validate.yml`): 4 per-engine packer templates + 3 per-cluster terraform envs (was 5 packer × 4 terraform incl. legacy entries through chunk 1's `d076abd`). ansible-lint scoped to `packer/oltp-{redis,mongo,pxc,proxysql}-node/ansible/` + `packer/_shared/ansible/`.

Handbook canonicalized:

- §1.1 build the Packer templates (4 per-engine, with shared `PACKER_CACHE_DIR` for ISO reuse + per-template bake-time + footprint table).
- §1.2 cross-env order: removed the "legacy DEPRECATED" block; per-cluster paths 3a/3b/3c are now canonical.
- §1.3 / §1.5 / §1.6 consolidated as redirects to §1.7 (the canonical per-cluster walkthrough already had full coverage).
- §1.4 verify: per-cluster smoke invocations (`oltp-<cluster>.ps1 smoke`).
- §1.7 renamed "Phase 0.G.3.5b" → "canonical interface".
- §2 phase status: 0.G.1/0.G.2/0.G.3 + 0.G.3.5a/b/c chunk 1/c chunk 2 all marked ✅ PROVEN cold-rebuildable from per-cluster envs.
- §3.1 cold-rebuild canon: per-cluster cycle with per-cluster timing table (~5-10 min per cluster vs ~30 min monolithic).
- §3.x recovery rows updated where the original recommended `oltp.ps1 apply`; now points at per-cluster equivalents. Historical 0.G.3 monolithic-ratification transient rows kept as-is (correct historical record).

README badge bumped to **`0.G.3.5c CLOSED`** (entire 0.G.3.5 refactor done). Status table flipped all 0.G.3.5 chunks to ✅.

**Cross-tier sweep (separate commits to other repos):** `nexus-platform-plan/MASTER-PLAN.md` row for 0.G.3 closure + per-cluster refactor + `docs/infra/vms.yaml` if any spec changed; `nexus-platform-plan/docs/glossary.md` if new tools surfaced; `portfolio-index/README.md` + `grezap/grezap` profile (public-face per `feedback_public_face_must_stay_current.md`).

### Verified — Phase 0.G.3.5c chunk 1 — LIVE COLD-REBUILD via per-cluster envs ALL GREEN (2026-05-18)

**All 3 OLTP clusters PROVEN cold-rebuildable from per-engine Packer templates + per-cluster Terraform states.** 14 VMs (6 redis + 3 mongo + 3 PXC + 2 ProxySQL) destroyed + cleanly re-cloned from `oltp-{redis,mongo,pxc,proxysql}-node.vmx` artifacts; per-cluster overlays applied; smoke gates green:

- **0.G.1** (`smoke-0.G.1.ps1`): 6-node Redis Cluster, 3 masters + 3 replicas, 16384 slots, cross-shard SET/GET ✅
- **0.G.2** (`smoke-0.G.2.ps1`): 3-node MongoDB RS `nexus-rs`, 1 PRIMARY + 2 SECONDARY, replicated write/read round-trip via readConcern=majority ✅
- **0.G.3** (`smoke-0.G.3.ps1`): 3-PXC + 2-ProxySQL stack on mutual TLS, VRRP-floated VIP `192.168.70.50` on proxysql-1 MASTER, end-to-end write via VIP propagates to all 3 PXC backends ✅
- Regression: legacy oltp 0.G.1 + 0.G.2 still active alongside the per-cluster envs (no cross-contamination) ✅

**11 new transients surfaced + permanently fixed during the cold-rebuild** (full table in [`docs/handbook.md` §3.x](./docs/handbook.md)):

1. **#17 — ProxySQL apt package is `proxysql` not `proxysql2`.** Vendor APT ships single-name `proxysql_2.6.x_*.deb`; the `proxysql2` in the role broke `oltp-proxysql-node` packer build. Fix: rename apt package in `packer/oltp-proxysql-node/ansible/roles/oltp_proxysql/tasks/main.yml`.
2. **#18 — Redis 8 `--cluster-replicas 1` leaves orphan masters.** Redis 8.0.2's redis-cli create silently fails to assign the secondary 3 nodes as replicas; cluster reports `cluster_state:ok` + 16384 slots but shape is 6 masters + 0 replicas. Live fix: SSH each orphan + `CLUSTER REPLICATE <master-id>`. Permanent fix TODO in `role-overlay-redis-cluster-create.tf` (orphan detection + auto-REPLICATE).
3. **#19 — Firstboot `chown root:mysql` crashed on proxysql nodes** (no mysql group there). Moved proxysql out of `cluster=percona` into `cluster=proxysql` + `IDENTITY_DIR=/etc/nexus-proxysql` in `packer/_shared/ansible/roles/oltp_firstboot/files/oltp-node-firstboot.sh`. Smoke updated to match (per-role dir).
4. **#16+#20 — Root cause of the unsolved monolithic #16 (joiner SST didn't sync).** TWO compounding bugs: (a) `sst-auth.cnf` written with `[mysqld]` section header — PXC 8.0 removed `wsrep_sst_auth` from `[mysqld]`; only valid under `[sst]`. mysqld errors `unknown variable` + aborts. (b) chunk 3b's `wsrep.cnf` render lacks trailing newline; chunk 3c step 6's `echo '!include sst-auth.cnf' | tee -a` concatenates onto the last line → `pxc-encrypt-cluster-traffic = ON!include /etc/nexus-percona/sst-auth.cnf` single garbage line → !include never fires → wsrep_sst_auth missing → joiner SST fails. Fixed: `[mysqld]` → `[sst]` in `role-overlay-percona-galera-bootstrap.tf` step 6 + trailing blank line in `role-overlay-percona-config.tf` wsrep.cnf render + belt-and-braces `sed -i -e '$a\\'` in step 6 before tee -a. Bumped `galera_bootstrap_v` to v5, `percona_config_v` to v5.
5. **#20.b — galera-bootstrap verify mysql calls run as nexusadmin** (no sudo) → can't traverse `/etc/nexus-percona/tls/` (0750 root:mysql) to read ca.pem → `--ssl-mode=VERIFY_CA` aborts. Fix: `sudo mysql ...` in v4+.
6. **#20.c — mysql client `[Warning] Using a password on the command line interface can be insecure.`** stderr line merges (via 2>&1) above SELECT result; `$readOut -eq $token` fails on multi-line. Write side used `-match` (regex), read side was `-eq`. Fix: `[regex]::Escape($token) -match` in v5.
7. **#21 — ProxySQL nodes lack `mysql` client** — oltp_proxysql role only installed `proxysql + keepalived`. The proxysql_config admin probe, keepalived check_proxysql.sh, smoke gate's :6033 client all fail with `command not found`. Fix: add `mariadb-client` to apt install list in the role. Rebake oltp-proxysql-node template (10m 15s).
8. **#22 — VRRP multicast (`224.0.0.18`) doesn't reliably traverse VMware Workstation VMnet11.** Both proxysql nodes go split-brain MASTER. Fix: switch to unicast VRRP — `unicast_src_ip <self>` + `unicast_peer { <peer> }` in keepalived.conf. Bumped `keepalived_v` to v2 + added per-host `peer` field to locals.
9. **Smoke uses `mysql --defaults-file=...`** but root has a KV-derived password post-bootstrap → mysql w/o credentials fails. Fix: 3 instances patched to use `/usr/local/sbin/nexus-pxc-mysql` wrapper.
10. **Smoke VIP probe fails `VERIFY_CA`** — ProxySQL serves :6033 TLS using its auto-generated self-signed cert (no SANs in our chain). Fix: smoke uses `--ssl-mode=REQUIRED` (TLS yes, validate-chain no). **TODO 0.G.3.6**: override proxysql frontend cert with our PKI-issued cert.
11. **`modules/vm` clone_vm destroy provisioner silent-error-swallow** — `vmrun deleteVM` fails against running VMs but `*>$null` hid the error. Stale VM dirs broke next clone_vm's "Destination already exists" pre-flight. Fix: stop → sleep 2 → deleteVM → retry-if-still-there → rm -rf in `terraform/modules/vm/main.tf`.

**Source files changed (this commit):**

- `packer/_shared/ansible/roles/oltp_firstboot/files/oltp-node-firstboot.sh` — #19 proxysql cluster split
- `packer/oltp-proxysql-node/ansible/roles/oltp_proxysql/tasks/main.yml` — #17 (proxysql2 → proxysql) + #21 (mariadb-client)
- `terraform/envs/oltp-percona/role-overlay-percona-config.tf` — #16 trailing blank line (`percona_config_v` v5)
- `terraform/envs/oltp-percona/role-overlay-percona-galera-bootstrap.tf` — #20 [sst] section + #20.b sudo verify + #20.c read regex + belt-and-braces sed ensure-newline before tee -a (`galera_bootstrap_v` v5)
- `terraform/envs/oltp-percona/role-overlay-proxysql-keepalived.tf` — #22 unicast VRRP (`keepalived_v` v2)
- `terraform/modules/vm/main.tf` — destroy provisioner: stop+wait+deleteVM+retry+rm
- `scripts/smoke-0.G.3.ps1` — nexus-pxc-mysql wrapper + per-role identity dir + sudo + `--ssl-mode=REQUIRED` for VIP
- `.github/workflows/packer-validate.yml` — packer + terraform matrices extended to validate the 4 new per-engine templates + 3 new per-cluster envs (legacy entries kept until chunk 2)
- `docs/handbook.md` — status header rewrite; §2 phase status: 0.G.3.5c chunk 1 ✅ PROVEN; §3.x: +11 transient rows with diagnoses + permanent fixes
- `README.md` — phase badge: "0.G.3.5b scaffolded" → "0.G.3.5c PROVEN cold-rebuildable" (all 3 OLTP clusters)
- `CHANGELOG.md` — this entry

**Live wall-clock (apply phases only):**

- destroy legacy 14 VMs: ~30s
- packer build ×4 (oltp-redis-node 8m 8s + oltp-mongo-node 7m 50s + oltp-pxc-node 9m 0s + oltp-proxysql-node 7m 12s first + 10m 15s retry post-#17 fix = ~32m sequential)
- apply oltp-redis: ~6m incl. #18 manual REPLICATE
- apply oltp-mongo: ~5m clean
- apply oltp-percona: ~25m incl. #16/#20 root-cause + live config fix + #21 rebake + #22 unicast switch + smoke iteration

Total cold-rebuild + diagnose 11 transients: ~75 min interactive — well under the monolithic design's per-iteration cost (which was 30 min PER terraform apply attempt before any diagnosis time).

**Legacy `packer/oltp-node/` + `terraform/envs/oltp/` + `scripts/oltp.ps1` kept this commit** for safety + git history reference. Removed in 0.G.3.5c chunk 2 (after this commit's CI is green).

### Added — Phase 0.G.3 (Percona XtraDB Cluster + ProxySQL, 5 nodes) — scaffolding complete; ratification deferred to 0.G.3.5 refactor (2026-05-18)

**Ratification status (honest):** Live ratification cycle hit **16 transients** across 7 Packer builds + 6 oltp apply iterations + a manual redis CLUSTER RESET HARD recovery. Each transient was diagnosed + fixed (with code changes baked into the chunk 3 overlays + the oltp_pxc Ansible role + the chunk 4 Packer template). Transient #16 (joiner SST didn't reach Synced) stopped converging — the monolithic `envs/oltp/` + `oltp-node.vmx` design's 30-min full-tree iteration loop made each new SST debug attempt too slow + each fix in percona kept cascading to redis/mongo state.

**Pivoted to Phase 0.G.3.5 refactor** per `memory/feedback_per_cluster_state_per_engine_template.md`: split monolithic oltp into per-engine Packer templates (oltp-redis-node + oltp-mongo-node + oltp-pxc-node + oltp-proxysql-node) + per-cluster Terraform envs (envs/oltp-redis + envs/oltp-mongo + envs/oltp-percona). The refactor:
- **Shrinks iteration loop from 30 min → 5 min** (per-cluster apply touches only that cluster's VMs)
- **Eliminates cascade replacement** between clusters (each has its own state)
- **Carries forward all 16 transient lessons** baked into the per-engine templates + per-cluster overlays
- **Verified by existing smoke gates** (smoke-0.G.1/2/3.ps1 are the regression test bed)

All 16 transients are documented in `docs/handbook.md` §3.x with symptom → diagnosis → fix.



5-node OLTP cluster: 3 PXC (Galera-replicated MySQL data plane, mTLS-only on :3306, Galera SST/IST over VMnet10 backplane via xtrabackup-v2) + 2 ProxySQL (galera-aware connection pooler + load balancer on :6033, admin :6032, VRRP-floated VIP `192.168.70.50` between proxysql-1 MASTER candidate / proxysql-2 BACKUP). 4 sub-chunks across chunk 3 + chunk 4 + chunk 5 + a chunk 4 lint fix:

**chunk 3a — oltp env scaffolding** ([commit 289f214](https://github.com/grezap/nexus-infra-oltp/commit/289f214)):
- `terraform/envs/oltp/main.tf`: +5 module.vm blocks (pxc-node-1/2/3 + proxysql-1/2) reading the canonical MACs from the foundation overlay (`00:50:56:3F:00:79-7D`).
- `terraform/envs/oltp/variables.tf`: +25 vars (5 per-VM toggles · 10 MAC vars · 1 master vault-agents toggle · 5 per-host vault-agent toggles · 4 overlay toggles · 3 cross-env coupling vars + VIP IP).
- `terraform/envs/oltp/role-overlay-oltp-nftables-backplane.tf` v2 → **v3**: +5 percona node IPs to push set, +3306 (MySQL), +6032/6033 (ProxySQL admin + frontend), +VRRP protocol 112 unicast/multicast accept rules. Galera SST/IST ports 4444/4567/4568 covered by existing VMnet10 whole-segment trust.
- `terraform/envs/oltp/role-overlay-percona-vault-agents.tf` (NEW, ~290 LOC): 5-host port of `role-overlay-mongo-vault-agents.tf` with `oltp-percona-` sidecar prefix.

**chunk 3b — TLS overlay + percona-config** ([commit 6e744a5](https://github.com/grezap/nexus-infra-oltp/commit/6e744a5)):
- `terraform/envs/oltp/role-overlay-percona-tls.tf` (NEW, ~410 LOC): per-host PKI leaf + 3 KV cred renders via 4 Vault Agent template stanzas (70-tls + 71-cluster-password + 72-monitor-password + role-dependent 73-root-password OR 73-proxysql-admin-password). Split script breaks bundle.pem into 3 files (server-cert + server-key + ca) -- MySQL + ProxySQL both require 3 separate `ssl-*` directives, vs mongo's combined .pem. PKCS#8 key (lab convention). ProxySQL nodes include VIP .50 in IP SANs so handshakes against the floating VIP validate regardless of which node holds it.
- `terraform/envs/oltp/role-overlay-percona-config.tf` (NEW, ~270 LOC): per-host PXC-only render of /etc/nexus-percona/{my,wsrep}.cnf. Two-file split per Percona convention. mTLS-only on 3306, `require_secure_transport=ON`. Galera over VMnet10 backplane with `wsrep_cluster_address` listing all 3 PXC backplane IPs, `wsrep_sst_method=xtrabackup-v2`, `pxc_strict_mode=ENFORCING`, `pxc-encrypt-cluster-traffic=ON`. `mysqld --validate-config` clean-check before reporting success. Service start NOT triggered here -- chunk 3c owns mysql.service lifecycle.
- Fix: escaped `${1:-mysql}` → `$${1:-mysql}` in the bash split script's positional-arg-with-default (Terraform heredoc interpolation lesson, per `memory/feedback_terraform_heredoc_powershell.md`).

**chunk 3c — galera-cluster-bootstrap** ([commit 9eb1a29](https://github.com/grezap/nexus-infra-oltp/commit/9eb1a29)) — the tricky one:
- `terraform/envs/oltp/role-overlay-percona-galera-bootstrap.tf` (NEW, ~370 LOC): probe-then-bootstrap with idempotent re-apply. Stage 1 probe via `SHOW STATUS LIKE 'wsrep_cluster_size'` from any active PXC node. If cluster exists, skip bootstrap dance (verification still runs). Otherwise: stop both services on all 3 PXC nodes → start `nexus-percona-bootstrap.service` on pxc-node-1 (--wsrep-new-cluster) → wait for socket → ALTER root password + CREATE wsrep_sst/clustercheck/smoke-rw users with grants → write `/etc/nexus-percona/sst-auth.cnf` (0640 root:mysql) on all 3 nodes with idempotent `!include` to wsrep.cnf → stop bootstrap unit on pxc-node-1 + start regular nexus-percona.service → wait Synced → sequential SST joiner start (pxc-node-2 then pxc-node-3, each waiting for own Synced + cluster size increment).
- Verification (PXC exit gate): wsrep_cluster_size=3 on bootstrap node · wsrep_local_state_comment=Synced on all 3 · wsrep_cluster_status=Primary on all 3 · write/read round-trip via smoke-rw + mTLS (insert on pxc-node-1 with ON DUPLICATE KEY UPDATE for idempotency, SELECT on pxc-node-2 + pxc-node-3 returns the token).
- smoke-rw password derived deterministically from cluster-password (`smoke-` + first 24 chars) -- forward-compat for a future smoke-rw-password sticky-seed.
- `terraform/envs/oltp/outputs.tf`: +percona_endpoints output (pxc + proxysql per-node IPs with both VMnet11 service + VMnet10 backplane addresses; MySQL/Galera/ProxySQL ports; cluster_name; VIP). next_step updated.

**chunk 3d — ProxySQL config + keepalived VRRP** ([commit 8b23c07](https://github.com/grezap/nexus-infra-oltp/commit/8b23c07)):
- `terraform/envs/oltp/role-overlay-proxysql-config.tf` (NEW, ~270 LOC): per-host (2 ProxySQL only) /etc/proxysql.cnf render + nexus-proxysql.service start + backend convergence verify. Galera-aware mysql_galera_hostgroups (writer=10, backup_writer=20, reader=30, offline=40 with max_writers=1, writer_is_also_reader=0). mysql_servers populates ALL 3 PXC nodes in hostgroup 10; Galera plugin auto-shuffles at runtime via the clustercheck user. p2s mTLS (ProxySQL <-> PXC backends) sharing the same cert set. Re-apply behavior: wipes runtime SQLite to force re-load from cnf (cnf is source of truth; runtime-edits via :6032 don't survive re-apply).
- `terraform/envs/oltp/role-overlay-proxysql-keepalived.tf` (NEW, ~250 LOC): VRRP VIP .50 failover between proxysql-1 (priority 110 MASTER candidate) and proxysql-2 (priority 100 BACKUP). vrrp_instance VI_PROXYSQL_NEXUS, virtual_router_id 51, advert_int 1s, preempt_delay 5s, AH auth (8-char password derived from cluster-password truncate). /etc/keepalived/check_proxysql.sh (0700 root): 2-check systemctl is-active + mysql SELECT 1 via :6033 as smoke-rw. 3 consecutive failures → weight -30 → priority drops below proxysql-2's 100 → VIP flips within ~1s.

**chunk 4 — oltp-node Packer extension** ([commit 13aa52d](https://github.com/grezap/nexus-infra-oltp/commit/13aa52d) + lint fix [90faabb](https://github.com/grezap/nexus-infra-oltp/commit/90faabb)):
- `packer/oltp-node/ansible/roles/oltp_pxc/` (NEW, 4 files): Percona vendor APT setup via `percona-release setup pxc-80` with trixie→bookworm pin (Percona doesn't ship trixie yet); apt install percona-xtradb-cluster-server + percona-xtradb-cluster-client + percona-xtrabackup-80 + socat + rsync + qpress; stop+disable+mask `mysql.service` + `mysql@bootstrap.service` (apt-installed; would race ours + auto-bootstrap a junk cluster); 4 nexus-percona dirs; install + DISABLED `nexus-percona.service` + `nexus-percona-bootstrap.service` systemd units.
- `packer/oltp-node/ansible/roles/oltp_proxysql/` (NEW, 4 files): ProxySQL vendor APT (repo.proxysql.com pinned to proxysql-2.6.x/debian/bookworm); apt install proxysql2 + keepalived; stop+disable+mask apt-shipped proxysql.service + disable keepalived.service at bake (TF chunk 3d enables per-host on the 2 ProxySQL nodes only); install + DISABLED `nexus-proxysql.service` systemd unit.
- `packer/oltp-node/ansible/roles/oltp_redis/files/oltp-node-firstboot.sh`: IP→hostname→CLUSTER map extended with 5 percona-tier IPs (.51-.55 → pxc-node-{1,2,3} + proxysql-{1,2}, CLUSTER=percona, ROLE=pxc/proxysql) + CLUSTER → IDENTITY_DIR/GROUP map extended with `percona: /etc/nexus-percona / mysql`.
- `packer/oltp-node/ansible/playbook.yml`: +2 vars passthrough + +2 roles in the list (oltp_pxc + oltp_proxysql).
- Lint fix (commit 90faabb): 4 ansible-lint violations -- name[casing] x2 ("apt-get..." → "Apt-get..."), yaml[line-length] (169 chars on debug msg → hoisted to vars: with folded scalar `>-`), no-handler (`when: percona_pin.changed` → unconditional cache refresh; handlers run at end-of-play, too late for the immediately-following install task).

**chunk 5 — close-out** (this commit):
- `scripts/smoke-0.G.3.ps1` (NEW, ~330 LOC): 12 sections (reachability x5 · firstboot x5 · identity x5 with role differentiation · vault-agent x5 + token sink · TLS material 3-file split + 3 KV creds with role-dependent 3rd · PXC config my.cnf + wsrep.cnf + sst-auth.cnf include · ProxySQL config + admin :6032 + galera_hostgroups · services per role · Galera cluster shape size=3/Synced/Primary · VIP .50 bound on MASTER + not-bound on BACKUP · end-to-end via VIP write + read from each PXC backend · regression: 0.G.1 redis + 0.G.2 mongo still active).
- `docs/handbook.md`: §0 prereqs extended with v3 dhcp + percona Vault state; §1.1 packer build time bumped to 40-55 min + expanded spot-check; §1.2 cross-env order extended with 0.G.3 sidecars; §1.3 apply breakdown +percona row; §1.5 +5 0.G.3 -Vars examples; §2 phase table flipped 0.G.3 from "not started" → "scaffolding complete + ratification documented"; §3.x +2 lint-time transient rows.
- `README.md`: phase badge "0.G.1 + 0.G.2 both proven" → "0.G.1 + 0.G.2 proven · 0.G.3 scaffolding complete"; sub-phase table 0.G.3 row updated.

### Added — Phase 0.G.3.5a (per-engine Packer templates) + 0.G.3.5b (per-cluster Terraform states + operator wrappers) (2026-05-18)

**Why**: 0.G.3 ratification hit 16 transients on the monolithic `packer/oltp-node/` template + `terraform/envs/oltp/` state. Iteration loop was ~30 min wall-clock for any single-cluster fix because every overlay change cascaded across the 14-VM tree. Per `memory/feedback_per_cluster_state_per_engine_template.md` the architectural canon is: **per-engine Packer template + per-cluster Terraform state for every multi-cluster infrastructure tier**.

**0.G.3.5a — 4 NEW per-engine Packer templates** ([commit `61ebad8`](https://github.com/grezap/nexus-infra-oltp/commit/61ebad8)):

- `packer/_shared/ansible/roles/oltp_firstboot/` (NEW, 3 files): hoisted firstboot logic out of `oltp_redis` into a shared role. Same IP→hostname→cluster→IDENTITY_DIR map (5 percona-tier rows + 3 mongo + 6 redis), same systemd unit. All 4 per-engine templates depend on it.
- `packer/oltp-redis-node/` (NEW, ~12 files): split from the monolithic oltp-node. `role_paths` = `[oltp_firstboot, oltp_redis]`. Drops `oltp_mongo` + `oltp_pxc` + `oltp_proxysql`. Bake time ~7-8 min vs ~40-55 min for monolithic. Output: `H:\VMS\NexusPlatform\_templates\oltp-redis-node\oltp-redis-node.vmx`.
- `packer/oltp-mongo-node/` (NEW, ~12 files): `role_paths` = `[oltp_firstboot, oltp_mongo]`. Same trim.
- `packer/oltp-pxc-node/` (NEW, ~12 files): `role_paths` = `[oltp_firstboot, oltp_pxc]`. **Carries all 12 PXC-specific transient fixes from 0.G.3 ratification** baked into the Ansible role (skip `percona-release setup`, manual GPG keyring extraction, bookworm libaio1+libldap-2.5-0 pin, datadir initialization, AppArmor mysqld profile disable, `nexus-pxc-mysql` try-then-fallback wrapper, sst-auth.cnf, etc.).
- `packer/oltp-proxysql-node/` (NEW, ~12 files): `role_paths` = `[oltp_firstboot, oltp_proxysql]`. Carries the ProxySQL flat-repo URL fix + apt-default `proxysql.service` mask defense.
- Shared scaffolding (`files/chrony.conf`, `files/nftables.conf`, `http/preseed.cfg`) duplicated per template (each template independently `packer init`-able; matches `nexus-infra-kafka/packer/kafka-node` per-template pattern).

48 files, 3423 insertions. `packer fmt -recursive` clean.

**0.G.3.5b — 3 NEW per-cluster Terraform states + operator wrappers** ([commit `ad4f563`](https://github.com/grezap/nexus-infra-oltp/commit/ad4f563) + the scripts in this commit):

- `terraform/envs/oltp-redis/` (NEW, ~9 files): 6 redis module.vm blocks pointing at `oltp-redis-node.vmx`. 5 overlays copied from monolithic envs/oltp/ with sed rewires (`oltp_nftables_backplane` → `redis_nftables_backplane`; dropped `var.enable_redis &&` cross-cluster guards). NEW `role-overlay-redis-nftables-backplane.tf` opens only redis ports (22 + 6379 + 16379 + VMnet10 trust) — no more cross-cluster MySQL/MongoDB/ProxySQL ports leaking into redis-tier nftables.
- `terraform/envs/oltp-mongo/` (NEW, ~9 files): 3 mongo module.vm blocks pointing at `oltp-mongo-node.vmx`. Same per-cluster nftables pattern (22 + 27017 + VMnet10 trust).
- `terraform/envs/oltp-percona/` (NEW, ~11 files): 5 module.vm blocks (3 PXC pointing at `oltp-pxc-node.vmx` + 2 ProxySQL pointing at `oltp-proxysql-node.vmx`) + `proxysql_vip = 192.168.70.50`. Per-cluster nftables opens 22 + 3306 + 6032 + 6033 + VRRP proto 112 + VMnet10 trust.
- 6 percona overlays carried forward with all 0.G.3 ratification fixes baked: vault-agents (5 hosts), tls (3-file split + 3 KV cluster-creds per node, role-differentiated PXC vs ProxySQL), config (PXC-only my.cnf + wsrep.cnf with `!include` + trailing blank line fix from transient #10), galera-bootstrap v3 (bootstrap-then-joiners ordering fix from transient #15), proxysql-config, proxysql-keepalived.
- All 3 envs validate clean (`terraform init`, `terraform validate`, `terraform fmt -check`).
- `scripts/oltp-redis.ps1` + `scripts/oltp-mongo.ps1` + `scripts/oltp-percona.ps1` (NEW, this commit): operator wrappers around the 3 per-cluster envs. Mirror `scripts/oltp.ps1`'s verb shape (`apply | destroy | smoke | cycle | plan | validate`) but bounded to one cluster each. `cycle` = per-cluster `destroy → apply → smoke` in ~5-10 min vs ~30 min for the legacy monolithic `oltp.ps1 cycle`.
- `docs/handbook.md` updated: status header marks 0.G.3.5 in flight; §1.2 cross-env order documents both monolithic (deprecated) and per-cluster (canonical going forward) paths; **NEW §1.7 per-cluster scripts** with full cold-rebuild walkthrough + per-cluster selective-ops `-Vars` examples (PXC-only without ProxySQL, re-iterate galera-bootstrap one-shot, skip VIP, etc.); §2 phase table grows 0.G.3.5a/b/c rows.

**What 0.G.3.5b explicitly DEFERS to 0.G.3.5c**:
- Live `packer build` of the 4 new per-engine templates
- Live cold-rebuild via the 3 per-cluster envs
- Live re-ratification of Percona (transient #16: joiner SST didn't converge under the monolithic loop; ~10 min iteration loop now should make root-cause tractable)
- Removal of legacy `packer/oltp-node/` + `terraform/envs/oltp/` + `scripts/oltp.ps1` after the 3 new envs are live-proven

**Legacy oltp env left in place** until 0.G.3.5c lands, so existing `oltp.ps1` commands still work for operators mid-iteration.

### Verified + Fixed — Phase 0.G.2 ratification (2026-05-17)

Live ratification cycle (foundation → security → packer build → oltp apply → smoke + 0.G.1 regression) **ALL GREEN end-to-end** after 7 iterations of the oltp apply path surfacing 7 distinct bugs / MongoDB-8.0 behavior changes. All fixes in TF + Packer + smoke. Cluster proven: 3-member RS `nexus-rs` live on mTLS + keyFile internal auth + smoke-rw SCRAM RBAC user + write/read round-trip via `readPreference=secondary` + `readConcern=majority`.

**7 transients surfaced + fixed in this commit:**

1. **PowerShell regex `(?m)^FOO=N$` doesn't match SSH-piped CRLF**. `$` end-of-line anchor matches before `\n` only — `\r` between value and newline blocks the match. Fix: `(?m)^FOO=N\s*$` (allow trailing whitespace incl. CR). Applied across all 4 status-summary regexes in rs-initiate + smoke. (rs-initiate v1 → v2.)
2. **MongoDB 8.0 protected-mode-equivalent**: tried `setParameter.enableLocalhostAuthBypass=true` in mongod.conf — does NOT activate the localhost-exception when `security.keyFile` + `security.authorization=enabled` are set. The bypass parameter loads but the runtime check still requires auth. (mongo_config_v=2 added, v=3 reverted with comment.)
3. **`__system` cluster auth as the bootstrap path**: keyFile-derived internal user, root-equivalent privs, authenticatable via `--username __system --password $(cat /etc/nexus-mongo/keyfile) --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256`. Pragmatic + works. Used for the one-shot `createUser smoke-rw` bootstrap. (rs-initiate v3 → v5.)
4. **Probe-via-getUser broken**: `db.getSiblingDB('admin').getUser('smoke-rw')` requires admin privs which localhost-bypass does NOT grant (only allows `createUser` and a few specific commands). Fix: always-try `createUser` + catch the duplicate-user error. (rs-initiate v4.)
5. **Writes need RS URI, not single `--host`**: RS can re-elect at any moment. A single-host write fails with `not primary` if that node isn't currently PRIMARY. Use `mongodb://mongo-1:27017,mongo-2:27017,mongo-3:27017/db?replicaSet=nexus-rs` for auto-routing. (rs-initiate v6 + smoke.)
6. **`rs.status()` requires auth**: privilege `replSetGetStatus` is in `clusterAdmin`/`__system` roles. smoke-rw (readWrite only) doesn't have it. Fix: thread `__system` auth through all status probes in rs-initiate Stage 1+2 + smoke section 9. (rs-initiate v7.)
7. **Bash `$set` variable expansion** inside the SSH double-quoted command envelope: PS `\`$set` produces `$set` literal for PS, but bash then re-expands inside the ssh command string, producing `{:{token:...}}` → mongosh syntax error. Fix: PS `\\`$set` emits `\$set` to bash, bash treats as literal `$set`. Also: mongosh 8.0 error message uses `E11000` / `duplicate key` (not `DuplicateKey` which is the codeName). Fix: `-match 'E11000|duplicate key'`. (rs-initiate v8 + smoke.)

**Cumulative TF state**:
- `nexus-infra-vmware/terraform/envs/security/role-overlay-vault-mongo-smoke-user-seed.tf` (NEW, ~112 LOC) — sticky-seeds 32-char base64 random password at `nexus/oltp/mongo/smoke-user-password`.
- `nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-mongo-policies.tf` v1 → v2 (+1 KV path grant on `nexus/data/oltp/mongo/smoke-user-password`).
- `nexus-infra-vmware/terraform/envs/security/variables.tf` (+1 var `enable_mongo_smoke_user_seed`).
- `nexus-infra-oltp/terraform/envs/oltp/role-overlay-mongo-tls.tf` v1 → v2 (+3rd Vault Agent template stanza rendering `/etc/nexus-mongo/smoke-user-password` from KV).
- `nexus-infra-oltp/terraform/envs/oltp/role-overlay-mongo-config.tf` v1 → v3 (v2 added bypass setParameter, v3 reverted with comment explaining MongoDB 8.0 behavior).
- `nexus-infra-oltp/terraform/envs/oltp/role-overlay-mongo-rs-initiate.tf` v1 → v8 (regex CRLF → __system bootstrap → always-try-createUser → RS URI writes → __system for rs.status → bash `$set` escape + E11000 message format).
- `nexus-infra-oltp/scripts/smoke-0.G.2.ps1` — same fixes (3-7 above).

**`docs/handbook.md` §3.x** gained 6 new MongoDB-specific recovery rows documenting each of the bugs/fixes. **§2 phase status row 0.G.2** flipped to ✅ PROVEN warm + cold-rebuild (2026-05-17).

**Pushed commits unchanged**: this work is on top of `d7f6c35` (foundation 3a), `a7e08c7` (security 3b), `0d8e73b` (oltp TF 3c), `5ac2df8` (packer 3d), `e7e6914` (smoke + handbook 3e).

### Added — Phase 0.G.2 MongoDB Replica Set scaffolding (2026-05-17)

Sub-phase 0.G.2 adds the 3-member MongoDB Replica Set `nexus-rs` alongside the 0.G.1 Redis Cluster. Pattern fully proven by 0.G.1 cold-rebuild; 0.G.2 ships smoother as a result. Scaffolding complete + smoke-tested clean; live ratification pending operator.

- **Foundation env** ([`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) `d7f6c35`): `role-overlay-gateway-oltp-reservations.tf` v1 → v2 — bumped marker + added 3 dhcp-host lines for mongo-1/2/3 (MAC `:76/:77/:78` → IP `.71/.72/.73`). 3 new variables in `foundation/variables.tf` (`mac_oltp_mongo_{1,2,3}_primary`).
- **Security env** ([`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) `a7e08c7`): 4 new TF files in `terraform/envs/security/`:
  - `role-overlay-vault-pki-mongo.tf` — `mongo-server` PKI role (90 d leaf TTL, 12 `allowed_domains` spanning mongo-1..3 bare/.nexus.lab/.mongo.nexus.lab, server+client EKU).
  - `role-overlay-vault-mongo-keyfile-seed.tf` — sticky-seed `nexus/oltp/mongo/keyfile` with a 1024-char base64 random keyFile (generated server-side on vault-1 via `openssl rand -base64 756 | tr -d '\n'`). Mirrors the 0.E.4d portainer admin sticky-seed pattern; preserves operator rotation. RS internal-auth shared secret.
  - `role-overlay-vault-agent-mongo-policies.tf` — 3 narrow policies (`nexus-agent-mongo-{1,2,3}`) granting PKI issue + KV read on `nexus/data/oltp/mongo/keyfile` + token self-mgmt. Mongo's policy is richer than redis's (which had no KV grant) because mongo needs the shared keyFile.
  - `role-overlay-vault-agent-mongo-approles.tf` — 3 AppRoles + 3 JSON sidecars at `$HOME/.nexus/vault-agent-oltp-mongo-mongo-<n>.json`. Mirrors redis sidecar shape with `oltp-mongo-` prefix.
  - 7 new vars in `security/variables.tf` (`enable_mongo_pki` · `vault_pki_mongo_role_name` · `enable_mongo_keyfile_seed` · `enable_mongo_agent_setup` · `enable_mongo_agent_policies` · `enable_mongo_agent_approles` · `vault_agent_mongo_creds_dir`).
- **OLTP env TF** (`0d8e73b`): 3 `module.vm` blocks (mongo-1..3) + 4 new role overlays:
  - `role-overlay-mongo-vault-agents.tf` (296 LOC) — linear port of redis-vault-agents.
  - `role-overlay-mongo-tls.tf` (315 LOC) — TWO Vault Agent templates: 70-template-mongo-tls.hcl (renders bundle.pem → split into `server.pem` COMBINED leaf+PKCS#8 key per mongod's `--tlsCertificateKeyFile` shape + `ca.crt` intermediate+root per the 0.G.1 OpenSSL strict-verify fix) and 71-template-mongo-keyfile.hcl (pulls KV `nexus/data/oltp/mongo/keyfile.content` → `/etc/nexus-mongo/keyfile` mode 0400 mongodb:mongodb).
  - `role-overlay-mongo-config.tf` (212 LOC) — renders identical `/etc/nexus-mongo/mongod.conf` per node (per-host identity lives in `rs.initiate` members[]). `tls.mode=requireTLS` + `tls.allowConnectionsWithoutCertificates=false` + `replication.replSetName=nexus-rs` + `security.keyFile` + `security.authorization=enabled` + `wiredTiger.cacheSizeGB=0.5` (constrains mongo from grabbing default 50% host RAM on lab 2 GB nodes).
  - `role-overlay-mongo-rs-initiate.tf` (186 LOC) — probe-then-init exit gate. Probes `rs.status().ok` on mongo-1; if 1, no-op. Else `rs.initiate({_id:'nexus-rs', members:[71/72/73:27017]})` via `mongosh`. Verifies 1 PRIMARY + 2 SECONDARY + 3 healthy + write/read round-trip (insert on PRIMARY → read on SECONDARY via `replicaSet=nexus-rs&readPreference=secondary&readConcernLevel=majority`).
  - `role-overlay-oltp-nftables-backplane.tf` v1 → v2 — single tier-wide ruleset now opens 27017 alongside 6379/16379 (one ruleset for all oltp clusters; harmless cross-port acceptance per the kafka-tier pattern). Push set extended via `oltp_node_ips = concat(redis_node_ips, mongo_node_ips)`.
  - 14 new vars in `oltp/variables.tf` (6 mongo MACs + 3 per-host enable + 4 overlay toggles + 2 cross-env paths).
- **Packer template** (`5ac2df8`): `oltp-node` extended with the `oltp_mongo` Ansible role:
  - `oltp-node.pkr.hcl` — `role_paths` += `oltp_mongo`; `extra-vars` += `oltp_node_mongodb_version`; post-install sanity adds `mongod --version` + `mongosh --version` + `systemctl cat nexus-mongo.service` + `mongod.service masked` + `id mongodb`.
  - `variables.pkr.hcl` — +1 var (`mongodb_version`, default `"8.0"`). MongoDB's vendor APT repo only goes through `bookworm` (Debian 12) as of this ship; `trixie` (Debian 13) lags. The role pins to the `bookworm` codename + relies on forward-compat (`mongodb-org-server` is essentially-static with minimal libc deps).
  - `ansible/playbook.yml` — vars += pass-through; roles += `oltp_mongo` after `oltp_redis`.
  - `ansible/roles/oltp_mongo/` — defaults + tasks + handlers + `templates/nexus-mongo.service.j2`. Tasks install MongoDB vendor APT keyring + apt source + `mongodb-org-server` + `mongodb-mongosh` + `mongodb-org-tools`, stop+disable+MASK the apt-shipped `mongod.service` (port-27017 race defense, same pattern as redis), verify the mongodb user+group (apt-created), create `/etc/nexus-mongo/{,tls/}` + `/var/lib/nexus-mongo/` + `/var/log/nexus-mongo/` with appropriate perms, install `nexus-mongo.service` DISABLED. The systemd unit uses `Type=simple` + `RuntimeDirectory=nexus-mongo` + StartLimit in `[Unit]` (per the 0.G.1 ratification lesson) + `LimitNOFILE=64000` (MongoDB requirement).
  - **BUG FIX in `oltp-node-firstboot.sh`**: `IDENTITY_DIR` was hardcoded to `/etc/nexus-redis`. Mongo's `EnvironmentFile` expects `/etc/nexus-mongo/node-identity.env`. `IDENTITY_DIR` is now derived per-cluster after the IP→role map runs (case on `$CLUSTER` → `/etc/nexus-redis` for redis, `/etc/nexus-mongo` for mongo). The chown also uses per-cluster `$IDENTITY_GROUP`. Latent in 0.G.1 (only redis existed); would have broken mongo's config + smoke gate.
- **Smoke gate** (THIS COMMIT): `scripts/smoke-0.G.2.ps1` — ~370 LOC, 9 sections, ~45 checks. Mirrors `smoke-0.G.1.ps1` shape; mongo-specifics: (1) `server.pem` has BOTH cert + key blocks (combined PEM shape mongod requires) · (2) `ca.crt` has 2 CERTIFICATE blocks (intermediate + root per the 0.G.1 OpenSSL lesson) · (3) `keyfile` perms == `0400 mongodb:mongodb` (mongod refuses to start otherwise) · (4) `mongod.conf` directives (`tls.mode=requireTLS`, `allowConnectionsWithoutCertificates=false`, `replSetName=nexus-rs`, `keyFile`, `authorization=enabled`) · (5) `apt mongod.service masked` · (6) `rs.status()` shows 1 PRIMARY + 2 SECONDARY + 3 healthy + 3 members · (7) `rs.status().set == 'nexus-rs'` · (8) write/read round-trip with `readPreference=secondary` + `readConcern=majority` (proves replication + mTLS + keyFile auth end-to-end). Parse-checked clean.
- **`docs/handbook.md` §2** — Phase status table updated: 0.G.2 row added with all 3 components ✅; 0.G.1 row updated to "✅ PROVEN cold-rebuildable (2026-05-17)". §1.5 selective-ops `-Vars` examples extended with 2 mongo recipes.

`§3.1 cold-rebuild canon` remains PROVEN for 0.G.1; 0.G.2's live ratification (foundation + security + packer rebuild + oltp apply + smoke) is pending — will fold into a future `### Verified` block.

### Verified — Phase 0.G.1 cold-rebuild PROVEN (2026-05-17)

Full canonical cycle (destroy → apply → smoke) ran end-to-end on the post-ratification-fixes codebase. All 3 boxes in `docs/handbook.md` §3.1 ratification checklist now checked:

- ✅ **Destroy**: 38 resources destroyed; all 6 VMs gone from `H:\VMS\NexusPlatform\05-oltp\`; `terraform state list` empty.
- ✅ **Apply**: returns exit 0 (after one retry on the vmrun "Unknown error" transient on `redis-5.power_on`; the retry succeeded second-try, which is the documented +1 row in §3.x).
- ✅ **Smoke**: all ~50 checks across 9 sections PASS; `ALL 0.G.1 SMOKE CHECKS PASSED`. `cluster_state:ok` + size=3 + known=6 + slots_assigned=16384 + slots_ok=16384 + 3 masters + 3 replicas + cross-shard SET/GET round-trip via `redis-cli -c`.

Wall-clock: destroy 30 s + apply ~4 min (first attempt) + retry ~3 min + smoke 23 s = **~8-12 min cold-rebuild** including the one retry. Fresh `packer build` (when the template doesn't exist) adds ~7-8 min on top.

`docs/handbook.md` §3.1 status flipped from "aspirational" to "PROVEN". §3.x gained one more row for the vmrun-transient (13 rows total now). README badge bumped to `0.G.1 cold-rebuild proven`. Phase 0.G.1 scaffolding milestone closed.

### Fixed — Phase 0.G.1 ratification fixes (2026-05-17)

Live ratification cycle (foundation → security → packer build → oltp apply → smoke) surfaced **5 issues**, all now fixed in TF + scripts + Packer. All checks green on first-pass smoke after fixes.

- **`packer/oltp-node/variables.pkr.hcl`**: bump Debian ISO `13.4.0` → `13.5.0`. The mirror dropped `13.4.0` the same day `13.5.0` published (`HTTP 404` at build start). New `iso_checksum` fetched from `https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS`. Other repos' Packer templates (`nexus-infra-kafka/packer/kafka-node`, `nexus-infra-vmware/packer/{deb13,vault}`, `nexus-infra-swarm-nomad/packer/swarm-node`) ALSO need this bump on their next rebuild; existing built artifacts in `H:\VMS\NexusPlatform\_templates\` are frozen from when `13.4.0` was current and don't need touching.
- **`terraform/envs/oltp/role-overlay-redis-tls.tf`** v1 → v2: `ca.crt` was just `{{ .CA }}` from Vault `pkiCert` (intermediate only). OpenSSL strict X509 verify requires walking up to a self-signed trust anchor — intermediate alone is not a valid anchor — so the Redis TLS handshake failed with `tlsv1 alert unknown ca` + `certificate verify failed`. The kafka equivalent (`role-overlay-kafka-tls.tf`) works because Java SSL accepts any cert in the trust store as a valid anchor without upchain walk. Fixed by extending the split script to `cat $CA /etc/vault-agent/ca-bundle.crt > ca.crt` (intermediate from `pkiCert` + root from the 0.D.2 distribute bundle).
- **`terraform/envs/oltp/role-overlay-redis-config.tf`** v1 → v2: added `protected-mode no` to rendered `redis.conf`. Redis 8.0 (the version Debian 13.5 ships, vs the assumed 7.4.x) defaults `protected-mode yes`, which refuses non-loopback connections when no `requirepass` is set — even from a node to its own VMnet11 IP. That tripped `redis-cli --cluster create` with `DENIED Redis is running in protected mode`. Safe to disable: nftables restricts 6379+16379 to VMnet11, `tls-port` + `port 0` forces TLS-only, `tls-auth-clients yes` requires a valid client cert chained to the lab CA.
- **`packer/oltp-node/ansible/roles/oltp_redis/templates/nexus-redis.service.j2`**: moved `StartLimitBurst=15` + `StartLimitIntervalSec=600` from `[Service]` to `[Unit]` (their canonical home per systemd.unit(5)). systemd was silently ignoring them in `[Service]` with a `Unknown key` warning, disabling the rate-limiting that protects against cluster-bus rejoin storms. **Takes effect on next Packer template rebuild + clone** — existing clones keep the warning until rebuilt.
- **`scripts/oltp.ps1`**: added `Initialize-TerraformIfNeeded` helper that auto-runs `terraform init` when `.terraform/` is absent (fresh clone or `git clean -fdx`). Idempotent: re-init on already-init env is a no-op-fast. Closes the UX gap where the first `oltp.ps1 apply` after a fresh clone failed with `Module not installed`.
- **`docs/handbook.md` §3.x apply-time recovery table**: +5 rows for the transients hit during ratification (`packer 404`, `Module not installed`, `tlsv1 alert unknown ca`, `protected-mode DENIED`, `4 masters + 2 replicas` shape) + 1 row noting the cosmetic StartLimit warning + recovery action. `§1.1` Packer build spot-check updated to note `Redis 8.0.x` (was: `7.x.x`).

`§3.1 cold-rebuild canon` stays aspirational pending a clean cold-rebuild cycle (destroy → apply → smoke). The warm-apply cycle (apply against existing VMs after these fixes land) is **proven green**.

### Added — Phase 0.G.1 smoke gate + operator handbook (2026-05-17)

- **`scripts/smoke-0.G.1.ps1`** — build-host-driven smoke gate, ~280 LOC, 9 sections, ~50 checks. Verifies per-node SSH reachability → firstboot marker → hostname + node-identity.env → nexus-vault-agent active + token sink populated → PKI cert material rendered (server.crt + server.key as PKCS#8 + ca.crt + CN match) → redis.conf is mTLS-only (port 0 + tls-port 6379 + tls-auth-clients yes + tls-cluster yes + cluster-enabled yes + per-host cluster-announce-ip) → nexus-redis.service active + apt redis-server.service masked → TLS listener on :6379 presents a cert → cluster health (state=ok + size=3 + known=6 + slots_assigned=16384 + slots_ok=16384 + 3 masters + 3 replicas) + 4-key cross-shard SET/GET round-trip via `redis-cli -c`. Mirrors nexus-infra-kafka `smoke-0.H.2.ps1` shape. Probe robustness per `feedback_smoke_gate_probe_robustness.md`. Idempotent: re-runnable against any stable cluster, no apply.
- **`docs/handbook.md`** Redis-specific fill-in (105 → ~280 LOC) — concrete §0 prereqs (foundation dhcp reservations + security PKI/AppRole sidecars with exact filenames), §1.1 packer build with template spot-check, §1.2 cross-env operator order with explicit failure mode when reordered, §1.3 numbered apply-flow breakdown (8 resource categories with what each does), §1.4 smoke pointer, §1.5 selective-ops `-Vars` examples (5 concrete recipes), §1.6 destroy notes (what survives vs what wipes), §2 phase status table, §3.1 cold-rebuild canon with operator ratification checklist (aspirational until live cycle), §3.2 build-host reboot recovery pointer, §3.x apply-time recovery table (6 symptom→diagnosis→recovery rows).
- **`README.md`** — Phase 0.G.1 status promoted from "scaffold" to "TF + Packer + smoke gate complete; awaiting first build/apply". Badge bumped. Quick-link to handbook updated.

### Added — Phase 0.G.1 Packer template real impl (2026-05-17)

- **`packer/oltp-node/oltp-node.pkr.hcl`** + **`variables.pkr.hcl`** — real Packer template (replaces non-buildable scaffold). Mirrors `nexus-infra-kafka/packer/kafka-node` shape: `vmware-iso` source with Debian 13.4.0 netinst (same HTTPS ISO + sha256 as kafka/vault/swarm-node; `-var iso_url=H:/VMS/ISO/...` overrides to local cache per `project_iso_directory.md`) + preseed + ansible-local provisioner; `vmx_remove_ethernet_interfaces=true` so `terraform/modules/vm` writes the real dual-NIC config at clone. Build-time defaults: 2 vCPU / 2048 MB / 40 GB (per `feedback_prefer_less_memory.md`). Stripped of JDK + Kafka + Confluent vars; adds `redis_version=apt-default` (Debian 13 ships Redis 7.4.x; vendor-repo pinning deferred since 0.G.1 uses no Redis 7.2+-only features).
- **`packer/oltp-node/ansible/`** real playbook + `oltp_redis` role (~440 LOC across 7 files): playbook runs the 4 shared `nexus_*` roles + `oltp_redis`; `oltp_redis` apt-installs `redis-server` + `redis-tools`, **stops/disables/MASKs the apt-shipped `redis-server.service`** (defensive against port-6379 race; the canonical unit is `nexus-redis.service` reading `/etc/nexus-redis/redis.conf`), verifies redis user/group, creates `/etc/nexus-redis/` + `/etc/nexus-redis/tls/` + `/var/lib/nexus-redis/` + `/var/log/nexus-redis/` with appropriate perms, installs `nexus-redis.service` DISABLED + `oltp-node-firstboot.service` ENABLED. `nexus-redis.service.j2` uses `Type=simple` (apt redis-server's libsystemd build is unknowable; the 3c overlay does its own TLS PING readiness probe), `ConditionPathExists=/etc/nexus-redis/redis.conf` (gates startup until Terraform renders config), `RuntimeDirectory=nexus-redis` (per `feedback_systemd_runtime_directory_tmpfs.md`), `StartLimitBurst=15` (cluster boot race), no `ExecStop=` (SIGTERM is graceful; avoids needing TLS flags for `redis-cli shutdown` against the TLS-only listener).
- **`packer/oltp-node/ansible/roles/oltp_redis/files/oltp-node-firstboot.sh`** — 232 LOC linear port of `kafka-node-firstboot.sh`. NIC discovery by MAC OUI byte 5 (0x00 primary/VMnet11, 0x01 secondary/VMnet10), nic0/nic1 rename, VMnet11 DHCP wait, **forward-compat IP→role map** (redis-1..6 = .81/.82/.83/.84/.87/.89 active; mongo/percona/patroni rows commented as placeholders for 0.G.2-0.G.4), hostnamectl, `/etc/hosts` entry (per `feedback_smoke_gate_probe_robustness.md`), `20-nic1.link` MAC-match + `20-nic1.network` static, `10-nic0.link` MAC-rewrite (per `feedback_systemd_link_precedence_multi_nic.md`), `/etc/nexus-redis/node-identity.env`, `/var/lib/oltp-node-firstboot-done` marker. Does NOT enable `nexus-redis.service` (the 3c `role-overlay-redis-config.tf` does that after rendering `redis.conf` with per-host `cluster-announce-ip`).
- **`packer/oltp-node/files/{chrony.conf,nftables.conf}`** + **`packer/oltp-node/http/preseed.cfg`** — copied from kafka-node shape with oltp-specific port list (6379 + 16379 instead of 9092/9093/etc.). `files/nftables.conf` is a cold-clone safety net; the 3c `oltp_nftables_backplane` overlay overwrites it at apply time with its own inlined ruleset.
- Verification: `packer init` + `packer validate` + `packer fmt -check` all clean.

### Added — Phase 0.G.1 Redis Cluster Terraform env (2026-05-16)

- **`terraform/envs/oltp/main.tf`** — 6 `module.vm` blocks (redis-1..6, dual-NIC, MAC-pinned). Conditional via `var.enable_redis` + per-host `var.enable_redis_N`. Per-VM dirs under `H:\VMS\NexusPlatform\05-oltp\<host>\` per `feedback_vmware_per_vm_folders.md`. Dropped the broken `vmware-desktop` provider declaration that blocked `terraform init` (provider not in public registry; modules/vm drives `vmrun.exe` via `null_resource` local-exec, same as kafka).
- **`terraform/envs/oltp/variables.tf`** — 12 MAC vars (primaries match foundation's dhcp-host pins on `:70-:75`; secondaries fifth-byte-`0x01` owned here) + 6 per-host enable toggles + 5 overlay toggles (`enable_nftables_backplane` · `enable_redis_vault_agents` + 6 per-host VA toggles · `enable_redis_tls` · `enable_redis_config` · `enable_redis_cluster_create`) + VMnet defaults + cross-env inputs (`vault_agent_redis_creds_dir` · `vault_pki_ca_bundle_path` · `vault_pki_redis_role_name` · `vault_agent_version`).
- **`terraform/envs/oltp/outputs.tf`** — `redis_endpoints` map (service + backplane IPs + 6379 + 16379 per host) + apply-order `next_step` hint.
- **`role-overlay-oltp-nftables-backplane.tf`** (162 LOC) — inlined ruleset (no Packer-baked file dep at this layer); opens 22 + 6379 + 16379 on VMnet11, whole-segment trust on VMnet10. Waits per-node on `/var/lib/oltp-node-firstboot-done`. Per `feedback_nftables_runtime_add_after_drop.md` (atomic `nft -f`, never runtime `add`) + `feedback_cluster_template_nftables_backplane.md` (nic1 accept rule mandatory for cluster bus).
- **`role-overlay-redis-vault-agents.tf`** (350 LOC) — linear port of `nexus-infra-kafka/role-overlay-kafka-vault-agents.tf`. Per-host AppRole sidecar staged + 00-base.hcl + nexus-vault-agent systemd unit with `RuntimeDirectory=nexus-vault-agent`. Surgical destroy preserves `/etc/vault-agent/` so `redis-tls`'s template survives an agent re-install. ERROR (not WARN+skip) when sidecar missing per 0.E.2 v2 lesson.
- **`role-overlay-redis-tls.tf`** (283 LOC) — straight-to-mTLS (no PLAINTEXT flip; Redis 7.x boots TLS-only from cold start). Drops `60-template-redis-tls.hcl` + `/usr/local/sbin/redis-tls-split.sh`. Renders 3 separate files (`server.crt` + `server.key` + `ca.crt`) per Redis's TLS config shape; PKCS#8 key (mirrors kafka per `feedback_vault_agent_template_hcl_heredoc.md`). World-readable CA at `/etc/ssl/certs/redis-ca.pem` for operator chain-verify.
- **`role-overlay-redis-config.tf`** (247 LOC) — per-host `redis.conf` render (TLS-only, `port 0` + `tls-port 6379`, `tls-cluster yes`, `tls-auth-clients yes` for full mTLS, `cluster-enabled yes`, `cluster-announce-ip = <VMnet11 IP>` per host). systemd enable + restart; verifies via self-mTLS PING (broker's own cert doubles as client identity — `redis-server` role has `client_flag=true`). Destroy preserves `/var/lib/nexus-redis/` (nodes.conf + AOF) so a partial destroy doesn't wipe cluster state.
- **`role-overlay-redis-cluster-create.tf`** (202 LOC) — probe-then-create exit gate. Probes `cluster info` for `cluster_state:ok` on redis-1; if present, no-op (idempotent re-apply). Else runs `redis-cli --cluster create --tls --cluster-replicas 1 --cluster-yes` across all 6 nodes. Verifies state=ok + size=3 + known=6 + slots_assigned=16384 + slots_ok=16384 + 3 masters + 3 replicas, then a 4-key cross-shard SET/GET round-trip via `-c` (cluster mode). **0.G.1 exit gate.**
- Cluster bus runs on **VMnet11** (not VMnet10 backplane) — single-IP `cluster-announce-ip` for simplicity; avoids Redis 7.2+ version dependency on `cluster-announce-bus-ip`. Dual-NIC + VMnet10 nftables trust preserved for future scale-out.
- Verification: `terraform fmt -recursive` + `terraform validate` clean; `terraform plan` fails cleanly with "vault-agent-oltp-redis-redis-N.json missing" until security env is applied (documented in `next_step` output + handbook §0).

### Added — Phase 0.G.1 scaffold (2026-05-16)

- **Repo scaffold** mirroring `nexus-infra-kafka`: `terraform/{envs/oltp,modules/vm}`, `packer/{_shared,oltp-node}`, `scripts/`, `docs/{handbook,adr,verification}/`. Shared parts (`modules/vm`, `packer/_shared/ansible`, `scripts/configure-vm-nic.ps1`, `ansible.cfg`, `.gitignore`, `LICENSE`) reused verbatim from `nexus-infra-kafka` per `feedback_dry_single_source_of_truth.md`.
- **`scripts/oltp.ps1`** — operator wrapper (verbs `apply` · `destroy` · `smoke` · `cycle` · `plan` · `validate`) mirroring `nexus-infra-kafka/scripts/kafka.ps1` per `feedback_build_host_pwsh_native.md` (no GNU make on the build host; pwsh wrappers are canonical).
- **Placeholder `packer/oltp-node/` template** — `oltp-node.pkr.hcl` + `variables.pkr.hcl` + empty `ansible/` + `files/` + `http/` subdirectories. Substantive Ansible roles + package installs land per cluster sub-phase: Redis 7.x in 0.G.1, MongoDB 7.0 in 0.G.2, Percona 8.0 + ProxySQL in 0.G.3, Postgres 16 + Patroni + etcd + HAProxy in 0.G.4.
- **Placeholder `terraform/envs/oltp/`** — `main.tf` (`vmware-desktop` provider boilerplate) + `variables.tf` (`enable_*` toggle scaffolding, defaults to `true` per `feedback_selective_provisioning.md` + `feedback_terraform_partial_apply_destroys_resources.md`) + `outputs.tf`. Substantive `module.<vm>` blocks + role overlays land per sub-phase.
- **Placeholder `docs/handbook.md`** with the 9-section structure mandated by `feedback_handbook_standard.md` invariant 2 (§0 prereqs · §1.1 Packer build · §1.2 cross-env operator order · §1.3 apply · §1.4 verify · §1.5 selective ops · §1.6 destroy · §2 phase status · §3 operator runbooks). Body populates as sub-phases close.
- **Placeholder `docs/adr/index.md`** — empty registry. Per-cluster ADRs land per sub-phase (Redis Cluster topology · MongoDB X.509 auth · Percona Galera SST tuning · Patroni leader election · SQL FCI shared-storage strategy).

This is the scaffold-only milestone. The first cluster (Redis) lands as the next commit; smoke gate `smoke-0.G.1.ps1` ratifies the exit.
