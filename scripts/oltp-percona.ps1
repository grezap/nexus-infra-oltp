#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster oltp-percona env -- Phase 0.G.3.5b.

.DESCRIPTION
  Per-cluster split of the legacy scripts/oltp.ps1. Drives terraform/envs/
  oltp-percona/ (3 Percona XtraDB Cluster nodes + 2 ProxySQL LB nodes +
  VRRP-floated VIP at 192.168.70.50). PXC uses the dedicated oltp-pxc-node
  Packer template (12 transient fixes baked); ProxySQL uses oltp-proxysql-node.
  Iteration loop is ~10 min vs ~30 min for the legacy monolithic envs/oltp/
  tree -- per memory/feedback_per_cluster_state_per_engine_template.md.

  Pre-flight (from outside this wrapper):
    1. nexus-infra-vmware foundation env applied (dnsmasq dhcp-host
       reservations for the 5 percona-tier MACs at .51-.55).
    2. nexus-infra-vmware security env applied (per-host AppRoles + KV
       sticky-seeds + sidecars at $HOME\.nexus\vault-agent-oltp-percona-<host>.json
       + PKI role percona-server).
    3. packer build packer/oltp-pxc-node/ + packer build packer/oltp-proxysql-node/
       (outputs:
       H:\VMS\NexusPlatform\_templates\oltp-pxc-node\oltp-pxc-node.vmx,
       H:\VMS\NexusPlatform\_templates\oltp-proxysql-node\oltp-proxysql-node.vmx).

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/oltp-percona
  destroy  -- terraform destroy -auto-approve
  smoke    -- run scripts/smoke-0.G.3.ps1 (PXC + ProxySQL + VRRP gate)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Use
  for selective per-VM bring-up, e.g.:
    -Vars enable_pxc_node_1=true,enable_pxc_node_2=true,enable_pxc_node_3=false,enable_proxysql_1=true,enable_proxysql_2=false

  NOTE per feedback_terraform_partial_apply_destroys_resources.md: every
  -Vars invocation is the FULL override set for that apply. Vars not
  passed default back (true), and `count = var.X ? 1 : 0` resources get
  DESTROYED on omission. Defaults reflect steady state -- omit -Vars when
  you mean "all 5 nodes enabled".

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.G.3.ps1.

.EXAMPLE
  pwsh -File scripts\oltp-percona.ps1 cycle

.EXAMPLE
  # iterate the Galera bootstrap one-shot only (assumes 3 PXC nodes + 2 ProxySQL already cloned + TLS + my.cnf rendered)
  pwsh -File scripts\oltp-percona.ps1 apply -Vars enable_galera_cluster_bootstrap=true

.EXAMPLE
  # bring up PXC only (no ProxySQL yet -- useful for first-bootstrap iteration)
  pwsh -File scripts\oltp-percona.ps1 apply -Vars enable_proxysql_1=false,enable_proxysql_2=false,enable_proxysql_config=false,enable_keepalived_vip=false

.NOTES
  Sibling wrappers: scripts\oltp-redis.ps1, scripts\oltp-mongo.ps1.
  See docs/handbook.md s1.2 for the cross-env operator order.
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
$envDir    = Join-Path $repoRoot 'terraform\envs\oltp-percona'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.G.3.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[oltp-percona] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
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
    Write-Step 'terraform apply -auto-approve  (envs/oltp-percona)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/oltp-percona)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.G.3.ps1  (PXC + ProxySQL + VRRP gate)'
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/oltp-percona)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/oltp-percona)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/oltp-percona)'
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
Write-Host "oltp-percona $Verb complete" -ForegroundColor Green
