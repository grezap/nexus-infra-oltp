# Phase 0.N -- final step: register the 2 shard RSes with the config-server
# cluster via sh.addShard("<rs_name>/host1:port,host2:port,host3:port") run
# against any mongos. Once this lands, the sharded cluster is operational:
#   - Clients connect via mongos -> queries route to shards via config-server
#   - Sharded collections distribute chunks across the 2 shards
#   - sh.status() shows both shards + balancer ON
#
# Idempotent: sh.addShard errors with "shard already exists" if the shard is
# already registered. We catch that.

locals {
  # Per-shard URI: "<rs_name>/<host1>:<port>,<host2>:<port>,<host3>:<port>"
  shard_uris = {
    "shard-1" = format(
      "shard-1/%s",
      join(",", [for h, s in local.shard_1_nodes : "${s.vmnet11}:${s.port}"])
    )
    "shard-2" = format(
      "shard-2/%s",
      join(",", [for h, s in local.shard_2_nodes : "${s.vmnet11}:${s.port}"])
    )
  }

  # Bootstrap mongos -- pick mongos-1.
  add_shards_mongos_ip = (
    contains(keys(local.mongos_nodes), "mongo-mongos-1")
    ? local.mongos_nodes["mongo-mongos-1"].vmnet11
    : (length(keys(local.mongos_nodes)) > 0 ? local.mongos_nodes[keys(local.mongos_nodes)[0]].vmnet11 : "")
  )
  add_shards_mongos_port = (
    contains(keys(local.mongos_nodes), "mongo-mongos-1")
    ? local.mongos_nodes["mongo-mongos-1"].port
    : 27017
  )

  # Config-server RS connection -- used to create the cluster admin user.
  # __system (keyFile) auth works against mongod's `local` DB but NOT through
  # mongos ("Can't use 'local' database through mongos"). Sharded-cluster
  # client users live in the `admin` DB ON THE CONFIG SERVERS; mongos validates
  # client auth against them. So we createUser on the config-server PRIMARY (via
  # __system+local, which IS allowed on mongod) and then auth mongos operations
  # as that user against `admin`. Diagnosed live at 0.N ratification 2026-05-30
  # (handbook §3.N transient N9).
  config_bootstrap_ip = (
    contains(keys(local.config_nodes), "mongo-cfg-1")
    ? local.config_nodes["mongo-cfg-1"].vmnet11
    : (length(keys(local.config_nodes)) > 0 ? local.config_nodes[keys(local.config_nodes)[0]].vmnet11 : "")
  )
  config_rs_uri = format(
    "mongodb://%s/admin?replicaSet=config",
    join(",", [for h, s in local.config_nodes : "${s.vmnet11}:${s.port}"])
  )
  # Cluster admin user (root role). Password = the shared keyFile content
  # (already distributed to every node at /etc/nexus-mongo/keyfile -- avoids
  # introducing a new Vault secret for the lab; the 0.N.1 hardening that adds
  # mTLS would also move this to a dedicated Vault-seeded credential + x509).
  cluster_admin_user = "nexus-sharded-admin"
}

resource "null_resource" "mongo_add_shards" {
  count = (
    var.enable_mongo_add_shards
    && var.enable_mongo_rs_initiate
    && local.add_shards_mongos_ip != ""
  ) ? 1 : 0

  triggers = {
    rs_initiate_ids = jsonencode([
      for k in keys(null_resource.mongo_rs_initiate) : null_resource.mongo_rs_initiate[k].id
    ])
    shard_uris = jsonencode(local.shard_uris)
    overlay_v  = "1"
  }

  depends_on = [null_resource.mongo_rs_initiate]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $mongosIp   = '${local.add_shards_mongos_ip}'
      $mongosPort = ${local.add_shards_mongos_port}
      $sshUser    = '${var.oltp_node_user}'
      $timeout    = ${var.oltp_cluster_timeout_minutes}
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[add-shards] using mongos at $${mongosIp}:$mongosPort to register shards"

      # Pre-read keyFile (identical on every node). Used as the __system
      # password to createUser on the config server, and as the cluster-admin
      # user's password.
      $keyfileContent = (ssh @sshOpts "$sshUser@$mongosIp" 'sudo cat /etc/nexus-mongo/keyfile 2>/dev/null' | Out-String).Trim()
      if (-not $keyfileContent -or $keyfileContent.Length -lt 100) {
        throw "[add-shards] keyfile missing or too short on $mongosIp"
      }

      # ─── Create the cluster admin user on the config-server PRIMARY ────────
      # __system+local auth is allowed on mongod but REJECTED through mongos
      # ("Can't use 'local' database through mongos"). Sharded-cluster client
      # users live in the admin DB on the config servers; create the user there
      # via __system, then auth all mongos operations as that user against
      # admin. createUser is a write -> the config RS URI routes to PRIMARY.
      # Idempotent: catch "already exists".
      $cfgIp     = '${local.config_bootstrap_ip}'
      $cfgRsUri  = '${local.config_rs_uri}'
      $adminUser = '${local.cluster_admin_user}'
      $sysAuth   = "--username __system --password '$keyfileContent' --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256"
      Write-Host "[add-shards] ensuring cluster admin user '$adminUser' on the config-server RS (auth __system, routes to PRIMARY)..."
      $createEval = "try{db.getSiblingDB('admin').createUser({user:'$adminUser',pwd:'$keyfileContent',roles:[{role:'root',db:'admin'}]});print('USER_CREATED')}catch(e){if(e.codeName==='Location51003'||e.message.indexOf('already exists')>=0){print('USER_EXISTS')}else{print('USER_ERROR:'+e.message)}}"
      $createOut = (ssh @sshOpts "$sshUser@$cfgIp" "sudo mongosh --quiet $sysAuth '$cfgRsUri' --eval `"$createEval`" 2>&1" | Out-String).Trim()
      if ($createOut -match 'USER_CREATED') {
        Write-Host "[add-shards] cluster admin user '$adminUser' created"
      } elseif ($createOut -match 'USER_EXISTS') {
        Write-Host "[add-shards] cluster admin user '$adminUser' already exists (idempotent)"
      } else {
        Write-Host $createOut
        throw "[add-shards] failed to create cluster admin user '$adminUser': $createOut"
      }

      # All mongos operations auth as the cluster admin user against admin.
      $sysAuthArgs = "--username $adminUser --password '$keyfileContent' --authenticationDatabase admin"

      # Wait for mongos to be reachable (sh.status() runs via mongos).
      Write-Host "[add-shards] waiting for mongos to accept commands (auth $adminUser)..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $mongosUp = $false
      while ((Get-Date) -lt $deadline) {
        $ping = (ssh @sshOpts "$sshUser@$mongosIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$mongosPort --eval 'print(db.adminCommand({ping:1}).ok)' 2>/dev/null" | Out-String).Trim()
        if ($ping -match '^1$') { $mongosUp = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $mongosUp) {
        throw "[add-shards] mongos at $mongosIp did not become reachable within $timeout min"
      }
      Write-Host "[add-shards] mongos is up"

      # Add each shard. Catch "already exists" for idempotency.
      $shards = @{
        'shard-1' = '${local.shard_uris["shard-1"]}'
        'shard-2' = '${local.shard_uris["shard-2"]}'
      }

      foreach ($entry in $shards.GetEnumerator()) {
        $rsName  = $entry.Key
        $shardUri = $entry.Value
        Write-Host "[add-shards] sh.addShard('$shardUri')..."
        $addEval = "try{var r=sh.addShard('$shardUri');print('ADD_OK:'+JSON.stringify(r))}catch(e){if(e.codeName==='OperationFailed'||e.message.indexOf('already exists')>=0){print('ALREADY_EXISTS')}else{print('ADD_ERROR:'+e.message)}}"
        $addOut = (ssh @sshOpts "$sshUser@$mongosIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$mongosPort --eval `"$addEval`" 2>&1" | Out-String).Trim()
        if ($addOut -match 'ADD_OK') {
          Write-Host "[add-shards] $rsName added"
        } elseif ($addOut -match 'ALREADY_EXISTS') {
          Write-Host "[add-shards] $rsName already registered -- skipping"
        } else {
          Write-Host $addOut
          throw "[add-shards] failed to add $rsName"
        }
      }

      # Verify sh.status() shows both shards.
      Write-Host "[add-shards] verifying sh.status()..."
      $statusEval = "var s=sh.status({_internalView:true}); var c=0; if(typeof s!=='undefined'&&s.shards){c=s.shards.length}else{c=db.getSiblingDB('config').shards.countDocuments()}; print('SHARD_COUNT='+c)"
      $statusOut = (ssh @sshOpts "$sshUser@$mongosIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$mongosPort --eval `"$statusEval`" 2>&1" | Out-String).Trim()
      if ($statusOut -notmatch '(?m)^SHARD_COUNT=2\s*$') {
        Write-Host $statusOut
        throw "[add-shards] sh.status() did not report 2 shards -- got: $statusOut"
      }
      Write-Host "[add-shards] OK -- 2 shards registered (shard-1 + shard-2)"

      # Final exit gate: sharded collection round-trip.
      # Create db `nexus_n_smoke` + sharded collection `samples` keyed by _id
      # (hashed shard key for even chunk distribution).
      Write-Host "[add-shards] sharded-collection smoke -- enableSharding + shardCollection + insert + balanceData..."
      $smokeEval = "sh.enableSharding('nexus_n_smoke'); db.getSiblingDB('nexus_n_smoke').samples.createIndex({k:'hashed'}); sh.shardCollection('nexus_n_smoke.samples',{k:'hashed'}); var batch=[]; for(var i=0;i<200;i++){batch.push({k:i, v:'data-'+i})}; db.getSiblingDB('nexus_n_smoke').samples.insertMany(batch); print('INSERTED='+db.getSiblingDB('nexus_n_smoke').samples.countDocuments())"
      $smokeOut = (ssh @sshOpts "$sshUser@$mongosIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$mongosPort --eval `"$smokeEval`" 2>&1" | Out-String).Trim()
      if ($smokeOut -match '(?m)^INSERTED=200\s*$' -or $smokeOut -match '(?m)^INSERTED=200$') {
        Write-Host "[add-shards] sharded collection round-trip OK -- 200 docs inserted via mongos"
      } else {
        # Already-sharded case: enableSharding errors -> we just verify count.
        $countEval = "print('COUNT='+db.getSiblingDB('nexus_n_smoke').samples.countDocuments())"
        $countOut = (ssh @sshOpts "$sshUser@$mongosIp" "sudo mongosh --quiet $sysAuthArgs --host 127.0.0.1:$mongosPort --eval `"$countEval`" 2>&1" | Out-String).Trim()
        if ($countOut -match 'COUNT=(\d+)') {
          $count = [int]$Matches[1]
          if ($count -ge 200) {
            Write-Host "[add-shards] sharded collection nexus_n_smoke.samples already has $count docs (idempotent re-apply)"
          } else {
            Write-Host $smokeOut
            throw "[add-shards] sharded collection round-trip failed: $smokeOut"
          }
        } else {
          Write-Host $smokeOut
          throw "[add-shards] sharded collection round-trip failed: $smokeOut"
        }
      }
      Write-Host ""
      Write-Host "[add-shards] Phase 0.N sharded cluster operational -- 2 shards registered + sharded collection live"
    PWSH
  }
}
