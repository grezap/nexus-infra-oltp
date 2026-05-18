# nexus-infra-oltp / terraform / envs / oltp-percona / outputs.tf
# Per-cluster Percona XtraDB Cluster + ProxySQL outputs -- Phase 0.G.3.5b.

output "percona_endpoints" {
  description = "PXC + ProxySQL endpoints. Apps connect via VIP $var.proxysql_vip:6033 (keepalived MASTER) for galera-aware LB. PXC nodes mTLS-only on 3306 + Galera SST/IST on VMnet10 backplane."
  value = {
    pxc = {
      for n in ["pxc-node-1", "pxc-node-2", "pxc-node-3"] : n => {
        service_ip = lookup({
          "pxc-node-1" = "192.168.70.51"
          "pxc-node-2" = "192.168.70.52"
          "pxc-node-3" = "192.168.70.53"
        }, n)
        backplane_ip = lookup({
          "pxc-node-1" = "192.168.10.51"
          "pxc-node-2" = "192.168.10.52"
          "pxc-node-3" = "192.168.10.53"
        }, n)
        mysql_port = 3306
        galera_sst = 4444
        galera_wsr = 4567
        galera_ist = 4568
      }
    }
    proxysql = {
      for n in ["proxysql-1", "proxysql-2"] : n => {
        service_ip = lookup({
          "proxysql-1" = "192.168.70.54"
          "proxysql-2" = "192.168.70.55"
        }, n)
        backplane_ip = lookup({
          "proxysql-1" = "192.168.10.54"
          "proxysql-2" = "192.168.10.55"
        }, n)
        admin_port    = 6032
        frontend_port = 6033
      }
    }
    cluster_name = "nexus-pxc"
    vip          = var.proxysql_vip
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.G.3.5b envs/oltp-percona/ state -- 3 PXC + 2 ProxySQL + VRRP VIP.
    Apply order:
      1. nexus-infra-vmware foundation + security envs applied.
      2. packer build packer/oltp-pxc-node + packer/oltp-proxysql-node.
      3. This env:       pwsh -File scripts/oltp-percona.ps1 apply (OR: terraform apply from this dir).
      4. Smoke:          pwsh -File scripts/smoke-0.G.3.ps1.
  EOT
}
