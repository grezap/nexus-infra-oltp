# Phase 0.G.7 Ratification Runbook

> **Status:** in progress (started 2026-05-20 after scaffold seal). Live
> ratification of the SQL Server FCI + Always On AG cluster. Updates the
> handbook's §3.5 transient chronology as discoveries are made.

## What this runbook covers

A **single source of truth** for the operator commands to take Phase 0.G.7
from "scaffold-complete" to "smoke ALL GREEN + tagged closed". Follows the
0.G.4 ratify-after-scaffold pattern verbatim. Run top-to-bottom; halt on
first failure + add the transient to handbook §3.5.

## §0 Pre-flight (read-only checks)

Ensure these are TRUE before starting. Per the pre-flight tally landed at
session start 2026-05-20:

| Check | Probe command | Expected |
|---|---|---|
| Vault HA unsealed | `$env:VAULT_ADDR='https://192.168.70.121:8200'; $env:VAULT_SKIP_VERIFY='true'; vault status` | `Sealed=false`, transit seal |
| KDS root key on dc-nexus | `ssh nexusadmin@192.168.70.240 'powershell -Command "Get-KdsRootKey \| Select KeyId,EffectiveTime"'` | KeyId present + EffectiveTime in the past |
| ws2025-desktop.vmx baked | `Test-Path H:\VMS\NexusPlatform\_templates\ws2025-desktop\ws2025-desktop.vmx` | True |
| 6 foundation VMs running | `vmrun list` | dc-nexus + nexus-gateway + vault-1/2/3 + vault-transit |
| vault-ad-bind.json + vault-init.json + vault-ca-bundle.crt | `Test-Path $HOME/.nexus/{vault-ad-bind.json,vault-init.json,vault-ca-bundle.crt}` | All True |
| **SQL Server 2025 Developer ISO** | `Test-Path H:\VMS\ISO\SqlServer2025EnterpriseDeveloperEdition.iso` | True (downloaded from MSDN per ADR-0144) |

**Initial state at ratification start (2026-05-20):** vault unsealed ✅;
KDS key present (effective 2026-05-01) ✅; ws2025-desktop baked ✅; foundation
VMs running ✅; foundation marker still at v5 (security/foundation 0.G.7
overlays not yet applied); SQL ISO downloading.

## §1 Cross-env apply sequence

Hard ordering — each step gates the next:

### §1.1 security.ps1 apply

Writes the 4 sqlserver AppRole sidecars + 5 KV sticky-seeds + iscsi-chap
sidecar + nexus-sql-cluster-members AD group + gmsa-sql-engine$ GMSA.

```pwsh
cd <repo-root>\workspace\nexus-infra-vmware
pwsh -File scripts\security.ps1 apply
```

Expected wall-clock: ~3-5 min (re-applies all security overlays incl. the
5 new sqlserver ones; secret-ids rotate across all clusters as a side
effect — this is the canon pattern + downstream agents re-read sidecars
on next apply).

Verify the sidecars landed:

```pwsh
Get-ChildItem $HOME\.nexus -Filter "*sqlserver*"
Test-Path $HOME\.nexus\iscsi-sqlfci-chap.json   # MUST be True
```

Verify the AD objects landed:

```pwsh
ssh nexusadmin@192.168.70.240 'powershell -Command "
  Get-ADGroup nexus-sql-cluster-members | Select Name;
  Get-ADServiceAccount gmsa-sql-engine | Select Name,DNSHostName,PrincipalsAllowedToRetrieveManagedPassword
"'
```

### §1.2 foundation.ps1 apply

Bumps dnsmasq dhcp-host marker from v5 → v6 (adds 4 SQL Server reservations)
+ installs `tgt` on nexus-gateway + writes the iSCSI target export
(consumes the iscsi-sqlfci-chap.json sidecar written by §1.1).

```pwsh
cd <repo-root>\workspace\nexus-infra-vmware
pwsh -File scripts\foundation.ps1 apply
```

Expected wall-clock: ~2-4 min. The new iSCSI overlay does a one-shot apt
install of tgt + truncate -s 60G of the sparse backing file + tgt-admin
--update reload — the heavy lift only happens on the first apply.

Verify:

```pwsh
ssh nexusadmin@192.168.70.1 "head -1 /etc/dnsmasq.d/foundation-oltp-reservations.conf; systemctl is-active tgt; sudo tgtadm --mode target --op show | head -8"
# Expected output:
#   # OLTP tier dhcp-host reservations managed by ... v6
#   active
#   Target 1: iqn.2026-05.local.nexus:sql-fci.lun1
#   ...
```

### §1.3 SQL Server ISO -- compute SHA256 + patch Packer variables

After Greg drops the ISO at `H:\VMS\ISO\SqlServer2025EnterpriseDeveloperEdition.iso`:

```pwsh
$iso = "H:\VMS\ISO\SqlServer2025EnterpriseDeveloperEdition.iso"
$hash = (Get-FileHash $iso -Algorithm SHA256).Hash.ToLower()
"sha256:$hash"  # paste this into variables.pkr.hcl
```

Then patch the Packer template's checksum default:

```pwsh
$varsPath = "<repo-root>\workspace\nexus-infra-oltp\packer\oltp-sqlserver-node\variables.pkr.hcl"
(Get-Content $varsPath -Raw) -replace 'sha256:000000000000000000000000000000000000000000000000000000000000PLACEHOLDER', "sha256:$hash" | Set-Content $varsPath
```

Commit + push the checksum fix to `grezap/nexus-infra-oltp` so the
released ratification state matches the bake.

## §2 Packer bake

```pwsh
$env:PACKER_CACHE_DIR = 'H:\VMS\packer_cache'
cd <repo-root>\workspace\nexus-infra-oltp\packer\oltp-sqlserver-node
packer init .
packer build .
```

Expected wall-clock: ~30 min:
- clone ws2025-desktop.vmx + power on through OOBE: ~5 min
- file provisioner uploads SQL ISO (~3.5 GB over SCP): ~3-5 min
- 10-sql-install.ps1 (setup.exe /Q /ACTION=Install): ~18 min
- 11-cluster-features.ps1 (3 Windows features + 10 firewall rules + HADR): ~3 min
- windows-restart: ~3 min
- 12-firstboot-stage.ps1 (stage ProgramData + scheduled task): ~30 sec
- sysprep + shutdown: ~2 min

Artifact: `H:\VMS\NexusPlatform\_templates\oltp-sqlserver-node\oltp-sqlserver-node.vmx`

Spot-check before terraform apply:

```pwsh
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' start H:\VMS\NexusPlatform\_templates\oltp-sqlserver-node\oltp-sqlserver-node.vmx nogui
# Wait ~5 min for OOBE; SSH in:
ssh nexusadmin@<dhcp-IP>   # password: nexus-packer-build-only
# Per-template steady-state checks:
Get-Service MSSQLSERVER                    # -> Stopped + StartupType Manual (set by Stage 5 cleanup)
sqlcmd -E -Q "SELECT @@VERSION" -h -1 -W   # -> 2025 Developer + 17.0.x.x (SQL 2025 = instance MSSQL17)
Get-WindowsFeature Failover-Clustering,Multipath-IO | Where InstallState -eq Installed   # iSCSI-Initiator is built-in on WS2025 (msiscsi service)
# Expected: all 3 listed Installed
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' stop <vmx-path> hard
```

## §3 Terraform apply (oltp-sqlserver env)

```pwsh
cd <repo-root>\workspace\nexus-infra-oltp
pwsh -File scripts\oltp-sqlserver.ps1 apply
```

Expected wall-clock: ~45-60 min for cold-rebuild. The apply runs the 9
role-overlays in the order documented in `main.tf`:

```
4 module.sql_* clones (parallel; ~5 min total)
  -> sqlserver_nftables_backplane (~2 min; waits for firstboot to complete on all 4)
  -> sqlserver_domain_join (~5 min; 4-min Add-Computer per node sequentially)
  -> sqlserver_vault_agents (~3 min; binary download + service install per node)
  -> sqlserver_tls (~2 min; cert render via Vault Agent + PFX import to LocalMachine\My)
  -> iscsi_attach (FCI pair only; ~2 min; Initialize-Disk + format S:\ on sql-fci-1)
  -> wsfc_bootstrap (~3 min; New-Cluster + Add-ClusterDisk + Add-CSV)
  -> fci_install (~15-25 min; setup.exe /ACTION=InstallFailoverCluster on -1 then AddNode on -2)
  -> ag_bootstrap (~5 min; CREATE CERTIFICATE x4 + CREATE ENDPOINT x4 + CREATE AVAILABILITY GROUP + ALTER AG JOIN x2)
  -> ag_listener (~2 min; ALTER AG ADD LISTENER + bind cert thumbprint x4)
```

## §4 Smoke gate

```pwsh
pwsh -File scripts\oltp-sqlserver.ps1 smoke
```

~165 checks across 14 sections. Expected wall-clock: ~2 min.

## §5 Iterate transients

Each transient surfaced → halt → SSH to live system → diagnose → fix in
source → re-apply → re-smoke. Append each to handbook §3.5 as one row.

Anticipated transient classes (per scaffold notes):

1. **iSCSI initiator CHAP negotiation** -- secret length / auth mode mismatch between tgt and Windows initiator
2. **SQL ISO upload OOM on Packer's SCP** -- 3.5 GB over SSH may need bigger TMP / `winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="4096"}'`
3. **setup.exe FCI /FAILOVERCLUSTERIPADDRESSES format** -- subnet mask must match cluster network exactly
4. **AG endpoint cert distribution paths/ACLs** -- 4×3 = 12-file scp + import (largest dance in the stage)
5. **Listener cert thumbprint binding race** -- registry edit vs service restart vs client connect ordering
6. **GMSA install on per-node SQL service** -- Test-ADServiceAccount timing post-AD-group-add

## §6 Close-out

When `smoke-0.G.7.ps1` reports `ALL 0.G.7 SMOKE CHECKS PASSED`:

1. Update handbook §3.5 -- replace the "(pending)" risk table with the
   actual transient chronology table (mirror the 0.G.4 §3.4 18-row format).
2. Update handbook §0 status header: `0.G.7 scaffolded` -> `0.G.7 closed`.
3. Update handbook §2 phase status row.
4. Update vms.yaml metadata: `oltp_tier_status: SEALED + PROVEN` (5/5
   cold-rebuild proven; was 5/5 scaffolded + 4/5 cold-rebuild proven).
5. Update MASTER-PLAN.md row 0.G.7 to `closed YYYY-MM-DD`.
6. Update grezap/README + portfolio-index/README.
7. Commit train: `nexus-infra-oltp` (handbook + tag `v0.2.0` "Phase 0.G
   OLTP tier sealed + cold-rebuild proven across all 5 clusters") + plan
   + grezap + portfolio-index.

## §7 Defer to next session

- nexus-cli `IClusterAdapter` SPI + `SqlFciAdapter` + `SqlAgAdapter`
  (Stage 10 from the scaffold session plan).
- 6 System B demo JSONs in nexus-cli/docs/demos/ (Stage 9).
- nexus-cli `v0.6.0` release with AOT gate ≤30 MB.
