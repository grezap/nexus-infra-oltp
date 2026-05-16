# nexus-infra-oltp / terraform / envs / oltp / outputs.tf
#
# Per-cluster outputs land per sub-phase, mirroring nexus-infra-kafka's
# pattern: a summary table emitted at apply completion + a `next_step` hint
# pointing at the appropriate smoke gate.

output "redis_endpoints" {
  description = "Per-node Redis Cluster endpoints (TLS on 6379, cluster bus on 16379). Build-host smoke can reach these via the VMnet11 dnsmasq names redis-N.nexus.lab."
  value = {
    for n in ["redis-1", "redis-2", "redis-3", "redis-4", "redis-5", "redis-6"] : n => {
      service_ip = lookup({
        "redis-1" = "192.168.70.81"
        "redis-2" = "192.168.70.82"
        "redis-3" = "192.168.70.83"
        "redis-4" = "192.168.70.84"
        "redis-5" = "192.168.70.87"
        "redis-6" = "192.168.70.89"
      }, n)
      backplane_ip = lookup({
        "redis-1" = "192.168.10.81"
        "redis-2" = "192.168.10.82"
        "redis-3" = "192.168.10.83"
        "redis-4" = "192.168.10.84"
        "redis-5" = "192.168.10.87"
        "redis-6" = "192.168.10.89"
      }, n)
      tls_port    = 6379
      cluster_bus = 16379
    }
  }
}

output "mongo_endpoints" {
  description = "Per-node MongoDB Replica Set endpoints (TLS on 27017). Build-host smoke can reach via VMnet11 dnsmasq names mongo-N.nexus.lab. Replica set name is `nexus-rs` (set by role-overlay-mongo-rs-initiate.tf)."
  value = {
    for n in ["mongo-1", "mongo-2", "mongo-3"] : n => {
      service_ip = lookup({
        "mongo-1" = "192.168.70.71"
        "mongo-2" = "192.168.70.72"
        "mongo-3" = "192.168.70.73"
      }, n)
      backplane_ip = lookup({
        "mongo-1" = "192.168.10.71"
        "mongo-2" = "192.168.10.72"
        "mongo-3" = "192.168.10.73"
      }, n)
      tls_port = 27017
      rs_name  = "nexus-rs"
    }
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.G.1 Redis Cluster TF: ${var.enable_redis ? "ENABLED" : "DISABLED"}.
    Phase 0.G.2 MongoDB RS TF:    ${var.enable_mongo ? "ENABLED" : "DISABLED"}.
    Apply order (per docs/handbook.md s1):
      1. Build oltp-node Packer template (packer build packer/oltp-node).
      2. nexus-infra-vmware: pwsh -File scripts/foundation.ps1 apply (dhcp reservations: 6 redis + 3 mongo).
      3. nexus-infra-vmware: pwsh -File scripts/security.ps1   apply (PKI + AppRoles + sidecars for redis + mongo + keyFile sticky-seed).
      4. This env:           pwsh -File scripts/oltp.ps1       apply.
      5. Smoke:              pwsh -File scripts/smoke-0.G.1.ps1 && pwsh -File scripts/smoke-0.G.2.ps1
    Selective ops: -Vars enable_{redis,mongo}_N=false (per-VM) or enable_{redis,mongo}_<overlay>=false (per-step).
  EOT
}
