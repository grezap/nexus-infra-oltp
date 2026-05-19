/*
 * role-overlay-haproxy-keepalived.tf -- Phase 0.G.4 -- VRRP-floated VIP
 *   for HAProxy HA pair via keepalived.
 *
 * Drops /etc/keepalived/keepalived.conf on both haproxy-pg-1 + haproxy-pg-2
 * + a health script that confirms HAProxy is alive before claiming MASTER.
 * Runs AFTER role-overlay-haproxy-config.tf (the HAProxy service must be
 * up + healthy before keepalived starts advertising the VIP).
 *
 * Mirrors the 0.G.3 role-overlay-proxysql-keepalived.tf shape verbatim --
 * same unicast pattern (multicast 224.0.0.18 doesn't reliably traverse
 * VMware Workstation VMnet11 between guests; lesson baked at 0.G.3.5c chunk
 * 1 ratification 2026-05-18 transient #22).
 *
 * --- VIP design ---
 *
 *   Virtual IP:    var.haproxy_vip (default 192.168.70.60, per
 *                  nexus-platform-plan/docs/infra/vms.yaml postgres.
 *                  virtual_ips.haproxy_pg_vip)
 *   Subnet:        192.168.70.0/24
 *   Interface:     nic0 (VMnet11 service NIC)
 *   VRRP instance: VI_HAPROXY_NEXUS (instance ID 60 = VIP last octet;
 *                  distinct from 51 used by the proxysql pair)
 *   Auth:          AH 8-char password derived from haproxy-stats-password
 *                  (same on both nodes; both nodes have it rendered by
 *                  Vault Agent at /etc/nexus-haproxy/haproxy-stats-password)
 *   Advert int:    1 second
 *   Priority:      haproxy-pg-1 = 110 (MASTER candidate)
 *                  haproxy-pg-2 = 100 (BACKUP)
 *
 *   Failover behavior: haproxy-pg-1 holds the VIP by default (higher
 *   priority). If haproxy-pg-1's health script fails (HAProxy not running OR
 *   admin socket unresponsive), priority demotes by weight=-30 -> effective
 *   priority 80, < haproxy-pg-2's 100, so VIP flips to haproxy-pg-2 within
 *   ~1 advert interval. When haproxy-pg-1 recovers, advertisements resume
 *   at 110 + preempt back to MASTER.
 *
 * --- Health script ---
 *
 *   /etc/keepalived/check_haproxy.sh
 *     - systemctl is-active --quiet nexus-haproxy.service
 *     - echo 'show info' | socat - UNIX-CONNECT:/run/nexus-haproxy/admin.sock
 *       proves haproxy is responsive on its admin socket
 *     Returns 0 if both pass, non-zero otherwise.
 *
 *   Called every 2s by keepalived's vrrp_script -- on 3 consecutive
 *   failures, weight -30 fires (effective priority drops).
 *
 * --- Reachability ---
 *
 *   nftables (overlay v2) opens proto 112 (VRRP) on nic0 + the multicast
 *   acceptance rule (belt+braces -- we use unicast for actual delivery).
 *
 * --- Verification ---
 *
 *   1. keepalived.service active on both nodes
 *   2. `ip -4 addr show dev nic0` on haproxy-pg-1 shows var.haproxy_vip
 *      (secondary scope) within ~5s of service start
 *   3. `ip -4 addr show dev nic0` on haproxy-pg-2 does NOT show the VIP
 *   4. From build host: `psql -h <vip> -p 5432 ...` works
 *
 * Selective ops: var.enable_haproxy_keepalived AND var.enable_haproxy_config.
 */

locals {
  haproxy_keepalived_per_host = {
    "haproxy-pg-1" = { vmnet11 = "192.168.70.67", peer = "192.168.70.68", priority = "110", role = "MASTER" }
    "haproxy-pg-2" = { vmnet11 = "192.168.70.68", peer = "192.168.70.67", priority = "100", role = "BACKUP" }
  }

  haproxy_keepalived_active = {
    for host, spec in local.haproxy_keepalived_per_host : host => spec
    if(
      var.enable_haproxy_keepalived && var.enable_haproxy_config
      && lookup(local.haproxy_nodes_active, host, null) != null
    )
  }
}

resource "null_resource" "haproxy_keepalived" {
  for_each = local.haproxy_keepalived_active

  triggers = {
    haproxy_id   = null_resource.haproxy_config[each.key].id
    vmnet11      = each.value.vmnet11
    priority     = each.value.priority
    vip          = var.haproxy_vip
    peer_ip      = each.value.peer
    keepalived_v = "1" # v1 (0.G.4) = initial 2-instance unicast VRRP for VIP .60 between haproxy-pg-1 (MASTER 110) and haproxy-pg-2 (BACKUP 100). Unicast from day one per the 0.G.3 transient #22 lesson (multicast doesn't traverse VMnet11).

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.haproxy_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $peerIp   = '${each.value.peer}'
      $priority = '${each.value.priority}'
      $role     = '${each.value.role}'
      $vip      = '${var.haproxy_vip}'
      $sshUser  = '${var.oltp_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[haproxy-keepalived $hostName] configuring VRRP instance VI_HAPROXY_NEXUS (role=$role, priority=$priority, vip=$vip)..."

      # Read haproxy-stats-password to derive VRRP AH auth password (8 chars
      # max per VRRP spec; truncate from the 32-char hex). Both haproxy nodes
      # have the same value rendered by Vault Agent so VRRP peers authenticate
      # each other's advertisements.
      $statsPwd = (ssh @sshOpts "$sshUser@$ip" 'sudo cat /etc/nexus-haproxy/haproxy-stats-password' | Out-String).Trim()
      if (-not $statsPwd -or $statsPwd.Length -lt 16) {
        throw "[haproxy-keepalived $hostName] haproxy-stats-password missing -- TLS overlay must have run first."
      }
      $vrrpAuthPwd = $statsPwd.Substring(0, 8)

      # ─── Health check script ─────────────────────────────────────────────
      # 2-check: systemctl active + admin-socket responsive. Both must pass.
      $checkScript = @'
#!/bin/bash
# Phase 0.G.4 health check for keepalived VRRP MASTER election.
# Returns 0 if nexus-haproxy is alive + serving on its admin socket.
set -e
if ! systemctl is-active --quiet nexus-haproxy.service; then
  exit 1
fi
# Probe HAProxy admin socket -- proves the daemon is responsive (not just
# the systemd unit pid still around). 2s socat timeout to keep VRRP fast.
out=$(timeout 2 bash -c 'echo show info | socat - UNIX-CONNECT:/run/nexus-haproxy/admin.sock 2>/dev/null' || true)
if echo "$out" | grep -q "^Name: HAProxy"; then
  exit 0
fi
exit 1
'@

      $checkScriptB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($checkScript -replace "`r`n","`n")))

      # ─── keepalived.conf ─────────────────────────────────────────────────
      $kpConf = @"
# Generated by nexus-infra-oltp/terraform/envs/oltp-patroni/role-overlay-haproxy-keepalived.tf
# Phase 0.G.4 -- VRRP VIP failover for HAProxy HA pair on $hostName (role=$role).
# DO NOT EDIT BY HAND.

global_defs {
  router_id  haproxy_nexus_$hostName
  enable_script_security
  script_user root
}

vrrp_script chk_haproxy {
  script   "/etc/keepalived/check_haproxy.sh"
  interval 2
  timeout  3
  rise     2
  fall     3
  weight   -30
}

vrrp_instance VI_HAPROXY_NEXUS {
  state         $role
  interface     nic0
  virtual_router_id 60
  priority      $priority
  advert_int    1
  preempt_delay 5

  # Unicast VRRP -- multicast 224.0.0.18 doesn't reliably forward across
  # VMware Workstation VMnet11; both nodes would go split-brain MASTER.
  # Unicast sends advertisements directly to the peer's VMnet11 IP. Same
  # lesson as the 0.G.3 proxysql-keepalived overlay (transient #22).
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
    chk_haproxy
  }
}
"@

      $kpConfB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kpConf -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail

# keepalived is baked into the oltp-haproxy-node Packer template; defensive
# install for partial-apply scenarios.
if ! command -v keepalived >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq keepalived
fi

sudo install -d -o root -g root -m 0755 /etc/keepalived

echo '$checkScriptB64' | base64 -d | sudo tee /etc/keepalived/check_haproxy.sh > /dev/null
sudo chown root:root /etc/keepalived/check_haproxy.sh
sudo chmod 0700 /etc/keepalived/check_haproxy.sh

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
        throw "[haproxy-keepalived $hostName] config / service start failed (rc=$LASTEXITCODE)"
      }

      # Verify keepalived active + (on MASTER candidate only) VIP bound.
      Write-Host "[haproxy-keepalived $hostName] waiting for keepalived.service active..."
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
        throw "[haproxy-keepalived $hostName] keepalived.service did not reach active within 2 min"
      }

      if ($role -eq 'MASTER') {
        Write-Host "[haproxy-keepalived $hostName] waiting for VIP $vip to bind on nic0 (MASTER role)..."
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
          throw "[haproxy-keepalived $hostName] VIP $vip did not bind on nic0 within 15s (MASTER)"
        }
        Write-Host "[haproxy-keepalived $hostName] VIP $vip bound on nic0 (MASTER) -- ready to serve VIP traffic on :5432"
      } else {
        Write-Host "[haproxy-keepalived $hostName] BACKUP role -- not expected to hold VIP. keepalived active + standing by."
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
      Write-Host "[haproxy-keepalived destroy] $${hostName}: stopping keepalived + removing config + health script"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now keepalived.service 2>/dev/null; sudo rm -f /etc/keepalived/keepalived.conf /etc/keepalived/check_haproxy.sh" 2>$null
      exit 0
    PWSH
  }
}
