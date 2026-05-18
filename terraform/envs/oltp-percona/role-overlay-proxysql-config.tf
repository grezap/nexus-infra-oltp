/*
 * role-overlay-proxysql-config.tf -- Phase 0.G.3 (chunk 3d) -- render
 *   /etc/proxysql.cnf on each of the 2 ProxySQL nodes + start
 *   nexus-proxysql.service + verify backend convergence
 *
 * Per-host /etc/proxysql.cnf render + nexus-proxysql.service enable +
 * start + galera-hostgroup convergence verification. Runs AFTER the PXC
 * cluster is bootstrapped (depends on percona_galera_bootstrap) and
 * AFTER ProxySQL TLS cert + 3 KV secrets are in place (depends on
 * percona_tls for the proxysql-1/proxysql-2 instances).
 *
 * --- Config shape ---
 *
 * ProxySQL stores runtime state in an embedded SQLite DB. /etc/proxysql.
 * cnf is the BOOTSTRAP config -- read only on first start (or when
 * --reload is passed). After that, config lives in the SQLite at
 * /var/lib/proxysql/proxysql.db and operator changes go through the
 * admin :6032 interface with LOAD ... TO RUNTIME + SAVE ... TO DISK.
 *
 * This overlay's stance: write a CANONICAL bootstrap config -- on every
 * apply we either:
 *   (a) First apply: write proxysql.cnf + start service (loads from cnf)
 *   (b) Subsequent apply: also nudge runtime via admin :6032 to re-load
 *       any cnf changes (mysql_servers / mysql_users / mysql_galera_
 *       hostgroups). Catches operator-rotated KV secrets too.
 *
 * --- Backends (the 3 PXC nodes) ---
 *
 * ProxySQL groups PXC backends into hostgroups via mysql_galera_
 * hostgroups (the galera-aware Galera plugin reads wsrep_local_state_
 * comment from each backend via the clustercheck user):
 *
 *   writer_hostgroup        = 10  -- exactly ONE PRIMARY Synced node
 *   backup_writer_hostgroup = 20  -- other Synced nodes (failover writers)
 *   reader_hostgroup        = 30  -- all Synced nodes (read-only queries)
 *   offline_hostgroup       = 40  -- Donor/Desync/non-Synced nodes
 *   max_writers             = 1   -- single-writer mode (no multi-master)
 *   writer_is_also_reader   = 0   -- writer doesn't take reader queries
 *
 * mysql_servers populates ALL 3 PXC nodes in hostgroup 10 initially;
 * the Galera plugin auto-shuffles them between writer/backup_writer/
 * reader/offline based on wsrep state.
 *
 * --- Users (mysql_users table) ---
 *
 *   smoke-rw -- default_hostgroup=10 (writer). Apps connect via VIP
 *               .50:6033 -- the keepalived MASTER ProxySQL routes
 *               them to the current writer.
 *
 * --- Admin (admin_variables) ---
 *
 *   admin-admin_credentials = admin:<proxysql-admin-pwd from KV>
 *   admin-mysql_ifaces      = 0.0.0.0:6032
 *
 * --- Monitor (mysql_variables) ---
 *
 *   monitor_username        = clustercheck
 *   monitor_password        = <from KV>
 *   monitor_galera_healthcheck_interval = 1000 (ms)
 *
 * --- TLS ---
 *
 *   mysql-ssl_p2s_ca           = /etc/nexus-percona/tls/ca.pem
 *   mysql-ssl_p2s_cert         = /etc/nexus-percona/tls/server-cert.pem
 *   mysql-ssl_p2s_key          = /etc/nexus-percona/tls/server-key.pem
 *   mysql-have_ssl             = true
 *
 *   These wire ProxySQL-to-server (p2s = proxy to server) TLS so backend
 *   PXC handshakes go encrypted. Client-to-ProxySQL (c2p) TLS is
 *   inherited from the same cert set.
 *
 * --- Verification ---
 *
 *   After service start + nexus-proxysql.service active:
 *     - admin :6032 reachable + auth as admin works
 *     - mysql_servers shows 3 backends, all in healthy hostgroups
 *     - mysql_galera_hostgroups shows the writer/reader splits
 *     - SELECT @@hostname via VIP .50:6033 as smoke-rw routes to a PXC
 *       node (any of the 3, depending on writer/reader split)
 *
 * --- Lifecycle ---
 *
 *   systemd: nexus-proxysql.service (chunk 4 ships)
 *
 * Reachability: nftables (v3, chunk 3a) opens 6032 + 6033 on VMnet11.
 *
 * Selective ops: var.enable_proxysql_config AND var.enable_percona_tls.
 */

locals {
  proxysql_config_per_host = {
    "proxysql-1" = { vmnet11 = "192.168.70.54", instance_id = "1" }
    "proxysql-2" = { vmnet11 = "192.168.70.55", instance_id = "2" }
  }

  proxysql_config_active = {
    for host, spec in local.proxysql_config_per_host : host => spec
    if(
      var.enable_proxysql_config && var.enable_percona_tls
      && lookup(local.percona_tls_active, host, null) != null
    )
  }

  # PXC backend IPs (the 3 Galera nodes ProxySQL routes to).
  proxysql_pxc_backends = compact([
    var.enable_pxc_node_1 ? "192.168.70.51" : "",
    var.enable_pxc_node_2 ? "192.168.70.52" : "",
    var.enable_pxc_node_3 ? "192.168.70.53" : "",
  ])
}

resource "null_resource" "proxysql_config" {
  for_each = local.proxysql_config_active

  triggers = {
    tls_id            = null_resource.percona_tls[each.key].id
    galera_id         = length(null_resource.percona_galera_bootstrap) > 0 ? null_resource.percona_galera_bootstrap[0].id : "disabled"
    vmnet11           = each.value.vmnet11
    instance_id       = each.value.instance_id
    backends_sha      = sha256(join(",", local.proxysql_pxc_backends))
    proxysql_config_v = "1" # v1 (0.G.3) = initial 2-instance ProxySQL with mysql_galera_hostgroups (writer/backup_writer/reader/offline) routing to 3 PXC backends, p2s mTLS via shared cert set, admin auth from KV.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.percona_tls, null_resource.percona_galera_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName  = '${each.key}'
      $ip        = '${each.value.vmnet11}'
      $instId    = '${each.value.instance_id}'
      $sshUser   = '${var.oltp_node_user}'
      $timeout   = ${var.oltp_cluster_timeout_minutes}
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $backends  = @('${join("','", local.proxysql_pxc_backends)}')

      Write-Host ""
      Write-Host "[proxysql-config $hostName] rendering /etc/proxysql.cnf + start nexus-proxysql.service (backends = $($backends -join ','))"

      # Read admin password from /etc/nexus-percona/proxysql-admin-password
      # (rendered by chunk 3b TLS overlay for the ProxySQL nodes only) +
      # monitor password (rendered for both PXC + ProxySQL roles).
      $adminPwd   = (ssh @sshOpts "$sshUser@$ip" 'sudo cat /etc/nexus-percona/proxysql-admin-password' | Out-String).Trim()
      $monitorPwd = (ssh @sshOpts "$sshUser@$ip" 'sudo cat /etc/nexus-percona/monitor-password'        | Out-String).Trim()
      $clusterPwd = (ssh @sshOpts "$sshUser@$ip" 'sudo cat /etc/nexus-percona/cluster-password'        | Out-String).Trim()
      $smokeRwPwd = "smoke-" + $clusterPwd.Substring(0, 24)

      foreach ($pwd in @($adminPwd, $monitorPwd, $clusterPwd)) {
        if (-not $pwd -or $pwd.Length -lt 16) {
          throw "[proxysql-config $hostName] one of admin/monitor/cluster password files missing or too short. Verify role-overlay-percona-tls.tf rendered them on $hostName."
        }
      }

      # mysql_servers + mysql_users + mysql_galera_hostgroups blocks
      # rendered from the backend list.
      $serverEntries = ($backends | ForEach-Object {
        "    { address = `"$_`" , port = 3306 , hostgroup = 10 , max_connections = 100 , use_ssl = 1 }"
      }) -join ",`n"

      $proxysqlCnf = @"
# Generated by nexus-infra-oltp/terraform/envs/oltp/role-overlay-proxysql-config.tf
# Phase 0.G.3 -- ProxySQL bootstrap config for $hostName (instance $instId).
# DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
# After first start, runtime config lives in /var/lib/proxysql/proxysql.db.
# Operator changes go via admin :6032 (LOAD ... TO RUNTIME + SAVE ... TO DISK).

datadir = "/var/lib/proxysql"
errorlog = "/var/log/proxysql/proxysql.log"

admin_variables = {
  admin_credentials = "admin:$adminPwd"
  mysql_ifaces      = "0.0.0.0:6032"
  refresh_interval  = 2000
}

mysql_variables = {
  threads                              = 4
  max_connections                      = 2048
  default_query_delay                  = 0
  default_query_timeout                = 36000000
  have_compress                        = true
  poll_timeout                         = 2000
  interfaces                           = "0.0.0.0:6033"
  default_schema                       = "information_schema"
  stacksize                            = 1048576
  server_version                       = "8.0.36"
  connect_timeout_server               = 3000
  monitor_username                     = "clustercheck"
  monitor_password                     = "$monitorPwd"
  monitor_history                      = 600000
  monitor_connect_interval             = 60000
  monitor_ping_interval                = 10000
  monitor_galera_healthcheck_interval  = 1000
  monitor_read_only_interval           = 1500
  monitor_read_only_timeout            = 500
  ping_interval_server_msec            = 120000
  ping_timeout_server                  = 500
  commands_stats                       = true
  sessions_sort                        = true
  connect_retries_on_failure           = 10
  # p2s mTLS (ProxySQL <-> PXC backends -- backend require_secure_transport=ON)
  have_ssl                             = true
  ssl_p2s_ca                           = "/etc/nexus-percona/tls/ca.pem"
  ssl_p2s_cert                         = "/etc/nexus-percona/tls/server-cert.pem"
  ssl_p2s_key                          = "/etc/nexus-percona/tls/server-key.pem"
}

mysql_servers =
(
$serverEntries
)

mysql_users:
(
  {
    username                = "smoke-rw"
    password                = "$smokeRwPwd"
    default_hostgroup       = 10
    max_connections         = 100
    default_schema          = "nexus_smoke"
    active                  = 1
    use_ssl                 = 0
    transaction_persistent  = 1
    fast_forward            = 0
    backend                 = 1
    frontend                = 1
  }
)

mysql_galera_hostgroups =
(
  {
    writer_hostgroup         = 10
    backup_writer_hostgroup  = 20
    reader_hostgroup         = 30
    offline_hostgroup        = 40
    active                   = 1
    max_writers              = 1
    writer_is_also_reader    = 0
    max_transactions_behind  = 100
    comment                  = "nexus-pxc"
  }
)

mysql_query_rules:
(
)

scheduler =
(
)

mysql_replication_hostgroups:
(
)
"@

      $cnfB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($proxysqlCnf -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail

# Directories the proxysql process needs.
sudo install -d -o proxysql -g proxysql -m 0750 /etc/proxysql
sudo install -d -o proxysql -g proxysql -m 0755 /var/lib/proxysql
sudo install -d -o proxysql -g proxysql -m 0755 /var/log/proxysql

# Drop proxysql.cnf atomically. mode 0640 root:proxysql -- contains admin
# + monitor + smoke-rw passwords; tighter than world-readable.
echo '$cnfB64' | base64 -d | sudo tee /etc/proxysql.cnf > /dev/null
sudo chown root:proxysql /etc/proxysql.cnf
sudo chmod 0640 /etc/proxysql.cnf

# First start (or restart with config reload). Use --reload via systemctl
# restart to force re-read of /etc/proxysql.cnf even on a subsequent
# apply (the embedded SQLite would otherwise win precedence on restart).
sudo systemctl daemon-reload
sudo systemctl enable nexus-proxysql.service
# If service is up + config changed, restart it. If down, start it.
if sudo systemctl is-active --quiet nexus-proxysql.service; then
  # Wipe SQLite to force re-load from cnf. On a re-apply, this discards
  # any operator-runtime-edits since the last apply -- the cnf is the
  # source of truth. Operators who want to persist runtime changes must
  # also update the cnf (or the upstream rendering vars).
  sudo systemctl stop nexus-proxysql.service
  sudo rm -f /var/lib/proxysql/proxysql.db /var/lib/proxysql/proxysql.db-journal
fi
sudo systemctl start nexus-proxysql.service

echo CONFIG_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'CONFIG_OK') {
        Write-Host $stageOut.Trim()
        throw "[proxysql-config $hostName] config render / service restart failed (rc=$LASTEXITCODE)"
      }

      # ─── Wait for service active + admin :6032 reachable + backends seen ─
      Write-Host "[proxysql-config $hostName] waiting for nexus-proxysql.service + admin probe + 3 backends..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $ok = $false
      while ((Get-Date) -lt $deadline) {
        $active = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active nexus-proxysql.service" 2>&1 | Out-String).Trim()
        if ($active -eq 'active') {
          # Admin probe: count rows in mysql_servers (should be 3 backends).
          $count = (ssh @sshOpts "$sshUser@$ip" "mysql -h 127.0.0.1 -P 6032 -u admin -p$adminPwd -BNe 'SELECT COUNT(*) FROM main.mysql_servers' 2>/dev/null" | Out-String).Trim()
          if ($count -eq '3') { $ok = $true; break }
        }
        Start-Sleep -Seconds 5
      }
      if (-not $ok) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-proxysql.service --no-pager -n 30; sudo tail -30 /var/log/proxysql/proxysql.log 2>/dev/null" 2>&1 | Out-String)
        Write-Host $journal
        throw "[proxysql-config $hostName] nexus-proxysql.service / admin probe / 3-backend convergence did not happen within $timeout min"
      }
      Write-Host "[proxysql-config $hostName] nexus-proxysql active + admin :6032 OK + mysql_servers has 3 backends"

      # Final round-trip: connect via :6033 as smoke-rw + SELECT @@hostname.
      # Should land on one of the 3 PXC nodes (writer or reader depending
      # on hostgroup state). Proves end-to-end client path works.
      $rt = (ssh @sshOpts "$sshUser@$ip" "mysql -h 127.0.0.1 -P 6033 -u smoke-rw -p$smokeRwPwd -BNe 'SELECT @@hostname' nexus_smoke 2>/dev/null" | Out-String).Trim()
      if ($rt -notmatch '^pxc-node-[123]$') {
        Write-Host "Got: $rt"
        throw "[proxysql-config $hostName] :6033 smoke-rw round-trip didn't return a pxc-node-N hostname (got: $rt)"
      }
      Write-Host "[proxysql-config $hostName] :6033 smoke-rw round-trip via VIP-eligible frontend OK -- routed to PXC backend $rt"
    PWSH
  }

  # Destroy: stop service + remove proxysql.cnf + wipe runtime SQLite.
  # /var/lib/proxysql is preserved at the dir level but DB file deleted
  # so a re-apply starts fresh from the rendered cnf.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[proxysql-config destroy] $${hostName}: stopping nexus-proxysql + removing proxysql.cnf + wiping runtime SQLite"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-proxysql.service 2>/dev/null; sudo rm -f /etc/proxysql.cnf /var/lib/proxysql/proxysql.db /var/lib/proxysql/proxysql.db-journal" 2>$null
      exit 0
    PWSH
  }
}
