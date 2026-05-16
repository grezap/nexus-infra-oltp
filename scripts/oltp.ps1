#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the oltp env -- pwsh-native equivalent of the
  bash-shaped Makefile targets.

.DESCRIPTION
  Mirrors nexus-infra-kafka/scripts/kafka.ps1 (per
  memory/feedback_build_host_pwsh_native.md -- GNU make is not installed
  on the build host; pwsh wrappers are canonical). apply/destroy/smoke/
  cycle/plan/validate verbs against terraform/envs/oltp/ + delegates
  smoke to scripts/smoke-0.G.<N>.ps1.

  Pre-flight dependency: nexus-gateway must have the OLTP dnsmasq
  dhcp-host reservations active (managed in nexus-infra-vmware's
  foundation env via role-overlay-gateway-oltp-reservations.tf, lands
  in Phase 0.G.1). This wrapper does NOT check or apply those
  reservations -- foundation ownership stays separate.

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/oltp
  destroy  -- terraform destroy -auto-approve
  smoke    -- run the active phase smoke gate (default 0.G.1 == Redis)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Phase
  Which smoke phase to run. '0.G.1' (Redis Cluster) is the first active
  phase; later sub-phases add their own gates (0.G.2 Mongo · 0.G.3
  Percona · 0.G.4 Patroni · 0.G.7 SQL FCI/AG). '0.G.5' + '0.G.6' belong
  to the sibling nexus-infra-analytics repo (ClickHouse + StarRocks).

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags. Use
  for selective bring-up per docs/handbook.md s1.5, e.g.:
    -Vars enable_mongo=false,enable_percona=false

  NOTE per feedback_terraform_partial_apply_destroys_resources.md: every
  -Vars invocation is the FULL override set for that apply. Vars not
  passed default back, and `count = var.X ? 1 : 0` resources get
  DESTROYED. Defaults reflect steady state -- omit -Vars when you mean
  "everything enabled".

.PARAMETER SmokeArgs
  Hashtable forwarded to the smoke script.

.EXAMPLE
  pwsh -File scripts\oltp.ps1 cycle

.EXAMPLE
  # bring up only Redis Cluster (skip Mongo + Percona + Patroni + SQL)
  pwsh -File scripts\oltp.ps1 apply -Vars enable_mongo=false,enable_percona=false,enable_patroni=false,enable_sql=false

.EXAMPLE
  # iterate on the Redis cluster create step (assumes nodes already cloned)
  pwsh -File scripts\oltp.ps1 apply -Vars enable_redis_cluster_create=true

.NOTES
  See scripts/smoke-0.G.<N>.ps1 for the underlying check definitions
  (smoke scripts land per sub-phase). See nexus-infra-kafka/scripts/
  kafka.ps1 for the same shape.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [ValidateSet('0.G.1', '0.G.2', '0.G.3', '0.G.4', '0.G.7')]
    [string]$Phase = '0.G.1',

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\oltp'
$smokePath = Join-Path $repoRoot ("scripts\smoke-{0}.ps1" -f $Phase)

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    # The terraform env needs `terraform init` once per checkout (downloads
    # the null provider + materialises modules/vm). The presence of the
    # .terraform/ dir is the canonical "init was done" marker -- this also
    # cleanly handles a fresh clone of the repo where .terraform/ is
    # gitignored. Idempotent: re-running terraform init on an already-init
    # env is a no-op-fast.
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[oltp] .terraform/ missing -- running `terraform init`..." -ForegroundColor Yellow
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
    # Accept both PS array form and comma-joined-string form (pwsh -File
    # doesn't tokenize commas like interactive PS does).
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
    Write-Step 'terraform apply -auto-approve'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath) (phase $Phase)"
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found for phase $Phase`: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate'
    Invoke-Terraform @('validate')
}

# --- Dispatch -----------------------------------------------------------
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
Write-Host "oltp $Verb complete" -ForegroundColor Green
