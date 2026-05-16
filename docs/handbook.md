# nexus-infra-oltp operator handbook

> **Status (Phase 0.G.1):** ✅ **PROVEN cold-rebuildable (2026-05-17).** Full
> destroy → apply → smoke cycle verified live. See §3.1 for the canon + the
> 3-box ratification checklist (all checked). §3.x recovery table documents
> the 12 transients surfaced during ratification + their fixes.
>
> Follows the 9-section structure mandated by `feedback_handbook_standard.md`
> invariant 2 (canonical exemplar: [`nexus-infra-kafka/docs/handbook.md`](https://github.com/grezap/nexus-infra-kafka/blob/main/docs/handbook.md)).

## §0 Prerequisites

**What MUST be alive before applying anything in this repo.**

Cross-tier dependencies (in hard-ordering for cold-rebuild):

- **Foundation tier** ([`nexus-infra-vmware/envs/foundation`](https://github.com/grezap/nexus-infra-vmware)) — `nexus-gateway` providing DHCP + DNS via dnsmasq. For 0.G.1 specifically: 6 `dhcp-host` reservations pinning the redis-1..6 MACs (`00:50:56:3F:00:70`-`:75`) to canonical VMnet11 IPs `.81/.82/.83/.84/.87/.89` (skip `.85/.86/.88` which belong to the kafka tier). Owned by `terraform/envs/foundation/role-overlay-gateway-oltp-reservations.tf`.
- **Security tier** ([`nexus-infra-vmware/envs/security`](https://github.com/grezap/nexus-infra-vmware)) — 3-node Vault HA + `vault-transit` auto-unseal. For 0.G.1 specifically: PKI role `redis-server` (90 d leaf TTL, 21 `allowed_domains` covering redis-1..6 hostnames in bare + `.nexus.lab` + `.redis.nexus.lab` forms + `localhost`) + 6 narrow Vault policies (`nexus-agent-redis-1..6`) + 6 AppRoles + 6 per-host JSON sidecars at `$HOME\.nexus\vault-agent-oltp-redis-redis-N.json`. Owned by `terraform/envs/security/role-overlay-vault-{pki-redis,agent-redis-policies,agent-redis-approles}.tf`.

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

Bake time est. **~30-40 min wall-clock** on a typical lab host (Debian 13 base install + apt update + Redis 7.x install + Ansible roles + post-install cleanup). Disk footprint ~5 GB. ISO download cached under `packer_cache/` (unless `-var iso_url=H:/VMS/ISO/...` overrides to a local cache per `memory/project_iso_directory.md`).

Output: `H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx`.

Spot-check the built template before promoting to apply:

```pwsh
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' start H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx nogui
# Wait for boot, then SSH in with the build-time creds:
ssh nexusadmin@<dhcp-assigned-IP>      # password: nexus-packer-build-only
# Expected steady-state inside the template:
systemctl is-active nexus-redis.service          # -> inactive (DISABLED; gates on /etc/nexus-redis/redis.conf)
systemctl is-active oltp-node-firstboot.service  # -> inactive (only runs on a fresh clone, gated by /var/lib/oltp-node-firstboot-done)
systemctl is-enabled redis-server.service        # -> masked (apt-shipped unit defensively masked)
redis-server --version                            # -> Redis server v=8.0.x (Debian 13.5 ships Redis 8.0.2)
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' stop H:\VMS\NexusPlatform\_templates\oltp-node\oltp-node.vmx hard
```

### §1.2 Cross-env operator order

**Hard ordering** (each step gates the next; per `feedback_handbook_standard.md` invariant 1):

```
┌─ [build host] ────────────────────────────────────────────────────────────────┐
│ 1. nexus-infra-vmware\scripts\foundation.ps1 apply                            │
│      adds the 6 OLTP-tier dnsmasq dhcp-host reservations on nexus-gateway.    │
│      (Already done via -Vars enable_oltp_dhcp_reservations=true default.)     │
│                                                                                │
│ 2. nexus-infra-vmware\scripts\security.ps1 apply                              │
│      writes:                                                                   │
│        - pki_int/roles/redis-server                                            │
│        - 6 nexus-agent-redis-N policies                                        │
│        - 6 nexus-agent-redis-N AppRoles                                        │
│        - 6 $HOME\.nexus\vault-agent-oltp-redis-redis-N.json sidecars          │
│      (-Vars enable_redis_pki=true, enable_redis_agent_setup=true are the      │
│       defaults; no override needed for steady-state apply.)                    │
│                                                                                │
│ 3. nexus-infra-oltp\scripts\oltp.ps1 apply                                    │
│      reads the 6 sidecars at plan time + clones + brings up.                  │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Cannot reorder**: the oltp env's `redis_vault_agent` resource uses `filesha256()` on the sidecar JSON at plan time, so the security env MUST have written them first. A premature `oltp apply` fails fast at plan time with `Call to function "filesha256" failed: open ...vault-agent-oltp-redis-redis-N.json: The system cannot find the file specified`.

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

Wall-clock: ~10-15 min from `apply` to exit gate (most of it is per-node SSH polling waiting for systemd-networkd + Vault Agent + Redis to settle).

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

## §2 Phase status

| Sub-phase | Cluster | TF | Packer | Smoke | Status | Closed |
|---|---|---|---|---|---|---|
| 0.G.1 | Redis Cluster (6 nodes) | `terraform/envs/oltp/` ✅ | `packer/oltp-node/` ✅ | `smoke-0.G.1.ps1` ✅ | scaffolding in place; first build + apply pending operator | — |
| 0.G.2 | MongoDB RS (3 nodes) | TBD | extends oltp-node | `smoke-0.G.2.ps1` | not started | — |
| 0.G.3 | Percona PXC + ProxySQL (5 nodes) | TBD | extends oltp-node | `smoke-0.G.3.ps1` | not started | — |
| 0.G.4 | Patroni + etcd + HAProxy (7 nodes) | TBD | extends oltp-node | `smoke-0.G.4.ps1` | not started | — |
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

(Table grows as new transients surface during live cycles.)
