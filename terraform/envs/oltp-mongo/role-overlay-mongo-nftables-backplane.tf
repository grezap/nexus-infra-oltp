/*
 * role-overlay-mongo-nftables-backplane.tf -- per-cluster nftables for the
 * 3 mongo nodes. Phase 0.G.3.5b refactor (memory/feedback_per_cluster_
 * state_per_engine_template.md).
 *
 * Ports opened (mongo-only):
 *   - 22       sshd (build-host reachability invariant)
 *   - 27017    MongoDB TLS data port (also serves RS heartbeat/replication/
 *              election traffic between members on the same port)
 *   - VMnet10  whole-segment trust (future scale-out)
 */

locals {
  mongo_node_ips = compact([
    var.enable_mongo_1 ? "192.168.70.71" : "",
    var.enable_mongo_2 ? "192.168.70.72" : "",
    var.enable_mongo_3 ? "192.168.70.73" : "",
  ])

  mongo_nftables_ruleset = <<-NFT
    #!/usr/sbin/nft -f
    # Managed by nexus-infra-oltp/terraform/envs/oltp-mongo/role-overlay-mongo-nftables-backplane.tf
    # DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
    # ruleset_v=1 (per-cluster mongo scope)

    flush ruleset

    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        iif "lo" accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        iifname "nic0" tcp dport 22 accept    # sshd
        iifname "nic0" tcp dport 27017 accept # MongoDB TLS + RS traffic

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

resource "null_resource" "mongo_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    mongo_1     = length(module.mongo_1) > 0 ? module.mongo_1[0].vm_name : "absent"
    mongo_2     = length(module.mongo_2) > 0 ? module.mongo_2[0].vm_name : "absent"
    mongo_3     = length(module.mongo_3) > 0 ? module.mongo_3[0].vm_name : "absent"
    ruleset_sha = sha256(local.mongo_nftables_ruleset)
    overlay_v   = "1"
  }

  depends_on = [module.mongo_1, module.mongo_2, module.mongo_3]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.mongo_node_ips)}')
      $user    = '${var.oltp_node_user}'
      $timeout = ${var.oltp_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.mongo_nftables_ruleset}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      if ($ips.Count -eq 0 -or $ips[0] -eq '') {
        Write-Host "[mongo-nftables] no enabled mongo nodes -- nothing to do"
        exit 0
      }

      foreach ($ip in $ips) {
        Write-Host "[mongo-nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[mongo-nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[mongo-nftables] $${ip}: pushing ruleset + nft -f"
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[mongo-nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[mongo-nftables] $${ip}: ruleset applied"
      }

      Write-Host "[mongo-nftables] all $($ips.Count) mongo node(s) converged on the per-cluster ruleset"
    PWSH
  }
}
