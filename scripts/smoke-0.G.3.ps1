#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.G.3 smoke gate -- Percona XtraDB Cluster + ProxySQL mTLS + VIP HA.

.DESCRIPTION
  Verifies the 0.G.3 exit gate: the 3-node Percona XtraDB Cluster
  (nexus-pxc) runs on mutual TLS over Galera (multi-master with
  single-writer mode), the 2 ProxySQL nodes route apps via the
  keepalived-floated VIP 192.168.70.50 on :6033, and an end-to-end
  write through the VIP propagates to ALL PXC backends.

  Ordered cheapest-first: reachability -> firstboot -> identity ->
  vault-agent -> TLS material + 3 KV creds -> per-role configs ->
  services active -> TLS listener -> Galera shape (size=3, Synced,
  Primary) -> VIP bound on proxysql-1 -> write via VIP/read from each
  PXC peer (proves Galera replication + frontend LB).

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality), `\s*$` end-of-line for
  CRLF tolerance. Each check echoes [OK]/[FAIL]; exits 1 on any FAIL.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the build host's ssh-agent +
  the canonical lab SSH key. mysql client is run on each node via sudo
  (config + TLS material is 0640 root:mysql).
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: percona).
$pxcIps      = @('192.168.70.51', '192.168.70.52', '192.168.70.53')
$proxysqlIps = @('192.168.70.54', '192.168.70.55')
$allIps      = $pxcIps + $proxysqlIps
$vip         = '192.168.70.50'
$bootstrapIp = $pxcIps[0]   # pxc-node-1

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

# ─── Section 1: per-node SSH reachability ─────────────────────────────────
Write-Section 'Per-node SSH reachability (5 nodes)'
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
Write-Section 'oltp-node firstboot completion'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/lib/oltp-node-firstboot-done present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/oltp-node-firstboot-done && echo done'
        $out -match 'done'
    } | Out-Null
}

# ─── Section 3: hostname + node-identity mapping ──────────────────────────
Write-Section 'Hostname + node-identity mapping (canonical IPs -> identity)'
$expected = @{
    '192.168.70.51' = @{ host = 'pxc-node-1'; role = 'pxc';      cluster = 'percona' }
    '192.168.70.52' = @{ host = 'pxc-node-2'; role = 'pxc';      cluster = 'percona' }
    '192.168.70.53' = @{ host = 'pxc-node-3'; role = 'pxc';      cluster = 'percona' }
    '192.168.70.54' = @{ host = 'proxysql-1'; role = 'proxysql'; cluster = 'percona' }
    '192.168.70.55' = @{ host = 'proxysql-2'; role = 'proxysql'; cluster = 'percona' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($e.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env under /etc/nexus-percona/ (cluster=percona, role=$($e.role))" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-percona/node-identity.env 2>&1'
        ($out -match "NEXUS_ROLE=$($e.role)") -and ($out -match 'NEXUS_CLUSTER=percona') -and ($out -match "NEXUS_HOSTNAME=$($e.host)")
    } | Out-Null
}

# ─── Section 4: nexus-vault-agent.service ─────────────────────────────────
Write-Section 'nexus-vault-agent.service active + AppRole token sink populated'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : Vault Agent token sink populated (AppRole auth OK)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT'
        $out -match 'TOKEN_PRESENT'
    } | Out-Null
}

# ─── Section 5: mTLS cert material + 3 KV creds rendered ──────────────────
Write-Section 'PKI cert material (3-file split) + 3 KV creds rendered (cluster/monitor + per-role-3rd)'
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    $cn = "$($e.host).percona.nexus.lab"
    # 3-file TLS split (vs mongo's combined .pem) -- chunk 3b lesson.
    Test-Check -Description "$ip : /etc/nexus-percona/tls/server-cert.pem present (LEAF only)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/tls/server-cert.pem && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-percona/tls/server-key.pem present (PKCS#8)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/tls/server-key.pem && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-percona/tls/ca.pem present (intermediate+root)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/tls/ca.pem && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : leaf cert CN == $cn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-percona/tls/server-cert.pem -noout -subject 2>/dev/null'
        $out -match [regex]::Escape($cn)
    } | Out-Null
    Test-Check -Description "$ip : server-key.pem is PKCS#8 (BEGIN PRIVATE KEY, not BEGIN RSA PRIVATE KEY)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo head -1 /etc/nexus-percona/tls/server-key.pem'
        $out -match 'BEGIN PRIVATE KEY'
    } | Out-Null
    Test-Check -Description "$ip : ca.pem has both intermediate AND root (2 CERTIFICATE blocks)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -c "BEGIN CERTIFICATE" /etc/nexus-percona/tls/ca.pem'
        $out -match '^2$'
    } | Out-Null
    # 3 KV creds: cluster-password + monitor-password are universal; the
    # 3rd file is role-dependent (root-password for PXC, proxysql-admin-
    # password for ProxySQL).
    Test-Check -Description "$ip : /etc/nexus-percona/cluster-password present (wsrep_sst / ProxySQL backend dial)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/cluster-password && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-percona/monitor-password present (clustercheck user)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/monitor-password && echo present'
        $out -match 'present'
    } | Out-Null
    if ($e.role -eq 'pxc') {
        Test-Check -Description "$ip : /etc/nexus-percona/root-password present (PXC role-specific)" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/root-password && echo present'
            $out -match 'present'
        } | Out-Null
    } else {
        Test-Check -Description "$ip : /etc/nexus-percona/proxysql-admin-password present (ProxySQL role-specific)" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-percona/proxysql-admin-password && echo present'
            $out -match 'present'
        } | Out-Null
    }
}

# ─── Section 6: PXC config (my.cnf + wsrep.cnf) is mTLS + Galera ──────────
Write-Section 'PXC config: my.cnf mTLS + wsrep.cnf Galera + sst-auth.cnf include'
foreach ($ip in $pxcIps) {
    Test-Check -Description "$ip : my.cnf require_secure_transport == ON" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^require_secure_transport' /etc/nexus-percona/my.cnf"
        $out -match 'require_secure_transport\s*=\s*ON'
    } | Out-Null
    Test-Check -Description "$ip : my.cnf ssl-cert points at 3-file split" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^ssl-cert' /etc/nexus-percona/my.cnf"
        $out -match 'server-cert\.pem'
    } | Out-Null
    Test-Check -Description "$ip : my.cnf pxc_strict_mode == ENFORCING" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^pxc_strict_mode' /etc/nexus-percona/my.cnf"
        $out -match 'pxc_strict_mode\s*=\s*ENFORCING'
    } | Out-Null
    Test-Check -Description "$ip : wsrep.cnf wsrep_cluster_name == nexus-pxc" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^wsrep_cluster_name' /etc/nexus-percona/wsrep.cnf"
        $out -match 'wsrep_cluster_name\s*=\s*nexus-pxc'
    } | Out-Null
    Test-Check -Description "$ip : wsrep.cnf wsrep_cluster_address lists all 3 backplane IPs" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^wsrep_cluster_address' /etc/nexus-percona/wsrep.cnf"
        ($out -match '192\.168\.10\.51') -and ($out -match '192\.168\.10\.52') -and ($out -match '192\.168\.10\.53')
    } | Out-Null
    Test-Check -Description "$ip : wsrep.cnf includes sst-auth.cnf (chunk 3c injected)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^!include\s+/etc/nexus-percona/sst-auth\.cnf' /etc/nexus-percona/wsrep.cnf"
        $out -match 'sst-auth\.cnf'
    } | Out-Null
    Test-Check -Description "$ip : sst-auth.cnf perms 0640 root:mysql" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo stat -c "%a %U %G" /etc/nexus-percona/sst-auth.cnf'
        $out -match '^640 root mysql$'
    } | Out-Null
}

# ─── Section 7: ProxySQL config + admin reachable ─────────────────────────
Write-Section 'ProxySQL config + admin :6032 reachable + 3 backends + galera_hostgroups'
foreach ($ip in $proxysqlIps) {
    Test-Check -Description "$ip : /etc/proxysql.cnf present (mode 0640 root:proxysql)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo stat -c "%a %U %G" /etc/proxysql.cnf'
        $out -match '^640 root proxysql$'
    } | Out-Null
    Test-Check -Description "$ip : proxysql.cnf wires p2s mTLS (have_ssl + ssl_p2s_*)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -cE "^\s*(have_ssl|ssl_p2s_(ca|cert|key))" /etc/proxysql.cnf'
        $out -match '^4$'
    } | Out-Null
    Test-Check -Description "$ip : admin :6032 returns mysql_servers count == 3" -Probe {
        $adminPwd = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-percona/proxysql-admin-password'
        if (-not $adminPwd) { return $false }
        $out = Invoke-RemoteCommand -Ip $ip -Command "mysql -h 127.0.0.1 -P 6032 -u admin -p$adminPwd -BNe 'SELECT COUNT(*) FROM main.mysql_servers' 2>/dev/null"
        $out -match '^3$'
    } | Out-Null
    Test-Check -Description "$ip : admin :6032 shows mysql_galera_hostgroups configured (writer=10)" -Probe {
        $adminPwd = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-percona/proxysql-admin-password'
        if (-not $adminPwd) { return $false }
        $out = Invoke-RemoteCommand -Ip $ip -Command "mysql -h 127.0.0.1 -P 6032 -u admin -p$adminPwd -BNe 'SELECT writer_hostgroup FROM main.mysql_galera_hostgroups WHERE comment=`"nexus-pxc`"' 2>/dev/null"
        $out -match '^10$'
    } | Out-Null
}

# ─── Section 8: services active per role ──────────────────────────────────
Write-Section 'Services active: nexus-percona on PXC, nexus-proxysql + keepalived on ProxySQL'
foreach ($ip in $pxcIps) {
    Test-Check -Description "$ip : nexus-percona.service active (PXC)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-percona.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : nexus-percona-bootstrap.service NOT running (regular mode)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-percona-bootstrap.service 2>&1 || true'
        # 'inactive' or 'failed' is fine -- not 'active'.
        $out -notmatch '^active$'
    } | Out-Null
    Test-Check -Description "$ip : apt-shipped mysql.service is masked (no port-3306 race)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-enabled mysql.service 2>&1 || true'
        $out -match '^masked$'
    } | Out-Null
}
foreach ($ip in $proxysqlIps) {
    Test-Check -Description "$ip : nexus-proxysql.service active (ProxySQL)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-proxysql.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : keepalived.service active (VRRP MASTER candidate or BACKUP)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active keepalived.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : apt-shipped proxysql.service is masked (no race)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-enabled proxysql.service 2>&1 || true'
        $out -match '^masked$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-cluster check(s) failed; skipping cluster + VIP probes." -ForegroundColor Red
    exit 1
}

# ─── Section 9: Galera cluster health (the PXC exit gate piece) ───────────
Write-Section 'Galera cluster: size=3, all Synced, all Primary'
foreach ($ip in $pxcIps) {
    Test-Check -Description "$ip : wsrep_cluster_size == 3" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo mysql --defaults-file=/etc/nexus-percona/my.cnf -BNe "SHOW STATUS LIKE ''wsrep_cluster_size''" 2>/dev/null'
        $out -match 'wsrep_cluster_size\s+3\s*$'
    } | Out-Null
    Test-Check -Description "$ip : wsrep_local_state_comment == Synced" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo mysql --defaults-file=/etc/nexus-percona/my.cnf -BNe "SHOW STATUS LIKE ''wsrep_local_state_comment''" 2>/dev/null'
        $out -match 'wsrep_local_state_comment\s+Synced'
    } | Out-Null
    Test-Check -Description "$ip : wsrep_cluster_status == Primary (not Non-Primary; no split-brain)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo mysql --defaults-file=/etc/nexus-percona/my.cnf -BNe "SHOW STATUS LIKE ''wsrep_cluster_status''" 2>/dev/null'
        $out -match 'wsrep_cluster_status\s+Primary'
    } | Out-Null
}

# ─── Section 10: VIP .50 bound on the MASTER candidate ────────────────────
Write-Section 'VIP 192.168.70.50 bound on the keepalived MASTER (proxysql-1 by priority)'
Test-Check -Description "proxysql-1 (.54) : VIP $vip bound on nic0" -Probe {
    $out = Invoke-RemoteCommand -Ip $proxysqlIps[0] -Command "ip -4 addr show dev nic0"
    $out -match [regex]::Escape($vip)
} | Out-Null
Test-Check -Description "proxysql-2 (.55) : VIP $vip NOT bound (BACKUP)" -Probe {
    $out = Invoke-RemoteCommand -Ip $proxysqlIps[1] -Command "ip -4 addr show dev nic0"
    $out -notmatch [regex]::Escape($vip)
} | Out-Null

# ─── Section 11: end-to-end via VIP -- smoke-rw write + Galera replication ─
Write-Section 'End-to-end via VIP :6033 -- write via VIP, read from each PXC node (proves frontend LB + Galera replication)'

Test-Check -Description "VIP $vip:6033 reachable from build host (mysql via VIP as smoke-rw)" -Probe {
    # Derive smoke-rw password from cluster-password (same scheme as chunk
    # 3c galera-bootstrap: "smoke-" + first 24 chars).
    $clusterPwd = Invoke-RemoteCommand -Ip $bootstrapIp -Command 'sudo cat /etc/nexus-percona/cluster-password'
    if (-not $clusterPwd -or $clusterPwd.Length -lt 24) { return $false }
    $smokeRwPwd = "smoke-" + $clusterPwd.Substring(0, 24)

    # End-to-end via VIP: build host -> VIP .50:6033 -> keepalived MASTER
    # (proxysql-1) -> ProxySQL galera_hostgroups -> writer hostgroup ->
    # one of the 3 PXC nodes. Don't have mysql client on build host
    # necessarily; SSH through pxc-node-1 to test the VIP path.
    $token = "smoke-0G3-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $tlsArgs = "--ssl-ca=/etc/nexus-percona/tls/ca.pem --ssl-mode=VERIFY_CA"
    # CREATE + INSERT via VIP. ON DUPLICATE KEY UPDATE for idempotency.
    $writeSql = "CREATE TABLE IF NOT EXISTS nexus_smoke.smoke_test (smoke_key VARCHAR(64) PRIMARY KEY, token VARCHAR(128) NOT NULL); INSERT INTO nexus_smoke.smoke_test (smoke_key, token) VALUES ('smoke-key', '$token') ON DUPLICATE KEY UPDATE token = '$token'; SELECT 'WROTE' AS status;"
    $writeOut = Invoke-RemoteCommand -Ip $bootstrapIp -Command "mysql -h $vip -P 6033 -u smoke-rw -p$smokeRwPwd $tlsArgs nexus_smoke -e `"$writeSql`" 2>&1"
    if ($writeOut -notmatch 'WROTE') { return $false }
    # Stash for next checks (script-level scope).
    $script:smokeToken      = $token
    $script:smokeRwPwd      = $smokeRwPwd
    return $true
} | Out-Null

# Galera replication: read from each PXC node directly (bypasses ProxySQL,
# proves the data actually landed on every node). Brief retry covers the
# very-rare Galera certification lag.
foreach ($ip in $pxcIps) {
    Test-Check -Description "Galera replication: read smoke token directly from $ip (proves Galera applier copied row)" -Probe {
        if (-not $script:smokeToken) { return $false }
        $tlsArgs = "--ssl-ca=/etc/nexus-percona/tls/ca.pem --ssl-mode=VERIFY_CA"
        $readSql = "SELECT token FROM nexus_smoke.smoke_test WHERE smoke_key='smoke-key'"
        for ($i = 1; $i -le 5; $i++) {
            $readOut = Invoke-RemoteCommand -Ip $ip -Command "mysql -h 127.0.0.1 -u smoke-rw -p$script:smokeRwPwd $tlsArgs nexus_smoke -BNe `"$readSql`" 2>&1"
            if ($readOut -eq $script:smokeToken) { return $true }
            Start-Sleep -Seconds 1
        }
        return $false
    } | Out-Null
}

# ─── Section 12 (regression): 0.G.1 redis + 0.G.2 mongo still green ───────
# Light-touch regression: just verify nexus-redis on redis-1 + nexus-mongo
# on mongo-1 are still active (full smoke for redis/mongo lives in
# smoke-0.G.1.ps1 + smoke-0.G.2.ps1).
Write-Section 'Regression: 0.G.1 (redis) + 0.G.2 (mongo) untouched by 0.G.3 nftables v3'
Test-Check -Description "redis-1 (192.168.70.81) : nexus-redis.service still active" -Probe {
    $out = Invoke-RemoteCommand -Ip '192.168.70.81' -Command 'systemctl is-active nexus-redis.service'
    $out -match '^active$'
} | Out-Null
Test-Check -Description "mongo-1 (192.168.70.71) : nexus-mongo.service still active" -Probe {
    $out = Invoke-RemoteCommand -Ip '192.168.70.71' -Command 'systemctl is-active nexus-mongo.service'
    $out -match '^active$'
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.G.3 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: 3-node Percona XtraDB Cluster 'nexus-pxc' Synced + Primary on mutual" -ForegroundColor Green
    Write-Host "TLS, ProxySQL pair routing apps via keepalived-floated VIP $vip:6033 with galera-" -ForegroundColor Green
    Write-Host "aware hostgroup splits, write via VIP + read from every PXC backend confirms" -ForegroundColor Green
    Write-Host "frontend LB + Galera replication end-to-end." -ForegroundColor Green
    Write-Host "Regression: 0.G.1 redis + 0.G.2 mongo unaffected by the chunk 3a nftables v3 update." -ForegroundColor Green
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
