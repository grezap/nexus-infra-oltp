#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Cold-rebuild prerequisite cleanup for the 0.G.7 SQL Server FCI + AG cluster.

.DESCRIPTION
  `terraform destroy` of the oltp-sqlserver env removes the 4 VMs + the overlay
  state, but it does NOT clean the cluster's footprint that lives OUTSIDE the
  env (in Active Directory on dc-nexus and on nexus-gateway). Those stale
  objects break a from-zero re-apply:

    - WSFC CNO `sql-fci-cluster` + the FCI/Listener VCOs (`sqlfci`,
      `sql-ag-listener`) + the 4 node computer accounts linger in AD ->
      New-Cluster / domain-join hit "already exists" / rejoin complications.
    - Stale DNS A records (`sqlfci` .16, `sql-ag-listener` .17,
      `sql-fci-cluster` .15) linger in the nexus.lab zone.
    - The iSCSI LUN backing file on nexus-gateway still holds the OLD NTFS +
      system databases -> the new FCI install collides with the old data
      (the iscsi-attach format only initializes a RAW disk).

  Run this AFTER `terraform destroy` and BEFORE `terraform apply` for a true
  from-zero rebuild. Idempotent (absent objects are skipped). Mirrors the
  swarm-nomad "wipe stale Vault KV tokens between rebuilds" prerequisite.

  PROVEN 2026-05-22: destroy -> packer build -force -> this script ->
  terraform apply -> smoke-0.G.7 ALL GREEN 56/56.

.PARAMETER DcIp        dc-nexus IP (AD + DNS). Default 192.168.70.240.
.PARAMETER GatewayIp   nexus-gateway IP (iSCSI tgt). Default 192.168.70.1.
.PARAMETER SshKey      SSH private key. Default ~/.ssh/nexus_gateway_ed25519.
.PARAMETER SshUser     SSH user. Default nexusadmin.
.PARAMETER SkipAd      Skip the AD/DNS cleanup.
.PARAMETER SkipIscsi   Skip the iSCSI LUN wipe.

.EXAMPLE
  pwsh -File scripts/cold-rebuild-prereqs.ps1
#>
[CmdletBinding()]
param(
  [string]$DcIp      = '192.168.70.240',
  [string]$GatewayIp = '192.168.70.1',
  [string]$SshKey    = "$HOME/.ssh/nexus_gateway_ed25519",
  [string]$SshUser   = 'nexusadmin',
  [switch]$SkipAd,
  [switch]$SkipIscsi
)
$ErrorActionPreference = 'Stop'

function Invoke-RemotePs([string]$ip, [string]$script) {
  # Prepend a progress-suppressor so Import-Module ActiveDirectory doesn't spew
  # CLIXML progress records onto stdout (which masked the real output, 2026-06-12).
  $wrapped = "`$ProgressPreference='SilentlyContinue';`n" + $script
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
  # Merge stderr so a connection/auth failure is visible (not silently swallowed).
  & ssh -i $SshKey -o StrictHostKeyChecking=no "$SshUser@$ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
}

# ── 1. AD + DNS cleanup (dc-nexus) ──────────────────────────────────────────
if (-not $SkipAd) {
  Write-Host "[cold-rebuild-prereqs] cleaning stale SQL AD objects + DNS on $DcIp ..." -ForegroundColor Cyan
  $adClean = @'
$ProgressPreference = 'SilentlyContinue'
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
# computer accounts + WSFC CNO + FCI/Listener VCOs
foreach ($n in @('SQL-FCI-1','SQL-FCI-2','SQL-AG-REP-1','SQL-AG-REP-2','sql-fci-cluster','sqlfci','sql-ag-listener')) {
  $c = Get-ADComputer -Identity $n -Properties ProtectedFromAccidentalDeletion -ErrorAction SilentlyContinue
  if ($c) {
    # ALWAYS clear the accidental-deletion protection first (a Deny-Everyone
    # Delete/DeleteTree ACE that blocks even the owner). Then a PLAIN Remove-ADObject
    # (the WSFC CNO is a leaf; -Recursive returns "Access is denied" on it -- cold-
    # rebuild 2026-06-12). Fall back to Remove-ADComputer. Simple flat form: a
    # foreach/switch here parse-failed inside the base64 EncodedCommand (2026-06-15).
    try { Set-ADObject -Identity $c.DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue } catch {}
    try {
      Remove-ADObject -Identity $c.DistinguishedName -Confirm:$false -ErrorAction Stop
      Write-Output ("RM_COMP $n: removed")
    } catch {
      try { Remove-ADComputer -Identity $n -Confirm:$false -ErrorAction Stop; Write-Output ("RM_COMP $n: removed(2)") }
      catch { Write-Output ("RM_COMP $n: ERR " + $_.Exception.Message) }
    }
  } else { Write-Output ("RM_COMP $n: absent") }
}
# DNS A records in nexus.lab
foreach ($d in @('sqlfci','sql-ag-listener','sql-fci-cluster')) {
  $r = Get-DnsServerResourceRecord -ZoneName nexus.lab -Name $d -RRType A -ErrorAction SilentlyContinue
  if ($r) { Remove-DnsServerResourceRecord -ZoneName nexus.lab -Name $d -RRType A -Force -ErrorAction SilentlyContinue; Write-Output ("RM_DNS $d: removed") } else { Write-Output ("RM_DNS $d: absent") }
}
'@
  $adOut = Invoke-RemotePs -ip $DcIp -script $adClean
  $adLines = @($adOut.Split("`n") | Where-Object { $_ -match 'RM_COMP|RM_DNS' })
  if ($adLines.Count -eq 0) {
    Write-Host "  WARN: AD cleanup returned no RM_COMP/RM_DNS lines — raw output below (verify dc-nexus reachable + AD module present):" -ForegroundColor Yellow
    Write-Host ($adOut.Trim())
  } else {
    $adLines | ForEach-Object { Write-Host "  $($_.Trim())" }
  }
}

# ── 2. iSCSI LUN wipe (nexus-gateway) ───────────────────────────────────────
if (-not $SkipIscsi) {
  Write-Host "[cold-rebuild-prereqs] wiping the iSCSI LUN backing file on $GatewayIp ..." -ForegroundColor Cyan
  $img = '/srv/iscsi/sql-fci-shared.img'
  $bash = "sudo systemctl stop tgt && sudo rm -f $img && sudo truncate -s 64424509440 $img && sudo chown root:root $img && sudo chmod 0640 $img && sudo systemctl start tgt && sleep 3 && echo LUN_WIPED=`$(sudo du -h $img | cut -f1)"
  $out = & ssh -i $SshKey -o StrictHostKeyChecking=no "$SshUser@$GatewayIp" $bash 2>&1 | Out-String
  $line = ($out.Split("`n") | Where-Object { $_ -match 'LUN_WIPED' } | Select-Object -First 1)
  if ($line) { Write-Host "  $($line.Trim()) (fresh RAW 60 GiB sparse)" } else { Write-Host "  WARN: LUN wipe output unexpected: $($out.Trim())" }
}

Write-Host "[cold-rebuild-prereqs] done -- ready for 'terraform apply' from zero." -ForegroundColor Green
