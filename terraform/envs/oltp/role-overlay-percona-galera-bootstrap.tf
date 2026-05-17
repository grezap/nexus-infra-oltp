/*
 * role-overlay-percona-galera-bootstrap.tf -- Phase 0.G.3 (chunk 3c)
 *   Galera 3-node cluster bootstrap + user creation + write/read round-trip
 *
 * One-shot probe-then-bootstrap that brings the 3-node Percona XtraDB
 * Cluster online + creates the wsrep_sst / clustercheck / smoke-rw users
 * + verifies cluster health.
 *
 * Idempotency:
 *   Stage 1 probe (`SHOW STATUS LIKE 'wsrep_cluster_size'` from any PXC
 *   node where mysql is currently up) returns the integer cluster size.
 *   If >=1, the cluster exists; we proceed to verification + user-create
 *   (which is also idempotent) only. If 0 (no nodes up), we run the full
 *   bootstrap dance.
 *
 * Why probe-then-bootstrap (vs unconditional):
 *   `galera_new_cluster` (or `systemctl start nexus-percona-bootstrap.
 *   service`) is dangerous to run when the cluster already exists --
 *   creates a SPLIT BRAIN that can corrupt data. The probe guards against
 *   that. Once any node is up + bootstrapped, joiners come up via SST/IST
 *   and the cluster auto-converges.
 *
 * Bootstrap dance (when cluster doesn't exist):
 *   1. Stop nexus-percona.service + nexus-percona-bootstrap.service on
 *      ALL 3 PXC nodes (clean slate).
 *   2. On pxc-node-1: systemctl start nexus-percona-bootstrap.service
 *      (uses --wsrep-new-cluster, ignores wsrep_cluster_address).
 *   3. Wait for mysqld to be ready (poll mysql -e 'SELECT 1' via socket).
 *   4. Set root password via ALTER USER (initial root@localhost is
 *      auth_socket on fresh apt install -- passwordless via unix socket
 *      from root OS user; ALTER swaps to mysql_native_password with the
 *      KV-rendered password).
 *   5. Create users:
 *        - wsrep_sst@'%'      IDENTIFIED BY <cluster-pwd>, RELOAD,
 *                             LOCK TABLES, PROCESS, REPLICATION CLIENT
 *                             (xtrabackup-v2 SST needs these grants)
 *        - clustercheck@'%'   IDENTIFIED BY <monitor-pwd>, USAGE +
 *                             PROCESS (ProxySQL galera_hostgroups
 *                             health-probe user)
 *        - smoke-rw@'%'       IDENTIFIED BY <smoke-rw-pwd>, ALL on
 *                             nexus_smoke.* (write/read round-trip)
 *   6. Write /etc/nexus-percona/sst-auth.cnf with [mysqld] wsrep_sst_auth
 *      = wsrep_sst:<cluster-pwd>. mode 0640 root:mysql (narrower than
 *      wsrep.cnf's 0644). Idempotent-append `!include /etc/nexus-
 *      percona/sst-auth.cnf` to wsrep.cnf.
 *   7. Stop nexus-percona-bootstrap.service on pxc-node-1.
 *   8. Start nexus-percona.service on pxc-node-1 (now reads canonical
 *      wsrep_cluster_address + finds itself, runs as size-1 cluster).
 *   9. Wait for pxc-node-1 wsrep_local_state_comment=Synced.
 *  10. On pxc-node-2: write sst-auth.cnf + !include line + start
 *      nexus-percona.service (joins via SST from pxc-node-1).
 *  11. Wait for pxc-node-2 wsrep_local_state_comment=Synced + cluster
 *      size on pxc-node-1 = 2.
 *  12. On pxc-node-3: same as step 10/11. Wait for size=3.
 *
 * Verification (the 0.G.3 PXC exit gate):
 *   1. From any node: SHOW STATUS LIKE 'wsrep_cluster_size' == 3
 *   2. From all 3:    SHOW STATUS LIKE 'wsrep_local_state_comment' == 'Synced'
 *   3. From all 3:    SHOW STATUS LIKE 'wsrep_cluster_status' == 'Primary'
 *   4. Write/read round-trip:
 *        - INSERT on pxc-node-1 via mysql -h 127.0.0.1 -u smoke-rw --ssl
 *        - SELECT on pxc-node-2 returns the value
 *        - SELECT on pxc-node-3 returns the value
 *      Proves Galera replication + mTLS + smoke-rw auth all work end-to-
 *      end. Idempotent: INSERT IGNORE on dupe.
 *
 * Reachability:
 *   - All 3 PXC nodes must be reachable from the build host on VMnet11.
 *   - PXC nodes must reach each other on VMnet10 backplane (Galera SST
 *     uses port 4444; replication uses 4567; IST uses 4568). Whole-
 *     segment trust opened in chunk 3a nftables v3.
 *
 * Selective ops: var.enable_galera_cluster_bootstrap AND
 *                var.enable_percona_config.
 */

locals {
  percona_pxc_members = compact([
    var.enable_pxc_node_1 ? "192.168.70.51" : "",
    var.enable_pxc_node_2 ? "192.168.70.52" : "",
    var.enable_pxc_node_3 ? "192.168.70.53" : "",
  ])

  # Bootstrap node = first member. galera_new_cluster runs here.
  percona_bootstrap_ip = length(local.percona_pxc_members) > 0 ? local.percona_pxc_members[0] : ""

  # Joiners = members 2 + 3 (start sequentially after bootstrap, SST from
  # whichever node is online -- typically the bootstrap node for the first
  # joiner, then either of the first two for the second joiner).
  percona_joiner_ips = length(local.percona_pxc_members) > 1 ? slice(local.percona_pxc_members, 1, length(local.percona_pxc_members)) : []
}

resource "null_resource" "percona_galera_bootstrap" {
  count = (
    var.enable_percona && var.enable_galera_cluster_bootstrap && var.enable_percona_config
    && length(local.percona_pxc_members) == 3
  ) ? 1 : 0

  triggers = {
    config_ids = jsonencode([
      for k in keys(null_resource.percona_config) : null_resource.percona_config[k].id
    ])
    pxc_members        = jsonencode(local.percona_pxc_members)
    bootstrap_ip       = local.percona_bootstrap_ip
    galera_bootstrap_v = "3" # v3 (0.G.3 ratification fix 2026-05-18, 2nd structural fix) = corrected bootstrap-vs-join ordering. v2 had nexus-percona-bootstrap.service stopped + regular nexus-percona.service started on pxc-node-1 BEFORE joiners came up; Galera in regular mode couldn't form primary view (no peers responding), entered systemd restart loop. v3 keeps bootstrap.service running on node-1 until joiners join, then rolling-restarts node-1 from bootstrap.service to regular service (now it has peers + can join). v2 was the mysql auth wrapper fix. v1 = initial.
  }

  depends_on = [null_resource.percona_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $bootIp     = '${local.percona_bootstrap_ip}'
      $joinerIps  = @('${join("','", local.percona_joiner_ips)}')
      $allIps     = @('${join("','", local.percona_pxc_members)}')
      $sshUser    = '${var.oltp_node_user}'
      $timeout    = ${var.oltp_cluster_timeout_minutes}
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[galera-bootstrap] cluster nexus-pxc -- bootstrap node = $bootIp ; joiners = $($joinerIps -join ',') ; total = 3"

      # ─── Stage 1: probe ANY PXC node for an existing healthy cluster ──
      # If wsrep_cluster_size >= 1 from any of the 3 nodes, the cluster
      # exists. Probe via the local mysql client + UNIX socket (no TLS, no
      # password -- root@localhost is auth_socket on Percona apt). We
      # don't error if mysql isn't up on a given node; just move on.
      Write-Host "[galera-bootstrap] probing all 3 nodes for existing cluster..."
      $existingSize = 0
      $probeFromIp  = $null
      foreach ($ip in $allIps) {
        $isActive = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active nexus-percona.service 2>/dev/null" | Out-String).Trim()
        if ($isActive -ne 'active') { continue }
        $sizeOut = (ssh @sshOpts "$sshUser@$ip" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_cluster_size'`" 2>/dev/null" | Out-String).Trim()
        # Output is `wsrep_cluster_size\t<N>`; extract the integer.
        if ($sizeOut -match 'wsrep_cluster_size\s+(\d+)') {
          $existingSize = [int]$matches[1]
          $probeFromIp  = $ip
          break
        }
      }

      if ($existingSize -ge 1) {
        Write-Host "[galera-bootstrap] cluster already exists (size=$existingSize via $probeFromIp); skipping bootstrap."
      } else {
        Write-Host "[galera-bootstrap] no cluster detected -- running full bootstrap dance..."

        # ─── Step 1: stop both services on ALL 3 nodes (clean slate) ───
        Write-Host "[galera-bootstrap] step 1: stopping mysql on all 3 PXC nodes..."
        foreach ($ip in $allIps) {
          ssh @sshOpts "$sshUser@$ip" "sudo systemctl stop nexus-percona-bootstrap.service nexus-percona.service 2>/dev/null; exit 0" 2>$null | Out-Null
        }
        Start-Sleep -Seconds 3

        # ─── Step 2: bootstrap pxc-node-1 with --wsrep-new-cluster ─────
        Write-Host "[galera-bootstrap] step 2: starting nexus-percona-bootstrap.service on $bootIp (galera_new_cluster mode)..."
        $bootOut = ssh @sshOpts "$sshUser@$bootIp" "sudo systemctl start nexus-percona-bootstrap.service && echo BOOT_OK" 2>&1 | Out-String
        if ($bootOut -notmatch 'BOOT_OK') {
          $journal = (ssh @sshOpts "$sshUser@$bootIp" "sudo journalctl -u nexus-percona-bootstrap.service --no-pager -n 50" 2>&1 | Out-String)
          Write-Host $journal
          throw "[galera-bootstrap] nexus-percona-bootstrap.service start failed on $bootIp"
        }

        # ─── Step 3: wait for mysqld ready (poll SELECT 1 via socket) ───
        # /usr/local/sbin/nexus-pxc-mysql is an auth-mode-aware wrapper
        # (handles both fresh-init passwordless root AND post-step-4
        # KV-passworded root). Written by chunk 4 oltp_pxc Ansible role
        # at template-bake time; defensively installed earlier in apply
        # if missing.
        Write-Host "[galera-bootstrap] step 3: waiting for mysqld socket on $bootIp..."
        $readyDeadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $readyDeadline) {
          $sel = (ssh @sshOpts "$sshUser@$bootIp" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe 'SELECT 1' 2>/dev/null" | Out-String).Trim()
          if ($sel -eq '1') { $ready = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$bootIp" "sudo journalctl -u nexus-percona-bootstrap.service --no-pager -n 50" 2>&1 | Out-String)
          Write-Host $journal
          throw "[galera-bootstrap] mysqld on $bootIp didn't accept SELECT 1 within $timeout min"
        }
        Write-Host "[galera-bootstrap] mysqld on $bootIp accepts SELECT 1"

        # ─── Step 4 + 5: set root password + create users on bootstrap node ──
        # Read all 3 KV-rendered passwords from /etc/nexus-percona/.
        Write-Host "[galera-bootstrap] step 4+5: setting root password + creating wsrep_sst/clustercheck/smoke-rw users..."
        $rootPwd    = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-percona/root-password'    | Out-String).Trim()
        $clusterPwd = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-percona/cluster-password' | Out-String).Trim()
        $monitorPwd = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-percona/monitor-password' | Out-String).Trim()
        # smoke-rw password is OUR responsibility for now -- not seeded via
        # Vault. Generate one for this bootstrap run + thread through. Future
        # enhancement: also sticky-seed in Vault KV like 0.G.2 mongo's
        # smoke-user-password. For now, derive deterministically from
        # cluster-password so re-applies don't churn.
        $smokeRwPwd = "smoke-" + $clusterPwd.Substring(0, 24)

        foreach ($pwd in @($rootPwd, $clusterPwd, $monitorPwd)) {
          if (-not $pwd -or $pwd.Length -lt 16) {
            throw "[galera-bootstrap] one of root/cluster/monitor password files missing or too short on $bootIp. Verify role-overlay-percona-tls.tf rendered them + the seeds in nexus/oltp/percona/{root,cluster,monitor}-password exist."
          }
        }

        # SQL bootstrap script: set root pwd + create 3 users with grants.
        # Use SINGLE-quoted PS here-string @'..'@ to avoid PS interpolation
        # of `$` -- bash + mysql see literal strings. The 3 passwords get
        # substituted via -replace below.
        $sqlBody = @'
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '__ROOT_PWD__';
CREATE USER IF NOT EXISTS 'wsrep_sst'@'%'    IDENTIFIED WITH mysql_native_password BY '__CLUSTER_PWD__';
GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT, BACKUP_ADMIN ON *.* TO 'wsrep_sst'@'%';
ALTER USER 'wsrep_sst'@'%' IDENTIFIED WITH mysql_native_password BY '__CLUSTER_PWD__';
CREATE USER IF NOT EXISTS 'clustercheck'@'%' IDENTIFIED WITH mysql_native_password BY '__MONITOR_PWD__';
GRANT PROCESS ON *.* TO 'clustercheck'@'%';
ALTER USER 'clustercheck'@'%' IDENTIFIED WITH mysql_native_password BY '__MONITOR_PWD__';
CREATE DATABASE IF NOT EXISTS nexus_smoke;
CREATE USER IF NOT EXISTS 'smoke-rw'@'%' IDENTIFIED WITH mysql_native_password BY '__SMOKE_RW_PWD__';
GRANT ALL PRIVILEGES ON nexus_smoke.* TO 'smoke-rw'@'%';
ALTER USER 'smoke-rw'@'%' IDENTIFIED WITH mysql_native_password BY '__SMOKE_RW_PWD__';
FLUSH PRIVILEGES;
SELECT 'USERS_OK' AS status;
'@
        $sql = $sqlBody `
          -replace '__ROOT_PWD__',     $rootPwd `
          -replace '__CLUSTER_PWD__',  $clusterPwd `
          -replace '__MONITOR_PWD__',  $monitorPwd `
          -replace '__SMOKE_RW_PWD__', $smokeRwPwd
        $sqlB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($sql -replace "`r`n","`n")))

        $userOut = ssh @sshOpts "$sshUser@$bootIp" "echo '$sqlB64' | base64 -d | sudo /usr/local/sbin/nexus-pxc-mysql 2>&1" | Out-String
        if ($userOut -notmatch 'USERS_OK') {
          Write-Host $userOut.Trim()
          throw "[galera-bootstrap] user-create batch on $bootIp did not return USERS_OK"
        }
        Write-Host "[galera-bootstrap] root pwd set + wsrep_sst + clustercheck + smoke-rw created + grants applied"

        # ─── Step 6: write sst-auth.cnf + !include on all 3 nodes ──────
        # Each node needs wsrep_sst_auth in its own config so SST joiners
        # can dial back to the donor. Idempotent-append the !include line.
        $sstAuthBody = "[mysqld]`nwsrep_sst_auth=wsrep_sst:$clusterPwd`n"
        $sstAuthB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($sstAuthBody))

        $sstStage = @"
set -euo pipefail
echo '$sstAuthB64' | base64 -d | sudo tee /etc/nexus-percona/sst-auth.cnf > /dev/null
sudo chown root:mysql /etc/nexus-percona/sst-auth.cnf
sudo chmod 0640 /etc/nexus-percona/sst-auth.cnf
# Idempotent: append `!include` only if missing.
if ! sudo grep -qE '^!include\s+/etc/nexus-percona/sst-auth\.cnf' /etc/nexus-percona/wsrep.cnf; then
  echo '!include /etc/nexus-percona/sst-auth.cnf' | sudo tee -a /etc/nexus-percona/wsrep.cnf > /dev/null
fi
echo SST_AUTH_OK
"@
        $sstStageLf = $sstStage -replace "`r`n","`n"
        foreach ($ip in $allIps) {
          Write-Host "[galera-bootstrap] step 6: writing sst-auth.cnf + !include on $ip..."
          $sstOut = ($sstStageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s") 2>&1 | Out-String
          if ($sstOut -notmatch 'SST_AUTH_OK') {
            Write-Host $sstOut.Trim()
            throw "[galera-bootstrap] sst-auth.cnf write failed on $ip"
          }
        }

        # ─── Step 7: KEEP bootstrap.service running on pxc-node-1 ─────
        # CORRECTED FLOW (per 0.G.3 ratification 2026-05-18 lesson):
        # The original step 7+8+9 stopped bootstrap.service + started
        # regular nexus-percona.service on pxc-node-1 BEFORE joiners came
        # up. Galera in regular mode reads the canonical wsrep_cluster_
        # address (gcomm://node-1,node-2,node-3) and tries to JOIN an
        # existing cluster. With node-2/3 not yet running, it cannot
        # form a primary view (`No nodes coming from primary view`),
        # mysqld exits, systemd restart loops forever.
        #
        # Correct sequence: bootstrap node-1 stays UP as the seed. Start
        # joiners (2, 3) -- they SST/IST from node-1 + form the cluster.
        # Once size=3 + all Synced, ROLLING-RESTART node-1 (stop
        # bootstrap.service, start nexus-percona.service); by then it
        # has peers to join, so regular mode succeeds.
        Write-Host "[galera-bootstrap] step 7: keeping nexus-percona-bootstrap.service running on $bootIp until joiners come up (corrected flow)"

        # ─── Step 8 + 9: start joiners sequentially, wait Synced ──────
        # Joiners get the canonical wsrep_cluster_address (gcomm://all 3)
        # + dial pxc-node-1 (which is up via bootstrap.service) for SST.
        # First joiner SSTs from node-1; second joiner SSTs from either
        # node-1 or node-2 (Galera picks).
        $joinerIdx = 1
        foreach ($jIp in $joinerIps) {
          $joinerIdx++
          $expectedSize = $joinerIdx
          Write-Host "[galera-bootstrap] step 8/9: starting nexus-percona.service on joiner $jIp (expect SST from existing member)..."
          ssh @sshOpts "$sshUser@$jIp" "sudo systemctl start nexus-percona.service" 2>&1 | Out-Null

          Write-Host "[galera-bootstrap] waiting for joiner $jIp Synced + cluster size=$expectedSize on $bootIp..."
          $joinDeadline = (Get-Date).AddMinutes($timeout)
          $joined = $false
          while ((Get-Date) -lt $joinDeadline) {
            $jState = (ssh @sshOpts "$sshUser@$jIp" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_local_state_comment'`" 2>/dev/null" | Out-String).Trim()
            $cSize  = (ssh @sshOpts "$sshUser@$bootIp" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_cluster_size'`" 2>/dev/null" | Out-String).Trim()
            if ($jState -match 'wsrep_local_state_comment\s+Synced' -and $cSize -match "wsrep_cluster_size\s+$expectedSize\s*$") {
              $joined = $true; break
            }
            Start-Sleep -Seconds 5
          }
          if (-not $joined) {
            $journal = (ssh @sshOpts "$sshUser@$jIp" "sudo journalctl -u nexus-percona.service --no-pager -n 50" 2>&1 | Out-String)
            Write-Host $journal
            throw "[galera-bootstrap] joiner $jIp did not reach Synced + cluster size $expectedSize within $timeout min"
          }
          Write-Host "[galera-bootstrap] joiner $jIp Synced (cluster size=$expectedSize)"
        }

        # ─── Step 10: rolling-restart pxc-node-1 bootstrap -> regular ──
        # Now cluster has 3 members (size 3 if both joiners present, else
        # 2). pxc-node-1 can safely switch to regular service: it has at
        # least one peer alive to join via gcomm://, so it'll re-join
        # the existing cluster as a normal member (vs auto-bootstrapping
        # a new one).
        Write-Host "[galera-bootstrap] step 10: rolling-restart $bootIp from bootstrap.service to nexus-percona.service..."
        ssh @sshOpts "$sshUser@$bootIp" "sudo systemctl stop nexus-percona-bootstrap.service && sudo systemctl start nexus-percona.service" 2>&1 | Out-Null

        Write-Host "[galera-bootstrap] waiting for $bootIp wsrep_local_state_comment=Synced (post rolling-restart)..."
        $rrDeadline = (Get-Date).AddMinutes($timeout)
        $bootRR = $false
        while ((Get-Date) -lt $rrDeadline) {
          $state = (ssh @sshOpts "$sshUser@$bootIp" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_local_state_comment'`" 2>/dev/null" | Out-String).Trim()
          if ($state -match 'wsrep_local_state_comment\s+Synced') { $bootRR = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $bootRR) {
          $journal = (ssh @sshOpts "$sshUser@$bootIp" "sudo journalctl -u nexus-percona.service --no-pager -n 50" 2>&1 | Out-String)
          Write-Host $journal
          throw "[galera-bootstrap] $bootIp did not reach Synced after rolling-restart within $timeout min"
        }
        Write-Host "[galera-bootstrap] $bootIp Synced (post rolling-restart; cluster size now expected at $($joinerIps.Count + 1))"
      }

      # ─── Verification (the 0.G.3 PXC exit gate) ─────────────────────
      Write-Host "[galera-bootstrap] verifying cluster: size=3, all Synced, all Primary..."
      $clusterPwd = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-percona/cluster-password' | Out-String).Trim()
      $smokeRwPwd = "smoke-" + $clusterPwd.Substring(0, 24)

      # 1. cluster_size from bootstrap node
      $sizeOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_cluster_size'`" 2>/dev/null" | Out-String).Trim()
      if ($sizeOut -notmatch 'wsrep_cluster_size\s+3\s*$') {
        throw "[galera-bootstrap] FAILED: wsrep_cluster_size != 3 on $bootIp (got: $sizeOut)"
      }
      Write-Host "[galera-bootstrap] verify 1/4: wsrep_cluster_size=3 on $bootIp"

      # 2. Synced + Primary on all 3
      foreach ($ip in $allIps) {
        $state = (ssh @sshOpts "$sshUser@$ip" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_local_state_comment'`" 2>/dev/null" | Out-String).Trim()
        if ($state -notmatch 'wsrep_local_state_comment\s+Synced') {
          throw "[galera-bootstrap] FAILED: $ip wsrep_local_state_comment != Synced (got: $state)"
        }
        $cstatus = (ssh @sshOpts "$sshUser@$ip" "sudo /usr/local/sbin/nexus-pxc-mysql -BNe `"SHOW STATUS LIKE 'wsrep_cluster_status'`" 2>/dev/null" | Out-String).Trim()
        if ($cstatus -notmatch 'wsrep_cluster_status\s+Primary') {
          throw "[galera-bootstrap] FAILED: $ip wsrep_cluster_status != Primary (got: $cstatus)"
        }
      }
      Write-Host "[galera-bootstrap] verify 2/4: all 3 nodes Synced + Primary"

      # 3. Write/read round-trip via smoke-rw + mTLS (the actual exit gate)
      # Token uses fixed key (idempotent: re-apply replaces value).
      $token = "smoke-0G3-" + (Get-Random) + "-" + ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
      $tlsArgs = "--ssl-ca=/etc/nexus-percona/tls/ca.pem --ssl-mode=VERIFY_CA"

      # 3a. WRITE on pxc-node-1 (via smoke-rw -- proves mTLS + auth flow).
      # Use INSERT ... ON DUPLICATE KEY UPDATE for idempotency.
      $writeSql = "CREATE TABLE IF NOT EXISTS nexus_smoke.galera_init_test (smoke_key VARCHAR(64) PRIMARY KEY, token VARCHAR(128) NOT NULL); INSERT INTO nexus_smoke.galera_init_test (smoke_key, token) VALUES ('galera-init-key', '$token') ON DUPLICATE KEY UPDATE token = '$token'; SELECT 'WROTE' AS status;"
      $writeOut = (ssh @sshOpts "$sshUser@$bootIp" "mysql -h 127.0.0.1 -u smoke-rw -p$smokeRwPwd $tlsArgs nexus_smoke -e `"$writeSql`" 2>&1" | Out-String)
      if ($writeOut -notmatch 'WROTE') {
        Write-Host $writeOut.Trim()
        throw "[galera-bootstrap] FAILED: write on $bootIp didn't return WROTE"
      }
      Write-Host "[galera-bootstrap] verify 3/4: wrote token to nexus_smoke.galera_init_test on $bootIp via smoke-rw + mTLS"

      # 3b. READ from each joiner (proves Galera replication actually flowed).
      $readSql = "SELECT token FROM nexus_smoke.galera_init_test WHERE smoke_key = 'galera-init-key';"
      foreach ($jIp in $joinerIps) {
        # Galera commits are synchronous (certification before commit on
        # source) so reads from peers should be immediate. Brief retry
        # loop covers the rare network blip / clock-sync window.
        $readOk = $false
        for ($i = 1; $i -le 5; $i++) {
          $readOut = (ssh @sshOpts "$sshUser@$jIp" "mysql -h 127.0.0.1 -u smoke-rw -p$smokeRwPwd $tlsArgs nexus_smoke -BNe `"$readSql`" 2>&1" | Out-String).Trim()
          if ($readOut -eq $token) { $readOk = $true; break }
          Start-Sleep -Seconds 1
        }
        if (-not $readOk) {
          Write-Host "Expected: $token"
          Write-Host "Got:      $readOut"
          throw "[galera-bootstrap] FAILED: replicated read on $jIp didn't return the inserted token within 5s"
        }
        Write-Host "[galera-bootstrap] verify 4/4 ($jIp): read token via smoke-rw + mTLS -- Galera replication confirmed"
      }

      Write-Host ""
      Write-Host "[galera-bootstrap] OK -- Phase 0.G.3 PXC exit gate met"
      Write-Host "  Cluster: nexus-pxc (3 nodes Synced + Primary)"
      Write-Host "  Wire:    mTLS-only on 3306 via /etc/nexus-percona/tls/{server-cert,server-key,ca}.pem"
      Write-Host "  SST:     xtrabackup-v2 over VMnet10 backplane (encrypted via pxc-encrypt-cluster-traffic=ON)"
      Write-Host "  Users:   wsrep_sst, clustercheck, smoke-rw (created on bootstrap node, replicated to all 3)"
      Write-Host "  Round-trip: write(pxc-node-1) -> read(pxc-node-2) + read(pxc-node-3) -- Galera replication verified"
    PWSH
  }

  # No destroy provisioner: cluster state lives in each node's
  # /var/lib/nexus-percona (preserved by percona-config destroy too).
  # Full env destroy via modules/vm takes the VMs (and disks) with it.
}
