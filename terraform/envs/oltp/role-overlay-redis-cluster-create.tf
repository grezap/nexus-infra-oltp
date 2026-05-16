/*
 * role-overlay-redis-cluster-create.tf -- Phase 0.G.1 exit gate
 *
 * One-shot that forms the Redis Cluster across all 6 nodes (3 masters +
 * 3 replicas via --cluster-replicas 1), then verifies cluster health +
 * cross-shard key round-trip.
 *
 * Idempotency:
 *   The first stage probes `redis-cli ... cluster info` for `cluster_state:ok`
 *   on redis-1. If the cluster is already formed, the create step is skipped
 *   (no-op-fast on re-apply). If not, the create runs. Either way the verify
 *   stage runs.
 *
 * Why probe-then-create (vs kafka's recover-cluster-id pattern):
 *   Redis Cluster doesn't persist a single cluster identifier; topology
 *   state lives in each node's nodes.conf. Probing `cluster info` is the
 *   equivalent "is this cluster alive?" check. `redis-cli --cluster create`
 *   refuses to overwrite an existing cluster (errors with "node N already
 *   knows other nodes (check with CLUSTER INFO)"), so the probe is also
 *   a guard against double-create.
 *
 * Bootstrap:
 *   Runs from redis-1 (an arbitrary cluster node; any node would work).
 *   `redis-cli --cluster create --tls --cacert --cert --key
 *      <ip1:6379> <ip2:6379> ... <ip6:6379> --cluster-replicas 1
 *      --cluster-yes`.
 *   With 6 nodes + --cluster-replicas 1 Redis picks 3 masters + 3 replicas
 *   with anti-affinity (each replica on a different "node group" than its
 *   master -- in our flat lab this just means the first 3 are masters and
 *   the last 3 are replicas).
 *
 * Verification (the 0.G.1 exit gate):
 *   1. cluster_state:ok                              (3 masters elected)
 *   2. cluster_size:3                                (3 shards)
 *   3. cluster_known_nodes:6                         (all 6 talking gossip)
 *   4. cluster_slots_assigned:16384                  (full keyspace covered)
 *   5. cluster_slots_ok:16384                        (no slots in error state)
 *   6. Cross-shard round-trip: SET 4 keys (chosen so they hash to >1 shard)
 *      via -c (cluster mode); GET them back; assert values match. This
 *      proves: (a) the cluster routes via MOVED redirects, (b) the slot
 *      table is consistent across nodes, (c) mTLS works end-to-end.
 *
 * Reachability: ssh in to redis-1; run redis-cli locally there (the cert
 * + key + ca are 0640 root:redis on each node, so sudo is required).
 *
 * Selective ops: var.enable_redis_cluster_create AND var.enable_redis_config.
 */

locals {
  redis_cluster_nodes = compact([
    var.enable_redis_1 ? "192.168.70.81" : "",
    var.enable_redis_2 ? "192.168.70.82" : "",
    var.enable_redis_3 ? "192.168.70.83" : "",
    var.enable_redis_4 ? "192.168.70.84" : "",
    var.enable_redis_5 ? "192.168.70.87" : "",
    var.enable_redis_6 ? "192.168.70.89" : "",
  ])

  redis_cluster_node_args = join(" ", [for ip in local.redis_cluster_nodes : "${ip}:6379"])

  # Bootstrap from redis-1 (an arbitrary node; just needs to be enabled +
  # have the certs). If redis-1 is disabled, fall back to the first enabled.
  redis_bootstrap_ip = length(local.redis_cluster_nodes) > 0 ? local.redis_cluster_nodes[0] : ""
}

resource "null_resource" "redis_cluster_create" {
  count = (
    var.enable_redis && var.enable_redis_cluster_create && var.enable_redis_config
    && length(local.redis_cluster_nodes) == 6
  ) ? 1 : 0

  triggers = {
    config_ids = jsonencode([
      for k in keys(null_resource.redis_config) : null_resource.redis_config[k].id
    ])
    cluster_node_args = local.redis_cluster_node_args
    bootstrap_ip      = local.redis_bootstrap_ip
    cluster_create_v  = "1" # v1 (0.G.1) = initial probe-then-create + RF=2 cross-shard round-trip exit gate.
  }

  depends_on = [null_resource.redis_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $bootIp   = '${local.redis_bootstrap_ip}'
      $nodeArgs = '${local.redis_cluster_node_args}'
      $sshUser  = '${var.oltp_node_user}'
      $timeout  = ${var.oltp_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # TLS args reused across every redis-cli invocation on the bootstrap node.
      $tlsArgs = "--tls --cacert /etc/nexus-redis/tls/ca.crt --cert /etc/nexus-redis/tls/server.crt --key /etc/nexus-redis/tls/server.key"

      Write-Host ""
      Write-Host "[redis-cluster-create] bootstrap node = $bootIp ; member set = $nodeArgs"

      # ─── Stage 1: probe `cluster info` for an existing healthy cluster ───
      Write-Host "[redis-cluster-create] probing for existing cluster on $bootIp..."
      $probe = (ssh @sshOpts "$sshUser@$bootIp" "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null" | Out-String)
      $alreadyFormed = $probe -match '(?m)^cluster_state:ok'

      if ($alreadyFormed) {
        Write-Host "[redis-cluster-create] cluster already formed (cluster_state:ok); skipping create."
      } else {
        Write-Host "[redis-cluster-create] no healthy cluster detected -- running redis-cli --cluster create..."
        # The create command. --cluster-yes skips the interactive accept-layout
        # prompt; --cluster-replicas 1 puts the 6 nodes into 3 shards (3 masters
        # + 3 replicas) with Redis's anti-affinity placement.
        $createCmd = "sudo redis-cli $tlsArgs --cluster create $nodeArgs --cluster-replicas 1 --cluster-yes"
        $createOut = (ssh @sshOpts "$sshUser@$bootIp" $createCmd 2>&1 | Out-String)
        if ($createOut -notmatch '(?m)\[OK\] All 16384 slots covered\.') {
          Write-Host $createOut.Trim()
          throw "[redis-cluster-create] cluster create did not report `[OK`] All 16384 slots covered."
        }
        Write-Host "[redis-cluster-create] cluster created (all 16384 slots covered)"
      }

      # ─── Stage 2: wait for cluster health ────────────────────────────────
      Write-Host "[redis-cluster-create] waiting for cluster_state:ok + cluster_slots_ok=16384 + 6 known nodes..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $healthy = $false
      $lastInfo = ""
      while ((Get-Date) -lt $deadline) {
        $lastInfo = (ssh @sshOpts "$sshUser@$bootIp" "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster info 2>/dev/null" | Out-String)
        if (
          $lastInfo -match '(?m)^cluster_state:ok' -and
          $lastInfo -match '(?m)^cluster_slots_assigned:16384' -and
          $lastInfo -match '(?m)^cluster_slots_ok:16384' -and
          $lastInfo -match '(?m)^cluster_known_nodes:6' -and
          $lastInfo -match '(?m)^cluster_size:3'
        ) {
          $healthy = $true
          break
        }
        Start-Sleep -Seconds 5
      }
      if (-not $healthy) {
        Write-Host $lastInfo.Trim()
        throw "[redis-cluster-create] cluster did not converge to (state=ok, size=3, known=6, slots=16384) within $timeout min"
      }
      Write-Host "[redis-cluster-create] cluster healthy: 3 masters + 3 replicas, 16384 slots assigned + ok"

      # ─── Stage 3: shard layout (masters vs replicas) ──────────────────────
      $nodes = (ssh @sshOpts "$sshUser@$bootIp" "sudo redis-cli -h 127.0.0.1 -p 6379 $tlsArgs cluster nodes 2>/dev/null" | Out-String)
      $masters  = ($nodes -split "`n" | Where-Object { $_ -match '\bmaster\b' }).Count
      $replicas = ($nodes -split "`n" | Where-Object { $_ -match '\bslave\b' }).Count   # Redis keeps the legacy term in CLUSTER NODES output.
      if ($masters -ne 3 -or $replicas -ne 3) {
        Write-Host $nodes.Trim()
        throw "[redis-cluster-create] expected 3 masters + 3 replicas, got $masters masters + $replicas replicas"
      }
      Write-Host "[redis-cluster-create] shard layout verified: $masters masters + $replicas replicas"

      # ─── Stage 4: cross-shard round-trip (the exit gate) ──────────────────
      # 4 keys chosen so they distribute across the 3 shards (Redis picks the
      # slot via CRC16(key) % 16384). Use cluster mode (-c) so SET to the
      # "wrong" shard is auto-redirected via MOVED. If routing + the slot
      # table are consistent across nodes + mTLS works end-to-end, all 4
      # GETs return the values we SET.
      $token = "nexus-smoke-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
      $rtScript = @"
set -e
TLS='--tls --cacert /etc/nexus-redis/tls/ca.crt --cert /etc/nexus-redis/tls/server.crt --key /etc/nexus-redis/tls/server.key'
# Cluster mode (-c): the client follows MOVED redirects automatically.
sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c SET nexus-smoke-key-1 '$token-alpha'  > /dev/null
sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c SET nexus-smoke-key-2 '$token-beta'   > /dev/null
sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c SET nexus-smoke-key-3 '$token-gamma'  > /dev/null
sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c SET nexus-smoke-key-4 '$token-delta'  > /dev/null
A=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c GET nexus-smoke-key-1)
B=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c GET nexus-smoke-key-2)
C=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c GET nexus-smoke-key-3)
D=`$(sudo redis-cli -h 127.0.0.1 -p 6379 `$TLS -c GET nexus-smoke-key-4)
echo "ROUND_TRIP_A=`$A"
echo "ROUND_TRIP_B=`$B"
echo "ROUND_TRIP_C=`$C"
echo "ROUND_TRIP_D=`$D"
"@
      $rtLf  = $rtScript -replace "`r`n", "`n"
      $rtOut = ($rtLf | ssh @sshOpts "$sshUser@$bootIp" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      $expectedA = "$token-alpha"
      $expectedB = "$token-beta"
      $expectedC = "$token-gamma"
      $expectedD = "$token-delta"
      if ($rtOut -notmatch "ROUND_TRIP_A=$([regex]::Escape($expectedA))" -or
          $rtOut -notmatch "ROUND_TRIP_B=$([regex]::Escape($expectedB))" -or
          $rtOut -notmatch "ROUND_TRIP_C=$([regex]::Escape($expectedC))" -or
          $rtOut -notmatch "ROUND_TRIP_D=$([regex]::Escape($expectedD))") {
        Write-Host $rtOut.Trim()
        throw "[redis-cluster-create] cross-shard round-trip failed (expected 4 token-tagged values to round-trip)"
      }
      Write-Host "[redis-cluster-create] cross-shard round-trip OK -- 4 keys SET + GET via cluster routing"
      Write-Host ""
      Write-Host "[redis-cluster-create] OK -- Phase 0.G.1 exit gate met (6-node Redis Cluster live on mTLS)"
    PWSH
  }

  # No destroy provisioner: cluster state lives in each node's nodes.conf +
  # AOF in /var/lib/nexus-redis (preserved by redis-config destroy too).
  # Terraform destroy of just THIS overlay should not destroy cluster state.
  # Full env destroy via modules/vm takes the VMs (and their disks) with it.
}
