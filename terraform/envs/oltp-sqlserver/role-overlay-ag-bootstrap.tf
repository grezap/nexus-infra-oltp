# role-overlay-ag-bootstrap.tf -- Phase 0.G.7
#
# Creates the Always On Availability Group `nexus-ag` with:
#   - PRIMARY:        the FCI virtual server (sqlfci, .70.16)
#   - SECONDARY 1:    sql-ag-rep-1 (async commit)
#   - SECONDARY 2:    sql-ag-rep-2 (async commit)
#
# Per ADR-0027: AG endpoint authentication is certificate-based
# (CREATE ENDPOINT Hadr_endpoint AUTHENTICATION = CERTIFICATE). Each of the
# 3 AG participants creates its own Hadr_endpoint_cert in master; each then
# imports the OTHER 2 participants' public .cer + maps a login to it + grants
# CONNECT on the endpoint. The cert round-trip is done via scp (pull each
# node's .cer to the build host, push to the peers).
#
# AUTH CONTEXT: every T-SQL operation runs as NEXUS\nexusadmin via the
# schtasks Password-logon-type Scheduled Task pattern (same as wsfc-bootstrap
# + fci-install). NEXUS\nexusadmin is a SQL sysadmin on all 4 nodes:
#   - FCI (sqlfci): granted via setup.exe /SQLSYSADMINACCOUNTS=NEXUS\Domain Admins
#   - replicas: NEXUS\Domain Admins is in local BUILTIN\Administrators (the
#     replicas' standalone install granted sysadmin to BUILTIN\Administrators)
# so `sqlcmd -E` (integrated auth, runs as the task principal) is sysadmin
# everywhere. Transient #29 at 0.G.7 ratify 2026-05-21: the original `-E`
# over a plain SSH session ran as LOCAL nexusadmin (sysadmin only on the
# replicas, NOT the FCI) -- the domain-task pattern fixes that.
#
# The 3 AG-participant T-SQL targets dispatch to:
#   - FCI:   sql-fci-1 (the active FCI owner at bootstrap), sqlcmd -S sqlfci
#   - rep-1: sql-ag-rep-1, sqlcmd -S .
#   - rep-2: sql-ag-rep-2, sqlcmd -S .
#
# A demo user DB `nexus_demo` is created on the FCI + added to the AG so the
# smoke gate has something to verify replication state on.

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
      $rep1Ip   = '${local.sql_nodes["sql-ag-rep-1"].vmnet11}'
      $rep2Ip   = '${local.sql_nodes["sql-ag-rep-2"].vmnet11}'
      $fciName  = '${local.fci_virtual_server_name}'
      $agName   = '${local.ag_name}'

      # Domain creds for the schtasks Password-logon-type dispatch.
      $adCredsJson = Join-Path $HOME ".nexus/nexusadmin-credentials.json"
      if (-not (Test-Path $adCredsJson)) { throw "[ag-bootstrap] nexusadmin-credentials.json not found at $adCredsJson" }
      $adCreds   = Get-Content $adCredsJson -Raw | ConvertFrom-Json
      $adNetbios = if ($adCreds.PSObject.Properties['netbios']) { $adCreds.netbios } else { 'NEXUS' }
      $adUser    = "$adNetbios\$($adCreds.username)"
      $adPass    = $adCreds.password

      # ── Helper: run a T-SQL batch on $ip as NEXUS\nexusadmin (sysadmin
      #    everywhere) via a Scheduled Task. $sqlServer is the -S target
      #    (e.g. 'sqlfci' for the FCI, '.' for a replica's local instance).
      #    Returns the task transcript. Mirrors fci-install's Invoke-AsDomainTask.
      function Invoke-Tsql {
        param([string]$ip, [string]$tag, [string]$sqlServer, [string]$tsql, [int]$timeoutMin = 10)

        $tsqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tsql))
        $logFile = "C:/Windows/Temp/$tag.log"
        # Orchestrate: decode the T-SQL + run via sqlcmd -E -S <server>.
        # Transient #29b at 0.G.7 ratify 2026-05-22: sqlcmd's -i argument
        # mis-parses FORWARD-slash paths ('C:/Windows/Temp/x.sql' -> it splits
        # at the first '/' + tries to open file 'C:' -> "Access is denied").
        # Use BACKSLASH paths for the sqlcmd -i temp file.
        $orchestrate = @"
`$ErrorActionPreference = 'Continue';
Start-Transcript -Path '$logFile' -Force | Out-Null;
`$tsql = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$tsqlB64'));
`$tmpSql = 'C:\Windows\Temp\$tag.sql';
Set-Content -Path `$tmpSql -Value `$tsql -Encoding UTF8;
& sqlcmd -S '$sqlServer' -E -b -i `$tmpSql;
`$rc = `$LASTEXITCODE;
Write-Output ('SQLCMD_RC=' + `$rc);
Remove-Item `$tmpSql -ErrorAction SilentlyContinue;
if (`$rc -eq 0) { Write-Output 'TSQL_OK'; } else { Write-Output 'TSQL_FAIL'; }
Stop-Transcript | Out-Null;
"@

        $wrapper = @"
`$ErrorActionPreference = 'Continue';
`$scriptPath = 'C:/Windows/Temp/$tag-orchestrate.ps1';
`$logPath = '$logFile';
Remove-Item `$logPath -ErrorAction SilentlyContinue;
Remove-Item `$scriptPath -ErrorAction SilentlyContinue;
@'
$orchestrate
'@ | Set-Content -Path `$scriptPath -Encoding UTF8;
`$taskName = '$tag';
try { schtasks /Delete /TN `$taskName /F 2>&1 | Out-Null } catch {};
schtasks /Create /TN `$taskName /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$scriptPath" /SC ONCE /ST 23:59 /RU '$adUser' /RP '$adPass' /RL HIGHEST /F | Out-Null;
schtasks /Run /TN `$taskName | Out-Null;
`$deadline = (Get-Date).AddMinutes($timeoutMin);
`$done = `$false;
do {
  Start-Sleep -Seconds 8;
  if (Test-Path `$logPath) {
    `$lc = Get-Content `$logPath -Raw -ErrorAction SilentlyContinue;
    if (`$lc -match 'Windows PowerShell transcript end') { `$done = `$true; }
  }
  `$status = schtasks /Query /TN `$taskName /FO LIST /V 2>`$null | Select-String 'Status:' | Select-Object -First 1;
  `$stillRunning = `$status -match 'Running';
} while ((-not `$done) -and `$stillRunning -and ((Get-Date) -lt `$deadline));
Start-Sleep -Seconds 2;
if (Test-Path `$logPath) { Get-Content `$logPath -Raw; }
try { schtasks /Delete /TN `$taskName /F 2>&1 | Out-Null } catch {};
Remove-Item `$scriptPath -ErrorAction SilentlyContinue;
"@
        $tempLocal = Join-Path $env:TEMP "$tag-wrapper-$([System.Guid]::NewGuid().ToString('N')).ps1"
        $wrapper | Out-File -FilePath $tempLocal -Encoding UTF8 -Force
        $remoteSrc = "C:/Windows/Temp/nexus-$tag-wrapper.ps1"
        scp -o ConnectTimeout=30 -o BatchMode=yes $tempLocal "$sshUser@$($ip):$remoteSrc" 2>&1 | Out-Null
        $scpRc = $LASTEXITCODE
        Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue
        if ($scpRc -ne 0) { throw "[ag-bootstrap] scp of $tag wrapper to $ip failed (rc=$scpRc)" }
        $out = ssh -o ConnectTimeout=120 "$sshUser@$ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteSrc" 2>&1 | Out-String
        ssh -o ConnectTimeout=10 "$sshUser@$ip" "Remove-Item -Path '$remoteSrc' -ErrorAction SilentlyContinue" 2>&1 | Out-Null
        return $out
      }

      Write-Host "[ag-bootstrap] creating AG $agName (FCI primary $fciName + 2 async replicas)..."

      # The 3 AG participants: (dispatch IP, tag, sqlcmd -S target, @@SERVERNAME).
      # The FCI is reached via sql-fci-1 (active owner) targeting -S sqlfci so
      # @@SERVERNAME returns the FCI virtual server name.
      $participants = @(
        @{ Ip = $sf1Ip;  Tag = 'fci';   Server = $fciName; Name = $fciName },
        @{ Ip = $rep1Ip; Tag = 'rep1';  Server = '.';      Name = 'sql-ag-rep-1' },
        @{ Ip = $rep2Ip; Tag = 'rep2';  Server = '.';      Name = 'sql-ag-rep-2' }
      )

      # ── Step 1: each participant creates MASTER KEY + Hadr_endpoint_cert +
      #    backs up the public .cer (no private key needed for peer import).
      $tsqlCreateCert = @'
DECLARE @pwd nvarchar(400) = (SELECT TOP 1 password_text FROM OPENROWSET(BULK 'C:\ProgramData\nexus\sql\creds\ag-endpoint-cert-password.txt', SINGLE_CLOB) AS T(password_text));
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
  EXEC('CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + @pwd + ''';');
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'Hadr_endpoint_cert')
  EXEC('CREATE CERTIFICATE Hadr_endpoint_cert WITH SUBJECT = ''AG endpoint cert for ' + @@SERVERNAME + ''';');
DECLARE @cerPath nvarchar(400) = 'C:\ProgramData\nexus\sql\tls\' + REPLACE(@@SERVERNAME, '\', '_') + '.endpoint.cer';
IF NOT EXISTS (SELECT 1 FROM sys.dm_os_file_exists(@cerPath) WHERE file_exists = 1)
  EXEC('BACKUP CERTIFICATE Hadr_endpoint_cert TO FILE = ''' + @cerPath + ''';');
SELECT 'CER_AT=' + @cerPath;
'@
      foreach ($p in $participants) {
        Write-Host "[ag-bootstrap] step 1: create endpoint cert on $($p.Name)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agcert-$($p.Tag)" -sqlServer $p.Server -tsql $tsqlCreateCert
        if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] cert create failed on $($p.Name)" }
      }

      # ── Step 2: distribute each participant's .cer to the other 2 via the
      #    build host (pull then push). Cert filenames use @@SERVERNAME with
      #    backslash->underscore (FCI name has no backslash; replicas are bare).
      $certNames = @{ fci = $fciName; rep1 = 'sql-ag-rep-1'; rep2 = 'sql-ag-rep-2' }
      $localCertDir = Join-Path $env:TEMP "ag-certs-$([System.Guid]::NewGuid().ToString('N'))"
      New-Item -ItemType Directory -Force -Path $localCertDir | Out-Null
      foreach ($p in $participants) {
        $cerFile = "$($certNames[$p.Tag]).endpoint.cer"
        scp -o ConnectTimeout=30 "$sshUser@$($p.Ip):C:/ProgramData/nexus/sql/tls/$cerFile" "$localCertDir/$cerFile" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[ag-bootstrap] pull cert $cerFile from $($p.Name) failed" }
      }
      foreach ($p in $participants) {
        foreach ($q in $participants) {
          if ($p.Tag -eq $q.Tag) { continue }
          $peerCer = "$($certNames[$q.Tag]).endpoint.cer"
          scp -o ConnectTimeout=30 "$localCertDir/$peerCer" "$sshUser@$($p.Ip):C:/ProgramData/nexus/sql/tls/$peerCer" 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "[ag-bootstrap] push cert $peerCer to $($p.Name) failed" }
        }
      }
      Remove-Item -Recurse -Force $localCertDir -ErrorAction SilentlyContinue

      # ── Step 3: each participant imports the other 2 peers' certs as
      #    login-mapped certs + creates the endpoint with cert auth.
      foreach ($p in $participants) {
        $peerImports = ""
        foreach ($q in $participants) {
          if ($p.Tag -eq $q.Tag) { continue }
          $peerName = $certNames[$q.Tag]
          $peerLogin = "ag_login_" + ($peerName -replace '[^A-Za-z0-9]', '_')
          $peerCert  = "ag_cert_"  + ($peerName -replace '[^A-Za-z0-9]', '_')
          $peerCer   = "C:\ProgramData\nexus\sql\tls\$peerName.endpoint.cer"
          $peerImports += @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$peerLogin')
  CREATE LOGIN [$peerLogin] FROM WINDOWS;
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$peerCert')
  CREATE CERTIFICATE [$peerCert] FROM FILE = '$peerCer';

"@
        }
        # NOTE: AG endpoint cert-auth maps a CERTIFICATE-based login (not
        # Windows) to each peer cert. Build the per-peer login+cert+grant.
        $endpointTsql = @"
$peerImports
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
        Write-Host "[ag-bootstrap] step 3: import peer certs + create endpoint on $($p.Name)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agep-$($p.Tag)" -sqlServer $p.Server -tsql $endpointTsql
        if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] endpoint create failed on $($p.Name)" }
      }

      # ── Step 3b: each participant grants CONNECT on the endpoint to the
      #    other 2 peers' cert-mapped logins. (Separate batch so the logins
      #    + certs from step 3 are committed first.)
      foreach ($p in $participants) {
        $grants = ""
        foreach ($q in $participants) {
          if ($p.Tag -eq $q.Tag) { continue }
          $peerName = $certNames[$q.Tag]
          $peerLogin = "ag_login_" + ($peerName -replace '[^A-Za-z0-9]', '_')
          $peerCert  = "ag_cert_"  + ($peerName -replace '[^A-Za-z0-9]', '_')
          # Re-map the cert-login to use the imported cert for endpoint auth.
          $grants += @"
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$peerLogin')
  GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [$peerLogin];

"@
        }
        if ($grants.Trim().Length -gt 0) {
          $o = Invoke-Tsql -ip $p.Ip -tag "aggrant-$($p.Tag)" -sqlServer $p.Server -tsql $grants
          if ($o -notmatch 'TSQL_OK') { Write-Host $o; Write-Host "[ag-bootstrap] WARN: grant on $($p.Name) reported non-OK (may already be granted)" }
        }
      }

      # ── Step 4: on the FCI primary, CREATE AVAILABILITY GROUP.
      $tsqlCreateAg = @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = '$agName')
  CREATE AVAILABILITY GROUP [$agName]
    WITH ( AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE )
    FOR REPLICA ON
      N'$fciName' WITH (
        ENDPOINT_URL = N'TCP://$${fciName}.nexus.lab:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC ),
      N'sql-ag-rep-1' WITH (
        ENDPOINT_URL = N'TCP://sql-ag-rep-1.nexus.lab:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC ),
      N'sql-ag-rep-2' WITH (
        ENDPOINT_URL = N'TCP://sql-ag-rep-2.nexus.lab:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        SEEDING_MODE = AUTOMATIC );
"@
      Write-Host "[ag-bootstrap] step 4: CREATE AVAILABILITY GROUP $agName on FCI primary..."
      $o = Invoke-Tsql -ip $sf1Ip -tag 'agcreate' -sqlServer $fciName -tsql $tsqlCreateAg -timeoutMin 10
      if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] CREATE AVAILABILITY GROUP failed" }

      # ── Step 5: each replica JOINs the AG + grants create-any-database.
      foreach ($p in @($participants[1], $participants[2])) {
        $joinTsql = @"
ALTER AVAILABILITY GROUP [$agName] JOIN;
ALTER AVAILABILITY GROUP [$agName] GRANT CREATE ANY DATABASE;
"@
        Write-Host "[ag-bootstrap] step 5: JOIN AG on $($p.Name)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agjoin-$($p.Tag)" -sqlServer $p.Server -tsql $joinTsql
        if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] AG JOIN failed on $($p.Name)" }
      }

      # ── Step 6: demo DB on the FCI primary + add to AG (auto-seed to replicas).
      $tsqlDemoDb = @"
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'nexus_demo') BEGIN
  CREATE DATABASE nexus_demo ON (NAME = N'nexus_demo', FILENAME = N'S:\SQLData\nexus_demo.mdf') LOG ON (NAME = N'nexus_demo_log', FILENAME = N'S:\SQLData\nexus_demo_log.ldf');
  ALTER DATABASE nexus_demo SET RECOVERY FULL;
  BACKUP DATABASE nexus_demo TO DISK = 'S:\SQLData\nexus_demo.bak' WITH INIT;
  ALTER AVAILABILITY GROUP [$agName] ADD DATABASE nexus_demo;
END
"@
      Write-Host "[ag-bootstrap] step 6: create nexus_demo DB + add to AG..."
      $o = Invoke-Tsql -ip $sf1Ip -tag 'agdemodb' -sqlServer $fciName -tsql $tsqlDemoDb -timeoutMin 10
      if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] demo DB create failed" }

      Write-Host "[ag-bootstrap] AG $agName created (FCI primary $fciName + 2 async replicas + nexus_demo DB)"
    PWSH
  }
}
