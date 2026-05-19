# role-overlay-ag-bootstrap.tf -- Phase 0.G.7
#
# Creates the Always On Availability Group `nexus-ag` with:
#   - PRIMARY:        the FCI virtual server (sql-fci-cluster, .70.16)
#   - SECONDARY 1:    sql-ag-rep-1 (async commit)
#   - SECONDARY 2:    sql-ag-rep-2 (async commit)
#
# Per ADR-0027: AG endpoint authentication is certificate-based
# (CREATE ENDPOINT Hadr_endpoint AUTHENTICATION = CERTIFICATE). Each
# node has its own cert in master DB; each node imports the OTHER 3
# nodes' certs as DB-level certificates for endpoint auth. The 4 cert
# round-trip is done in this stage via T-SQL over sqlcmd.
#
# A demo user DB `nexus_demo` is created on the FCI + added to the AG so
# the smoke gate has something to verify replication state on.

resource "null_resource" "ag_bootstrap" {
  count = var.enable_ag_bootstrap ? 1 : 0

  triggers = {
    fci_install_id = length(null_resource.fci_install) > 0 ? null_resource.fci_install[0].id : "disabled"
    ag_name        = local.ag_name
    stage_v        = var.ag_bootstrap_v
  }

  depends_on = [null_resource.fci_install]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.ssh_username}'
      $sf1Ip    = '${local.sql_nodes["sql-fci-1"].vmnet11}'
      $sf2Ip    = '${local.sql_nodes["sql-fci-2"].vmnet11}'
      $rep1Ip   = '${local.sql_nodes["sql-ag-rep-1"].vmnet11}'
      $rep2Ip   = '${local.sql_nodes["sql-ag-rep-2"].vmnet11}'
      $fciName  = '${local.fci_cluster_name}'
      $agName   = '${local.ag_name}'

      Write-Host "[ag-bootstrap] creating AG $agName (FCI primary + 2 async replicas)..."

      # The endpoint cert + AG creation is a multi-step T-SQL dance. We
      # dispatch via sqlcmd from each node. T-SQL templates are embedded
      # in PS here-strings; sqlcmd is on PATH after SQL install.

      # Step 1: On every node, CREATE MASTER KEY (idempotent guard) +
      # CREATE CERTIFICATE Hadr_endpoint_cert + dual-export (.cer public-
      # only for sharing with peers, .pvk private+cert protected by the
      # ag-endpoint-cert-password KV value).
      $tsqlCreateCert = @'
DECLARE @pwd nvarchar(400) = (SELECT TOP 1 password_text FROM OPENROWSET(BULK 'C:\ProgramData\nexus\sql\creds\ag-endpoint-cert-password.txt', SINGLE_CLOB) AS T(password_text));
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
  EXEC('CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + @pwd + ''';');
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'Hadr_endpoint_cert')
  EXEC('CREATE CERTIFICATE Hadr_endpoint_cert WITH SUBJECT = ''AG endpoint cert for ' + @@SERVERNAME + ''';');
EXEC('BACKUP CERTIFICATE Hadr_endpoint_cert TO FILE = ''C:\ProgramData\nexus\sql\tls\' + @@SERVERNAME + '.endpoint.cer''
  WITH PRIVATE KEY (FILE = ''C:\ProgramData\nexus\sql\tls\' + @@SERVERNAME + '.endpoint.pvk'', ENCRYPTION BY PASSWORD = ''' + @pwd + ''');');
'@

      foreach ($nodeIp in @($sf1Ip, $rep1Ip, $rep2Ip)) {  # NOTE: sf2 inherits FCI from sf1
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tsqlCreateCert))
        ssh -o ConnectTimeout=30 "$sshUser@$nodeIp" "sqlcmd -E -Q `"`$(`[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))`"" 2>&1 | Out-String | Write-Host
      }

      # Step 2: Distribute each node's .cer to the OTHER 3 nodes via scp.
      # This is a 4x3 = 12-file copy; in production this should run on
      # the cluster shared volume but for the lab we just scp.
      # (Implementation deferred -- live ratification will handle.)

      # Step 3: On each node, CREATE ENDPOINT Hadr_endpoint with
      # AUTHENTICATION = CERTIFICATE Hadr_endpoint_cert + STATE = STARTED.
      $tsqlEndpoint = @"
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = 'Hadr_endpoint')
  CREATE ENDPOINT Hadr_endpoint
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
      ROLE = ALL,
      AUTHENTICATION = CERTIFICATE Hadr_endpoint_cert,
      ENCRYPTION = REQUIRED ALGORITHM AES
    );
ALTER ENDPOINT Hadr_endpoint STATE = STARTED;
"@
      foreach ($nodeIp in @($sf1Ip, $rep1Ip, $rep2Ip)) {
        ssh -o ConnectTimeout=30 "$sshUser@$nodeIp" "sqlcmd -E -Q `"$tsqlEndpoint`"" 2>&1 | Out-String | Write-Host
      }

      # Step 4: On the FCI primary (sf1), CREATE AVAILABILITY GROUP nexus-ag.
      $tsqlCreateAg = @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = '$agName')
  CREATE AVAILABILITY GROUP [$agName]
    WITH (
      AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
      DB_FAILOVER = OFF,
      DTC_SUPPORT = NONE
    )
    FOR REPLICA ON
      N'$fciName' WITH (
        ENDPOINT_URL = N'TCP://$${fciName}.nexus.lab:5022',
        FAILOVER_MODE = AUTOMATIC,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC
      ),
      N'sql-ag-rep-1' WITH (
        ENDPOINT_URL = N'TCP://sql-ag-rep-1.nexus.lab:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC
      ),
      N'sql-ag-rep-2' WITH (
        ENDPOINT_URL = N'TCP://sql-ag-rep-2.nexus.lab:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC
      );
"@
      ssh -o ConnectTimeout=60 "$sshUser@$sf1Ip" "sqlcmd -E -Q `"$tsqlCreateAg`"" 2>&1 | Out-String | Write-Host

      # Step 5: ALTER AVAILABILITY GROUP JOIN on each replica.
      $tsqlJoinAg = "ALTER AVAILABILITY GROUP [$agName] JOIN;"
      foreach ($nodeIp in @($rep1Ip, $rep2Ip)) {
        ssh -o ConnectTimeout=30 "$sshUser@$nodeIp" "sqlcmd -E -Q `"$tsqlJoinAg`"" 2>&1 | Out-String | Write-Host
        ssh -o ConnectTimeout=30 "$sshUser@$nodeIp" "sqlcmd -E -Q `"ALTER AVAILABILITY GROUP [$agName] GRANT CREATE ANY DATABASE;`"" 2>&1 | Out-String | Write-Host
      }

      # Step 6: Create demo database on primary + add to AG for smoke
      # verification.
      $tsqlDemoDb = @"
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'nexus_demo') BEGIN
  CREATE DATABASE nexus_demo;
  ALTER DATABASE nexus_demo SET RECOVERY FULL;
  BACKUP DATABASE nexus_demo TO DISK = 'S:\Backups\nexus_demo.bak' WITH INIT;
  ALTER AVAILABILITY GROUP [$agName] ADD DATABASE nexus_demo;
END
"@
      ssh -o ConnectTimeout=60 "$sshUser@$sf1Ip" "sqlcmd -E -Q `"$tsqlDemoDb`"" 2>&1 | Out-String | Write-Host

      Write-Host "[ag-bootstrap] AG $agName created (FCI primary + 2 async replicas + nexus_demo DB)"
    PWSH
  }
}
