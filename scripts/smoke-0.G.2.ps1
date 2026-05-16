#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.G.2 smoke gate -- MongoDB Replica Set mutual TLS + keyFile.

.DESCRIPTION
  Verifies the 0.G.2 exit gate: the 3-member MongoDB Replica Set
  (nexus-rs) runs on mutual TLS -- per-node Vault PKI leaf certs,
  tls-auth-clients required, shared keyFile internal auth between RS
  members -- and forms a healthy RS with 1 PRIMARY + 2 SECONDARY +
  replication round-trip.

  Re-runs the protocol-agnostic checks (reachability, firstboot, identity,
  vault-agent, service-active) plus the 0.G.2-specific TLS material +
  TLS listener + RS-health checks.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality) to tolerate sudo's "unable
  to resolve host" stderr noise. Each check echoes [OK]/[FAIL]; exits 1
  on any FAIL, 0 on all-green.

  Ordered cheapest-first: reachability -> firstboot -> identity ->
  vault-agent -> TLS material + keyFile -> mongod.conf -> nexus-mongo.
  service -> TLS listener -> RS health + write/read round-trip.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the build host's ssh-agent +
  the canonical lab SSH key. mongosh is run on each node via sudo (TLS
  material is 0640 root:mongodb) pointing --tlsCertificateKeyFile at
  the node's own server.pem.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: mongo).
$nodeIps = @(
    '192.168.70.71', '192.168.70.72', '192.168.70.73'
)
$bootstrapIp = $nodeIps[0]   # mongo-1

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$tlsArgs = '--tls --tlsCAFile /etc/nexus-mongo/tls/ca.crt --tlsCertificateKeyFile /etc/nexus-mongo/tls/server.pem'

# Cluster-status commands like rs.status() require auth in 8.0+keyFile
# replica sets. The localhost-exception is disabled. We auth as __system
# via SCRAM-SHA-256 with the keyFile content as the password -- the
# pragmatic cluster-admin bootstrap path (per 0.G.2 ratification lesson;
# see handbook §3.x). Read the keyFile once + reuse for all status calls.
$keyfile = ($null)
function Get-SystemAuthArgs {
    if ($null -eq $script:keyfile) {
        $script:keyfile = (ssh @sshOpts "$user@$bootstrapIp" 'sudo cat /etc/nexus-mongo/keyfile' 2>&1 | Out-String).Trim()
    }
    return "--username __system --password '$script:keyfile' --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256"
}

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    try {
        $result = & $Probe
        if ($result) {
            Write-Host "[OK]   $Description" -ForegroundColor Green
            return $true
        } else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            $script:failures += $Description
            return $false
        }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"
        return $false
    }
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Command
    )
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# ─── Section 1: per-node SSH reachability ─────────────────────────────────
Write-Section 'Per-node SSH reachability'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker'
        $out -match 'nexus-smoke-marker'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping later sections." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot completion ──────────────────────────────────────
Write-Section 'oltp-node firstboot completion'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : /var/lib/oltp-node-firstboot-done present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/oltp-node-firstboot-done && echo done'
        $out -match 'done'
    } | Out-Null
}

# ─── Section 3: hostname + node-identity mapping ──────────────────────────
Write-Section 'Hostname + node-identity mapping (canonical IPs -> identity)'
$expected = @{
    '192.168.70.71' = @{ host = 'mongo-1' }
    '192.168.70.72' = @{ host = 'mongo-2' }
    '192.168.70.73' = @{ host = 'mongo-3' }
}
foreach ($ip in $nodeIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($e.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env role=mongo cluster=mongo (under /etc/nexus-mongo/, not /etc/nexus-redis/)" -Probe {
        # IDENTITY_DIR per-cluster bug fixed at 0.G.2: mongo nodes write
        # their identity env to /etc/nexus-mongo/node-identity.env (NOT
        # /etc/nexus-redis/ which was the latent bug from 0.G.1).
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-mongo/node-identity.env 2>&1'
        ($out -match 'NEXUS_ROLE=mongo') -and ($out -match 'NEXUS_CLUSTER=mongo') -and ($out -match "NEXUS_HOSTNAME=$($e.host)")
    } | Out-Null
}

# ─── Section 4: nexus-vault-agent.service ─────────────────────────────────
Write-Section 'nexus-vault-agent.service active + AppRole token sink populated'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : Vault Agent token sink populated (AppRole auth OK)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT'
        $out -match 'TOKEN_PRESENT'
    } | Out-Null
}

# ─── Section 5: mTLS cert material + keyFile ──────────────────────────────
Write-Section 'PKI cert material rendered (server.pem combined + ca.crt + keyfile + CN)'
foreach ($ip in $nodeIps) {
    $e = $expected[$ip]
    $cn = "$($e.host).mongo.nexus.lab"
    Test-Check -Description "$ip : /etc/nexus-mongo/tls/server.pem present (combined leaf+key)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-mongo/tls/server.pem && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-mongo/tls/ca.crt present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-mongo/tls/ca.crt && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-mongo/keyfile present (RS internal auth)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-mongo/keyfile && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : leaf cert CN == $cn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-mongo/tls/server.pem -noout -subject 2>/dev/null'
        $out -match [regex]::Escape($cn)
    } | Out-Null
    Test-Check -Description "$ip : server.pem is combined (1 CERTIFICATE + 1 PRIVATE KEY block, NOT split)" -Probe {
        # mongod's --tlsCertificateKeyFile requires ONE PEM file with both
        # the leaf and the key concatenated. server.pem must contain BOTH.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -c "BEGIN CERTIFICATE\|BEGIN PRIVATE KEY" /etc/nexus-mongo/tls/server.pem'
        $out -match '^2$'
    } | Out-Null
    Test-Check -Description "$ip : ca.crt has both intermediate AND root (2 CERTIFICATE blocks)" -Probe {
        # Same OpenSSL strict-verify lesson as 0.G.1: ca.crt must walk to a
        # self-signed root anchor; intermediate alone fails.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -c "BEGIN CERTIFICATE" /etc/nexus-mongo/tls/ca.crt'
        $out -match '^2$'
    } | Out-Null
    Test-Check -Description "$ip : keyfile permissions == 0400 mongodb:mongodb" -Probe {
        # mongod refuses to start if the keyFile is too permissive.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo stat -c "%a %U %G" /etc/nexus-mongo/keyfile'
        $out -match '^400 mongodb mongodb$'
    } | Out-Null
}

# ─── Section 6: mongod.conf is mTLS + RS + keyFile ────────────────────────
Write-Section 'mongod.conf is mTLS + replication.replSetName=nexus-rs + security.keyFile'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : net.tls.mode == requireTLS" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^\s*mode:\s*' /etc/nexus-mongo/mongod.conf"
        $out -match 'mode:\s*requireTLS'
    } | Out-Null
    Test-Check -Description "$ip : net.tls.allowConnectionsWithoutCertificates == false (mTLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^\s*allowConnectionsWithoutCertificates:\s*' /etc/nexus-mongo/mongod.conf"
        $out -match 'allowConnectionsWithoutCertificates:\s*false'
    } | Out-Null
    Test-Check -Description "$ip : replication.replSetName == nexus-rs" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^\s*replSetName:\s*' /etc/nexus-mongo/mongod.conf"
        $out -match 'replSetName:\s*nexus-rs'
    } | Out-Null
    Test-Check -Description "$ip : security.keyFile == /etc/nexus-mongo/keyfile" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^\s*keyFile:\s*' /etc/nexus-mongo/mongod.conf"
        $out -match 'keyFile:\s*/etc/nexus-mongo/keyfile'
    } | Out-Null
    Test-Check -Description "$ip : security.authorization == enabled" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^\s*authorization:\s*' /etc/nexus-mongo/mongod.conf"
        $out -match 'authorization:\s*enabled'
    } | Out-Null
}

# ─── Section 7: nexus-mongo.service state ─────────────────────────────────
Write-Section 'nexus-mongo.service active on every node'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : nexus-mongo.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-mongo.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : apt-shipped mongod.service is masked (no port-27017 race)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-enabled mongod.service 2>&1 || true'
        $out -match '^masked$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-RS check(s) failed; skipping RS-health probes." -ForegroundColor Red
    exit 1
}

# ─── Section 8: TLS listener on :27017 presents a cert ────────────────────
Write-Section 'TLS listener on :27017 presents a server certificate'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : openssl s_client handshake against localhost:27017 yields a cert" -Probe {
        # tls.allowConnectionsWithoutCertificates=false means the handshake
        # ultimately fails without a client cert, but the server still
        # presents its certificate first -- enough to prove :27017 speaks
        # TLS, not PLAINTEXT.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo | timeout 10 openssl s_client -connect localhost:27017 2>&1'
        $out -match 'BEGIN CERTIFICATE'
    } | Out-Null
}

# ─── Section 9: RS health + write/read round-trip (0.G.2 exit gate) ───────
Write-Section 'RS health + write/read round-trip (0.G.2 exit gate)'

# Single eval that emits a 4-line summary. Auth as __system (rs.status
# requires replSetGetStatus privilege which only clusterAdmin / __system
# has -- smoke-rw is too narrow).
$sysAuth = Get-SystemAuthArgs
$statusEval = "var s=rs.status(); var p=0,sec=0,h=0; s.members.forEach(function(m){if(m.stateStr=='PRIMARY')p++; if(m.stateStr=='SECONDARY')sec++; if(m.health==1)h++}); print('PRIMARY='+p); print('SECONDARY='+sec); print('HEALTH='+h); print('MEMBERS='+s.members.length)"
$rsStatus = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo mongosh --quiet $tlsArgs $sysAuth --host 127.0.0.1:27017 --eval `"$statusEval`" 2>/dev/null"

# `\s*$` allows trailing CR (SSH pipes through CRLF; `$` alone in multiline
# mode matches just before `\n`, leaving `\r` unmatched). Same lesson as
# the role-overlay-mongo-rs-initiate.tf fix, surfaced at 0.G.2 first
# ratification 2026-05-17.
Test-Check -Description "rs.status() shows 1 PRIMARY" -Probe {
    $rsStatus -match '(?m)^PRIMARY=1\s*$'
} | Out-Null

Test-Check -Description "rs.status() shows 2 SECONDARY" -Probe {
    $rsStatus -match '(?m)^SECONDARY=2\s*$'
} | Out-Null

Test-Check -Description "rs.status() shows 3 members all health:1" -Probe {
    ($rsStatus -match '(?m)^HEALTH=3\s*$') -and ($rsStatus -match '(?m)^MEMBERS=3\s*$')
} | Out-Null

Test-Check -Description "rs.status().set == 'nexus-rs' (replica set name canonical)" -Probe {
    $sysAuth = Get-SystemAuthArgs
    $setEval = "print(rs.status().set)"
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo mongosh --quiet $tlsArgs $sysAuth --host 127.0.0.1:27017 --eval `"$setEval`" 2>/dev/null"
    $out -match '^nexus-rs$'
} | Out-Null

Test-Check -Description "write/read round-trip: insert on PRIMARY -> read on SECONDARY via readPreference=secondary + readConcern=majority (auth as smoke-rw)" -Probe {
    # Read the smoke-rw password from mongo-1 (same value rendered on all 3
    # nodes from KV nexus/oltp/mongo/smoke-user-password). 0400 root:mongodb
    # so sudo required.
    $smokePwd = Invoke-RemoteCommand -Ip $bootstrapIp -Command 'sudo cat /etc/nexus-mongo/smoke-user-password'
    if (-not $smokePwd -or $smokePwd.Length -lt 16) { return $false }
    $authArgs = "--username smoke-rw --password '$smokePwd' --authenticationDatabase admin"

    $token  = "smoke-0G2-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    # Write URI: routes to PRIMARY automatically (RS topology + default
    # readPreference=primary). `--host 127.0.0.1` alone would write to the
    # local mongod which may NOT be PRIMARY at this moment, causing "not
    # primary" errors after RS re-elections.
    $writeRsUri = "mongodb://$($nodeIps -join ':27017,'):27017/nexus_smoke?replicaSet=nexus-rs"
    $writeEval = "db.smoke_test.insertOne({_id:'smoke-key',token:'$token'}); print('WROTE')"
    $writeOut = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo mongosh --quiet $tlsArgs $authArgs '$writeRsUri' --eval `"$writeEval`" 2>&1"
    # Idempotent re-run: if smoke-key already exists from a prior smoke run,
    # insertOne errors with DuplicateKey -> updateOne refreshes the token.
    if ($writeOut -notmatch 'WROTE') {
        # MongoDB 8.0 mongosh emits "E11000 duplicate key error" on
        # duplicate key (not "DuplicateKey" -- that's the codeName, not the
        # message text).
        if ($writeOut -match 'E11000|duplicate key') {
            $updateEval = "db.smoke_test.updateOne({_id:'smoke-key'},{\`$set:{token:'$token'}}); print('UPDATED')"
            $writeOut = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo mongosh --quiet $tlsArgs $authArgs '$writeRsUri' --eval `"$updateEval`" 2>&1"
            if ($writeOut -notmatch 'UPDATED') { return $false }
        } else {
            return $false
        }
    }
    # Read from a SECONDARY via the RS connection string + same auth.
    $rsUri = "mongodb://$($nodeIps -join ':27017,'):27017/nexus_smoke?replicaSet=nexus-rs&readPreference=secondary&readConcernLevel=majority"
    $readEval = "var d=db.smoke_test.findOne({_id:'smoke-key'},{token:1,_id:0}); print('READ='+(d?d.token:'null'))"
    # Retry up to 10x with 2s between for replication catch-up.
    for ($i = 1; $i -le 10; $i++) {
        $readOut = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo mongosh --quiet $tlsArgs $authArgs '$rsUri' --eval `"$readEval`" 2>&1"
        if ($readOut -match "READ=$([regex]::Escape($token))") { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.G.2 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: 3-member MongoDB Replica Set 'nexus-rs' runs on mutual TLS --" -ForegroundColor Green
    Write-Host "per-node Vault PKI leaf certs, tls.allowConnectionsWithoutCertificates=false," -ForegroundColor Green
    Write-Host "shared keyFile internal auth, 1 PRIMARY + 2 SECONDARY all healthy, replicated" -ForegroundColor Green
    Write-Host "write/read round-trip verified via readConcern=majority." -ForegroundColor Green
    if ($warnings.Count -gt 0 -and $Strict) {
        Write-Host "Warnings (Strict mode): $($warnings.Count)" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        exit 1
    }
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
