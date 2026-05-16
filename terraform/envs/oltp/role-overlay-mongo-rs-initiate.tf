/*
 * role-overlay-mongo-rs-initiate.tf -- Phase 0.G.2 exit gate
 *
 * One-shot probe-then-init that brings the 3-member MongoDB replica set
 * online + verifies health.
 *
 * Idempotency:
 *   The probe `rs.status().ok` returns 1 if the RS is initialized + the
 *   probing node is a member; returns 0 / errors otherwise. If RS is
 *   already healthy, init is skipped. If not, init runs from mongo-1.
 *
 * Why probe-then-init (vs unconditional):
 *   rs.initiate() is one-shot per node lifetime. Re-running on a node
 *   already in a healthy RS errors with `already initialized`. The probe
 *   guards against that.
 *
 * Bootstrap:
 *   Runs from mongo-1 (an arbitrary member; any would work since the RS
 *   isn't formed yet -- the localhost exception + mTLS combo lets the
 *   initial admin command through). The init document names all 3
 *   members by VMnet11 IP+port:
 *     rs.initiate({
 *       _id: "nexus-rs",
 *       members: [
 *         { _id: 0, host: "192.168.70.71:27017" },  # mongo-1 (initial PRIMARY)
 *         { _id: 1, host: "192.168.70.72:27017" },  # mongo-2
 *         { _id: 2, host: "192.168.70.73:27017" },  # mongo-3
 *       ]
 *     })
 *   MongoDB elects a PRIMARY within ~3-5s; mongo-1 typically wins the
 *   first election but the cluster can re-elect at any point.
 *
 * Verification (the 0.G.2 exit gate):
 *   1. rs.status().ok == 1                         (RS initialized)
 *   2. rs.status().members.length == 3             (all 3 members in config)
 *   3. exactly one member has stateStr == "PRIMARY"
 *   4. exactly two members have stateStr == "SECONDARY"
 *   5. All 3 members report health == 1
 *   6. Write/read round-trip: insert {_id, smokeToken} on PRIMARY via
 *      mongosh -> find {_id} on a SECONDARY (after readPreference shift
 *      + readConcern majority) -> assert smokeToken matches. Proves
 *      replication + mTLS-auth + keyFile-auth all work end-to-end.
 *
 * Reachability: ssh in to mongo-1; run mongosh locally there (the cert +
 * key are 0640 root:mongodb on each node, so sudo is required).
 *
 * Selective ops: var.enable_mongo_rs_initiate AND var.enable_mongo_config.
 */

locals {
  mongo_rs_members = compact([
    var.enable_mongo_1 ? "192.168.70.71" : "",
    var.enable_mongo_2 ? "192.168.70.72" : "",
    var.enable_mongo_3 ? "192.168.70.73" : "",
  ])

  mongo_bootstrap_ip = length(local.mongo_rs_members) > 0 ? local.mongo_rs_members[0] : ""

  # JS body for rs.initiate -- members[] array with VMnet11 endpoints.
  mongo_rs_init_js = format(
    "rs.initiate({_id:'nexus-rs',members:[%s]})",
    join(",", [
      for i, ip in local.mongo_rs_members : format("{_id:%d,host:'%s:27017'}", i, ip)
    ])
  )
}

resource "null_resource" "mongo_rs_initiate" {
  count = (
    var.enable_mongo && var.enable_mongo_rs_initiate && var.enable_mongo_config
    && length(local.mongo_rs_members) == 3
  ) ? 1 : 0

  triggers = {
    config_ids = jsonencode([
      for k in keys(null_resource.mongo_config) : null_resource.mongo_config[k].id
    ])
    rs_members          = jsonencode(local.mongo_rs_members)
    bootstrap_ip        = local.mongo_bootstrap_ip
    mongo_rs_initiate_v = "8" # v8 (0.G.2 ratification fix 2026-05-17, sixth iter) = updateOne fallback escapes `\$set` via `\\`$set` (bash inside the ssh double-quote envelope was expanding `$set` as a shell variable -> empty string -> mongosh syntax error). Also: E11000|duplicate-key regex (vs bare 'DuplicateKey' which is the codeName not the message text in 8.0). Smoke proved the same fix end-to-end. v7 + __system auth for rs.status. v6 RS URI writes. v5 __system bootstrap. v4 always-try-createUser. v3 createUser (bypass broken). v2 regex CRLF. v1 initial.
  }

  depends_on = [null_resource.mongo_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $bootIp   = '${local.mongo_bootstrap_ip}'
      $sshUser  = '${var.oltp_node_user}'
      $timeout  = ${var.oltp_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # mongosh TLS flags reused throughout.
      $tlsArgs = "--tls --tlsCAFile /etc/nexus-mongo/tls/ca.crt --tlsCertificateKeyFile /etc/nexus-mongo/tls/server.pem"

      Write-Host ""
      Write-Host "[mongo-rs-initiate] bootstrap node = $bootIp ; member set = ${join(",", local.mongo_rs_members)}"

      # Pre-read keyFile for __system cluster auth -- used by Stage 1 probe,
      # Stage 2 status polling, Stage 2.5 createUser, and as a fallback for
      # any cluster-admin command. Once smoke-rw exists in admin.system.users,
      # the localhost-exception is fully off + rs.status requires auth.
      $keyfileContent = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-mongo/keyfile 2>/dev/null' | Out-String).Trim()
      $sysAuthArgs = ""
      if ($keyfileContent -and $keyfileContent.Length -ge 100) {
        $sysAuthArgs = "--username __system --password '$keyfileContent' --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256"
      }
      # Empty $sysAuthArgs is fine for fresh-RS Stage 1/2 probes where the
      # localhost-exception IS active (no users yet). Once we hit Stage 2.5
      # createUser, we require non-empty $sysAuthArgs (validated there).

      # ─── Stage 1: probe `rs.status().ok` for an existing healthy RS ─────
      Write-Host "[mongo-rs-initiate] probing for existing RS on $bootIp..."
      # try/catch: rs.status() throws if the RS isn't initialized.
      $probeEval = "try{print(rs.status().ok)}catch(e){print(0)}"
      $probe = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs $sysAuthArgs --host 127.0.0.1:27017 --eval '$probeEval' 2>/dev/null" | Out-String).Trim()
      $alreadyInited = $probe -match '^1$'

      if ($alreadyInited) {
        Write-Host "[mongo-rs-initiate] RS already initialized (rs.status().ok=1); skipping init."
      } else {
        Write-Host "[mongo-rs-initiate] no RS detected -- running rs.initiate..."
        # rs.initiate is the ONE command allowed without auth even when
        # auth is on (special bootstrap pre-condition). No $sysAuthArgs.
        $initJs = "${local.mongo_rs_init_js}"
        $initOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs --host 127.0.0.1:27017 --eval `"printjson($initJs)`" 2>&1" | Out-String)
        if ($initOut -notmatch 'ok:\s*1') {
          Write-Host $initOut.Trim()
          throw "[mongo-rs-initiate] rs.initiate() did not return ok:1"
        }
        Write-Host "[mongo-rs-initiate] rs.initiate() ok:1"
      }

      # ─── Stage 2: wait for 1 PRIMARY + 2 SECONDARY all health:1 ──────────
      Write-Host "[mongo-rs-initiate] waiting for 1 PRIMARY + 2 SECONDARY all health:1..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $healthy = $false
      $lastStatus = ""
      while ((Get-Date) -lt $deadline) {
        # rs.status requires replSetGetStatus priv -- __system has it.
        $statusEval = "var s=rs.status(); var p=0,sec=0,h=0; s.members.forEach(function(m){if(m.stateStr=='PRIMARY')p++; if(m.stateStr=='SECONDARY')sec++; if(m.health==1)h++}); print('PRIMARY='+p); print('SECONDARY='+sec); print('HEALTH='+h); print('MEMBERS='+s.members.length)"
        $lastStatus = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs $sysAuthArgs --host 127.0.0.1:27017 --eval `"$statusEval`" 2>/dev/null" | Out-String)
        # `\s*$` allows trailing CR (SSH pipes through CRLF line endings;
        # `$` alone in multiline mode matches just before `\n`, leaving the
        # `\r` unmatched). Bug surfaced at 0.G.2 first ratification attempt
        # 2026-05-17 where the eval output was correct but never matched.
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
        throw "[mongo-rs-initiate] RS did not converge to 1 PRIMARY + 2 SECONDARY + 3 healthy within $timeout min"
      }
      Write-Host "[mongo-rs-initiate] RS healthy: 1 PRIMARY + 2 SECONDARY + 3 members healthy"

      # ─── Stage 2.5: bootstrap smoke-rw user via __system cluster auth ────
      # MongoDB 8.0 + security.keyFile + security.authorization=enabled
      # does NOT activate the localhost-exception even when the bypass
      # setParameter is set (the runtime check still requires auth -- see
      # mongo_config_v=3 comment). The pragmatic bootstrap path: auth as
      # `__system` (the internal cluster user) via SCRAM-SHA-256 using the
      # keyFile content as the password. `__system` has root-equivalent
      # privileges; we use it ONLY for the one-time createUser of smoke-rw.
      # After that, all writes/reads auth as smoke-rw with the narrower
      # `readWrite on nexus_smoke` role.
      #
      # Per MongoDB docs `__system` is "discouraged but supported" for
      # operator use. For a one-shot bootstrap step + sticky-seed user
      # creation, this is acceptable. Real application access (later
      # phases) would use x509 user auth (cert subject -> $external user).
      Write-Host "[mongo-rs-initiate] reading smoke-rw password from /etc/nexus-mongo/smoke-user-password on $bootIp..."
      $smokePwd = (ssh @sshOpts "$sshUser@$bootIp" 'sudo cat /etc/nexus-mongo/smoke-user-password' | Out-String).Trim()
      if (-not $smokePwd -or $smokePwd.Length -lt 16) {
        throw "[mongo-rs-initiate] smoke-user-password missing or too short on $bootIp (got $($smokePwd.Length) chars; need >=16). Verify role-overlay-mongo-tls.tf rendered it + nexus/oltp/mongo/smoke-user-password is seeded in Vault KV."
      }

      # $sysAuthArgs was pre-computed at script top (used by Stage 1 + 2).
      # Validate it's non-empty for Stage 2.5 createUser which requires
      # cluster-admin privs.
      if (-not $sysAuthArgs) {
        throw "[mongo-rs-initiate] keyfile missing or too short on $bootIp -- cannot bootstrap smoke-rw via __system. Verify role-overlay-mongo-tls.tf rendered /etc/nexus-mongo/keyfile + nexus/oltp/mongo/keyfile is seeded in Vault KV."
      }

      # createUser is a WRITE -- must hit the PRIMARY. mongo-1 might or
      # might not be PRIMARY at this moment (RS can re-elect during the
      # restart sequence). Use the RS connection string so mongosh auto-
      # routes the write to whichever member is currently PRIMARY.
      $bootRsUri = "mongodb://${join(",", [for ip in local.mongo_rs_members : "${ip}:27017"])}/admin?replicaSet=nexus-rs"

      # Always try createUser as __system (root-equivalent privs). If
      # smoke-rw already exists (idempotent re-apply), MongoDB errors with
      # "user already exists" -- catch + treat as success.
      Write-Host "[mongo-rs-initiate] createUser smoke-rw (auth as __system via keyFile, RS URI routes to PRIMARY, idempotent: catches duplicate-user)..."
      $createUserEval = "try{db.getSiblingDB('admin').createUser({user:'smoke-rw', pwd:'$smokePwd', roles:[{role:'readWrite', db:'nexus_smoke'}]}); print('CREATE_OK')}catch(e){if(e.codeName==='Location51003'||e.message.indexOf('already exists')>=0){print('USER_EXISTS')}else{print('CREATE_ERROR:'+e.message)}}"
      $createOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs $sysAuthArgs '$bootRsUri' --eval `"$createUserEval`" 2>&1" | Out-String).Trim()
      if ($createOut -match 'CREATE_OK') {
        Write-Host "[mongo-rs-initiate] smoke-rw created"
      } elseif ($createOut -match 'USER_EXISTS') {
        Write-Host "[mongo-rs-initiate] smoke-rw already exists (idempotent re-apply). Verifying auth with the seeded password..."
        # If user exists, verify the seeded password still authenticates.
        # If not, operator rotated the seed without updating mongo's pwd.
        $authProbeEval = "print(db.runCommand({ping:1}).ok)"
        $authProbe = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs --username smoke-rw --password '$smokePwd' --authenticationDatabase admin --host 127.0.0.1:27017 --eval `"$authProbeEval`" 2>&1" | Out-String).Trim()
        if ($authProbe -notmatch '^1') {
          Write-Host $authProbe
          throw "[mongo-rs-initiate] smoke-rw exists but seeded password doesn't authenticate. Operator likely rotated nexus/oltp/mongo/smoke-user-password in Vault KV without the matching `db.updateUser` in MongoDB. See handbook s3.x for the rotation procedure."
        }
        Write-Host "[mongo-rs-initiate] smoke-rw auth works -- user in sync with KV"
      } else {
        Write-Host $createOut
        throw "[mongo-rs-initiate] createUser smoke-rw failed -- __system cluster auth via keyFile content didn't grant privs (output above). See handbook s3.x for the manual mongosh --username __system reproduction command."
      }

      # ─── Stage 3: write/read round-trip via mTLS + replication (exit gate) ─
      # Writes happen on PRIMARY (auto-routed). Reads happen with
      # readPreference:secondary + readConcern:majority to prove replication
      # actually flowed. Both auth as smoke-rw.
      $token  = "smoke-0G2-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
      $authArgs = "--username smoke-rw --password '$smokePwd' --authenticationDatabase admin"
      # Write URI: routes to PRIMARY (default readPreference=primary).
      $writeRsUri = "mongodb://${join(",", [for ip in local.mongo_rs_members : "${ip}:27017"])}/nexus_smoke?replicaSet=nexus-rs"
      $writeEval = "db.rs_init_test.insertOne({_id:'rs-init-key',token:'$token'}); print('WROTE')"
      $writeOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs $authArgs '$writeRsUri' --eval `"$writeEval`" 2>&1" | Out-String)
      # Idempotent: on re-apply, the key already exists -> DuplicateKey ->
      # updateOne to refresh the token.
      if ($writeOut -notmatch 'WROTE') {
        # MongoDB 8.0 mongosh emits "E11000 duplicate key error" on
        # duplicate key (the codeName is "DuplicateKey" but the message
        # text uses E11000 + lowercase "duplicate key").
        if ($writeOut -match 'E11000|duplicate key') {
          $updateEval = "db.rs_init_test.updateOne({_id:'rs-init-key'},{\`$set:{token:'$token'}}); print('UPDATED')"
          $writeOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs $authArgs '$writeRsUri' --eval `"$updateEval`" 2>&1" | Out-String)
          if ($writeOut -notmatch 'UPDATED') {
            Write-Host $writeOut.Trim()
            throw "[mongo-rs-initiate] update on PRIMARY failed (re-apply path)"
          }
        } else {
          Write-Host $writeOut.Trim()
          throw "[mongo-rs-initiate] insert on PRIMARY failed"
        }
      }

      # Read from a SECONDARY via RS connection string + auth.
      $rsUri = "mongodb://${join(",", [for ip in local.mongo_rs_members : "${ip}:27017"])}/nexus_smoke?replicaSet=nexus-rs&readPreference=secondary&readConcernLevel=majority"
      $readEval = "var d=db.rs_init_test.findOne({_id:'rs-init-key'},{token:1,_id:0}); print('READ='+(d?d.token:'null'))"
      # Retry up to 10x with 2s between to allow replication catch-up.
      $readOk = $false
      for ($i = 1; $i -le 10; $i++) {
        $readOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs $authArgs '$rsUri' --eval `"$readEval`" 2>&1" | Out-String)
        if ($readOut -match "READ=$([regex]::Escape($token))") { $readOk = $true; break }
        Start-Sleep -Seconds 2
      }
      if (-not $readOk) {
        Write-Host $readOut.Trim()
        throw "[mongo-rs-initiate] replicated read did not return the inserted token within 20s"
      }
      Write-Host "[mongo-rs-initiate] write/read round-trip OK -- PRIMARY -> SECONDARY (readConcern:majority) replicated the token (auth as smoke-rw)"
      Write-Host ""
      Write-Host "[mongo-rs-initiate] OK -- Phase 0.G.2 exit gate met (3-node MongoDB RS live on mTLS + keyFile internal auth)"
    PWSH
  }

  # No destroy provisioner: RS state lives in each member's
  # /var/lib/nexus-mongo (preserved by mongo-config destroy too). Full env
  # destroy via modules/vm takes the VMs (and disks) with it.
}
