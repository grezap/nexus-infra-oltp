#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster oltp-patroni env -- Phase 0.G.4.

.DESCRIPTION
  Per-cluster operator interface for the Patroni PG HA + etcd DCS + HAProxy
  HA pair stack. Drives terraform/envs/oltp-patroni/ (3 Patroni nodes + 3
  etcd nodes + 2 HAProxy = 8 VMs total on the 05-oltp tier, with VRRP VIP
  192.168.70.60 between the haproxy pair mirroring the 0.G.3 proxysql-1/2
  pattern). Patroni uses the dedicated oltp-patroni-node Packer template
  (PG 17 + Patroni 4); etcd uses oltp-etcd-node (etcd 3.5 upstream
  tarball); HAProxy uses oltp-haproxy-node (HAProxy 3.0 LTS from
  haproxy.debian.net + keepalived for VRRP).

  Pre-flight (from outside this wrapper):
    1. nexus-infra-vmware foundation env applied (dnsmasq dhcp-host
       reservations for the 8 patroni-tier MACs at .61-.68 in marker v5).
    2. nexus-infra-vmware security env applied (per-host AppRoles + KV
       sticky-seeds + sidecars at $HOME\.nexus\vault-agent-oltp-patroni-<host>.json
       + PKI role patroni-server + 5 KV-seeded creds in
       nexus/oltp/patroni/{etcd-root,patroni-rest,postgres-superuser,
       postgres-replication,haproxy-stats}-password).
    3. packer build packer/oltp-patroni-node/ + packer/oltp-etcd-node/
       + packer/oltp-haproxy-node/
       (outputs:
       H:\VMS\NexusPlatform\_templates\oltp-patroni-node\oltp-patroni-node.vmx,
       H:\VMS\NexusPlatform\_templates\oltp-etcd-node\oltp-etcd-node.vmx,
       H:\VMS\NexusPlatform\_templates\oltp-haproxy-node\oltp-haproxy-node.vmx).

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/oltp-patroni
  destroy  -- terraform destroy -auto-approve
  smoke    -- run scripts/smoke-0.G.4.ps1 (Patroni + etcd + HAProxy gate)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Use
  for selective per-VM bring-up, e.g.:
    -Vars enable_pg_primary=true,enable_pg_replica_1=false,enable_etcd_1=true

  NOTE per feedback_terraform_partial_apply_destroys_resources.md: every
  -Vars invocation is the FULL override set for that apply. Vars not
  passed default back (true), and `count = var.X ? 1 : 0` resources get
  DESTROYED on omission. Defaults reflect steady state -- omit -Vars when
  you mean "all 8 nodes enabled".

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.G.4.ps1.

.EXAMPLE
  pwsh -File scripts\oltp-patroni.ps1 cycle

.EXAMPLE
  # iterate the patroni-bootstrap one-shot only (assumes etcd up + TLS + KV creds rendered)
  pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_nftables_backplane=false,enable_patroni_vault_agents=false,enable_patroni_tls=false,enable_etcd_bootstrap=false,enable_haproxy_config=false,enable_haproxy_keepalived=false

.EXAMPLE
  # bring up etcd quorum only (no patroni nodes, no haproxy -- useful for etcd-side debug)
  pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_pg_primary=false,enable_pg_replica_1=false,enable_pg_replica_2=false,enable_haproxy_pg_1=false,enable_haproxy_pg_2=false,enable_patroni_bootstrap=false,enable_haproxy_config=false,enable_haproxy_keepalived=false

.EXAMPLE
  # iterate just the haproxy-config + haproxy-keepalived (assumes patroni + etcd up)
  pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_nftables_backplane=false,enable_patroni_vault_agents=false,enable_patroni_tls=false,enable_etcd_bootstrap=false,enable_patroni_bootstrap=false

.EXAMPLE
  # HAProxy pair + config without keepalived VIP (apps hit haproxy-pg-1 directly on .67 -- debugging only)
  pwsh -File scripts\oltp-patroni.ps1 apply -Vars enable_haproxy_keepalived=false

.NOTES
  Sibling wrappers: scripts\oltp-redis.ps1, scripts\oltp-mongo.ps1,
  scripts\oltp-percona.ps1. See docs/handbook.md s1.2 for the cross-env
  operator order.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\oltp-patroni'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.G.4.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[oltp-patroni] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
        Push-Location $envDir
        try {
            & terraform init
            if ($LASTEXITCODE -ne 0) {
                throw "terraform init failed (exit $LASTEXITCODE)"
            }
        } finally {
            Pop-Location
        }
    }
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Initialize-TerraformIfNeeded
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) {
            throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

function Get-VarFlags {
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
    return $flags
}

function Invoke-Apply {
    Write-Step 'terraform apply -auto-approve  (envs/oltp-patroni)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/oltp-patroni)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.G.4.ps1  (Patroni + etcd + HAProxy gate)'
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/oltp-patroni)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/oltp-patroni)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/oltp-patroni)'
    Invoke-Terraform @('validate')
}

switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "oltp-patroni $Verb complete" -ForegroundColor Green
