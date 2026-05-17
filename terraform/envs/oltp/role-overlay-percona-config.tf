/*
 * role-overlay-percona-config.tf -- Phase 0.G.3 (chunk 3b) -- render
 *   /etc/nexus-percona/{my,wsrep}.cnf on each PXC node (PXC-ONLY; ProxySQL
 *   nodes have a different config format handled in chunk 3d)
 *
 * Per-host config render + filesystem prep. Runs AFTER percona-tls has the
 * cert + 3 KV secrets in place (depends_on chain enforces order). Does NOT
 * start mysql.service -- that happens in chunk 3c (galera-cluster-bootstrap)
 * which has to flip wsrep_cluster_address to gcomm:// on pxc-node-1 first
 * for galera_new_cluster, then start the other 2 nodes one-by-one to join
 * via SST.
 *
 * --- Two-file config split (Percona convention) ---
 *
 *   /etc/nexus-percona/my.cnf      -- MySQL/InnoDB settings + TLS + perf
 *                                     schema tuning. Identical across 3
 *                                     nodes EXCEPT server_id (unique per
 *                                     node; Galera replicates all writes
 *                                     but server_id is still mandatory).
 *
 *   /etc/nexus-percona/wsrep.cnf   -- Galera-specific settings. Per-node
 *                                     differences: wsrep_node_name,
 *                                     wsrep_node_address (VMnet10
 *                                     backplane), wsrep_cluster_address
 *                                     (full peer list on VMnet10 -- same
 *                                     across all 3 in steady state; the
 *                                     chunk 3c bootstrap overlay
 *                                     temporarily flips pxc-node-1's to
 *                                     gcomm:// for galera_new_cluster).
 *
 * --- TLS shape ---
 *
 *   ssl-cert = /etc/nexus-percona/tls/server-cert.pem      (LEAF only)
 *   ssl-key  = /etc/nexus-percona/tls/server-key.pem       (PKCS#8)
 *   ssl-ca   = /etc/nexus-percona/tls/ca.pem               (intermediate+root)
 *   require_secure_transport = ON                          (mTLS-only on 3306)
 *
 * --- Galera (wsrep) shape ---
 *
 *   wsrep_provider                  = /usr/lib/galera4/libgalera_smm.so
 *   wsrep_cluster_address           = gcomm://192.168.10.51,192.168.10.52,
 *                                              192.168.10.53
 *   wsrep_cluster_name              = nexus-pxc
 *   wsrep_node_name                 = <hostname>
 *   wsrep_node_address              = <vmnet10 backplane IP>
 *   wsrep_sst_method                = xtrabackup-v2
 *   wsrep_sst_auth                  = wsrep_sst:<from /etc/nexus-percona/
 *                                                  cluster-password>
 *   pxc_strict_mode                 = ENFORCING
 *   binlog_format                   = ROW
 *   default_storage_engine          = InnoDB
 *   innodb_autoinc_lock_mode        = 2
 *
 * --- Persistence + sizing ---
 *
 *   datadir = /var/lib/nexus-percona
 *   innodb_buffer_pool_size = 1G       (lab: 8 GB RAM nodes; leave headroom
 *                                       for Galera + xtrabackup + OS)
 *   max_connections = 200
 *
 * --- Lifecycle ---
 *
 *   systemd: nexus-percona.service (chunk 4 ships) -- NOT started here
 *   (chunk 3c galera-bootstrap does the cluster-aware start).
 *
 * --- Idempotency / verify ---
 *
 * Hash-keyed re-render. NO service restart triggered here (chunk 3c owns
 * service lifecycle). Verify: confs exist + my.cnf parses cleanly via
 * `mysqld --validate-config`.
 *
 * --- Reachability ---
 *
 * nftables (v3, chunk 3a) opens 3306 on VMnet11 + 4444/4567/4568 on the
 * VMnet10 whole-segment trust.
 *
 * Selective ops: var.enable_percona_config AND var.enable_percona_tls.
 */

locals {
  percona_config_per_host = {
    "pxc-node-1" = { vmnet10 = "192.168.10.51", vmnet11 = "192.168.70.51", server_id = "1" }
    "pxc-node-2" = { vmnet10 = "192.168.10.52", vmnet11 = "192.168.70.52", server_id = "2" }
    "pxc-node-3" = { vmnet10 = "192.168.10.53", vmnet11 = "192.168.70.53", server_id = "3" }
  }

  percona_config_active = {
    for host, spec in local.percona_config_per_host : host => spec
    if(
      var.enable_percona && var.enable_percona_config && var.enable_percona_tls
      && lookup(local.percona_tls_active, host, null) != null
    )
  }

  # Galera peer list (full mesh of all 3 PXC backplane IPs). Same across all
  # 3 nodes in steady state. Chunk 3c temporarily flips pxc-node-1's to
  # gcomm:// for galera_new_cluster, then restores from this list.
  percona_cluster_address = "gcomm://192.168.10.51,192.168.10.52,192.168.10.53"
}

resource "null_resource" "percona_config" {
  for_each = local.percona_config_active

  triggers = {
    tls_id           = null_resource.percona_tls[each.key].id
    vmnet10          = each.value.vmnet10
    vmnet11          = each.value.vmnet11
    server_id        = each.value.server_id
    cluster_address  = local.percona_cluster_address
    percona_config_v = "4" # v4 (0.G.3 ratification fix 2026-05-18, 3rd iter) = REMOVED the mysqld --validate-config smoke. On PXC (not vanilla MySQL), --validate-config tries to ACTIVATE wsrep + connect to gcomm:// peers (which aren't bootstrapped yet) -> times out + fails -> chunk 3b errors. The chunk 3c galera-bootstrap probe + actual cluster formation are the real verification. v3 = trailing newline on my.cnf. v2 = !include wsrep.cnf added. v1 = initial two-file split (orphaned wsrep.cnf -- bug).

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.percona_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $serverId = '${each.value.server_id}'
      $sshUser  = '${var.oltp_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # ─── my.cnf: MySQL + InnoDB + TLS + perf schema ──────────────────────
      $myCnf = @"
# Generated by nexus-infra-oltp/terraform/envs/oltp/role-overlay-percona-config.tf
# Phase 0.G.3 -- Percona XtraDB Cluster mTLS + Galera. Do NOT edit by hand.

[mysqld]
# ─── Identity ──────────────────────────────────────────────────────────
server_id                       = $serverId
bind-address                    = 0.0.0.0
port                            = 3306
datadir                         = /var/lib/nexus-percona
socket                          = /var/run/nexus-percona/mysqld.sock
pid-file                        = /var/run/nexus-percona/mysqld.pid

# ─── Logging ───────────────────────────────────────────────────────────
log_error                       = /var/log/nexus-percona/mysqld.log
slow_query_log                  = OFF
general_log                     = OFF

# ─── TLS (mTLS-only on 3306; see role-overlay-percona-tls.tf) ──────────
ssl-cert                        = /etc/nexus-percona/tls/server-cert.pem
ssl-key                         = /etc/nexus-percona/tls/server-key.pem
ssl-ca                          = /etc/nexus-percona/tls/ca.pem
require_secure_transport        = ON
tls_version                     = TLSv1.2,TLSv1.3

# ─── InnoDB sizing (lab: 8 GB RAM nodes; leave headroom for Galera + xtrabackup + OS) ──
default_storage_engine          = InnoDB
innodb_buffer_pool_size         = 1G
innodb_log_file_size            = 256M
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = ON

# ─── Connections + perf schema ─────────────────────────────────────────
max_connections                 = 200
max_allowed_packet              = 64M
performance_schema              = ON

# ─── Galera prereqs (binlog_format MUST be ROW; autoinc_lock_mode MUST be 2) ──
binlog_format                   = ROW
innodb_autoinc_lock_mode        = 2

# ─── pxc_strict_mode: ENFORCING refuses unsupported statements ─────────
# (MyISAM writes, table without PK, LOCK TABLES, etc.). Catches Galera
# anti-patterns at write-time vs silent divergence later.
pxc_strict_mode                 = ENFORCING

[client]
socket                          = /var/run/nexus-percona/mysqld.sock
ssl-ca                          = /etc/nexus-percona/tls/ca.pem

# Pull in the per-host Galera/wsrep config (rendered as wsrep.cnf below).
# Without this !include, mysqld with --defaults-file=/etc/nexus-percona/my.cnf
# reads ONLY my.cnf and the wsrep_provider directive is never loaded ->
# mysqld starts in standalone mode (no Galera) -> chunk 3c bootstrap probe
# fails because wsrep_cluster_size is not a defined variable. Caught at
# 0.G.3 first ratification 2026-05-17. Chunk 3c's runtime `!include sst-
# auth.cnf` goes INTO wsrep.cnf, so this transitive include picks it up too.
#
# CRITICAL: the file MUST end with a trailing newline. MySQL's `!include`
# parser strips the last character of every line under the assumption it's
# `\n`. If the file lacks a trailing LF, the last char of the last line
# (the `f` in `wsrep.cnf`) gets eaten -> mysqld tries to open `wsrep.cn`
# and fails with `Can't get stat of '/etc/nexus-percona/wsrep.cn'`.
# Trailing blank line before the closing `"@` adds the LF. Caught at
# 0.G.3 ratification 2026-05-18.
!include /etc/nexus-percona/wsrep.cnf

"@

      # ─── wsrep.cnf: Galera-specific (per-host node identity) ─────────────
      $wsrepCnf = @"
# Generated by nexus-infra-oltp/terraform/envs/oltp/role-overlay-percona-config.tf
# Phase 0.G.3 -- Galera replication settings (per-host identity for $hostName).
# Steady-state wsrep_cluster_address is the full peer list. Chunk 3c galera-
# bootstrap temporarily flips pxc-node-1's to gcomm:// for galera_new_cluster
# then restores from this canonical value.

[mysqld]
# ─── Galera provider ───────────────────────────────────────────────────
wsrep_provider                  = /usr/lib/galera4/libgalera_smm.so
wsrep_cluster_name              = nexus-pxc

# ─── Per-host identity ─────────────────────────────────────────────────
# wsrep_node_name + wsrep_node_address are per-node; differ on each PXC node.
wsrep_node_name                 = $hostName
wsrep_node_address              = $vmnet10

# ─── Cluster membership (full peer list, VMnet10 backplane) ────────────
# Chunk 3c galera-bootstrap will temporarily flip pxc-node-1's to gcomm://
# (empty members = bootstrap mode), invoke galera_new_cluster, then restore
# this canonical value across all 3 nodes.
wsrep_cluster_address           = ${local.percona_cluster_address}

# ─── SST method (xtrabackup-v2: online, non-blocking, no donor read-lock) ──
# xtrabackup-v2 is the recommended SST method for Percona XtraDB Cluster.
# auth uses the wsrep_sst user; password is injected at chunk 3c bootstrap
# time from /etc/nexus-percona/cluster-password (Vault Agent rendered).
wsrep_sst_method                = xtrabackup-v2

# ─── Galera flow control + provider tuning ─────────────────────────────
wsrep_provider_options          = "gcache.size=512M; gcache.recover=yes"

# ─── Galera-on-Galera-mTLS settings ────────────────────────────────────
# Galera SST/IST inherits MySQL's ssl-cert/key/ca from my.cnf via
# pxc-encrypt-cluster-traffic=ON. This makes ALL Galera replication
# (SST + IST + state transfers + applier traffic) flow encrypted.
pxc-encrypt-cluster-traffic     = ON
"@

      $myCnfB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($myCnf -replace "`r`n","`n")))
      $wsrepCnfB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($wsrepCnf -replace "`r`n","`n")))

      Write-Host ""
      Write-Host "[percona-config $hostName] rendering my.cnf + wsrep.cnf (server_id=$serverId, node_address=$vmnet10)"

      $stage = @"
set -euo pipefail

# Directories the mysqld process needs (matches my.cnf paths).
sudo install -d -o mysql -g mysql -m 0750 /etc/nexus-percona
sudo install -d -o mysql -g mysql -m 0750 /var/lib/nexus-percona
sudo install -d -o mysql -g mysql -m 0755 /var/log/nexus-percona
# /var/run/nexus-percona: systemd RuntimeDirectory= owns this at runtime,
# but an install-time mkdir is harmless on cold boot.
sudo install -d -o mysql -g mysql -m 0755 /var/run/nexus-percona

# Drop both confs atomically. World-readable (0644) so mysql --validate-
# config can read them without sudo; secrets stay in /etc/nexus-percona/
# *-password (0400 root:mysql).
echo '$myCnfB64' | base64 -d | sudo tee /etc/nexus-percona/my.cnf > /dev/null
sudo chown root:mysql /etc/nexus-percona/my.cnf
sudo chmod 0644 /etc/nexus-percona/my.cnf

echo '$wsrepCnfB64' | base64 -d | sudo tee /etc/nexus-percona/wsrep.cnf > /dev/null
sudo chown root:mysql /etc/nexus-percona/wsrep.cnf
sudo chmod 0644 /etc/nexus-percona/wsrep.cnf

# Note: NO `mysqld --validate-config` smoke here. On Percona XtraDB Cluster
# (vs vanilla MySQL), --validate-config tries to ACTIVATE the wsrep provider
# (including a Galera connection attempt to gcomm:// peers). Since the
# cluster isn't bootstrapped yet at this point in the apply graph, the
# connect attempt times out + validate-config returns non-zero with
# `[Galera] gcs connect failed: Operation timed out`. The validate step
# turns out to be a bad fit for PXC. Chunk 3c galera-bootstrap's
# `mysql -e 'SELECT 1'` probe + the actual cluster formation are the real
# verification. Caught at 0.G.3 ratification 2026-05-18.

echo CONFIG_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'CONFIG_OK') {
        Write-Host $stageOut.Trim()
        throw "[percona-config $hostName] config render / validation failed (rc=$LASTEXITCODE)"
      }

      Write-Host "[percona-config $hostName] my.cnf + wsrep.cnf rendered + validated (mysqld --validate-config clean); service start owned by chunk 3c galera-bootstrap"
    PWSH
  }

  # Destroy: remove rendered confs. /var/lib/nexus-percona is preserved
  # (Galera-replicated data lives there; SST can rehydrate but the operator
  # may want to forensically inspect first).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[percona-config destroy] $${hostName}: removing my.cnf + wsrep.cnf (preserving /var/lib/nexus-percona)"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/nexus-percona/my.cnf /etc/nexus-percona/wsrep.cnf" 2>$null
      exit 0
    PWSH
  }
}
