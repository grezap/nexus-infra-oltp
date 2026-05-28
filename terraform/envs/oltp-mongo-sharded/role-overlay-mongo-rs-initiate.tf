# Phase 0.N -- one-shot rs.initiate for the 3 replica sets (config, shard-1,
# shard-2). Mirrors the 0.G.2 RS pattern but iterates over 3 RSes.
#
# Per-RS choreography:
#   1. Probe rs.status() on the bootstrap node (first member). If ok:1,
#      skip (idempotent re-apply).
#   2. Otherwise run rs.initiate({_id: <name>, [configsvr: true,] members: [...]}).
#      Config-server RS gets the configsvr:true flag.
#   3. Wait for 1 PRIMARY + 2 SECONDARY + all health:1.
#
# Auth: bootstrap uses no auth (rs.initiate is the one cluster command
# permitted pre-auth on a fresh cluster). After init, all further commands
# require __system cluster auth via the keyFile content (MongoDB 8.0 +
# keyFile + authorization=enabled disables the localhost-exception, per
# the 0.G.2 finding -- see role-overlay-mongo-rs-initiate.tf v5+ in the
# oltp-mongo env for the diagnostic).

locals {
  # Per-RS bootstrap: pick the first node (by member-id 0) of each RS.
  # Build the rs.initiate members[] JS array.
  sharded_rs_defs = {
    config = {
      configsvr    = true
      bootstrap_ip = local.config_nodes["mongo-cfg-1"].vmnet11
      port         = local.config_nodes["mongo-cfg-1"].port
      members_js = join(",", [
        for i, host in keys(local.config_nodes) :
        format("{_id:%d,host:'%s:%d'}", i, local.config_nodes[host].vmnet11, local.config_nodes[host].port)
      ])
    }
    shard-1 = {
      configsvr    = false
      bootstrap_ip = local.shard_1_nodes["mongo-shard-1-1"].vmnet11
      port         = local.shard_1_nodes["mongo-shard-1-1"].port
      members_js = join(",", [
        for i, host in keys(local.shard_1_nodes) :
        format("{_id:%d,host:'%s:%d'}", i, local.shard_1_nodes[host].vmnet11, local.shard_1_nodes[host].port)
      ])
    }
    shard-2 = {
      configsvr    = false
      bootstrap_ip = local.shard_2_nodes["mongo-shard-2-1"].vmnet11
      port         = local.shard_2_nodes["mongo-shard-2-1"].port
      members_js = join(",", [
        for i, host in keys(local.shard_2_nodes) :
        format("{_id:%d,host:'%s:%d'}", i, local.shard_2_nodes[host].vmnet11, local.shard_2_nodes[host].port)
      ])
    }
  }

  # rs.initiate JS body per RS.
  sharded_rs_init_js = {
    for rs_name, def in local.sharded_rs_defs : rs_name => (
      def.configsvr ?
      format("rs.initiate({_id:'%s',configsvr:true,members:[%s]})", rs_name, def.members_js) :
      format("rs.initiate({_id:'%s',members:[%s]})", rs_name, def.members_js)
    )
  }

  # config-server config-id dependency for the data shards' init. Shards
  # don't strictly require the config-server RS to be initialized first
  # (sh.addShard is what cross-references them), but ordering it
  # deterministically simplifies debugging.
}

resource "null_resource" "mongo_rs_initiate" {
  for_each = (
    var.enable_mongo_rs_initiate && var.enable_mongo_config
  ) ? local.sharded_rs_defs : {}

  triggers = {
    # All config-overlay IDs for the cluster's nodes -- changes if any
    # node's mongod.conf changes (forces re-init verification).
    config_ids = jsonencode([
      for k in keys(null_resource.mongo_config) : null_resource.mongo_config[k].id
    ])
    rs_name      = each.key
    bootstrap_ip = each.value.bootstrap_ip
    overlay_v    = "1"
  }

  depends_on = [null_resource.mongo_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $rsName   = '${each.key}'
      $bootIp   = '${each.value.bootstrap_ip}'
      $port     = ${each.value.port}
      $sshUser  = '${var.oltp_node_user}'
      $timeout  = ${var.oltp_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[rs-initiate $rsName] bootstrap=$bootIp:$port"

      # Pre-read keyFile for __system cluster auth.
      $keyfileContent = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-mongo/keyfile 2>/dev/null' | Out-String).Trim()
      if (-not $keyfileContent -or $keyfileContent.Length -lt 100) {
        throw "[rs-initiate $rsName] keyfile missing or too short on $bootIp"
      }
      $sysAuthArgs = "--username __system --password '$keyfileContent' --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256"

      # Stage 1: probe rs.status() for existing healthy RS.
      $probeEval = "try{print(rs.status().ok)}catch(e){print(0)}"
      $probe = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$port --eval '$probeEval' 2>/dev/null" | Out-String).Trim()
      if ($probe -match '^1$') {
        Write-Host "[rs-initiate $rsName] already initialized (rs.status().ok=1); skipping init"
      } else {
        # rs.initiate is allowed pre-auth on a fresh cluster.
        $initJs = "${local.sharded_rs_init_js[each.key]}"
        Write-Host "[rs-initiate $rsName] running rs.initiate..."
        $initOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet --host 127.0.0.1:$port --eval `"printjson($initJs)`" 2>&1" | Out-String)
        if ($initOut -notmatch 'ok:\s*1') {
          Write-Host $initOut.Trim()
          throw "[rs-initiate $rsName] rs.initiate did not return ok:1"
        }
        Write-Host "[rs-initiate $rsName] rs.initiate ok:1"
      }

      # Stage 2: wait for 1 PRIMARY + 2 SECONDARY + all health:1.
      Write-Host "[rs-initiate $rsName] waiting for 1 PRIMARY + 2 SECONDARY + all health:1..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $healthy = $false
      $lastStatus = ""
      while ((Get-Date) -lt $deadline) {
        $statusEval = "var s=rs.status(); var p=0,sec=0,h=0; s.members.forEach(function(m){if(m.stateStr=='PRIMARY')p++; if(m.stateStr=='SECONDARY')sec++; if(m.health==1)h++}); print('PRIMARY='+p); print('SECONDARY='+sec); print('HEALTH='+h); print('MEMBERS='+s.members.length)"
        $lastStatus = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$port --eval `"$statusEval`" 2>/dev/null" | Out-String)
        if (
          $lastStatus -match '(?m)^PRIMARY=1\s*$' -and
          $lastStatus -match '(?m)^SECONDARY=2\s*$' -and
          $lastStatus -match '(?m)^HEALTH=3\s*$' -and
          $lastStatus -match '(?m)^MEMBERS=3\s*$'
        ) {
          $healthy = $true
          break
        }
        Start-Sleep -Seconds 5
      }
      if (-not $healthy) {
        Write-Host $lastStatus.Trim()
        throw "[rs-initiate $rsName] did not converge to 1 PRIMARY + 2 SECONDARY + 3 healthy within $timeout min"
      }
      Write-Host "[rs-initiate $rsName] OK -- 1 PRIMARY + 2 SECONDARY + 3 members healthy"
    PWSH
  }
}
