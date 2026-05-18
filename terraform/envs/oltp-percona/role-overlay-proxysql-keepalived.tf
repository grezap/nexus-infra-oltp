/*
 * role-overlay-proxysql-keepalived.tf -- Phase 0.G.3 (chunk 3d) --
 *   VRRP-floated VIP for ProxySQL HA via keepalived
 *
 * Drops /etc/keepalived/keepalived.conf on both ProxySQL nodes + a health
 * script that confirms ProxySQL is serving on :6033 before claiming MASTER.
 * Runs AFTER role-overlay-proxysql-config.tf (the ProxySQL service must
 * be up + healthy before keepalived starts advertising the VIP).
 *
 * --- VIP design ---
 *
 *   Virtual IP:    192.168.70.50 (per nexus-platform-plan/docs/infra/
 *                  vms.yaml percona.virtual_ips.proxysql_vip)
 *   Subnet:        192.168.70.0/24
 *   Interface:     nic0 (VMnet11 service NIC)
 *   VRRP instance: VI_PROXYSQL_NEXUS (instance ID 51 = vault auth_id;
 *                  unique across the whole VMnet11 segment)
 *   Auth:          AH (Authentication Header), 8-char password derived
 *                  from cluster-password (consistent across the 2 nodes
 *                  so VRRP peers authenticate each other's advertisements)
 *   Advert int:    1 second
 *   Priority:      proxysql-1 = 110 (MASTER candidate)
 *                  proxysql-2 = 100 (BACKUP)
 *
 *   Failover behavior: proxysql-1 holds the VIP by default (higher
 *   priority). If proxysql-1's health script fails (ProxySQL not serving
 *   on :6033 OR systemctl is-active != active), priority demotes by
 *   weight=-30 -> effective priority 80, < proxysql-2's 100, so VIP
 *   flips to proxysql-2 within 1 advert interval (~1s). When proxysql-1
 *   recovers, advertisements resume at 110 + preempt back to MASTER.
 *
 *   Lab simplification: preempt is ON (default). In a production scenario
 *   you'd typically set nopreempt to avoid flap, but for the demo it's
 *   useful to see the VIP land back on the canonical primary.
 *
 * --- Health script ---
 *
 *   /etc/keepalived/check_proxysql.sh
 *     - systemctl is-active --quiet nexus-proxysql.service
 *     - mysql -h 127.0.0.1 -P 6033 -u smoke-rw -p... -BNe 'SELECT 1'
 *     Returns 0 if both pass, non-zero otherwise.
 *
 *   Called every 2s by keepalived's `vrrp_script` -- on 3 consecutive
 *   failures, weight -30 fires (effective priority drops).
 *
 * --- Reachability ---
 *
 *   nftables (v3, chunk 3a) opens:
 *     - ip protocol 112 accept (VRRP unicast)
 *     - ip daddr 224.0.0.18 ip protocol 112 accept (VRRP multicast)
 *
 *   The VIP itself is a kernel-level secondary address on nic0; floats
 *   between the 2 ProxySQL nodes without any switch / router work.
 *
 * --- Verification ---
 *
 *   1. keepalived.service active on both nodes
 *   2. `ip addr show dev nic0` on proxysql-1 shows 192.168.70.50/24
 *      (secondary scope) within 5s of service start
 *   3. `ip addr show dev nic0` on proxysql-2 does NOT show .50
 *   4. From build host: `mysql -h 192.168.70.50 -P 6033 -u smoke-rw
 *      -p... -BNe 'SELECT 1'` returns 1
 *
 * Selective ops: var.enable_keepalived_vip AND var.enable_proxysql_config.
 */

locals {
  # Per-host: own IP + the PEER's IP for VRRP unicast.
  # Multicast VRRP (224.0.0.18 + proto 112) doesn't reliably traverse
  # VMware Workstation VMnet11 -- both nodes go split-brain MASTER because
  # neither sees the other's advertisements. Unicast bypasses multicast
  # entirely. Fixed at 0.G.3.5c chunk 1 ratification 2026-05-18 (transient
  # #22 in handbook s3.x).
  keepalived_per_host = {
    "proxysql-1" = { vmnet11 = "192.168.70.54", peer = "192.168.70.55", priority = "110", role = "MASTER" }
    "proxysql-2" = { vmnet11 = "192.168.70.55", peer = "192.168.70.54", priority = "100", role = "BACKUP" }
  }

  keepalived_active = {
    for host, spec in local.keepalived_per_host : host => spec
    if(
      var.enable_keepalived_vip && var.enable_proxysql_config
      && lookup(local.proxysql_config_active, host, null) != null
    )
  }
}

resource "null_resource" "proxysql_keepalived" {
  for_each = local.keepalived_active

  triggers = {
    proxysql_id  = null_resource.proxysql_config[each.key].id
    vmnet11      = each.value.vmnet11
    priority     = each.value.priority
    vip          = var.proxysql_vip
    peer_ip      = each.value.peer
    keepalived_v = "2" # v2 (0.G.3.5c chunk 1 ratification 2026-05-18) = unicast VRRP via unicast_src_ip + unicast_peer (multicast 224.0.0.18 doesn't reliably traverse VMware Workstation VMnet11, both nodes go split-brain MASTER; transient #22 in handbook s3.x). v1 = initial 2-instance multicast VRRP for VIP .50 with priority 110/100 + check script + AH auth derived from cluster-password.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.proxysql_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName  = '${each.key}'
      $ip        = '${each.value.vmnet11}'
      $peerIp    = '${each.value.peer}'
      $priority  = '${each.value.priority}'
      $role      = '${each.value.role}'
      $vip       = '${var.proxysql_vip}'
      $sshUser   = '${var.oltp_node_user}'
      $timeout   = ${var.oltp_cluster_timeout_minutes}
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[keepalived $hostName] configuring VRRP instance VI_PROXYSQL_NEXUS (role=$role, priority=$priority, vip=$vip)..."

      # Read cluster-password to derive VRRP AH auth password (8 chars max
      # per VRRP spec; truncate from the 32-char hex).
      $clusterPwd = (ssh @sshOpts "$sshUser@$ip" 'sudo cat /etc/nexus-percona/cluster-password' | Out-String).Trim()
      if (-not $clusterPwd -or $clusterPwd.Length -lt 16) {
        throw "[keepalived $hostName] cluster-password missing -- chunk 3b TLS overlay must have run first."
      }
      $vrrpAuthPwd = $clusterPwd.Substring(0, 8)

      # smoke-rw password for health-check.
      $smokeRwPwd = "smoke-" + $clusterPwd.Substring(0, 24)

      # ─── Health check script ─────────────────────────────────────────────
      # 2-check: systemctl active + actual :6033 SELECT 1. Both must pass.
      # smoke-rw password is embedded in the script (mode 0700 root) -- not
      # ideal but VRRP keepalived has no way to read external secret files.
      $checkScript = @"
#!/bin/bash
# Phase 0.G.3 health check for keepalived VRRP MASTER election.
# Returns 0 if ProxySQL is healthy + serving SELECT 1 via mTLS frontend.
set -e
if ! systemctl is-active --quiet nexus-proxysql.service; then
  exit 1
fi
# Probe SELECT 1 via :6033 frontend as smoke-rw -- proves the whole
# read path (frontend listener + galera_hostgroups -> writer hostgroup ->
# backend PXC SELECT). 2s connect_timeout to keep VRRP responsive.
result=`$(mysql -h 127.0.0.1 -P 6033 -u smoke-rw -p$smokeRwPwd \
  --connect-timeout=2 -BNe 'SELECT 1' nexus_smoke 2>/dev/null)
if [ "`$result" = "1" ]; then
  exit 0
fi
exit 1
"@

      $checkScriptB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($checkScript -replace "`r`n","`n")))

      # ─── keepalived.conf ─────────────────────────────────────────────────
      $kpConf = @"
# Generated by nexus-infra-oltp/terraform/envs/oltp/role-overlay-proxysql-keepalived.tf
# Phase 0.G.3 -- VRRP VIP failover for ProxySQL on $hostName (role=$role).
# DO NOT EDIT BY HAND.

global_defs {
  router_id  proxysql_nexus_$hostName
  enable_script_security
  script_user root
}

vrrp_script chk_proxysql {
  script   "/etc/keepalived/check_proxysql.sh"
  interval 2
  timeout  3
  rise     2
  fall     3
  weight   -30
}

vrrp_instance VI_PROXYSQL_NEXUS {
  state         $role
  interface     nic0
  virtual_router_id 51
  priority      $priority
  advert_int    1
  preempt_delay 5

  # Unicast VRRP -- VMware Workstation VMnet11 doesn't reliably forward
  # the 224.0.0.18 multicast group between guests, so multicast advertise-
  # ments are lost both ways and both nodes claim MASTER (split-brain).
  # Unicast sends advertisements directly to the peer's VMnet11 IP. Fixed
  # at 0.G.3.5c chunk 1 ratification 2026-05-18 (transient #22).
  unicast_src_ip $ip
  unicast_peer {
    $peerIp
  }

  authentication {
    auth_type AH
    auth_pass $vrrpAuthPwd
  }

  virtual_ipaddress {
    $vip/24 dev nic0 label nic0:vip
  }

  track_script {
    chk_proxysql
  }
}
"@

      $kpConfB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kpConf -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail

# Install keepalived if not present (Packer baseline includes it for the
# proxysql nodes; defensive install for partial-apply scenarios).
if ! command -v keepalived >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq keepalived
fi

sudo install -d -o root -g root -m 0755 /etc/keepalived

echo '$checkScriptB64' | base64 -d | sudo tee /etc/keepalived/check_proxysql.sh > /dev/null
sudo chown root:root /etc/keepalived/check_proxysql.sh
sudo chmod 0700 /etc/keepalived/check_proxysql.sh

echo '$kpConfB64' | base64 -d | sudo tee /etc/keepalived/keepalived.conf > /dev/null
sudo chown root:root /etc/keepalived/keepalived.conf
sudo chmod 0640 /etc/keepalived/keepalived.conf

sudo systemctl daemon-reload
sudo systemctl enable keepalived.service
sudo systemctl restart keepalived.service

echo KEEPALIVED_OK
"@

      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'KEEPALIVED_OK') {
        Write-Host $stageOut.Trim()
        throw "[keepalived $hostName] config / service start failed (rc=$LASTEXITCODE)"
      }

      # Verify keepalived active + (on MASTER candidate only) VIP bound.
      Write-Host "[keepalived $hostName] waiting for keepalived.service active..."
      $deadline = (Get-Date).AddMinutes(2)
      $active = $false
      while ((Get-Date) -lt $deadline) {
        $st = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active keepalived.service" 2>&1 | Out-String).Trim()
        if ($st -eq 'active') { $active = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $active) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u keepalived.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[keepalived $hostName] keepalived.service did not reach active within 2 min"
      }

      # If we're the MASTER candidate (priority 110), check VIP binds within ~10s.
      # If we're the BACKUP, VIP should NOT bind (proxysql-1 holds it).
      if ($role -eq 'MASTER') {
        Write-Host "[keepalived $hostName] waiting for VIP $vip to bind on nic0 (MASTER role)..."
        $vipDeadline = (Get-Date).AddSeconds(15)
        $bound = $false
        while ((Get-Date) -lt $vipDeadline) {
          $ipShow = (ssh @sshOpts "$sshUser@$ip" "ip -4 addr show dev nic0 2>/dev/null" | Out-String)
          if ($ipShow -match [regex]::Escape($vip)) { $bound = $true; break }
          Start-Sleep -Seconds 2
        }
        if (-not $bound) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u keepalived.service --no-pager -n 20" 2>&1 | Out-String)
          Write-Host $journal
          throw "[keepalived $hostName] VIP $vip did not bind on nic0 within 15s (MASTER)"
        }
        Write-Host "[keepalived $hostName] VIP $vip bound on nic0 (MASTER) -- ready to serve VIP traffic on :6033"
      } else {
        Write-Host "[keepalived $hostName] BACKUP role -- not expected to hold VIP. keepalived active + standing by."
      }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[keepalived destroy] $${hostName}: stopping keepalived + removing config + health script"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now keepalived.service 2>/dev/null; sudo rm -f /etc/keepalived/keepalived.conf /etc/keepalived/check_proxysql.sh" 2>$null
      exit 0
    PWSH
  }
}
