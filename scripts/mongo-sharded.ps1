#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.N operator wrapper for the oltp-mongo-sharded env.

.DESCRIPTION
  pwsh-native equivalent of `make` targets. Drives
  terraform/envs/oltp-mongo-sharded/ with apply/destroy/cycle/smoke/plan/validate.

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate

.PARAMETER Vars
  Forwarded -var pairs (comma- or array-separated).

.EXAMPLE
  pwsh -File scripts\mongo-sharded.ps1 apply
  pwsh -File scripts\mongo-sharded.ps1 cycle
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,
    [string[]]$Vars = @()
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\oltp-mongo-sharded'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.N.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
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
    Write-Step 'terraform apply -auto-approve'
    $argv = @('apply', '-auto-approve')
    $argv += (Get-VarFlags)
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath)"
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan'
    $argv = @('plan')
    $argv += (Get-VarFlags)
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate'
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
Write-Host "oltp-mongo-sharded $Verb complete" -ForegroundColor Green
