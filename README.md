# nexus-infra-oltp

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan%20v0.1.3-orange)](https://github.com/grezap/nexus-platform-plan)
[![Phase](https://img.shields.io/badge/phase-0.G.1%E2%80%930.G.3.5%20CLOSED%20%E2%80%A2%200.G.4%20SCAFFOLDED-brightgreen)](./CHANGELOG.md)
[![Release](https://img.shields.io/badge/release-unreleased-lightgrey)](./CHANGELOG.md)

OLTP data tier of the **NexusPlatform 66-VM lab** — Redis Cluster · MongoDB RS · Percona XtraDB Cluster + ProxySQL · PostgreSQL Patroni + etcd + HAProxy · SQL Server FCI + AG. 25 VMs across tiers `02-sqlserver` (4 Windows) + `05-oltp` (21 Linux).

> **Canon:** This repo implements [Phase 0.G](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) (line 159) of the NexusPlatform blueprint. VM inventory is `nexus-platform-plan/docs/infra/vms.yaml`. Architectural source of truth is [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan).
>
> **➜ Want to rebuild the OLTP tier from zero?** [`docs/handbook.md`](./docs/handbook.md) is the operator canon. The body fills in as each sub-phase closes.
>
> **Phase 0.G.1 + 0.G.2 + 0.G.3 status (2026-05-18): ✅ ALL PROVEN cold-rebuildable from per-engine Packer templates + per-cluster Terraform states.** Live cold-rebuild (destroy legacy → packer build × 4 → per-cluster apply × 3 → smoke × 3) verified end-to-end via 0.G.3.5c chunk 1. 11 transients surfaced + permanently fixed (incl. root-causing the long-unsolved monolithic transient #16: `wsrep_sst_auth [mysqld]→[sst]` PXC 8.0 section change + wsrep.cnf trailing-newline gap). Full chronology in [`docs/handbook.md` §3.x](./docs/handbook.md).
>
> **Phase 0.G.4 status (2026-05-19): ✅ scaffolded with full HA promise; live ratification pending.** 3 new per-engine Packer templates (`oltp-patroni-node` PG 17 + Patroni 4 + `nexus-patronictl`; `oltp-etcd-node` etcd 3.5.16 + `nexus-etcdctl`; `oltp-haproxy-node` HAProxy 3.0 LTS + `keepalived`) + per-cluster TF env `envs/oltp-patroni/` (**7 overlays**: nftables, vault-agents, tls, etcd-bootstrap, patroni-bootstrap, haproxy-config, **haproxy-keepalived**) + foundation v5 dnsmasq overlay (+8 reservations `.61-.68`) + security overlays (PKI `patroni-server` role + 5 KV sticky-seeds + 8 AppRoles + 8 sidecars) + `scripts/oltp-patroni.ps1` wrapper + `scripts/smoke-0.G.4.ps1` (~90 checks across 13 sections) + 4 System B JSON demos in [`nexus-cli/docs/demos/demo-0.G.4-*.json`](https://github.com/grezap/nexus-cli/tree/main/docs/demos). **HAProxy HA pair (haproxy-pg-1 + haproxy-pg-2) + VRRP-floated VIP `192.168.70.60`** mirroring the 0.G.3 proxysql-1/2 + VIP `.50` pattern (no SPOF on the LB tier). Apps connect via `<VIP>:5432` which routes to the current Patroni leader via REST `/leader` health probes; the haproxy nodes' PKI leaf certs carry the VIP in their IP-SANs so client `sslmode=verify-full` against the floating IP validates regardless of which haproxy currently holds it.

## Status

Phase 0.G in progress. Each sub-phase pairs a cluster bring-up with a `nexus-cli` `v0.6.x` release that adds 13 verb groups for that cluster:

| Sub-phase | Cluster | VMs | nexus-cli release | Status |
|---|---|---|---|---|
| 0.G.1 | Redis Cluster | 6 (3 primaries + 3 replicas) | v0.6.0 RedisAdapter | ✅ cold-rebuild proven (2026-05-17 monolithic; 2026-05-18 per-cluster) |
| 0.G.2 | MongoDB RS | 3 | v0.6.1 MongoAdapter | ✅ cold-rebuild proven (2026-05-17 monolithic; 2026-05-18 per-cluster) |
| 0.G.3 | Percona PXC + ProxySQL | 5 (3 PXC + 2 ProxySQL) | v0.6.2 PerconaAdapter | ✅ cold-rebuild PROVEN end-to-end 2026-05-18 (per-cluster `envs/oltp-percona/`); 16 legacy + 11 refactor transients all documented + permanently fixed in `docs/handbook.md` §3.x |
| 0.G.3.5a | **refactor: per-engine Packer templates** (oltp-redis-node + oltp-mongo-node + oltp-pxc-node + oltp-proxysql-node) | — | — | ✅ scaffolded 2026-05-18 ([commit 61ebad8](https://github.com/grezap/nexus-infra-oltp/commit/61ebad8); 4 NEW templates + shared oltp_firstboot role); live baked 2026-05-18 in 0.G.3.5c chunk 1 |
| 0.G.3.5b | **refactor: per-cluster Terraform states** (envs/oltp-redis + envs/oltp-mongo + envs/oltp-percona) + per-cluster operator scripts | — | — | ✅ scaffolded 2026-05-18 ([commit ad4f563](https://github.com/grezap/nexus-infra-oltp/commit/ad4f563); 3 NEW envs + 3 NEW scripts; `terraform validate` clean); live applied 2026-05-18 in 0.G.3.5c chunk 1 |
| 0.G.3.5c chunk 1 | live cold-rebuild via per-cluster envs + 11 transient fixes (incl. root-causing the unsolved monolithic #16) + permanent fixes in source | — | — | ✅ ALL 3 cluster smoke gates GREEN end-to-end 2026-05-18 ([commit d076abd](https://github.com/grezap/nexus-infra-oltp/commit/d076abd)) |
| 0.G.3.5c chunk 2 | delete legacy `packer/oltp-node/` + `envs/oltp/` + `scripts/oltp.ps1` + drop legacy CI matrix entries + handbook canonicalization | — | — | ✅ removed 2026-05-18 (this commit) |
| 0.G.4 | PostgreSQL Patroni + etcd + HAProxy HA pair + VRRP VIP `.60` | 8 (3 PG + 3 etcd + 2 HAProxy) | v0.6.3 PatroniAdapter | ✅ scaffolded 2026-05-19 (3 per-engine Packer templates + `envs/oltp-patroni/` with 7 overlays incl. NEW haproxy-keepalived + `scripts/oltp-patroni.ps1` + `scripts/smoke-0.G.4.ps1` ~90 checks + 4 System B JSON demos); live ratification pending |
| 0.G.7 | SQL Server FCI + AG | 4 (2 FCI + 2 AG replicas, `ws2025-desktop`) | v0.6.6 SqlFciAdapter + SqlAgAdapter | TBD |

Analytics tier (ClickHouse + StarRocks, sub-phases 0.G.5 + 0.G.6) lives in the sibling repo [`nexus-infra-analytics`](https://github.com/grezap/nexus-infra-analytics) (created when 0.G.5 starts).

## Cross-tier prerequisites

The OLTP tier consumes state from earlier-phase tiers:

- **Foundation tier alive** — `nexus-gateway` (dnsmasq DHCP + DNS + dhcp-host reservations for the 25 OLTP MACs) + `dc-nexus` (AD DS for SQL FCI domain auth) + `nexus-jumpbox`. Managed in [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) (`envs/foundation`).
- **Security tier alive** — 3-node Vault HA cluster + `vault-transit` auto-unseal + PKI hierarchy. Per-cluster PKI roles (`redis-server`, `mongo-server`, `percona-server`, `patroni-server`, `sql-fci-server`) issue 90-day leaf certs for mTLS; per-node Vault Agent AppRoles render the certs + cluster bootstrap creds from `nexus/data/<cluster>/*` KV. Managed in [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) (`envs/security`).

Per `feedback_handbook_standard.md` invariant 2, the exact-from-zero replay path enumerates this dependency chain (with hostnames + IPs + how to verify each prerequisite is alive) in `docs/handbook.md` §0.

## Cluster verbs (nexus-cli surface)

Every cluster in this repo gets 13 verb groups via [`grezap/nexus-cli`](https://github.com/grezap/nexus-cli) `v0.6.x` (`IClusterAdapter` SPI per [nexus-platform-plan ADR-0024](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0024-aot-gate-amendment-and-cluster-adapter-framework.md) + nexus-cli ADR-0009):

| Verb group | Purpose |
|---|---|
| `cluster-status` | live introspection (members, leader, replication state) |
| `failover-test` | drive a failover scenario + measure RTO |
| **`scale-out`** add/remove | cluster-membership change — add or drain a node |
| **`scale-up`** | vertical VM resize (CPU/RAM/disk) — cluster-aware (refuses primary mid-write-window without `--force-primary`) |
| `backup` take/restore | snapshot-aware backup + point-in-time restore |
| `health` | rich healthcheck (replica lag, disk usage, memory pressure) |
| `topology --watch` | live replication / shard map |
| `cert-rotate` | trigger Vault Agent re-render + service reload |
| `chaos` | injection (network partition, slow disk, CPU starve) |
| `acl` | per-cluster ACL management |
| `demo` | run a System B demo against this cluster |

## Quick links

- **Operator handbook:** [`docs/handbook.md`](./docs/handbook.md) (0.G.1 fully populated; §3.1 cold-rebuild canon aspirational pending live ratification)
- **Per-sub-phase verification:** [`docs/verification/`](./docs/verification/) (populated as smoke gates pass)
- **Architectural decisions:** [`docs/adr/`](./docs/adr/) (cluster-specific ADRs land per sub-phase)
- **Cross-tier setup index:** [`nexus-platform-plan/docs/setup-guides.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/setup-guides.md)

## License

[MIT](./LICENSE) © 2026 Greg Zapantis
