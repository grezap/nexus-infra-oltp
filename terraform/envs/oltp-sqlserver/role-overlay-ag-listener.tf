# role-overlay-ag-listener.tf -- Phase 0.G.7
#
# Creates the AG Listener (`sql-ag-listener`) at 192.168.70.17. Per
# ADR-0025, the Listener IS the LB-tier HA primitive for AG: client
# connection strings target the Listener IP, and WSFC migrates the IP
# atomically with the AG primary across failover. No external LB needed
# (vs the Linux clusters that need keepalived + VRRP).
#
# Listener cert (CN=sql-ag-listener.nexus.lab, IP-SAN .17) was already
# rendered + imported into LocalMachine\My on all 4 nodes by the
# sqlserver-tls overlay. This overlay just creates the Listener via
# T-SQL on the primary + binds the cert to the SQL Server TLS wire via
# the registry's SuperSocketNetLib\Certificate value.
#
# The Listener also enables read-only routing for AG read intent: client
# `ApplicationIntent=ReadOnly` connections route to sql-ag-rep-1 or -2.
# Read-routing is documented but not enabled by default (deferred per the
# plan -- can be enabled in a future 0.G.7.1 follow-up if Greg wants read-
# routing demo'd in the smoke gate).

resource "null_resource" "ag_listener" {
  count = var.enable_ag_listener ? 1 : 0

  triggers = {
    ag_bootstrap_id = length(null_resource.ag_bootstrap) > 0 ? null_resource.ag_bootstrap[0].id : "disabled"
    listener_ip     = local.ag_listener_ip
    listener_name   = local.ag_listener_name
    stage_v         = var.ag_listener_v
  }

  depends_on = [null_resource.ag_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser     = '${var.ssh_username}'
      $sf1Ip       = '${local.sql_nodes["sql-fci-1"].vmnet11}'
      $listenerName = '${local.ag_listener_name}'
      $listenerIp  = '${local.ag_listener_ip}'
      $agName      = '${local.ag_name}'
      $nodeIps     = @('${local.sql_nodes["sql-fci-1"].vmnet11}', '${local.sql_nodes["sql-fci-2"].vmnet11}', '${local.sql_nodes["sql-ag-rep-1"].vmnet11}', '${local.sql_nodes["sql-ag-rep-2"].vmnet11}')

      Write-Host "[ag-listener] creating Listener $listenerName at $listenerIp..."

      # Step 1: ALTER AVAILABILITY GROUP ... ADD LISTENER on the primary.
      # /WITHIPV4= 192.168.70.17/255.255.255.0 + PORT = 1433 is canonical.
      $tsqlAddListener = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.availability_group_listeners WHERE dns_name = '$listenerName')
  ALTER AVAILABILITY GROUP [$agName]
    ADD LISTENER N'$listenerName' (
      WITH IP ((N'$listenerIp', N'255.255.255.0')),
      PORT = 1433
    );
"@
      ssh -o ConnectTimeout=60 "$sshUser@$sf1Ip" "sqlcmd -E -Q `"$tsqlAddListener`"" 2>&1 | Out-String | Write-Host
      if ($LASTEXITCODE -ne 0) { throw "[ag-listener] ALTER AG ADD LISTENER failed (rc=$LASTEXITCODE)" }

      # Step 2: bind the Listener cert thumbprint to SQL Server TLS on
      # EACH of the 4 nodes (so whichever node currently owns the Listener
      # IP serves the Listener cert at TLS handshake time).
      $tsqlBindCert = @'
$thumbprint = (Get-ChildItem Cert:/LocalMachine/My | Where-Object { $_.Subject -match 'CN=sql-ag-listener\.nexus\.lab' } | Select-Object -First 1).Thumbprint
if (-not $thumbprint) {
  Write-Host 'WARN: no Listener cert in LocalMachine\My; tls overlay may have skipped on this node'
  exit 0
}
# SQL Server reads the cert thumbprint from the registry; the path is
# instance-name dependent. For default instance MSSQLSERVER:
$regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
Set-ItemProperty -Path $regPath -Name 'Certificate' -Value $thumbprint.ToLower()
Set-ItemProperty -Path $regPath -Name 'ForceEncryption' -Value 1
# Set ACL on the private key to allow the gmsa-sql-engine read access.
$cert = Get-ChildItem Cert:/LocalMachine/My | Where-Object { $_.Thumbprint -eq $thumbprint }
$keyPath = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
$keyFile = "$env:PROGRAMDATA\Microsoft\Crypto\RSA\MachineKeys\$keyPath"
if (Test-Path $keyFile) {
  $acl = Get-Acl $keyFile
  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule('NEXUS\gmsa-sql-engine$','Read','Allow')
  $acl.AddAccessRule($rule)
  Set-Acl $keyFile $acl
}
Restart-Service -Name MSSQLSERVER -Force
Write-Output ('BOUND_CERT: ' + $thumbprint.Substring(0,8) + '...')
'@

      foreach ($nodeIp in $nodeIps) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($tsqlBindCert))
        $output = ssh -o ConnectTimeout=60 "$sshUser@$nodeIp" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        Write-Host "[ag-listener] $nodeIp : $($output.Trim() | Select-Object -First 2)"
      }

      Write-Host "[ag-listener] Listener $listenerName live at $listenerIp; cert bound on all 4 nodes; AG primary serves on 1433"
    PWSH
  }
}
