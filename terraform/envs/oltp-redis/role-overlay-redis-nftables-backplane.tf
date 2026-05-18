/*
 * role-overlay-redis-nftables-backplane.tf -- push the per-cluster nftables
 * ruleset to the 6 redis nodes + `nft -f` for atomic replacement.
 *
 * Per-cluster scope per Phase 0.G.3.5b refactor (memory/feedback_per_cluster_
 * state_per_engine_template.md). Replaces the monolithic role-overlay-oltp-
 * nftables-backplane.tf which pushed a SHARED ruleset to all 14 OLTP nodes
 * (one v2->v3 version bump cascaded replacement through every cluster's
 * vault-agent + tls + config + cluster-create overlays -- the very issue
 * the 0.G.3.5 refactor is solving).
 *
 * Ports opened (redis-only):
 *   - 22       sshd (build-host reachability invariant per memory/feedback_
 *              lab_host_reachability.md -- never close)
 *   - 6379     Redis TLS data port
 *   - 16379    Redis Cluster bus (gossip + failover voting; full mesh)
 *   - VMnet10  whole-segment trust (cluster bus + replication backplane)
 */

locals {
  redis_node_ips = compact([
    var.enable_redis_1 ? "192.168.70.81" : "",
    var.enable_redis_2 ? "192.168.70.82" : "",
    var.enable_redis_3 ? "192.168.70.83" : "",
    var.enable_redis_4 ? "192.168.70.84" : "",
    var.enable_redis_5 ? "192.168.70.87" : "",
    var.enable_redis_6 ? "192.168.70.89" : "",
  ])

  redis_nftables_ruleset = <<-NFT
    #!/usr/sbin/nft -f
    # Managed by nexus-infra-oltp/terraform/envs/oltp-redis/role-overlay-redis-nftables-backplane.tf
    # DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
    # ruleset_v=1 (per-cluster redis scope; the legacy shared monolithic
    # ruleset_v reached v3 before the 0.G.3.5 split)

    flush ruleset

    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        iif "lo" accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        # VMnet11 service network: sshd + redis data port + cluster bus
        iifname "nic0" tcp dport 22 accept    # sshd (build-host reachability)
        iifname "nic0" tcp dport 6379 accept  # Redis TLS data port
        iifname "nic0" tcp dport 16379 accept # Redis Cluster bus

        # VMnet10 cluster backplane: whole-segment trust (replication +
        # cluster bus future scale-out)
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

resource "null_resource" "redis_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    redis_1     = length(module.redis_1) > 0 ? module.redis_1[0].vm_name : "absent"
    redis_2     = length(module.redis_2) > 0 ? module.redis_2[0].vm_name : "absent"
    redis_3     = length(module.redis_3) > 0 ? module.redis_3[0].vm_name : "absent"
    redis_4     = length(module.redis_4) > 0 ? module.redis_4[0].vm_name : "absent"
    redis_5     = length(module.redis_5) > 0 ? module.redis_5[0].vm_name : "absent"
    redis_6     = length(module.redis_6) > 0 ? module.redis_6[0].vm_name : "absent"
    ruleset_sha = sha256(local.redis_nftables_ruleset)
    overlay_v   = "1" # v1 (0.G.3.5b) = per-cluster redis-only ruleset.
  }

  depends_on = [
    module.redis_1, module.redis_2, module.redis_3,
    module.redis_4, module.redis_5, module.redis_6,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.redis_node_ips)}')
      $user    = '${var.oltp_node_user}'
      $timeout = ${var.oltp_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.redis_nftables_ruleset}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      if ($ips.Count -eq 0 -or $ips[0] -eq '') {
        Write-Host "[redis-nftables] no enabled redis nodes -- nothing to do"
        exit 0
      }

      foreach ($ip in $ips) {
        Write-Host "[redis-nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[redis-nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[redis-nftables] $${ip}: pushing ruleset + nft -f"
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[redis-nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[redis-nftables] $${ip}: ruleset applied"
      }

      Write-Host "[redis-nftables] all $($ips.Count) redis node(s) converged on the per-cluster ruleset"
    PWSH
  }
}
