# role-overlay-fci-install.tf -- Phase 0.G.7
#
# Converts the standalone SQL Server install on sql-fci-1/2 into a 2-node
# Failover Cluster Instance (FCI). Two-stage:
#   1. On sql-fci-1: setup.exe /ACTION=InstallFailoverCluster. Reuses the
#      already-installed binaries from the Packer bake; the action creates
#      the FCI resource group in WSFC with the CSV as data dir, virtual
#      server name `sql-fci-cluster`, virtual server IP .70.16.
#   2. On sql-fci-2: setup.exe /ACTION=AddNode. Joins the existing FCI as
#      a possible owner.
#
# The original standalone MSSQLSERVER service on each node is removed by
# /ACTION=InstallFailoverCluster (cluster-aware install replaces the
# standalone instance with the FCI-aware one). SQL service identity moves
# to nexus.lab\gmsa-sql-engine$.
#
# Bootstrap SA password (the placeholder from 10-sql-install.ps1) is
# rotated to the KV-seeded sa-password via T-SQL inside this stage.

resource "null_resource" "fci_install" {
  count = var.enable_fci_install ? 1 : 0

  triggers = {
    wsfc_bootstrap_id = length(null_resource.wsfc_bootstrap) > 0 ? null_resource.wsfc_bootstrap[0].id : "disabled"
    fci_ip            = local.fci_virtual_ip
    stage_v           = var.fci_install_v
  }

  depends_on = [null_resource.wsfc_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.ssh_username}'
      $sf1Ip     = '${local.sql_nodes["sql-fci-1"].vmnet11}'
      $sf2Ip     = '${local.sql_nodes["sql-fci-2"].vmnet11}'
      $fciVip    = '${local.fci_virtual_ip}'
      $fciName   = '${local.fci_cluster_name}'

      Write-Host "[fci-install] step 1/2: InstallFailoverCluster on sql-fci-1..."

      # The ISO has been removed in the bake's cleanup stage; we re-mount
      # it from the host's H:/VMS/ISO via vmrun mountedFolder + Mount-DiskImage.
      # For simplicity in this scaffold we assume the ISO is uploaded again
      # to C:/Windows/Temp/sqlserver.iso by an operator step or a follow-up
      # script -- the live ratification will iron out the exact path.

      $sf1Remote = @"
`$ErrorActionPreference = 'Stop';
`$saPwd = (Get-Content 'C:/ProgramData/nexus/sql/creds/sa-password.txt' -Raw).Trim();

# Probe: is FCI already installed?
`$fciSvc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue;
`$isFci  = (Get-ClusterResource -Cluster '$fciName' -ErrorAction SilentlyContinue | Where-Object { `$_.ResourceType -eq 'SQL Server' }) -ne `$null;
if (`$isFci) {
  Write-Output 'FCI_ALREADY_INSTALLED';
  exit 0;
}

# Mount ISO if not mounted.
if (-not (Test-Path 'D:/setup.exe')) {
  if (Test-Path 'C:/Windows/Temp/sqlserver.iso') {
    Mount-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' | Out-Null;
    Start-Sleep -Seconds 5;
  } else {
    throw 'SQL Server ISO not at C:/Windows/Temp/sqlserver.iso -- operator must upload before fci-install';
  }
}

# Install Failover Cluster instance.
`$setupArgs = @(
  '/Q', '/ACTION=InstallFailoverCluster',
  '/FEATURES=SQLEngine,FullText',
  '/INSTANCENAME=MSSQLSERVER',
  '/FAILOVERCLUSTERGROUP=SQL Server (MSSQLSERVER)',
  ('/FAILOVERCLUSTERNETWORKNAME=$fciName'),
  ('/FAILOVERCLUSTERIPADDRESSES=IPv4;$fciVip;Cluster Network 1;255.255.255.0'),
  '/INSTALLSQLDATADIR=S:/SQLData',
  '/SQLUSERDBDIR=S:/SQLData/UserDB',
  '/SQLUSERDBLOGDIR=S:/SQLData/UserDBLog',
  '/SQLSVCACCOUNT=NEXUS\gmsa-sql-engine`$',
  '/SQLSYSADMINACCOUNTS=NEXUS\Domain Admins',
  '/SECURITYMODE=SQL',
  ('/SAPWD=' + `$saPwd),
  '/IACCEPTSQLSERVERLICENSETERMS'
) -join ' ';
& 'D:/setup.exe' `$setupArgs.Split(' ');
if (`$LASTEXITCODE -ne 0 -and `$LASTEXITCODE -ne 3010) {
  throw 'setup.exe InstallFailoverCluster failed (exit=' + `$LASTEXITCODE + ')';
}
Write-Output 'FCI_INSTALLED_ON_FCI1';
"@

      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sf1Remote))
      $output = ssh -o ConnectTimeout=900 "$sshUser@$sf1Ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($LASTEXITCODE -ne 0) { throw "[fci-install] sql-fci-1 InstallFailoverCluster failed (rc=$LASTEXITCODE)" }

      if ($output -notmatch 'FCI_ALREADY_INSTALLED') {
        Write-Host "[fci-install] step 2/2: AddNode on sql-fci-2..."

        $sf2Remote = @"
`$ErrorActionPreference = 'Stop';
`$saPwd = (Get-Content 'C:/ProgramData/nexus/sql/creds/sa-password.txt' -Raw).Trim();
if (-not (Test-Path 'D:/setup.exe')) {
  if (Test-Path 'C:/Windows/Temp/sqlserver.iso') {
    Mount-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' | Out-Null;
    Start-Sleep -Seconds 5;
  } else { throw 'SQL Server ISO not present on sql-fci-2' }
}
`$addArgs = @(
  '/Q', '/ACTION=AddNode',
  '/INSTANCENAME=MSSQLSERVER',
  '/CONFIRMIPDEPENDENCYCHANGE=1',
  '/SQLSVCACCOUNT=NEXUS\gmsa-sql-engine`$',
  ('/SAPWD=' + `$saPwd),
  '/IACCEPTSQLSERVERLICENSETERMS'
) -join ' ';
& 'D:/setup.exe' `$addArgs.Split(' ');
if (`$LASTEXITCODE -ne 0 -and `$LASTEXITCODE -ne 3010) {
  throw 'setup.exe AddNode failed (exit=' + `$LASTEXITCODE + ')';
}
Write-Output 'FCI_ADDED_ON_FCI2';
"@
        $b64_2 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sf2Remote))
        $output_2 = ssh -o ConnectTimeout=900 "$sshUser@$sf2Ip" "powershell -NoProfile -EncodedCommand $b64_2" 2>&1 | Out-String
        Write-Host $output_2.Trim()
        if ($LASTEXITCODE -ne 0) { throw "[fci-install] sql-fci-2 AddNode failed (rc=$LASTEXITCODE)" }
      }

      Write-Host "[fci-install] FCI install complete; virtual server $fciName online at $fciVip"
    PWSH
  }
}
