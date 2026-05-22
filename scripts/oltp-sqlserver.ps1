#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster oltp-sqlserver env -- Phase 0.G.7.

.DESCRIPTION
  Per-cluster operator interface for the SQL Server FCI + Always On AG
  cluster. Drives terraform/envs/oltp-sqlserver/ (2 FCI nodes sharing
  iSCSI LUN + 2 async AG replicas = 4 VMs on the 02-sqlserver tier, with
  3 WSFC-managed VIPs: cluster .15, FCI .16, Listener .17). All 4 nodes
  use the dedicated oltp-sqlserver-node Packer template (Windows Server
  2025 Desktop + SQL Server 2025 Developer Edition + Failover-Clustering
  + MPIO features + built-in msiscsi initiator).

  Pre-flight (from outside this wrapper):
    1. nexus-infra-vmware foundation env applied at v6 (dnsmasq dhcp-host
       reservations for the 4 sqlserver MACs at .11-.14 + iSCSI target
       on nexus-gateway exporting sql-fci.lun1 to FCI pair).
    2. nexus-infra-vmware security env applied (PKI role sqlserver-server
       + 4 AppRoles + 5 KV sticky-seeds at nexus/oltp/sqlserver/* +
       gmsa-sql-engine$ GMSA + nexus-sql-cluster-members AD group +
       sidecars at $HOME/.nexus/vault-agent-oltp-sqlserver-<host>.json).
    3. packer build packer/oltp-sqlserver-node/
       (output: H:\VMS\NexusPlatform\_templates\oltp-sqlserver-node\
       oltp-sqlserver-node.vmx -- clones from ws2025-desktop.vmx + adds
       SQL 2025 + cluster features + firstboot pre-staging; ~40 min).

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/oltp-sqlserver
  destroy  -- terraform destroy -auto-approve
  smoke    -- run scripts/smoke-0.G.7.ps1 (WSFC + FCI + AG + Listener gate)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Use for
  selective per-VM or per-stage iteration, e.g.:
    -Vars enable_sql_ag_rep_2=false   # bring up FCI pair + 1 AG rep only
    -Vars enable_ag_listener=false    # skip Listener (apps hit FCI VIP)

  NOTE per feedback_terraform_partial_apply_destroys_resources.md: every
  -Vars invocation is the FULL override set. Vars not passed default
  back (true), and `count = var.X ? 1 : 0` resources get DESTROYED on
  omission. Defaults reflect steady state -- omit -Vars when you mean
  "all 4 nodes + all stages enabled".

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.G.7.ps1.

.EXAMPLE
  pwsh -File scripts\oltp-sqlserver.ps1 cycle

.EXAMPLE
  # iterate just the AG bootstrap (assumes FCI install + nodes joined)
  pwsh -File scripts\oltp-sqlserver.ps1 apply -Vars enable_nftables_backplane=false,enable_sqlserver_domain_join=false,enable_sqlserver_vault_agents=false,enable_sqlserver_tls=false,enable_iscsi_attach=false,enable_wsfc_bootstrap=false,enable_fci_install=false,enable_ag_listener=false

.EXAMPLE
  # FCI install only (skip AG bootstrap + Listener -- useful for FCI-side debug)
  pwsh -File scripts\oltp-sqlserver.ps1 apply -Vars enable_ag_bootstrap=false,enable_ag_listener=false

.NOTES
  Sibling wrappers: scripts\oltp-redis.ps1, scripts\oltp-mongo.ps1,
  scripts\oltp-percona.ps1, scripts\oltp-patroni.ps1. See docs/handbook.md
  s1.2 for the cross-env operator order. 0.G.7 is the LAST OLTP sub-phase
  -- closes the OLTP tier (5/5 clusters).
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
$envDir    = Join-Path $repoRoot 'terraform\envs\oltp-sqlserver'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.G.7.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[oltp-sqlserver] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
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
    Write-Step 'terraform apply -auto-approve  (envs/oltp-sqlserver)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/oltp-sqlserver)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.G.7.ps1  (WSFC + FCI + AG + Listener gate)'
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/oltp-sqlserver)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/oltp-sqlserver)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/oltp-sqlserver)'
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
Write-Host "oltp-sqlserver $Verb complete" -ForegroundColor Green
