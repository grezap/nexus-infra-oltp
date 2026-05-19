/*
 * role-overlay-patroni-nftables-backplane.tf -- per-cluster nftables for
 * the 8 patroni-tier nodes (3 Patroni + 3 etcd + 2 HAProxy HA pair).
 * Phase 0.G.4.
 *
 * Ports opened on VMnet11 (service):
 *   - 22       sshd
 *   - 5432     PostgreSQL (PG accept on patroni nodes + HAProxy frontend on both haproxy-pg-{1,2})
 *   - 8008     Patroni REST (only patroni nodes listen; HAProxy dials this for health probes)
 *   - 2379     etcd client API (only etcd nodes listen; Patroni dials this for DCS)
 *   - 2380     etcd peer raft (only etcd nodes listen; mesh between members)
 *   - 8404     HAProxy stats UI (only haproxy-pg-{1,2} listen)
 *   - proto 112 + 224.0.0.18 multicast: VRRP for keepalived between the
 *     HAProxy HA pair (unicast in practice -- VMware VMnet11 multicast
 *     doesn't traverse reliably -- but the rules are harmless on the
 *     non-HAProxy hosts and the multicast accept is defense-in-depth).
 *
 * VMnet10 whole-segment trust: streaming replication + etcd raft + Patroni
 * REST cross-calls + VRRP unicast between haproxy-pg-1/-2 ride the backplane.
 */

locals {
  patroni_node_ips = compact([
    var.enable_pg_primary ? "192.168.70.61" : "",
    var.enable_pg_replica_1 ? "192.168.70.62" : "",
    var.enable_pg_replica_2 ? "192.168.70.63" : "",
    var.enable_etcd_1 ? "192.168.70.64" : "",
    var.enable_etcd_2 ? "192.168.70.65" : "",
    var.enable_etcd_3 ? "192.168.70.66" : "",
    var.enable_haproxy_pg_1 ? "192.168.70.67" : "",
    var.enable_haproxy_pg_2 ? "192.168.70.68" : "",
  ])

  patroni_nftables_ruleset = <<-NFT
    #!/usr/sbin/nft -f
    # Managed by nexus-infra-oltp/terraform/envs/oltp-patroni/role-overlay-patroni-nftables-backplane.tf
    # DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
    # ruleset_v=2 (per-cluster patroni scope; +HAProxy HA pair VRRP)

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
        iifname "nic0" tcp dport 5432 accept  # PostgreSQL (PG accept on patroni; HAProxy frontend on haproxy-pg-{1,2})
        iifname "nic0" tcp dport 8008 accept  # Patroni REST (only patroni nodes listen)
        iifname "nic0" tcp dport 2379 accept  # etcd client API (only etcd nodes listen)
        iifname "nic0" tcp dport 2380 accept  # etcd peer raft (only etcd nodes listen)
        iifname "nic0" tcp dport 8404 accept  # HAProxy stats UI (only haproxy-pg-{1,2})
        iifname "nic0" tcp dport 9100 accept  # node_exporter

        # VRRP for keepalived between haproxy-pg-1/haproxy-pg-2 (unicast in
        # practice on this lab; multicast advertised here as belt+braces).
        iifname "nic0" ip protocol 112 accept                      # VRRP unicast
        iifname "nic0" ip daddr 224.0.0.18 ip protocol 112 accept  # VRRP multicast advertisements

        # VMnet10 cluster backplane: streaming replication + etcd raft mesh +
        # Patroni REST cross-calls + pg_basebackup + VRRP unicast.
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

resource "null_resource" "patroni_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    pg_primary   = length(module.pg_primary) > 0 ? module.pg_primary[0].vm_name : "absent"
    pg_replica_1 = length(module.pg_replica_1) > 0 ? module.pg_replica_1[0].vm_name : "absent"
    pg_replica_2 = length(module.pg_replica_2) > 0 ? module.pg_replica_2[0].vm_name : "absent"
    etcd_1       = length(module.etcd_1) > 0 ? module.etcd_1[0].vm_name : "absent"
    etcd_2       = length(module.etcd_2) > 0 ? module.etcd_2[0].vm_name : "absent"
    etcd_3       = length(module.etcd_3) > 0 ? module.etcd_3[0].vm_name : "absent"
    haproxy_pg_1 = length(module.haproxy_pg_1) > 0 ? module.haproxy_pg_1[0].vm_name : "absent"
    haproxy_pg_2 = length(module.haproxy_pg_2) > 0 ? module.haproxy_pg_2[0].vm_name : "absent"
    ruleset_sha  = sha256(local.patroni_nftables_ruleset)
    overlay_v    = "2"
  }

  depends_on = [
    module.pg_primary, module.pg_replica_1, module.pg_replica_2,
    module.etcd_1, module.etcd_2, module.etcd_3,
    module.haproxy_pg_1, module.haproxy_pg_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.patroni_node_ips)}')
      $user    = '${var.oltp_node_user}'
      $timeout = ${var.oltp_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.patroni_nftables_ruleset}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      if ($ips.Count -eq 0 -or $ips[0] -eq '') {
        Write-Host "[patroni-nftables] no enabled patroni-tier nodes -- nothing to do"
        exit 0
      }

      foreach ($ip in $ips) {
        Write-Host "[patroni-nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[patroni-nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[patroni-nftables] $${ip}: pushing ruleset + nft -f"
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[patroni-nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[patroni-nftables] $${ip}: ruleset applied"
      }

      Write-Host "[patroni-nftables] all $($ips.Count) patroni-tier node(s) converged on the per-cluster ruleset"
    PWSH
  }
}
