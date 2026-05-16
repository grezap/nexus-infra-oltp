#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.G.1 smoke gate -- Redis Cluster mutual TLS.

.DESCRIPTION
  Verifies the 0.G.1 exit gate: the 6-node Redis Cluster (3 masters + 3
  replicas via --cluster-replicas 1) runs on mutual TLS -- per-node Vault
  PKI leaf certs, tls-auth-clients yes (every client presents a cert),
  cluster bus + replication also TLS -- and forms a healthy cluster with
  full slot coverage + cross-shard routing.

  Re-runs the protocol-agnostic checks (reachability, firstboot, identity,
  vault-agent, service-active) plus the 0.G.1-specific TLS material + TLS
  listener + cluster-health checks.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality) to tolerate sudo's "unable
  to resolve host" stderr noise. Each check echoes [OK]/[FAIL]; exits 1
  on any FAIL, 0 on all-green.

  Ordered cheapest-first: reachability -> firstboot -> identity ->
  vault-agent -> TLS material -> redis.conf -> nexus-redis.service ->
  TLS listener -> cluster health + cross-shard round-trip.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the build host's ssh-agent + the
  canonical lab SSH key. redis-cli is run on each node via sudo (TLS
  material is 0640 root:redis) pointing at the self-cert as the client
  identity (the redis-server PKI role has client_flag=true).
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: redis).
# IPs match the foundation env's dhcp-host reservations + the 3c oltp env's
# module.vm blocks.
$nodeIps = @(
    '192.168.70.81', '192.168.70.82', '192.168.70.83',
    '192.168.70.84', '192.168.70.87', '192.168.70.89'
)
$bootstrapIp = $nodeIps[0]   # redis-1; an arbitrary cluster member

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

# Self-mTLS args reused across every redis-cli invocation on a node.
$tlsArgs = '--tls --cacert /etc/nexus-redis/tls/ca.crt --cert /etc/nexus-redis/tls/server.crt --key /etc/nexus-redis/tls/server.key'

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
    '192.168.70.81' = @{ host = 'redis-1' }
    '192.168.70.82' = @{ host = 'redis-2' }
    '192.168.70.83' = @{ host = 'redis-3' }
    '192.168.70.84' = @{ host = 'redis-4' }
    '192.168.70.87' = @{ host = 'redis-5' }
    '192.168.70.89' = @{ host = 'redis-6' }
}
foreach ($ip in $nodeIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($e.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env role=redis cluster=redis" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-redis/node-identity.env'
        ($out -match 'NEXUS_ROLE=redis') -and ($out -match 'NEXUS_CLUSTER=redis') -and ($out -match "NEXUS_HOSTNAME=$($e.host)")
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

# ─── Section 5: mTLS cert material ────────────────────────────────────────
Write-Section 'PKI cert material rendered (server.crt + server.key + ca.crt + CN)'
foreach ($ip in $nodeIps) {
    $e = $expected[$ip]
    $cn = "$($e.host).redis.nexus.lab"
    Test-Check -Description "$ip : /etc/nexus-redis/tls/server.crt present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-redis/tls/server.crt && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-redis/tls/server.key present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-redis/tls/server.key && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-redis/tls/ca.crt present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-redis/tls/ca.crt && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : leaf cert CN == $cn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-redis/tls/server.crt -noout -subject 2>/dev/null'
        $out -match [regex]::Escape($cn)
    } | Out-Null
    Test-Check -Description "$ip : server.key is PKCS#8 (BEGIN PRIVATE KEY, not BEGIN RSA PRIVATE KEY)" -Probe {
        # PKCS#1 keys have 'BEGIN RSA PRIVATE KEY'; PKCS#8 is 'BEGIN PRIVATE KEY'.
        # The 3c redis-tls split script converts to PKCS#8.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo head -1 /etc/nexus-redis/tls/server.key'
        $out -match '^-----BEGIN PRIVATE KEY-----$'
    } | Out-Null
}

# ─── Section 6: redis.conf is TLS-only ────────────────────────────────────
Write-Section 'redis.conf is mTLS-only (port 0 + tls-port 6379 + tls-auth-clients yes + cluster-enabled yes)'
foreach ($ip in $nodeIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : port 0 (plain port disabled)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^port\s+' /etc/nexus-redis/redis.conf"
        $out -match '^port\s+0$'
    } | Out-Null
    Test-Check -Description "$ip : tls-port 6379" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^tls-port\s+' /etc/nexus-redis/redis.conf"
        $out -match '^tls-port\s+6379$'
    } | Out-Null
    Test-Check -Description "$ip : tls-auth-clients yes (mutual TLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^tls-auth-clients\s+' /etc/nexus-redis/redis.conf"
        $out -match '^tls-auth-clients\s+yes$'
    } | Out-Null
    Test-Check -Description "$ip : tls-cluster yes (cluster bus also TLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^tls-cluster\s+' /etc/nexus-redis/redis.conf"
        $out -match '^tls-cluster\s+yes$'
    } | Out-Null
    Test-Check -Description "$ip : cluster-enabled yes" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^cluster-enabled\s+' /etc/nexus-redis/redis.conf"
        $out -match '^cluster-enabled\s+yes$'
    } | Out-Null
    Test-Check -Description "$ip : cluster-announce-ip == $ip" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^cluster-announce-ip\s+' /etc/nexus-redis/redis.conf"
        $out -match ("^cluster-announce-ip\s+" + [regex]::Escape($ip) + "$")
    } | Out-Null
}

# ─── Section 7: nexus-redis.service state ─────────────────────────────────
Write-Section 'nexus-redis.service active on every node'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : nexus-redis.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-redis.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : apt-shipped redis-server.service is masked (no port-6379 race)" -Probe {
        # Mask is the canonical state: stronger than disable, survives a stray
        # `systemctl enable redis-server.service`.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-enabled redis-server.service 2>&1 || true'
        $out -match '^masked$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-cluster check(s) failed; skipping cluster-health probes." -ForegroundColor Red
    exit 1
}

# ─── Section 8: TLS listener on :6379 presents a cert ─────────────────────
Write-Section 'TLS listener on :6379 presents a server certificate'
foreach ($ip in $nodeIps) {
    Test-Check -Description "$ip : openssl s_client handshake against localhost:6379 yields a cert" -Probe {
        # tls-auth-clients yes means the handshake ultimately fails without a
        # client cert, but the server still presents its certificate first --
        # enough to prove :6379 speaks TLS, not PLAINTEXT.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo | timeout 10 openssl s_client -connect localhost:6379 2>&1'
        $out -match 'BEGIN CERTIFICATE'
    } | Out-Null
}

# ─── Section 9: Cluster health + cross-shard round-trip (0.G.1 exit gate) ─
Write-Section 'Cluster health + cross-shard round-trip (0.G.1 exit gate)'

Test-Check -Description "cluster_state:ok (3 masters elected)" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null"
    $out -match '(?m)^cluster_state:ok'
} | Out-Null

Test-Check -Description "cluster_size:3 (3 shards)" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null"
    $out -match '(?m)^cluster_size:3'
} | Out-Null

Test-Check -Description "cluster_known_nodes:6 (all 6 talking gossip)" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null"
    $out -match '(?m)^cluster_known_nodes:6'
} | Out-Null

Test-Check -Description "cluster_slots_assigned:16384 (full keyspace covered)" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null"
    $out -match '(?m)^cluster_slots_assigned:16384'
} | Out-Null

Test-Check -Description "cluster_slots_ok:16384 (no slots in error state)" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null"
    $out -match '(?m)^cluster_slots_ok:16384'
} | Out-Null

Test-Check -Description "CLUSTER NODES shows 3 masters" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster nodes 2>/dev/null"
    $masters = ($out -split "`n" | Where-Object { $_ -match '\bmaster\b' }).Count
    $masters -eq 3
} | Out-Null

Test-Check -Description "CLUSTER NODES shows 3 replicas" -Probe {
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster nodes 2>/dev/null"
    # Redis keeps the legacy term 'slave' in CLUSTER NODES output.
    $replicas = ($out -split "`n" | Where-Object { $_ -match '\bslave\b' }).Count
    $replicas -eq 3
} | Out-Null

Test-Check -Description "cross-shard round-trip via redis-cli -c (cluster mode)" -Probe {
    $token = "smoke-0G1-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $rt = "set -e; " +
          "T='$tlsArgs'; " +
          "sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c SET nexus-smoke-key-1 '$token-alpha' > /dev/null; " +
          "sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c SET nexus-smoke-key-2 '$token-beta'  > /dev/null; " +
          "sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c SET nexus-smoke-key-3 '$token-gamma' > /dev/null; " +
          "sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c SET nexus-smoke-key-4 '$token-delta' > /dev/null; " +
          "echo SMOKE_A=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c GET nexus-smoke-key-1); " +
          "echo SMOKE_B=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c GET nexus-smoke-key-2); " +
          "echo SMOKE_C=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c GET nexus-smoke-key-3); " +
          "echo SMOKE_D=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$T -c GET nexus-smoke-key-4)"
    $out = Invoke-RemoteCommand -Ip $bootstrapIp -Command $rt
    ($out -match "SMOKE_A=$([regex]::Escape($token))-alpha") -and
    ($out -match "SMOKE_B=$([regex]::Escape($token))-beta") -and
    ($out -match "SMOKE_C=$([regex]::Escape($token))-gamma") -and
    ($out -match "SMOKE_D=$([regex]::Escape($token))-delta")
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.G.1 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: 6-node Redis Cluster runs on mutual TLS -- per-node Vault PKI" -ForegroundColor Green
    Write-Host "leaf certs, tls-auth-clients yes, tls-cluster yes, cluster_state:ok with 3 masters" -ForegroundColor Green
    Write-Host "+ 3 replicas + 16384 slots assigned + cross-shard SET/GET round-trip verified." -ForegroundColor Green
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
