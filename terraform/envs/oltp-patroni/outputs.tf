# nexus-infra-oltp / terraform / envs / oltp-patroni / outputs.tf
# Per-cluster Patroni PG HA + etcd + HAProxy HA pair outputs -- Phase 0.G.4.

output "patroni_endpoints" {
  description = "Patroni + etcd + HAProxy HA pair endpoints. Apps connect via the keepalived-floated VIP (var.haproxy_vip, default 192.168.70.60) on :5432 for primary writes -- HAProxy routes to the current Patroni leader via REST /leader. Patroni REST :8008 on each pg-* node for switchover/restart RPCs. etcd :2379 for DCS reads/writes."
  value = {
    patroni = {
      for n in ["pg-primary", "pg-replica-1", "pg-replica-2"] : n => {
        service_ip = lookup({
          "pg-primary"   = "192.168.70.61"
          "pg-replica-1" = "192.168.70.62"
          "pg-replica-2" = "192.168.70.63"
        }, n)
        backplane_ip = lookup({
          "pg-primary"   = "192.168.10.61"
          "pg-replica-1" = "192.168.10.62"
          "pg-replica-2" = "192.168.10.63"
        }, n)
        pg_port      = 5432
        patroni_rest = 8008
      }
    }
    etcd = {
      for n in ["etcd-1", "etcd-2", "etcd-3"] : n => {
        service_ip = lookup({
          "etcd-1" = "192.168.70.64"
          "etcd-2" = "192.168.70.65"
          "etcd-3" = "192.168.70.66"
        }, n)
        backplane_ip = lookup({
          "etcd-1" = "192.168.10.64"
          "etcd-2" = "192.168.10.65"
          "etcd-3" = "192.168.10.66"
        }, n)
        client_port = 2379
        peer_port   = 2380
      }
    }
    haproxy = {
      for n in ["haproxy-pg-1", "haproxy-pg-2"] : n => {
        service_ip = lookup({
          "haproxy-pg-1" = "192.168.70.67"
          "haproxy-pg-2" = "192.168.70.68"
        }, n)
        backplane_ip = lookup({
          "haproxy-pg-1" = "192.168.10.67"
          "haproxy-pg-2" = "192.168.10.68"
        }, n)
        pg_frontend = 5432
        stats_ui    = 8404
        keepalived_role = lookup({
          "haproxy-pg-1" = "MASTER candidate (priority 110)"
          "haproxy-pg-2" = "BACKUP (priority 100)"
        }, n)
      }
    }
    cluster_scope = var.patroni_scope
    haproxy_vip   = var.haproxy_vip
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.G.4 envs/oltp-patroni/ state -- 3 Patroni + 3 etcd + 2 HAProxy HA pair + VRRP VIP.
    Apply order:
      1. nexus-infra-vmware foundation + security envs applied.
      2. packer build packer/oltp-patroni-node + packer/oltp-etcd-node + packer/oltp-haproxy-node.
      3. This env:       pwsh -File scripts/oltp-patroni.ps1 apply (OR: terraform apply from this dir).
      4. Smoke:          pwsh -File scripts/smoke-0.G.4.ps1.
  EOT
}
