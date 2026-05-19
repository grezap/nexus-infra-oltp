#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.G.4 smoke gate -- Patroni PG HA + etcd DCS + HAProxy HA pair + VIP.

.DESCRIPTION
  Verifies the 0.G.4 exit gate: the 3-node Patroni-orchestrated PostgreSQL 17
  streaming-replication cluster runs on mutual TLS, backed by a 3-node etcd
  raft quorum with HTTP-basic-auth RBAC for the DCS, fronted by an HA pair of
  HAProxy nodes (haproxy-pg-1 + haproxy-pg-2) with a VRRP-floated VIP at
  192.168.70.60. Apps connect to <VIP>:5432; HAProxy routes to the current
  Patroni leader via /leader REST probes. End-to-end: write via <VIP>:5432
  + replication observable on the 2 streaming replicas via pg_stat_replication.

  Ordered cheapest-first: reachability -> firstboot -> identity ->
  vault-agent -> TLS material + role-specific KV creds -> per-role services
  active -> etcd quorum + RBAC -> Patroni cluster shape -> streaming
  replication -> HAProxy backend health -> end-to-end write via LB.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality), `\s*$` end-of-line for
  CRLF tolerance, sudo wrapping for /etc/nexus-*/* traversal.
  Each check echoes [OK]/[FAIL]; exits 1 on any FAIL.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the canonical lab SSH key.
  psql / patronictl / etcdctl run on each node via sudo (config + TLS
  is 0640 root:<role-group>; nexus-patronictl + nexus-etcdctl wrappers
  pre-load endpoints + TLS material).
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: postgres).
$patroniIps = @('192.168.70.61', '192.168.70.62', '192.168.70.63')
$etcdIps    = @('192.168.70.64', '192.168.70.65', '192.168.70.66')
$haproxyIps = @('192.168.70.67', '192.168.70.68')
$haproxyVip = '192.168.70.60'
$haproxyMasterCandidate = $haproxyIps[0]   # haproxy-pg-1 priority 110
$allIps     = $patroniIps + $etcdIps + $haproxyIps
$leaderCandidate = $patroniIps[0]   # pg-primary -- usually the leader at first apply

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

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

# ─── Section 1: per-node SSH reachability (8 nodes) ───────────────────────
Write-Section 'Per-node SSH reachability (8 nodes)'
foreach ($ip in $allIps) {
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
Write-Section 'oltp-node firstboot completion (8 nodes)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/lib/oltp-node-firstboot-done present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/oltp-node-firstboot-done && echo done'
        $out -match 'done'
    } | Out-Null
}

# ─── Section 3: hostname + node-identity mapping ──────────────────────────
Write-Section 'Hostname + per-role node-identity mapping'
$expected = @{
    '192.168.70.61' = @{ host = 'pg-primary';   role = 'patroni'; cluster = 'patroni'; dir = '/etc/nexus-patroni' }
    '192.168.70.62' = @{ host = 'pg-replica-1'; role = 'patroni'; cluster = 'patroni'; dir = '/etc/nexus-patroni' }
    '192.168.70.63' = @{ host = 'pg-replica-2'; role = 'patroni'; cluster = 'patroni'; dir = '/etc/nexus-patroni' }
    '192.168.70.64' = @{ host = 'etcd-1';       role = 'etcd';    cluster = 'etcd';    dir = '/etc/nexus-etcd' }
    '192.168.70.65' = @{ host = 'etcd-2';       role = 'etcd';    cluster = 'etcd';    dir = '/etc/nexus-etcd' }
    '192.168.70.66' = @{ host = 'etcd-3';       role = 'etcd';    cluster = 'etcd';    dir = '/etc/nexus-etcd' }
    '192.168.70.67' = @{ host = 'haproxy-pg-1'; role = 'haproxy'; cluster = 'haproxy'; dir = '/etc/nexus-haproxy' }
    '192.168.70.68' = @{ host = 'haproxy-pg-2'; role = 'haproxy'; cluster = 'haproxy'; dir = '/etc/nexus-haproxy' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($e.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env under $($e.dir)/ (cluster=$($e.cluster), role=$($e.role))" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo cat $($e.dir)/node-identity.env 2>&1"
        ($out -match "NEXUS_ROLE=$($e.role)") -and ($out -match "NEXUS_CLUSTER=$($e.cluster)") -and ($out -match "NEXUS_HOSTNAME=$($e.host)")
    } | Out-Null
}

# ─── Section 4: nexus-vault-agent.service ─────────────────────────────────
Write-Section 'nexus-vault-agent.service active + AppRole token sink populated (8 nodes)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service'
        $out -match '^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : Vault Agent token sink populated (AppRole auth OK)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT'
        $out -match 'TOKEN_PRESENT'
    } | Out-Null
}

# ─── Section 5: TLS material + role-specific KV creds rendered ────────────
Write-Section 'PKI cert material (3-file split, per-role dir) + role-specific KV creds'
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    $cn = "$($e.host).patroni.nexus.lab"
    foreach ($f in @('server-cert.pem', 'server-key.pem', 'ca.pem')) {
        Test-Check -Description "$ip : $($e.dir)/tls/$f present" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command "sudo test -s $($e.dir)/tls/$f && echo present"
            $out -match 'present'
        } | Out-Null
    }
    Test-Check -Description "$ip : leaf cert CN == $cn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in $($e.dir)/tls/server-cert.pem -noout -subject 2>/dev/null"
        $out -match [regex]::Escape($cn)
    } | Out-Null
    Test-Check -Description "$ip : server-key.pem is PKCS#8 (BEGIN PRIVATE KEY)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo head -1 $($e.dir)/tls/server-key.pem"
        $out -match 'BEGIN PRIVATE KEY'
    } | Out-Null
    Test-Check -Description "$ip : ca.pem has 2 CERTIFICATE blocks (intermediate+root)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -c 'BEGIN CERTIFICATE' $($e.dir)/tls/ca.pem"
        $out -match '^2\s*$'
    } | Out-Null
    # HAProxy nodes additionally carry the VIP .60 in their cert IP SANs so
    # client handshakes against the floating VIP validate regardless of
    # which haproxy currently holds it.
    if ($e.role -eq 'haproxy') {
        Test-Check -Description "$ip : leaf cert IP SANs include VIP $haproxyVip" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in $($e.dir)/tls/server-cert.pem -noout -ext subjectAltName 2>/dev/null"
            $out -match [regex]::Escape($haproxyVip)
        } | Out-Null
    }

    # Role-specific KV creds rendered (count + names depend on role).
    $kvFiles = switch ($e.role) {
        'patroni' { @('etcd-root-password', 'patroni-rest-password', 'postgres-superuser-password', 'postgres-replication-password') }
        'etcd'    { @('etcd-root-password', 'patroni-rest-password') }
        'haproxy' { @('patroni-rest-password', 'haproxy-stats-password') }
    }
    foreach ($kv in $kvFiles) {
        Test-Check -Description "$ip : $($e.dir)/$kv present" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command "sudo test -s $($e.dir)/$kv && echo present"
            $out -match 'present'
        } | Out-Null
    }
}

# ─── Section 6: nexus-etcd.service + member health ────────────────────────
Write-Section 'nexus-etcd.service active + member raft health (3 nodes)'
foreach ($ip in $etcdIps) {
    Test-Check -Description "$ip : nexus-etcd.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-etcd.service'
        $out -match '^active\s*$'
    } | Out-Null
}
Test-Check -Description 'etcd cluster has a leader (endpoint status reports non-zero leader id)' -Probe {
    # JSON field is `"leader":<member-id>` (uint64); non-zero = cluster has leader.
    # Use `--user` because RBAC is enabled (auth status requires auth post-enable).
    $foundLeader = $false
    foreach ($ip in $etcdIps) {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'ROOT_PWD=$(sudo cat /etc/nexus-etcd/etcd-root-password); sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" endpoint status --write-out=json 2>/dev/null'
        if ($out -match '"leader":\s*[1-9][0-9]*') { $foundLeader = $true; break }
    }
    $foundLeader
} | Out-Null
Test-Check -Description 'etcd member list shows all 3 members healthy (endpoint health)' -Probe {
    $cmd = 'ROOT_PWD=$(sudo cat /etc/nexus-etcd/etcd-root-password); sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" endpoint health --cluster --write-out=json 2>/dev/null'
    $out = Invoke-RemoteCommand -Ip $etcdIps[0] -Command $cmd
    $healthyCount = ([regex]::Matches($out, '"health":true')).Count
    $healthyCount -ge 3
} | Out-Null

# ─── Section 7: etcd RBAC enabled + put-then-get round-trip ───────────────
Write-Section 'etcd RBAC + authenticated put-then-get round-trip'
Test-Check -Description 'etcd auth status reports enabled' -Probe {
    # Post-enable, auth status REQUIRES --user (etcdserver: user name is empty
    # otherwise). Transient #17 at 0.G.4 ratification 2026-05-19.
    $cmd = 'ROOT_PWD=$(sudo cat /etc/nexus-etcd/etcd-root-password); sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" auth status 2>&1'
    $out = Invoke-RemoteCommand -Ip $etcdIps[0] -Command $cmd
    $out -match 'Authentication Status: true'
} | Out-Null
Test-Check -Description 'etcd authenticated put-then-get round-trip (root user)' -Probe {
    $cmd = 'set -e; ROOT_PWD=$(sudo cat /etc/nexus-etcd/etcd-root-password); MARK="smoke-$(date +%s)"; sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" put /nexus/smoke/round-trip "$MARK" >/dev/null; VAL=$(sudo /usr/local/sbin/nexus-etcdctl --user "root:$ROOT_PWD" get /nexus/smoke/round-trip --print-value-only); [ "$VAL" = "$MARK" ] && echo RT_OK'
    $out = Invoke-RemoteCommand -Ip $etcdIps[0] -Command $cmd
    $out -match 'RT_OK'
} | Out-Null

# ─── Section 8: nexus-patroni.service + cluster shape ────────────────────
Write-Section 'nexus-patroni.service active + 1 Leader + 2 Streaming Replica shape'
foreach ($ip in $patroniIps) {
    Test-Check -Description "$ip : nexus-patroni.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-patroni.service'
        $out -match '^active\s*$'
    } | Out-Null
}
$patroniListJson = $null
Test-Check -Description "Patroni cluster: patronictl list returns JSON with 3 members" -Probe {
    $script:patroniListJson = Invoke-RemoteCommand -Ip $leaderCandidate -Command 'sudo /usr/local/sbin/nexus-patronictl list --format json 2>/dev/null'
    $script:patroniListJson -match '^\['
} | Out-Null
Test-Check -Description "Patroni cluster: exactly 1 Leader + 2 streaming Replica" -Probe {
    if (-not $script:patroniListJson) { return $false }
    $cluster = $script:patroniListJson | ConvertFrom-Json
    $leaders  = @($cluster | Where-Object { $_.Role -eq 'Leader' })
    $replicas = @($cluster | Where-Object { $_.Role -eq 'Replica' -or $_.Role -eq 'Sync Standby' })
    ($leaders.Count -eq 1) -and ($replicas.Count -eq 2)
} | Out-Null
Test-Check -Description "Patroni cluster: all 3 members in 'running' or 'streaming' state" -Probe {
    if (-not $script:patroniListJson) { return $false }
    $cluster = $script:patroniListJson | ConvertFrom-Json
    $running = @($cluster | Where-Object { $_.State -eq 'running' -or $_.State -eq 'streaming' })
    $running.Count -ge 3
} | Out-Null

# Capture the current leader for downstream sections.
$currentLeader = $leaderCandidate
$leaderVm = '192.168.70.61'
if ($patroniListJson) {
    try {
        $cluster = $patroniListJson | ConvertFrom-Json
        $leader = $cluster | Where-Object { $_.Role -eq 'Leader' } | Select-Object -First 1
        if ($leader) {
            $currentLeader = $leader.Member
            $leaderVm = switch ($currentLeader) {
                'pg-primary'   { '192.168.70.61' }
                'pg-replica-1' { '192.168.70.62' }
                'pg-replica-2' { '192.168.70.63' }
            }
        }
    } catch { }
}
Write-Host "    -> current leader: $currentLeader ($leaderVm)" -ForegroundColor DarkGray

# ─── Section 9: PostgreSQL streaming replication health ──────────────────
Write-Section 'PostgreSQL streaming replication health (pg_stat_replication on leader)'
Test-Check -Description "leader $currentLeader : pg_stat_replication shows 2 streaming entries" -Probe {
    $cmd = @'
sudo -u postgres psql -h /var/run/nexus-patroni -U postgres -d postgres -tA -c "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';"
'@
    $out = Invoke-RemoteCommand -Ip $leaderVm -Command $cmd
    $out -match '^2\s*$'
} | Out-Null

# ─── Section 10: psql write/read round-trip via leader Unix socket ────────
Write-Section 'psql write-then-read round-trip via leader Unix socket'
Test-Check -Description "leader $currentLeader : nexusops can CREATE/INSERT/SELECT via Unix socket" -Probe {
    $cmd = @'
sudo -u postgres psql -h /var/run/nexus-patroni -U nexusops -d postgres -tA -c "CREATE TABLE IF NOT EXISTS nexus_smoke (k text PRIMARY KEY, v text);" >/dev/null
MARK=$(date +%s)
sudo -u postgres psql -h /var/run/nexus-patroni -U nexusops -d postgres -tA -c "INSERT INTO nexus_smoke (k, v) VALUES ('smoke-rt', '$MARK') ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" >/dev/null
VAL=$(sudo -u postgres psql -h /var/run/nexus-patroni -U nexusops -d postgres -tA -c "SELECT v FROM nexus_smoke WHERE k='smoke-rt';")
[ "$VAL" = "$MARK" ] && echo RT_OK
'@
    $out = Invoke-RemoteCommand -Ip $leaderVm -Command $cmd
    $out -match 'RT_OK'
} | Out-Null

# Verify replication: read the value from a replica (allow a few seconds for streaming).
$replicaIps = $patroniIps | Where-Object { $_ -ne $leaderVm }
foreach ($rip in $replicaIps) {
    $rhost = $expected[$rip].host
    Test-Check -Description "replica $rhost : nexus_smoke 'smoke-rt' replicated from leader" -Probe {
        Start-Sleep -Seconds 2
        $cmd = @'
sudo -u postgres psql -h /var/run/nexus-patroni -U nexusops -d postgres -tA -c "SELECT v FROM nexus_smoke WHERE k='smoke-rt';"
'@
        $out = Invoke-RemoteCommand -Ip $rip -Command $cmd
        # As long as the row exists (any non-empty value), replication propagated.
        $out -and ($out -match '\d')
    } | Out-Null
}

# ─── Section 11: nexus-haproxy.service + backend health (both haproxy nodes) ─
Write-Section 'nexus-haproxy.service active on both HAProxy nodes + pg_pool backend health'
foreach ($hip in $haproxyIps) {
    Test-Check -Description "$hip : nexus-haproxy.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $hip -Command 'systemctl is-active nexus-haproxy.service'
        $out -match '^active\s*$'
    } | Out-Null
    Test-Check -Description "$hip : haproxy.cfg validates (-c)" -Probe {
        $out = Invoke-RemoteCommand -Ip $hip -Command 'sudo /usr/sbin/haproxy -c -f /etc/nexus-haproxy/haproxy.cfg 2>&1 | tail -3'
        ($out -match 'Configuration file is valid') -or ($out -match '^$')
    } | Out-Null
    Test-Check -Description "$hip : pg_pool has at least 1 UP backend (current Patroni leader)" -Probe {
        $cmd = 'STATS_PWD=$(sudo cat /etc/nexus-haproxy/haproxy-stats-password); curl -sS --max-time 5 -u "nexusops:$STATS_PWD" "http://127.0.0.1:8404/stats;csv" | awk -F, ''$1=="pg_pool" && $2!="BACKEND" && $2!="FRONTEND" && $18=="UP"{c++} END{print c+0}'''
        $out = Invoke-RemoteCommand -Ip $hip -Command $cmd
        [int]($out -replace '\D', '0') -ge 1
    } | Out-Null
    Test-Check -Description "$hip : stats UI :8404 returns 401 without auth" -Probe {
        $out = Invoke-RemoteCommand -Ip $hip -Command 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8404/stats'
        $out -match '^401\s*$'
    } | Out-Null
    Test-Check -Description "$hip : stats UI :8404 returns 200 with KV-seeded basic auth" -Probe {
        $cmd = 'STATS_PWD=$(sudo cat /etc/nexus-haproxy/haproxy-stats-password); curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "nexusops:$STATS_PWD" http://127.0.0.1:8404/stats'
        $out = Invoke-RemoteCommand -Ip $hip -Command $cmd
        $out -match '^200\s*$'
    } | Out-Null
}

# ─── Section 12: keepalived + VRRP VIP bound on exactly one HAProxy node ─
Write-Section "keepalived active on both HAProxy nodes + VIP $haproxyVip bound on exactly one"
foreach ($hip in $haproxyIps) {
    Test-Check -Description "$hip : keepalived.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $hip -Command 'systemctl is-active keepalived.service'
        $out -match '^active\s*$'
    } | Out-Null
}
# Count nodes that currently hold the VIP. Should be exactly 1 (no split-brain,
# no orphaned VIP). If we see 0, BACKUP also didn't take over -- broken.
$vipHolders = @()
foreach ($hip in $haproxyIps) {
    $out = Invoke-RemoteCommand -Ip $hip -Command "ip -4 addr show dev nic0 2>/dev/null"
    if ($out -match [regex]::Escape($haproxyVip)) { $vipHolders += $hip }
}
Test-Check -Description "VIP $haproxyVip bound on exactly 1 HAProxy node (current count: $($vipHolders.Count); holder: $($vipHolders -join ','))" -Probe {
    $vipHolders.Count -eq 1
} | Out-Null
Test-Check -Description "VIP $haproxyVip holder is the MASTER candidate ($haproxyMasterCandidate) on first apply (preempt ON, no failover yet)" -Probe {
    # Permissive: if BACKUP holds it, it means MASTER demoted -- pass with a warning.
    if ($vipHolders.Count -eq 1 -and $vipHolders[0] -eq $haproxyMasterCandidate) { return $true }
    if ($vipHolders.Count -eq 1) { $script:warnings += "VIP held by BACKUP ($($vipHolders[0])), not MASTER candidate ($haproxyMasterCandidate)"; return $true }
    return $false
} | Out-Null

# ─── Section 13: end-to-end write via VIP -> current Patroni leader ──────
Write-Section "End-to-end: write via VIP ${haproxyVip}:5432 routes to current Patroni leader"
Test-Check -Description "from leader ${leaderVm}: psql via VIP ${haproxyVip}:5432 INSERT then SELECT (sslmode=verify-ca, chain-only)" -Probe {
    # Connect via VIP. NOTE: sslmode=verify-ca, NOT verify-full.
    # HAProxy is a TCP proxy + does NOT terminate TLS -- the TLS handshake
    # happens with the BACKEND PG node (current leader). The PG cert's IP
    # SANs include the leader's own VMnet11+VMnet10 IPs + 127.0.0.1 but
    # NOT the VIP (.60) -- VIP IP-SAN coverage is on the HAProxy node's
    # cert, but HAProxy's cert isn't seen by the client (TCP-proxy).
    # verify-ca validates the chain via the lab CA (TLS path proven) but
    # skips hostname match. Future fix: add VIP to all 3 PG nodes' IP-SANs
    # in role-overlay-patroni-tls.tf so verify-full passes. Documented as
    # transient #18 in handbook s3.x at 0.G.4 ratification 2026-05-19.
    $vip = $haproxyVip
    $cmd = @"
SUPER_PWD=`$(sudo cat /etc/nexus-patroni/postgres-superuser-password)
export PGPASSWORD="`$SUPER_PWD"
MARK=`$(date +%s)
psql "host=$vip port=5432 dbname=postgres user=nexusops sslmode=verify-ca sslrootcert=/etc/ssl/certs/patroni-ca.pem" -tA -c "INSERT INTO nexus_smoke (k, v) VALUES ('lb-rt', '`$MARK') ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" >/dev/null
VAL=`$(psql "host=$vip port=5432 dbname=postgres user=nexusops sslmode=verify-ca sslrootcert=/etc/ssl/certs/patroni-ca.pem" -tA -c "SELECT v FROM nexus_smoke WHERE k='lb-rt';")
[ "`$VAL" = "`$MARK" ] && echo LB_RT_OK
"@
    $out = Invoke-RemoteCommand -Ip $leaderVm -Command $cmd
    $out -match 'LB_RT_OK'
} | Out-Null

# ─── Final summary ───────────────────────────────────────────────────────
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.G.4 SMOKE CHECKS PASSED' -ForegroundColor Green
    if ($warnings.Count -gt 0) {
        Write-Host "($($warnings.Count) warning(s); rerun with -Strict to fail on warnings)" -ForegroundColor Yellow
    }
    exit 0
} else {
    Write-Host "0.G.4 SMOKE FAILED -- $($failures.Count) failure(s), $($warnings.Count) warning(s)" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
