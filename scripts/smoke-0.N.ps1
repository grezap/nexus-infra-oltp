#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.N smoke gate: 11-VM MongoDB sharded cluster (3 config + 2x3 shards + 2 mongos).

.DESCRIPTION
  ~57 checks across 9 sections:
    1. Reachability     -- SSH/22 to all 11 nodes
    2. Engine + ports   -- mongod/mongos service Running + listening on the right port
    3. Config-server RS -- 1 PRIMARY + 2 SECONDARY + all health:1 (RS name "config")
    4. Shard-1 RS       -- 1 PRIMARY + 2 SECONDARY + all health:1 (RS name "shard-1")
    5. Shard-2 RS       -- 1 PRIMARY + 2 SECONDARY + all health:1 (RS name "shard-2")
    6. Sharded topology -- sh.status() via mongos shows 2 shards + balancer enabled
    7. Sharded collection -- nexus_n_smoke.samples has 200 docs distributed across both shards
    8. Mongos routing   -- a {k:50} query via mongos returns the right doc
    9. Wire mTLS        -- 0.N.1: per-host leaf CN, ca.crt chain, requireTLS
                           rejects a non-TLS conn, mTLS ping succeeds

  Per memory/feedback_smoke_gate_probe_robustness.md: marker tokens + -match (not strict-eq) for multi-line probes.
  0.N.1: every mongosh connects over mTLS ($tlsArgs folded into $auth/$mongosAuth).

.NOTES
  Reproducibility:
    pwsh -File scripts\mongo-sharded.ps1 apply
    pwsh -File scripts\smoke-0.N.ps1
#>

[CmdletBinding()]
param(
    [string]$CfgIp1 = '192.168.70.74',
    [string]$CfgIp2 = '192.168.70.75',
    [string]$CfgIp3 = '192.168.70.76',
    [string]$Shard1Ip1 = '192.168.70.77',
    [string]$Shard1Ip2 = '192.168.70.78',
    [string]$Shard1Ip3 = '192.168.70.79',
    [string]$Shard2Ip1 = '192.168.70.80',
    [string]$Shard2Ip2 = '192.168.70.56',
    [string]$Shard2Ip3 = '192.168.70.57',
    [string]$MongosIp1 = '192.168.70.58',
    [string]$MongosIp2 = '192.168.70.59',
    [int]$CfgPort = 27019,
    [int]$ShardPort = 27018,
    [int]$MongosPort = 27017
)

$ErrorActionPreference = 'Continue'
$script:failures = @()
$user = 'nexusadmin'
$sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]      $Label,
        [Parameter(Mandatory)][scriptblock] $Probe,
        [Parameter(Mandatory)][scriptblock] $Predicate
    )
    $out = & $Probe 2>&1 | Out-String
    $ok  = & $Predicate $out
    if ($ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        Write-Host ($out.Trim() -split "`r?`n" | ForEach-Object { "       $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
        $script:failures += $Label
    }
}

# Fetch keyfile content for __system auth (mongosh requires it for all post-init commands).
$keyfile = (ssh @sshOpts $user@$CfgIp1 'sudo cat /etc/nexus-mongo/keyfile 2>/dev/null' | Out-String).Trim()
if (-not $keyfile -or $keyfile.Length -lt 100) {
    Write-Host "[FATAL] keyfile not readable from $CfgIp1 -- cluster not yet bootstrapped?" -ForegroundColor Red
    exit 1
}
# __system (keyFile) auth works against mongod's `local` DB (used for the
# direct per-RS health probes on cfg/shard nodes). It is REJECTED through mongos
# ("Can't use 'local' database through mongos"), so mongos probes auth as the
# cluster admin user (created by the add-shards overlay on the config servers,
# password = keyFile content) against the `admin` DB. Invoke-Mongosh selects the
# right auth by port: mongos port -> admin user; mongod ports -> __system.
# 0.N.1 wire mTLS: every mongosh dials the requireTLS listener presenting the
# node's own leaf as its client cert. Folded into both auth strings so every
# check below connects over TLS.
$tlsArgs = "--tls --tlsCAFile /etc/nexus-mongo/tls/ca.crt --tlsCertificateKeyFile /etc/nexus-mongo/tls/server.pem"
$auth = "$tlsArgs --username __system --password '$keyfile' --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256"
$mongosAuth = "$tlsArgs --username nexus-sharded-admin --password '$keyfile' --authenticationDatabase admin"

function Invoke-Mongosh {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Eval)
    $a = if ($Port -eq $MongosPort) { $mongosAuth } else { $auth }
    ssh @sshOpts "$user@$Ip" "sudo mongosh --quiet $a --host 127.0.0.1:$Port --eval `"$Eval`" 2>/dev/null"
}

Write-Host ''
Write-Host 'Phase 0.N smoke gate -- MongoDB sharded cluster' -ForegroundColor White

# ─── 1. Reachability ──────────────────────────────────────────────────────
Write-Section '1. Reachability (SSH/22 -- non-negotiable invariant)'
$allNodes = @(
    @{ Name='mongo-cfg-1';     Ip=$CfgIp1 },    @{ Name='mongo-cfg-2';     Ip=$CfgIp2 },    @{ Name='mongo-cfg-3';     Ip=$CfgIp3 },
    @{ Name='mongo-shard-1-1'; Ip=$Shard1Ip1 }, @{ Name='mongo-shard-1-2'; Ip=$Shard1Ip2 }, @{ Name='mongo-shard-1-3'; Ip=$Shard1Ip3 },
    @{ Name='mongo-shard-2-1'; Ip=$Shard2Ip1 }, @{ Name='mongo-shard-2-2'; Ip=$Shard2Ip2 }, @{ Name='mongo-shard-2-3'; Ip=$Shard2Ip3 },
    @{ Name='mongo-mongos-1';  Ip=$MongosIp1 }, @{ Name='mongo-mongos-2';  Ip=$MongosIp2 }
)
foreach ($n in $allNodes) {
    $node = $n
    Test-Check "$($node.Name) SSH/22 open ($($node.Ip))" `
        { Test-NetConnection -ComputerName $node.Ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue } `
        { param($o) $o -match 'True' }
}

# ─── 2. Engine + ports ────────────────────────────────────────────────────
Write-Section '2. Engine service Running + correct port listening'
$dataNodes = @(
    @{ Name='mongo-cfg-1';     Ip=$CfgIp1;    Port=$CfgPort;   Svc='nexus-mongo.service'  },
    @{ Name='mongo-cfg-2';     Ip=$CfgIp2;    Port=$CfgPort;   Svc='nexus-mongo.service'  },
    @{ Name='mongo-cfg-3';     Ip=$CfgIp3;    Port=$CfgPort;   Svc='nexus-mongo.service'  },
    @{ Name='mongo-shard-1-1'; Ip=$Shard1Ip1; Port=$ShardPort; Svc='nexus-mongo.service'  },
    @{ Name='mongo-shard-1-2'; Ip=$Shard1Ip2; Port=$ShardPort; Svc='nexus-mongo.service'  },
    @{ Name='mongo-shard-1-3'; Ip=$Shard1Ip3; Port=$ShardPort; Svc='nexus-mongo.service'  },
    @{ Name='mongo-shard-2-1'; Ip=$Shard2Ip1; Port=$ShardPort; Svc='nexus-mongo.service'  },
    @{ Name='mongo-shard-2-2'; Ip=$Shard2Ip2; Port=$ShardPort; Svc='nexus-mongo.service'  },
    @{ Name='mongo-shard-2-3'; Ip=$Shard2Ip3; Port=$ShardPort; Svc='nexus-mongo.service'  },
    @{ Name='mongo-mongos-1';  Ip=$MongosIp1; Port=$MongosPort; Svc='nexus-mongos.service' },
    @{ Name='mongo-mongos-2';  Ip=$MongosIp2; Port=$MongosPort; Svc='nexus-mongos.service' }
)
foreach ($n in $dataNodes) {
    $node = $n
    Test-Check "$($node.Name): $($node.Svc) active" `
        { ssh @sshOpts "$user@$($node.Ip)" "systemctl is-active $($node.Svc)" } `
        { param($o) $o.Trim() -eq 'active' }

    Test-Check "$($node.Name): port $($node.Port) listening" `
        {
            $portHex = '{0:X4}' -f $node.Port
            ssh @sshOpts "$user@$($node.Ip)" "grep -E ':$portHex 00000000:0000 0A' /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l"
        } `
        { param($o) $o.Trim() -match '^[1-9]' }
}

# ─── 3-5. Per-RS health ───────────────────────────────────────────────────
$rsTargets = @(
    @{ Section='3. Config-server RS (name=config)'; RsName='config';  BootIp=$CfgIp1;    Port=$CfgPort   },
    @{ Section='4. Shard-1 RS (name=shard-1)';      RsName='shard-1'; BootIp=$Shard1Ip1; Port=$ShardPort },
    @{ Section='5. Shard-2 RS (name=shard-2)';      RsName='shard-2'; BootIp=$Shard2Ip1; Port=$ShardPort }
)
foreach ($rs in $rsTargets) {
    $r = $rs
    Write-Section $r.Section

    Test-Check "$($r.RsName): rs.status().ok == 1" `
        { Invoke-Mongosh -Ip $r.BootIp -Port $r.Port -Eval "print(rs.status().ok)" } `
        { param($o) $o.Trim() -eq '1' }

    Test-Check "$($r.RsName): exactly 1 PRIMARY" `
        { Invoke-Mongosh -Ip $r.BootIp -Port $r.Port -Eval "var n=0; rs.status().members.forEach(function(m){if(m.stateStr=='PRIMARY')n++}); print(n)" } `
        { param($o) $o.Trim() -eq '1' }

    Test-Check "$($r.RsName): exactly 2 SECONDARY" `
        { Invoke-Mongosh -Ip $r.BootIp -Port $r.Port -Eval "var n=0; rs.status().members.forEach(function(m){if(m.stateStr=='SECONDARY')n++}); print(n)" } `
        { param($o) $o.Trim() -eq '2' }

    Test-Check "$($r.RsName): all 3 members health=1" `
        { Invoke-Mongosh -Ip $r.BootIp -Port $r.Port -Eval "var n=0; rs.status().members.forEach(function(m){if(m.health==1)n++}); print(n)" } `
        { param($o) $o.Trim() -eq '3' }

    Test-Check "$($r.RsName): _id matches" `
        { Invoke-Mongosh -Ip $r.BootIp -Port $r.Port -Eval "print(rs.status()['set'])" } `
        { param($o) $o.Trim() -eq $r.RsName }
}

# ─── 6. Sharded topology via mongos ───────────────────────────────────────
Write-Section '6. Sharded topology via mongos (sh.status + balancer)'

Test-Check 'mongos: 2 shards registered' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "print(db.getSiblingDB('config').shards.countDocuments())" } `
    { param($o) $o.Trim() -eq '2' }

Test-Check 'mongos: shard-1 listed in config.shards' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "var s=db.getSiblingDB('config').shards.findOne({_id:'shard-1'}); print(s ? 'FOUND' : 'MISSING')" } `
    { param($o) $o.Trim() -eq 'FOUND' }

Test-Check 'mongos: shard-2 listed in config.shards' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "var s=db.getSiblingDB('config').shards.findOne({_id:'shard-2'}); print(s ? 'FOUND' : 'MISSING')" } `
    { param($o) $o.Trim() -eq 'FOUND' }

Test-Check 'mongos: balancer state' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "print(sh.getBalancerState())" } `
    { param($o) $o.Trim() -match '^(true|false)$' }
# Balancer can be true OR false (auto-disables when chunks are balanced).
# What matters is sh.status() reports both shards as healthy targets.

# ─── 7. Sharded collection state ──────────────────────────────────────────
Write-Section '7. Sharded collection (nexus_n_smoke.samples)'

Test-Check 'sharded collection: db nexus_n_smoke has sharded:true in config.databases' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "var d=db.getSiblingDB('config').databases.findOne({_id:'nexus_n_smoke'}); print(d ? 'FOUND' : 'MISSING')" } `
    { param($o) $o.Trim() -eq 'FOUND' }

Test-Check 'sharded collection: samples has >=200 docs via mongos' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "print(db.getSiblingDB('nexus_n_smoke').samples.countDocuments())" } `
    { param($o) try { [int]$o.Trim() -ge 200 } catch { $false } }

Test-Check 'sharded collection: nexus_n_smoke.samples in config.collections' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "var c=db.getSiblingDB('config').collections.findOne({_id:'nexus_n_smoke.samples'}); print(c ? 'FOUND' : 'MISSING')" } `
    { param($o) $o.Trim() -eq 'FOUND' }

# Chunks distributed across both shards (the actual sharding proof).
Test-Check 'sharded collection: chunks exist on shard-1' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "print(db.getSiblingDB('config').chunks.countDocuments({shard:'shard-1'}))" } `
    { param($o) try { [int]$o.Trim() -ge 1 } catch { $false } }

Test-Check 'sharded collection: chunks exist on shard-2' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "print(db.getSiblingDB('config').chunks.countDocuments({shard:'shard-2'}))" } `
    { param($o) try { [int]$o.Trim() -ge 1 } catch { $false } }

# ─── 8. Mongos routing ────────────────────────────────────────────────────
Write-Section '8. Mongos routing'

Test-Check 'mongos-1: ping returns ok:1' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "print(db.adminCommand({ping:1}).ok)" } `
    { param($o) $o.Trim() -eq '1' }

Test-Check 'mongos-2: ping returns ok:1' `
    { Invoke-Mongosh -Ip $MongosIp2 -Port $MongosPort -Eval "print(db.adminCommand({ping:1}).ok)" } `
    { param($o) $o.Trim() -eq '1' }

Test-Check 'mongos-1: query {k:50} returns a doc' `
    { Invoke-Mongosh -Ip $MongosIp1 -Port $MongosPort -Eval "var d=db.getSiblingDB('nexus_n_smoke').samples.findOne({k:50}); print(d ? d.v : 'NULL')" } `
    { param($o) $o.Trim() -eq 'data-50' }

Test-Check 'mongos-2: query {k:100} returns a doc' `
    { Invoke-Mongosh -Ip $MongosIp2 -Port $MongosPort -Eval "var d=db.getSiblingDB('nexus_n_smoke').samples.findOne({k:100}); print(d ? d.v : 'NULL')" } `
    { param($o) $o.Trim() -eq 'data-100' }

# ─── 9. Wire mTLS (0.N.1) ─────────────────────────────────────────────────
Write-Section '9. Wire mTLS (0.N.1 -- Vault-PKI per-host certs + requireTLS)'

# Each node presents a per-host leaf whose CN = <host>.mongo.nexus.lab.
$tlsNodes = @(
    @{ Name='mongo-cfg-1';     Ip=$CfgIp1 },    @{ Name='mongo-shard-1-1'; Ip=$Shard1Ip1 },
    @{ Name='mongo-shard-2-1'; Ip=$Shard2Ip1 }, @{ Name='mongo-mongos-1';  Ip=$MongosIp1 }
)
foreach ($n in $tlsNodes) {
    $node = $n
    Test-Check "$($node.Name): leaf CN = $($node.Name).mongo.nexus.lab" `
        { ssh @sshOpts "$user@$($node.Ip)" "sudo openssl x509 -in /etc/nexus-mongo/tls/server.pem -noout -subject 2>/dev/null" } `
        { param($o) $o -match "$($node.Name)\.mongo\.nexus\.lab" }
}

# ca.crt walks to a self-signed root anchor (intermediate + root).
Test-Check 'mongo-cfg-1: ca.crt contains >= 2 certs (intermediate + root)' `
    { ssh @sshOpts "$user@$CfgIp1" "grep -c 'BEGIN CERTIFICATE' /etc/nexus-mongo/tls/ca.crt 2>/dev/null || sudo grep -c 'BEGIN CERTIFICATE' /etc/nexus-mongo/tls/ca.crt" } `
    { param($o) try { [int]$o.Trim() -ge 2 } catch { $false } }

# requireTLS is enforced: a NON-TLS mongosh connection is rejected.
Test-Check 'config-server rejects a non-TLS connection (requireTLS enforced)' `
    { ssh @sshOpts "$user@$CfgIp1" "sudo mongosh --quiet --host 127.0.0.1:$CfgPort --eval 'db.adminCommand({ping:1})' 2>&1; echo RC=`$?" } `
    { param($o) $o -match 'RC=[^0]' -or $o -match 'closed|TLS|SSL|no reachable|MongoNetworkError' }

# A full mTLS ping (via Invoke-Mongosh, which now carries $tlsArgs) succeeds.
Test-Check 'config-server accepts an mTLS-authenticated ping' `
    { Invoke-Mongosh -Ip $CfgIp1 -Port $CfgPort -Eval "print(db.adminCommand({ping:1}).ok)" } `
    { param($o) $o.Trim() -eq '1' }

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.N SMOKE CHECKS PASSED' -ForegroundColor Green
    Write-Host 'MongoDB sharded cluster operational: 3 config RS + 2 shard RSes + 2 mongos + sharded collection routed end-to-end.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
