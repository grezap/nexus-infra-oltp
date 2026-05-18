# nexus-infra-oltp

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan%20v0.1.3-orange)](https://github.com/grezap/nexus-platform-plan)
[![Phase](https://img.shields.io/badge/phase-0.G.1%20%2B%200.G.2%20proven%20%E2%80%A2%200.G.3.5b%20scaffolded-yellow)](./CHANGELOG.md)
[![Release](https://img.shields.io/badge/release-unreleased-lightgrey)](./CHANGELOG.md)

OLTP data tier of the **NexusPlatform 66-VM lab** — Redis Cluster · MongoDB RS · Percona XtraDB Cluster + ProxySQL · PostgreSQL Patroni + etcd + HAProxy · SQL Server FCI + AG. 25 VMs across tiers `02-sqlserver` (4 Windows) + `05-oltp` (21 Linux).

> **Canon:** This repo implements [Phase 0.G](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) (line 159) of the NexusPlatform blueprint. VM inventory is `nexus-platform-plan/docs/infra/vms.yaml`. Architectural source of truth is [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan).
>
> **➜ Want to rebuild the OLTP tier from zero?** [`docs/handbook.md`](./docs/handbook.md) is the operator canon. The body fills in as each sub-phase closes.
>
> **Phase 0.G.1 status (2026-05-17): ✅ PROVEN cold-rebuildable.** Live ratification cycle (foundation → security → packer build → oltp destroy → apply → smoke) verified end-to-end. 5 transients surfaced + fixed (Debian ISO 13.4.0 → 13.5.0; redis-tls chain bug; Redis 8 protected-mode; systemd StartLimit placement; oltp.ps1 auto-init) — all documented in [`docs/handbook.md` §3.x](./docs/handbook.md). Cold-rebuild wall-clock ~8-12 min (incl. one expected vmrun-transient retry on `power_on`).

## Status

Phase 0.G in progress. Each sub-phase pairs a cluster bring-up with a `nexus-cli` `v0.6.x` release that adds 13 verb groups for that cluster:

| Sub-phase | Cluster | VMs | nexus-cli release | Status |
|---|---|---|---|---|
| 0.G.1 | Redis Cluster | 6 (3 primaries + 3 replicas) | v0.6.0 RedisAdapter | ✅ cold-rebuild proven (2026-05-17) |
| 0.G.2 | MongoDB RS | 3 | v0.6.1 MongoAdapter | ✅ cold-rebuild proven (2026-05-17) |
| 0.G.3 | Percona PXC + ProxySQL | 5 (3 PXC + 2 ProxySQL) | v0.6.2 PerconaAdapter | ⚠️ scaffolding complete (2026-05-18); ratification **deferred to 0.G.3.5 refactor** -- monolithic design too brittle, 16 ratification transients documented in `docs/handbook.md` §3.x |
| 0.G.3.5a | **refactor: per-engine Packer templates** (oltp-redis-node + oltp-mongo-node + oltp-pxc-node + oltp-proxysql-node) | — | — | ✅ scaffolded 2026-05-18 ([commit 61ebad8](https://github.com/grezap/nexus-infra-oltp/commit/61ebad8); 4 NEW templates + shared oltp_firstboot role); live bake deferred to 0.G.3.5c |
| 0.G.3.5b | **refactor: per-cluster Terraform states** (envs/oltp-redis + envs/oltp-mongo + envs/oltp-percona) + per-cluster operator scripts | — | — | ✅ scaffolded 2026-05-18 ([commit ad4f563](https://github.com/grezap/nexus-infra-oltp/commit/ad4f563); 3 NEW envs + 3 NEW scripts; `terraform validate` clean); live apply deferred to 0.G.3.5c |
| 0.G.3.5c | live cold-rebuild via per-cluster envs + re-ratify Percona transient #16 + delete legacy `oltp-node` + `envs/oltp` + `oltp.ps1` | — | — | pending (next live cycle) |
| 0.G.4 | PostgreSQL Patroni + etcd + HAProxy | 7 (3 PG + 3 etcd + 1 HAProxy) | v0.6.3 PatroniAdapter | TBD |
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
