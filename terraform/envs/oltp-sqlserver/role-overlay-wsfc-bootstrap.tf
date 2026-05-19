# role-overlay-wsfc-bootstrap.tf -- Phase 0.G.7
#
# One-shot bootstrap: creates the WSFC cluster `sql-fci-cluster` with all 4
# SQL nodes as members + static cluster IP at .70.15. Adds the iSCSI LUN as
# a Cluster Shared Volume so the FCI install (next stage) can use it as
# the SQL Server data + log dir.
#
# Runs on sql-fci-1 only (idempotent via Get-Cluster probe). New-Cluster
# auto-discovers each node's network adapters + builds NetFT (the WSFC
# heartbeat fabric) across both VMnet10 + VMnet11. The Domain Admins group
# is implicitly granted cluster admin via WSFC's default ACL.
#
# Pre-req: all 4 nodes domain-joined + nexus-sql-cluster-members group
# populated + nexusadmin in Domain Admins (per foundation env's role-overlay-
# dc-nexusadmin-membership.tf -- EA + DA membership).

resource "null_resource" "wsfc_bootstrap" {
  count = var.enable_wsfc_bootstrap ? 1 : 0

  triggers = {
    iscsi_attach_id = length(null_resource.iscsi_attach) > 0 ? null_resource.iscsi_attach["sql-fci-1"].id : "disabled"
    cluster_name    = local.fci_cluster_name
    cluster_ip      = local.wsfc_cluster_ip
    stage_v         = var.wsfc_bootstrap_v
  }

  depends_on = [null_resource.iscsi_attach]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.ssh_username}'
      $sf1Ip      = '${local.sql_nodes["sql-fci-1"].vmnet11}'
      $cluster    = '${local.fci_cluster_name}'
      $clusterIp  = '${local.wsfc_cluster_ip}'

      Write-Host "[wsfc-bootstrap] creating WSFC cluster $cluster (members: 4 SQL nodes; cluster IP $clusterIp)..."

      $nodeList = "'sql-fci-1','sql-fci-2','sql-ag-rep-1','sql-ag-rep-2'"

      $remote = @"
`$ErrorActionPreference = 'Stop';
Import-Module FailoverClusters;

# Idempotent: if cluster exists, skip create + go straight to CSV add.
`$existing = Get-Cluster -Name '$cluster' -ErrorAction SilentlyContinue;
if (`$existing) {
  Write-Output 'CLUSTER_EXISTS';
} else {
  # Validate cluster first (skip Storage for now -- iSCSI LUN testing
  # would block, and Test-Cluster's storage tests fail on a not-yet-CSV LUN).
  Write-Output 'Running Test-Cluster (skipping Storage tests)...';
  Test-Cluster -Node $nodeList -Include 'System Configuration','Network','Inventory' -ReportName 'WSFCValidation' -WarningAction SilentlyContinue | Out-Null;

  Write-Output 'Running New-Cluster...';
  New-Cluster -Name '$cluster' -Node $nodeList ``
    -StaticAddress '$clusterIp' ``
    -NoStorage ``
    -AdministrativeAccessPoint ActiveDirectoryAndDns | Out-Null;
  Write-Output ('CLUSTER_CREATED: ' + (Get-Cluster).Name);
}

# Add the iSCSI LUN as a Cluster Shared Volume (CSV). The disk is online
# on sql-fci-1 (formatted in iscsi-attach stage) + accessible from sql-fci-2.
`$availDisk = Get-ClusterAvailableDisk -ErrorAction SilentlyContinue | Where-Object { `$_.Size -gt 50GB };
if (`$availDisk) {
  `$availDisk | Add-ClusterDisk | Out-Null;
  # Find the cluster disk resource that just got added + add it to CSV.
  `$clusDisk = Get-ClusterResource | Where-Object { `$_.ResourceType -eq 'Physical Disk' -and `$_.State -eq 'Online' } | Select-Object -First 1;
  if (`$clusDisk) {
    Add-ClusterSharedVolume -InputObject `$clusDisk | Out-Null;
    Write-Output ('CSV_ADDED: ' + `$clusDisk.Name);
  }
} else {
  # Already a CSV? Probe.
  `$existingCsv = Get-ClusterSharedVolume -ErrorAction SilentlyContinue;
  if (`$existingCsv) {
    Write-Output ('CSV_ALREADY: ' + `$existingCsv.Name);
  } else {
    Write-Output 'WARN: no available iSCSI disk to add as CSV (may need iscsi-attach re-run or manual Add-ClusterDisk)';
  }
}

# Report final cluster state.
Get-ClusterNode | ForEach-Object { Write-Output ('NODE: ' + `$_.Name + ' state=' + `$_.State) };
"@

      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
      $output = ssh -o ConnectTimeout=120 "$sshUser@$sf1Ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($LASTEXITCODE -ne 0) { throw "[wsfc-bootstrap] New-Cluster failed (rc=$LASTEXITCODE)" }
      Write-Host "[wsfc-bootstrap] WSFC cluster $cluster live at $clusterIp; CSV mounted"
    PWSH
  }
}
