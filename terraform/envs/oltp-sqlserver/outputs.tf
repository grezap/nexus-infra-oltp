# nexus-infra-oltp / terraform / envs / oltp-sqlserver / outputs.tf
#
# Outputs surfaced for the operator wrapper (scripts/oltp-sqlserver.ps1)
# + the smoke gate (scripts/smoke-0.G.7.ps1) + downstream nexus-cli
# SqlFciAdapter/SqlAgAdapter consumption.

output "sql_nodes" {
  description = "Map of SQL node hostname -> { vmnet11_ip, vmnet10_ip, role }. All 4 nodes regardless of enable_*."
  value       = local.sql_nodes
}

output "fci_nodes" {
  description = "Map of FCI-only nodes (sql-fci-1/2). These share the iSCSI LUN + own the FCI virtual server identity."
  value       = local.fci_nodes
}

output "wsfc_cluster_ip" {
  description = "WSFC cluster IP (.70.15). Used by Get-Cluster + Get-ClusterNode probes from anywhere on VMnet11."
  value       = local.wsfc_cluster_ip
}

output "fci_virtual_ip" {
  description = "FCI virtual server IP (.70.16). SQL clients connect to this for the FCI's user databases; migrates with the FCI role between sql-fci-1/2."
  value       = local.fci_virtual_ip
}

output "ag_listener_ip" {
  description = "AG Listener IP (.70.17). Per ADR-0025 this IS the LB-tier HA primitive for AG -- SQL clients connect here, WSFC migrates the IP across the current AG primary."
  value       = local.ag_listener_ip
}

output "fci_cluster_name" {
  description = "WSFC cluster name (`sql-fci-cluster`). Resolves to .15 via dnsmasq; the FCI virtual server is the same name + the FCI role IP .16."
  value       = local.fci_cluster_name
}

output "ag_listener_name" {
  description = "AG Listener DNS name (`sql-ag-listener`). Resolves to .17 via dnsmasq; SQL connection strings target this."
  value       = local.ag_listener_name
}

output "ag_name" {
  description = "Availability Group name (`nexus-ag`)."
  value       = local.ag_name
}

output "endpoint_summary" {
  description = "Operator-facing summary of how SQL clients reach this cluster."
  value       = <<-EOT
    SQL Server FCI + Always On AG (Phase 0.G.7):
      AG Listener:     sql-ag-listener.nexus.lab (192.168.70.17:1433)  <- primary client endpoint
      FCI virtual:     sql-fci-cluster.nexus.lab (192.168.70.16:1433)  <- direct-to-FCI for ops
      AG name:         nexus-ag
      Nodes:           sql-fci-1/2 (FCI pair sharing iSCSI .16) + sql-ag-rep-1/2 (async replicas)
      WSFC cluster:    sql-fci-cluster (.70.15, 4-node node-majority quorum)
      mTLS:            sqlserver-server Vault PKI role (90-day leaf); Listener cert IP-SAN .17 validates across failover
      Service account: nexus.lab\\gmsa-sql-engine$ (GMSA; AD-managed 30-day password rotation)
  EOT
}
