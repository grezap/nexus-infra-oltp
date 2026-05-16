/*
 * role-overlay-oltp-nftables-backplane.tf -- push the oltp-node nftables
 * ruleset to every redis node + `nft -f` for atomic replacement.
 *
 * Same shape as nexus-infra-kafka's role-overlay-nftables-backplane.tf:
 *   - Per memory/feedback_nftables_runtime_add_after_drop.md: patch the file
 *     + `nft -f` (atomic replace, also persistent). Never runtime `nft add`
 *     (lands after the counter-drop, unreachable).
 *   - Per memory/feedback_cluster_template_nftables_backplane.md: every
 *     dual-NIC cluster template MUST add `iifname "nic1" ip saddr <vmnet10>
 *     accept` rules; ping works without them but TCP doesn't, and Redis
 *     Cluster cluster bus (16379) silently never converges.
 *   - SSH transit: LF-normalized plaintext piped to ssh stdin + `bash -s`
 *     with `tr -d '\r'` (memory/feedback_pwsh_ssh_stdin_cr_injection.md +
 *     feedback_ssh_stage1_size_limit.md).
 *
 * Ports opened:
 *   - 22       (sshd; build-host reachability invariant per
 *               memory/feedback_lab_host_reachability.md -- never close this)
 *   - 6379     (Redis TLS data port)
 *   - 16379    (Redis Cluster bus -- gossip + failover voting; full mesh
 *               between all 6 nodes)
 *   - VMnet10  (whole-segment trust -- mirrors kafka's nic1 trust pattern;
 *               cluster bus + replication run here)
 *
 * Ruleset is inlined here as a local (NOT read from a Packer-baked file like
 * kafka does) -- the 3d oltp-node Packer template bakes a baseline copy at
 * /etc/nftables.conf as a cold-clone safety net, but the canonical source of
 * truth is this TF (the overlay always converges to whatever ruleset is
 * inlined here on every apply, so a tweak is a TF change + re-apply, no
 * Packer rebuild needed).
 *
 * Selective ops: var.enable_redis AND var.enable_nftables_backplane.
 */

locals {
  # Enabled redis-node VMnet11 IPs (the ssh target set).
  redis_node_ips = compact([
    var.enable_redis_1 ? "192.168.70.81" : "",
    var.enable_redis_2 ? "192.168.70.82" : "",
    var.enable_redis_3 ? "192.168.70.83" : "",
    var.enable_redis_4 ? "192.168.70.84" : "",
    var.enable_redis_5 ? "192.168.70.87" : "",
    var.enable_redis_6 ? "192.168.70.89" : "",
  ])

  # Inlined oltp-node nftables ruleset. Whole-segment VMnet10 trust + the
  # operator/data ports on VMnet11. Mirrors deb13 baseline + kafka-node shape.
  oltp_nftables_ruleset = <<-NFT
    #!/usr/sbin/nft -f
    # Managed by nexus-infra-oltp/terraform/envs/oltp/role-overlay-oltp-nftables-backplane.tf
    # DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
    # ruleset_v=1

    flush ruleset

    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        iif "lo" accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        # ─── VMnet11 service network (mgmt + Redis clients) ────────────────
        iifname "nic0" tcp dport 22 accept    # sshd (build-host reachability)
        iifname "nic0" tcp dport 6379 accept  # Redis TLS data port
        iifname "nic0" tcp dport 16379 accept # Redis Cluster bus (cross-tier MM2-style traffic later)

        # ─── VMnet10 cluster backplane (whole-segment trust) ────────────────
        # Mirrors nexus-infra-swarm-nomad's swarm-node + nexus-infra-kafka's
        # kafka-node "whole-segment accept" pattern. Cluster bus (16379) +
        # replication (6379) flow over the backplane.
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

resource "null_resource" "oltp_nftables_backplane" {
  count = var.enable_redis && var.enable_nftables_backplane ? 1 : 0

  triggers = {
    redis_1     = length(module.redis_1) > 0 ? module.redis_1[0].vm_name : "absent"
    redis_2     = length(module.redis_2) > 0 ? module.redis_2[0].vm_name : "absent"
    redis_3     = length(module.redis_3) > 0 ? module.redis_3[0].vm_name : "absent"
    redis_4     = length(module.redis_4) > 0 ? module.redis_4[0].vm_name : "absent"
    redis_5     = length(module.redis_5) > 0 ? module.redis_5[0].vm_name : "absent"
    redis_6     = length(module.redis_6) > 0 ? module.redis_6[0].vm_name : "absent"
    ruleset_sha = sha256(local.oltp_nftables_ruleset)
    overlay_v   = "1" # v1 (0.G.1) = initial 6-node Redis Cluster ruleset.
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

      # Inlined ruleset, LF-normalized for stdin transit.
      $ruleset = @'
${local.oltp_nftables_ruleset}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      if ($ips.Count -eq 0 -or $ips[0] -eq '') {
        Write-Host "[oltp-nftables] no enabled redis nodes -- nothing to do"
        exit 0
      }

      foreach ($ip in $ips) {
        # Wait for SSH + the oltp-node firstboot marker (firstboot must have
        # renamed the NICs + set up the VMnet10 backplane before the ruleset's
        # nic1 rule means anything).
        Write-Host "[oltp-nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[oltp-nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[oltp-nftables] $${ip}: pushing ruleset + nft -f"
        # Pipe the LF-normalized ruleset to a remote command that strips any
        # residual CR, writes /etc/nftables.conf atomically, reloads, and
        # ensures the nftables unit is enabled. ssh runs the command string
        # with the piped ruleset on its stdin.
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[oltp-nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[oltp-nftables] $${ip}: ruleset applied"
      }

      Write-Host "[oltp-nftables] all $($ips.Count) redis-node(s) converged on the oltp-node ruleset"
    PWSH
  }
}
