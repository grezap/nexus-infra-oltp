# nexus-infra-oltp operator handbook

> **Status:** scaffold only — body populates as each Phase 0.G sub-phase closes.
> Follows the 9-section structure mandated by `feedback_handbook_standard.md`
> invariant 2 (the canonical exemplar is
> [`nexus-infra-kafka/docs/handbook.md`](https://github.com/grezap/nexus-infra-kafka/blob/main/docs/handbook.md)).

## §0 Prerequisites

**What MUST be alive before applying anything in this repo.** Filled in once 0.G.1 (Redis Cluster) ships.

Cross-tier dependencies (high-level — to be expanded with exact hostnames + IPs + verification commands):

- **Foundation tier** ([`nexus-infra-vmware/envs/foundation`](https://github.com/grezap/nexus-infra-vmware)) — `nexus-gateway` providing DHCP + DNS + dnsmasq `dhcp-host` reservations for the 25 OLTP MACs (`00:50:56:3F:00:70` through `:88`, allocation per Phase 0.G.0 audit). AD DS forest on `dc-nexus` for SQL FCI domain authentication.
- **Security tier** ([`nexus-infra-vmware/envs/security`](https://github.com/grezap/nexus-infra-vmware)) — 3-node Vault HA + `vault-transit` auto-unseal. Per-cluster PKI roles + per-node Vault Agent AppRoles + JSON sidecars on the build host. Operator order: `security` MUST apply BEFORE `oltp` (the oltp env reads the per-node AppRole sidecars at plan time).

Build-host tools:
- pwsh 7+ (`winget install --id Microsoft.PowerShell`)
- VMware Workstation Pro 25+ on `H:\`
- Terraform 1.9+
- Packer 1.11+
- Ansible (WSL2 or native; consumed by Packer at bake time)

## §1 Phase walkthrough

### §1.1 Build the Packer template

```pwsh
cd packer\oltp-node
packer init .
packer build .
```

Bake time est. ~30-40 min (Debian 13 base + Ansible roles installing Redis + MongoDB + Percona + Postgres/Patroni/etcd/HAProxy + ProxySQL packages, all systemd-disabled).

Output: `H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx`.

### §1.2 Cross-env operator order

**Hard ordering** (each step gates the next):

1. `nexus-infra-vmware\scripts\foundation.ps1 apply -Vars enable_oltp_dhcp_reservations=true` — adds the 25 dnsmasq `dhcp-host` reservations for the OLTP tier.
2. `nexus-infra-vmware\scripts\security.ps1 apply -Vars enable_oltp_pki=true,enable_oltp_vault_agents=true` — writes the per-cluster PKI roles + 25 per-node AppRole sidecars to `$HOME\.nexus\vault-agent-oltp-<host>.json`.
3. `nexus-infra-oltp\scripts\oltp.ps1 apply` — reads the sidecars at plan time + clones + brings up.

Cannot reorder: the oltp env's `vault_agent_*` overlays use `filesha256()` on the sidecar JSONs at plan time, so the security env MUST have written them first.

### §1.3 Apply

```pwsh
pwsh -File scripts\oltp.ps1 apply
```

Numbered apply-flow breakdown lands per cluster sub-phase (see §2 below).

### §1.4 Verify the exit gate

```pwsh
pwsh -File scripts\oltp.ps1 smoke -Phase 0.G.1
```

Each `smoke-0.G.<N>.ps1` script ships in its corresponding sub-phase commit.

### §1.5 Iterating (selective ops)

Per `feedback_selective_provisioning.md` + `feedback_terraform_partial_apply_destroys_resources.md`: every cluster has `enable_<cluster>=true` defaults. Pass `-Vars` ONLY to opt out:

```pwsh
# Bring up only Redis (skip everything else)
pwsh -File scripts\oltp.ps1 apply -Vars enable_mongo=false,enable_percona=false,enable_patroni=false,enable_sql=false

# Iterate on Patroni leader election without rebuilding the rest
pwsh -File scripts\oltp.ps1 apply -Vars enable_patroni_leader_election=true
```

(Concrete toggle lists land per sub-phase.)

### §1.6 Tear down

```pwsh
pwsh -File scripts\oltp.ps1 destroy
```

Survives across destroy/apply cycles (per `feedback_cold_rebuild_stale_kv_tokens.md`): gateway dnsmasq reservations, security env's PKI roles + AppRole sidecars. Wipe the per-cluster bootstrap tokens in Vault KV (`nexus/data/<cluster>/bootstrap*`) before re-apply if the previous cluster left them populated.

## §2 Phase status

| Sub-phase | Cluster | Smoke gate | Status | Closed |
|---|---|---|---|---|
| 0.G.1 | Redis Cluster | `smoke-0.G.1.ps1` | scaffold | — |
| 0.G.2 | MongoDB RS | `smoke-0.G.2.ps1` | TBD | — |
| 0.G.3 | Percona PXC + ProxySQL | `smoke-0.G.3.ps1` | TBD | — |
| 0.G.4 | Patroni + etcd + HAProxy | `smoke-0.G.4.ps1` | TBD | — |
| 0.G.7 | SQL FCI + AG | `smoke-0.G.7.ps1` | TBD | — |

## §3 Operator runbooks

### §3.1 Cold-rebuild canon

The exact `destroy → (cross-env regen) → apply → smoke` sequence with zero operator hot-state between destroy and smoke. Filled in once a cluster cold-rebuild has been actually performed + proven (Phase 0.H's pattern).

### §3.x Apply-time recovery

Per-cluster troubleshooting tables land here as they surface during sub-phase bring-up. The canonical exemplar of "every transient gets a row with symptom → diagnosis → recovery action" is
[`nexus-infra-kafka/docs/handbook.md` §3.7](https://github.com/grezap/nexus-infra-kafka/blob/main/docs/handbook.md).
