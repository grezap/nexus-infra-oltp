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
    mongo_rs_initiate_v = "1" # v1 (0.G.2) = initial probe-then-init + 5-axis health verify + write/read round-trip exit gate.
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

      # ─── Stage 1: probe `rs.status().ok` for an existing healthy RS ─────
      Write-Host "[mongo-rs-initiate] probing for existing RS on $bootIp..."
      # try/catch: rs.status() throws if the RS isn't initialized.
      $probeEval = "try{print(rs.status().ok)}catch(e){print(0)}"
      $probe = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs --host 127.0.0.1:27017 --eval '$probeEval' 2>/dev/null" | Out-String).Trim()
      $alreadyInited = $probe -match '^1$'

      if ($alreadyInited) {
        Write-Host "[mongo-rs-initiate] RS already initialized (rs.status().ok=1); skipping init."
      } else {
        Write-Host "[mongo-rs-initiate] no RS detected -- running rs.initiate..."
        # Use a here-doc style eval string so the JS object syntax is verbatim.
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
        # Single eval that emits a 3-line summary: PRIMARY count, SECONDARY count, healthy count.
        $statusEval = "var s=rs.status(); var p=0,sec=0,h=0; s.members.forEach(function(m){if(m.stateStr=='PRIMARY')p++; if(m.stateStr=='SECONDARY')sec++; if(m.health==1)h++}); print('PRIMARY='+p); print('SECONDARY='+sec); print('HEALTH='+h); print('MEMBERS='+s.members.length)"
        $lastStatus = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs --host 127.0.0.1:27017 --eval `"$statusEval`" 2>/dev/null" | Out-String)
        if (
          $lastStatus -match '(?m)^PRIMARY=1$' -and
          $lastStatus -match '(?m)^SECONDARY=2$' -and
          $lastStatus -match '(?m)^HEALTH=3$' -and
          $lastStatus -match '(?m)^MEMBERS=3$'
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

      # ─── Stage 3: write/read round-trip via mTLS + replication (exit gate) ─
      # Writes happen on PRIMARY (auto-routed). Reads happen with
      # readPreference:secondary + readConcern:majority to prove replication
      # actually flowed. The test database (`nexus_smoke`) is created on
      # write; nothing to clean up after destroy since /var/lib/nexus-mongo
      # gets wiped with the VM.
      $token  = "smoke-0G2-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
      $writeEval = "db.getSiblingDB('nexus_smoke').rs_init_test.insertOne({_id:'rs-init-key',token:'$token'}); print('WROTE')"
      $writeOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs --host 127.0.0.1:27017 --eval `"$writeEval`" 2>&1" | Out-String)
      if ($writeOut -notmatch 'WROTE') {
        Write-Host $writeOut.Trim()
        throw "[mongo-rs-initiate] insert on PRIMARY failed"
      }

      # Read from a SECONDARY (after the PRIMARY at $bootIp wrote it).
      # Connection string with replicaSet + readPreference for proper RS
      # routing. mongosh prints the doc's token field on success.
      $rsUri = "mongodb://${join(",", [for ip in local.mongo_rs_members : "${ip}:27017"])}/nexus_smoke?replicaSet=nexus-rs&readPreference=secondary&readConcernLevel=majority"
      $readEval = "var d=db.rs_init_test.findOne({_id:'rs-init-key'},{token:1,_id:0}); print('READ='+(d?d.token:'null'))"
      # Retry up to 10x with 2s between to allow replication catch-up.
      $readOk = $false
      for ($i = 1; $i -le 10; $i++) {
        $readOut = (ssh @sshOpts "$sshUser@$bootIp" "sudo mongosh --quiet $tlsArgs '$rsUri' --eval `"$readEval`" 2>&1" | Out-String)
        if ($readOut -match "READ=$([regex]::Escape($token))") { $readOk = $true; break }
        Start-Sleep -Seconds 2
      }
      if (-not $readOk) {
        Write-Host $readOut.Trim()
        throw "[mongo-rs-initiate] replicated read did not return the inserted token within 20s"
      }
      Write-Host "[mongo-rs-initiate] write/read round-trip OK -- PRIMARY -> SECONDARY (readConcern:majority) replicated the token"
      Write-Host ""
      Write-Host "[mongo-rs-initiate] OK -- Phase 0.G.2 exit gate met (3-node MongoDB RS live on mTLS + keyFile internal auth)"
    PWSH
  }

  # No destroy provisioner: RS state lives in each member's
  # /var/lib/nexus-mongo (preserved by mongo-config destroy too). Full env
  # destroy via modules/vm takes the VMs (and disks) with it.
}
