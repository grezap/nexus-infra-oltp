# Phase 0.N per-host nftables. Opens role-specific MongoDB ports + VMnet10
# whole-segment trust (cluster backplane). configsvr listens on 27019,
# shardsvr on 27018, mongos on 27017. Ports follow MongoDB convention.

locals {
  # Per-host rendered ruleset with role-specific listening port.
  mongo_sharded_nftables = {
    for host, spec in local.sharded_nodes_active : host => <<-NFT
      #!/usr/sbin/nft -f
      # Managed by nexus-infra-oltp/terraform/envs/oltp-mongo-sharded/role-overlay-mongo-nftables-backplane.tf
      # role=${spec.role} rs=${spec.rs_name} port=${spec.port}
      flush ruleset

      table inet filter {
        chain input {
          type filter hook input priority filter; policy drop;
          ct state established,related accept
          ct state invalid drop
          iif "lo" accept
          meta l4proto icmp accept
          meta l4proto ipv6-icmp accept

          iifname "nic0" tcp dport 22 accept
          iifname "nic0" tcp dport ${spec.port} accept

          iifname "nic1" ip saddr 192.168.10.0/24 accept
          counter drop
        }
        chain forward { type filter hook forward priority filter; policy drop; }
        chain output  { type filter hook output  priority filter; policy accept; }
      }
    NFT
  }
}

resource "null_resource" "mongo_nftables" {
  for_each = var.enable_nftables_backplane ? local.sharded_nodes_active : {}

  triggers = {
    vmnet11     = each.value.vmnet11
    role        = each.value.role
    port        = each.value.port
    ruleset_sha = sha256(local.mongo_sharded_nftables[each.key])
    overlay_v   = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [
    module.mongo_cfg_1, module.mongo_cfg_2, module.mongo_cfg_3,
    module.mongo_shard_1_1, module.mongo_shard_1_2, module.mongo_shard_1_3,
    module.mongo_shard_2_1, module.mongo_shard_2_2, module.mongo_shard_2_3,
    module.mongo_mongos_1, module.mongo_mongos_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $user     = '${var.oltp_node_user}'
      $timeout  = ${var.oltp_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.mongo_sharded_nftables[each.key]}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      Write-Host "[nftables $hostName] waiting for SSH + firstboot marker..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $ready = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $ready = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $ready) { throw "[nftables $hostName] SSH + firstboot marker never ready after $timeout min" }

      Write-Host "[nftables $hostName] pushing ruleset (port=${each.value.port}) + nft -f"
      $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
      $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
      if ($out -notmatch 'NFT_OK') { throw "[nftables $hostName] ruleset push failed -- $out" }
      Write-Host "[nftables $hostName] applied"
    PWSH
  }
}
