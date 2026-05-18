/*
 * role-overlay-percona-nftables-backplane.tf -- per-cluster nftables for
 * the 5 percona-tier nodes (3 PXC + 2 ProxySQL). Phase 0.G.3.5b refactor.
 *
 * Ports opened:
 *   - 22       sshd
 *   - 3306     MySQL data port (PXC accepts direct; ProxySQL backends dial here)
 *   - 6032     ProxySQL admin
 *   - 6033     ProxySQL frontend MySQL
 *   - proto 112 + 224.0.0.18 multicast: VRRP for keepalived
 *   - VMnet10 whole-segment trust: Galera SST/IST runs here (4444/4567/4568)
 */

locals {
  percona_node_ips = compact([
    var.enable_pxc_node_1 ? "192.168.70.51" : "",
    var.enable_pxc_node_2 ? "192.168.70.52" : "",
    var.enable_pxc_node_3 ? "192.168.70.53" : "",
    var.enable_proxysql_1 ? "192.168.70.54" : "",
    var.enable_proxysql_2 ? "192.168.70.55" : "",
  ])

  percona_nftables_ruleset = <<-NFT
    #!/usr/sbin/nft -f
    # Managed by nexus-infra-oltp/terraform/envs/oltp-percona/role-overlay-percona-nftables-backplane.tf
    # DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
    # ruleset_v=1 (per-cluster percona scope)

    flush ruleset

    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        iif "lo" accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        # VMnet11 service network
        iifname "nic0" tcp dport 22 accept    # sshd
        iifname "nic0" tcp dport 3306 accept  # MySQL (PXC direct + ProxySQL backend dial)
        iifname "nic0" tcp dport 6032 accept  # ProxySQL admin (only ProxySQL nodes listen)
        iifname "nic0" tcp dport 6033 accept  # ProxySQL frontend

        # VRRP for keepalived between proxysql-1/proxysql-2
        iifname "nic0" ip protocol 112 accept                       # VRRP unicast
        iifname "nic0" ip daddr 224.0.0.18 ip protocol 112 accept   # VRRP multicast advertisements

        # VMnet10 cluster backplane: Galera SST (4444) + replication (4567) + IST (4568)
        iifname "nic1" ip saddr 192.168.10.0/24 accept

        counter drop
      }

      chain forward {
        type filter hook forward priority filter; policy drop;
      }

      chain output {
        type filter hook output priority filter; policy accept;
      }
    }
  NFT
}

resource "null_resource" "percona_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    pxc_node_1  = length(module.pxc_node_1) > 0 ? module.pxc_node_1[0].vm_name : "absent"
    pxc_node_2  = length(module.pxc_node_2) > 0 ? module.pxc_node_2[0].vm_name : "absent"
    pxc_node_3  = length(module.pxc_node_3) > 0 ? module.pxc_node_3[0].vm_name : "absent"
    proxysql_1  = length(module.proxysql_1) > 0 ? module.proxysql_1[0].vm_name : "absent"
    proxysql_2  = length(module.proxysql_2) > 0 ? module.proxysql_2[0].vm_name : "absent"
    ruleset_sha = sha256(local.percona_nftables_ruleset)
    overlay_v   = "1"
  }

  depends_on = [
    module.pxc_node_1, module.pxc_node_2, module.pxc_node_3,
    module.proxysql_1, module.proxysql_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.percona_node_ips)}')
      $user    = '${var.oltp_node_user}'
      $timeout = ${var.oltp_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.percona_nftables_ruleset}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      if ($ips.Count -eq 0 -or $ips[0] -eq '') {
        Write-Host "[percona-nftables] no enabled percona nodes -- nothing to do"
        exit 0
      }

      foreach ($ip in $ips) {
        Write-Host "[percona-nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[percona-nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[percona-nftables] $${ip}: pushing ruleset + nft -f"
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[percona-nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[percona-nftables] $${ip}: ruleset applied"
      }

      Write-Host "[percona-nftables] all $($ips.Count) percona-tier node(s) converged on the per-cluster ruleset"
    PWSH
  }
}
