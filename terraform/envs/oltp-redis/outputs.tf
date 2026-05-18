# nexus-infra-oltp / terraform / envs / oltp-redis / outputs.tf
#
# Per-cluster Redis state outputs -- Phase 0.G.3.5b.

output "redis_endpoints" {
  description = "Per-node Redis Cluster endpoints (TLS on 6379, cluster bus on 16379). Reach via VMnet11 dnsmasq names redis-N.nexus.lab."
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

output "next_step" {
  value = <<-EOT
    Phase 0.G.3.5b envs/oltp-redis/ state -- 6 redis VMs + cluster overlays.
    Apply order:
      1. nexus-infra-vmware: pwsh -File scripts/foundation.ps1 apply (dhcp reservations).
      2. nexus-infra-vmware: pwsh -File scripts/security.ps1   apply (PKI + AppRoles + sidecars).
      3. packer build packer/oltp-redis-node.
      4. This env:           pwsh -File scripts/oltp-redis.ps1 apply  (OR: terraform apply from this dir).
      5. Smoke:              pwsh -File scripts/smoke-0.G.1.ps1.
    Selective ops: -Vars enable_redis_N=false (per-VM) or enable_redis_<overlay>=false (per-step).
  EOT
}
