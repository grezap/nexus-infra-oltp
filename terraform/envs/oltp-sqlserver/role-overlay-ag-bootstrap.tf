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
      $sf2Ip    = '${local.sql_nodes["sql-fci-2"].vmnet11}'
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
        param([string]$ip, [string]$tag, [string]$sqlServer, [string]$tsql, [int]$timeoutMin = 10, [string]$pwFile = "")

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
# Password injection (transient #29d at 0.G.7 ratify 2026-05-22): the AG
# endpoint cert password can't be read via T-SQL OPENROWSET BULK -- that runs
# as the SQL service (gmsa-sql-engine`$) which lacks NTFS read on the 0640
# vault-agent-rendered creds file (Msg 4860 "cannot bulk load ... file does
# not exist [or no access]"). Instead this orchestrate -- running as NEXUS\
# nexusadmin (a local admin, can read the file) -- reads the password + text-
# substitutes the __AGPW__ placeholder before sqlcmd runs. The password lives
# only in the temp .sql file briefly (deleted after).
`$pwFile = '$pwFile';
if (`$pwFile -and (Test-Path `$pwFile)) {
  `$agpw = (Get-Content `$pwFile -Raw).Trim();
  `$tsql = `$tsql.Replace('__AGPW__', `$agpw);
}
`$tmpSql = 'C:\Windows\Temp\$tag.sql';
Set-Content -Path `$tmpSql -Value `$tsql -Encoding UTF8;
# -C (TrustServerCertificate): transient #29c at 0.G.7 ratify 2026-05-22.
# sqlcmd's ODBC Driver 18 defaults to Encrypt=Mandatory + validates the
# server cert chain; -S sqlfci presents the Vault-PKI FCI cert which the
# client doesn't chain-validate -> "SSL Provider: certificate chain ... not
# trusted". -C trusts the cert (lab-internal AG bootstrap; the wire is still
# encrypted). Client-side cert trust is a smoke-gate concern, not bootstrap.
& sqlcmd -S '$sqlServer' -E -C -b -i `$tmpSql;
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

      # ── Step 0: ensure MSSQLSERVER is RUNNING on every AG participant.
      #    Transient #29g at 0.G.7 ratify 2026-05-22: the AG-replica standalone
      #    instances (sql-ag-rep-1/2) were Stopped (left by the unclean power-off
      #    in #28 + the FCI-install reboots), so sqlcmd -S . couldn't connect
      #    ("Named Pipes ... Login timeout"). Cold-rebuild-defensive: set the
      #    service Automatic + Start it on each participant. Simple local-admin
      #    SSH (no domain context needed to start a service). The FCI's SQL is
      #    cluster-managed (already Online from fci-install); Start-Service on
      #    the active FCI node is a harmless no-op.
      foreach ($p in $participants) {
        Write-Host "[ag-bootstrap] step 0: ensure MSSQLSERVER running on $($p.Name)..."
        ssh -o ConnectTimeout=20 "$sshUser@$($p.Ip)" "Set-Service -Name MSSQLSERVER -StartupType Automatic -EA SilentlyContinue; Start-Service -Name MSSQLSERVER -EA SilentlyContinue; Start-Sleep -Seconds 3; (Get-Service MSSQLSERVER).Status" 2>&1 | Out-String | ForEach-Object { Write-Host ("  " + $_.Trim()) }
      }

      # ── Step 0b: correct @@SERVERNAME on the standalone replicas.
      #    Transient #29h at 0.G.7 ratify 2026-05-22: the standalone SQL
      #    instances (sql-ag-rep-1/2) were installed during the Packer bake when
      #    the machine was named 'OLTPSQL-BAKE', so @@SERVERNAME is pinned to
      #    'OLTPSQL-BAKE' on BOTH replicas (SQL Server captures the server name
      #    at install time + never updates it on a host rename). This breaks
      #    (a) the endpoint cert filename -- REPLACE(@@SERVERNAME,'\','_') makes
      #    BOTH replicas write 'OLTPSQL-BAKE.endpoint.cer' (a collision, and the
      #    step-2 scp pull of 'sql-ag-rep-1.endpoint.cer' 404s) AND (b) AG
      #    itself -- replicas are identified by @@SERVERNAME, so CREATE/JOIN AG
      #    with the stale name fails. Fix: sp_dropserver + sp_addserver to the
      #    real MachineName, then restart MSSQLSERVER for @@SERVERNAME to take
      #    effect. Idempotent (the IF-guard no-ops once names match). The FCI's
      #    @@SERVERNAME is already correct ('sqlfci', set at FCI install) so only
      #    the 2 replicas need this. Cold-rebuild-defensive: runs every apply.
      $fixServerName = @'
DECLARE @m sysname = CAST(SERVERPROPERTY('MachineName') AS sysname);
IF @@SERVERNAME <> @m BEGIN EXEC sp_dropserver @@SERVERNAME; EXEC sp_addserver @m, 'local'; END
SELECT 'SERVERNAME_PRE=' + @@SERVERNAME;
'@
      foreach ($p in @($participants[1], $participants[2])) {
        Write-Host "[ag-bootstrap] step 0b: correct @@SERVERNAME on $($p.Name)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agsrvname-$($p.Tag)" -sqlServer $p.Server -tsql $fixServerName
        if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] @@SERVERNAME fix failed on $($p.Name)" }
        # Also enable Always On Availability Groups (HADR) on this replica now --
        # a per-node registry setting read at SQL service start -- so the single
        # restart below applies BOTH the @@SERVERNAME change AND HADR. Transient
        # #29j at 0.G.7 ratify 2026-05-22: CREATE AVAILABILITY GROUP fails with
        # Msg 35221 "Always On Availability Groups replica manager is disabled"
        # unless every participating instance has HADR enabled.
        ssh -o ConnectTimeout=60 "$sshUser@$($p.Ip)" "Enable-SqlAlwaysOn -ServerInstance localhost -NoServiceRestart -Force -EA SilentlyContinue" 2>&1 | Out-Null
        # sp_addserver + HADR both need a SQL service restart to take effect.
        # Restart, wait for the instance to come back, then verify @@SERVERNAME.
        Write-Host "[ag-bootstrap] step 0b: restart MSSQLSERVER on $($p.Name) to apply @@SERVERNAME + HADR..."
        ssh -o ConnectTimeout=30 "$sshUser@$($p.Ip)" "Restart-Service -Name MSSQLSERVER -Force; Start-Sleep -Seconds 6; (Get-Service MSSQLSERVER).Status" 2>&1 | Out-String | ForEach-Object { Write-Host ("  " + $_.Trim()) }
        $verifyTsql = "SET NOCOUNT ON; SELECT 'SERVERNAME_NOW=' + @@SERVERNAME;"
        $v = Invoke-Tsql -ip $p.Ip -tag "agsrvverify-$($p.Tag)" -sqlServer $p.Server -tsql $verifyTsql
        if ($v -notmatch ('SERVERNAME_NOW=' + [regex]::Escape($p.Name))) {
          Write-Host $v
          throw "[ag-bootstrap] @@SERVERNAME on $($p.Name) did not update to $($p.Name) after restart"
        }
        Write-Host "  [ag-bootstrap] @@SERVERNAME on $($p.Name) is now $($p.Name)"
      }

      # ── Step 0c: enable HADR on the FCI. Transient #29j at 0.G.7 ratify
      #    2026-05-22: the FCI's @@SERVERNAME is already correct ('sqlfci', set
      #    at FCI install) but HADR is off -- the InstallFailoverCluster re-image
      #    dropped the Packer-baked AlwaysOn extensibility -- so CREATE
      #    AVAILABILITY GROUP fails Msg 35221. HADR is a per-node registry
      #    setting read when the SQL instance starts on that node, so enable it
      #    on BOTH FCI nodes (covers failover), then cycle the clustered SQL
      #    group so the active instance re-reads it. Stop/Start-ClusterGroup
      #    cycles ALL resources in the group (handles the SQL Server / Agent /
      #    CEIP dependency order automatically). Brief FCI virtual-server
      #    downtime; harmless during bootstrap.
      foreach ($fciIp in @($sf1Ip, $sf2Ip)) {
        Write-Host "[ag-bootstrap] step 0c: enable HADR (no-restart) on FCI node $fciIp..."
        ssh -o ConnectTimeout=60 "$sshUser@$fciIp" "Enable-SqlAlwaysOn -ServerInstance localhost -NoServiceRestart -Force -EA SilentlyContinue" 2>&1 | Out-Null
      }
      Write-Host "[ag-bootstrap] step 0c: cycle the FCI SQL Server cluster group (apply HADR)..."
      $cycleScript = @'
$ErrorActionPreference = 'Continue'
Import-Module FailoverClusters -EA SilentlyContinue
$grp = (Get-ClusterResource -Name 'SQL Server').OwnerGroup.Name
Stop-ClusterGroup -Name $grp | Out-Null
Start-Sleep -Seconds 4
Start-ClusterGroup -Name $grp | Out-Null
Start-Sleep -Seconds 6
Write-Output ('SQLRES_STATE=' + (Get-ClusterResource -Name 'SQL Server').State)
'@
      $cycleB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cycleScript))
      $cyc = ssh -o ConnectTimeout=180 "$sshUser@$sf1Ip" "powershell -NoProfile -EncodedCommand $cycleB64" 2>&1 | Out-String
      Write-Host ("  " + $cyc.Trim())
      if ($cyc -notmatch 'SQLRES_STATE=Online') { throw "[ag-bootstrap] FCI 'SQL Server' resource not Online after HADR cycle: $cyc" }

      # ── Step 1: each participant creates MASTER KEY + Hadr_endpoint_cert +
      #    backs up the public .cer (no private key needed for peer import).
      $tsqlCreateCert = @'
DECLARE @pwd nvarchar(400) = N'__AGPW__';
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
  EXEC('CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + @pwd + ''';');
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'Hadr_endpoint_cert')
  EXEC('CREATE CERTIFICATE Hadr_endpoint_cert WITH SUBJECT = ''AG endpoint cert for ' + @@SERVERNAME + ''';');
-- BACKUP/FROM FILE run as the SQL service (gmsa) -> use C:\Windows\Temp which
-- the service can read+write (the vault-agent tls dir is not gmsa-writable).
-- Transient #29e at 0.G.7 ratify 2026-05-22.
DECLARE @cerPath nvarchar(400) = 'C:\Windows\Temp\' + REPLACE(@@SERVERNAME, '\', '_') + '.endpoint.cer';
IF NOT EXISTS (SELECT 1 FROM sys.dm_os_file_exists(@cerPath) WHERE file_exists = 1)
  EXEC('BACKUP CERTIFICATE Hadr_endpoint_cert TO FILE = ''' + @cerPath + ''';');
SELECT 'CER_AT=' + @cerPath;
'@
      foreach ($p in $participants) {
        Write-Host "[ag-bootstrap] step 1: create endpoint cert on $($p.Name)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agcert-$($p.Tag)" -sqlServer $p.Server -tsql $tsqlCreateCert -pwFile 'C:\ProgramData\nexus\sql\creds\ag-endpoint-cert-password.txt'
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
        scp -o ConnectTimeout=30 "$sshUser@$($p.Ip):C:/Windows/Temp/$cerFile" "$localCertDir/$cerFile" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[ag-bootstrap] pull cert $cerFile from $($p.Name) failed" }
      }
      foreach ($p in $participants) {
        foreach ($q in $participants) {
          if ($p.Tag -eq $q.Tag) { continue }
          $peerCer = "$($certNames[$q.Tag]).endpoint.cer"
          scp -o ConnectTimeout=30 "$localCertDir/$peerCer" "$sshUser@$($p.Ip):C:/Windows/Temp/$peerCer" 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "[ag-bootstrap] push cert $peerCer to $($p.Name) failed" }
        }
        # Grant read on the pushed peer certs to the SQL service account.
        # Transient #29i at 0.G.7 ratify 2026-05-22: CREATE CERTIFICATE FROM FILE
        # (step 3) runs as the SQL SERVICE account (NEXUS\gmsa-sql-engine$ on the
        # FCI, NT AUTHORITY\NETWORK SERVICE on the replicas), NOT as nexusadmin --
        # and scp writes each .cer with an ACL of only BUILTIN\Administrators +
        # NT AUTHORITY\SYSTEM (no inheritance from C:\Windows\Temp), so the
        # service account hits Msg 15208 "...you do not have permissions for it."
        # These are PUBLIC certs (BACKUP CERTIFICATE w/o PRIVATE KEY exports the
        # public key only), so granting read to Everyone (*S-1-1-0) is harmless +
        # avoids the 3-layer $-escaping of the per-node service-account name.
        $grantCmd = 'icacls "C:\Windows\Temp\*.endpoint.cer" /grant "*S-1-1-0:(R)" /Q'
        ssh -o ConnectTimeout=30 "$sshUser@$($p.Ip)" $grantCmd 2>&1 | Out-Null
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
          $peerCer   = "C:\Windows\Temp\$peerName.endpoint.cer"
          # AG endpoint cert-auth: the peer LOGIN is mapped FROM the peer's
          # CERTIFICATE (not FROM WINDOWS) -- transient #29f. The certificate
          # MUST be created before the login that references it.
          $peerImports += @"
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$peerCert')
  CREATE CERTIFICATE [$peerCert] FROM FILE = '$peerCer';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$peerLogin')
  CREATE LOGIN [$peerLogin] FROM CERTIFICATE [$peerCert];

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
      #    The 2 async replicas use SEEDING_MODE = MANUAL (transient #29k at
      #    0.G.7 ratify 2026-05-22): the FCI primary keeps its databases on the
      #    shared iSCSI disk S:\ (so they survive an FCI node failover), but the
      #    standalone replicas have only local C:\ -- so AUTOMATIC seeding fails
      #    ("failure_state = Seeding") trying to create S:\SQLData\*.mdf on a node
      #    with no S: drive. Step 6 seeds manually (backup -> copy -> RESTORE WITH
      #    MOVE NORECOVERY -> SET HADR AVAILABILITY GROUP), which is path-agnostic.
      #    The FCI replica stays AUTOMATIC -- if the AG ever fails over to a
      #    standalone replica and the FCI rejoins as secondary, auto-seed back to
      #    the FCI's S:\ (which exists there) works fine.
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
        SEEDING_MODE = MANUAL ),
      N'sql-ag-rep-2' WITH (
        ENDPOINT_URL = N'TCP://sql-ag-rep-2.nexus.lab:5022',
        FAILOVER_MODE = MANUAL,
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        SEEDING_MODE = MANUAL );
"@
      Write-Host "[ag-bootstrap] step 4: CREATE AVAILABILITY GROUP $agName on FCI primary..."
      $o = Invoke-Tsql -ip $sf1Ip -tag 'agcreate' -sqlServer $fciName -tsql $tsqlCreateAg -timeoutMin 10
      if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] CREATE AVAILABILITY GROUP failed" }

      # ── Step 5: each replica JOINs the AG + grants create-any-database.
      #    Idempotent (transient #29L at 0.G.7 ratify 2026-05-22): a re-run after
      #    a successful JOIN hits Msg 41106 "an availability replica ... already
      #    exists on this instance." Guard on dm_hadr_availability_replica_states
      #    is_local = 1 (set once this instance hosts the AG replica).
      foreach ($p in @($participants[1], $participants[2])) {
        $joinTsql = @"
IF NOT EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id WHERE ag.name = '$agName' AND rs.is_local = 1)
BEGIN
  ALTER AVAILABILITY GROUP [$agName] JOIN;
  ALTER AVAILABILITY GROUP [$agName] GRANT CREATE ANY DATABASE;
END
"@
        Write-Host "[ag-bootstrap] step 5: JOIN AG on $($p.Name) (idempotent)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agjoin-$($p.Tag)" -sqlServer $p.Server -tsql $joinTsql
        if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] AG JOIN failed on $($p.Name)" }
      }

      # ── Step 6a: on the FCI primary, ensure the demo DB exists (on the shared
      #    iSCSI S:\), is in FULL recovery + in the AG, force the replicas to
      #    MANUAL seeding, then take a fresh FULL + LOG backup base to seed the
      #    replicas from. Backups land on C:\Windows\Temp of the active FCI node
      #    (sql-fci-1) which the SQL service (gmsa) can write + nexusadmin can scp.
      $tsqlDemoDb = @"
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'nexus_demo')
  CREATE DATABASE nexus_demo ON (NAME = N'nexus_demo', FILENAME = N'S:\SQLData\nexus_demo.mdf') LOG ON (NAME = N'nexus_demo_log', FILENAME = N'S:\SQLData\nexus_demo_log.ldf');
ALTER DATABASE nexus_demo SET RECOVERY FULL;
-- force the 2 standalone replicas to MANUAL seeding (idempotent: seeding_mode
-- 0 = AUTOMATIC, 1 = MANUAL). Stops the failing auto-seed retry loop.
IF EXISTS (SELECT 1 FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ar.group_id = ag.group_id WHERE ag.name = '$agName' AND ar.replica_server_name = 'sql-ag-rep-1' AND ar.seeding_mode <> 1)
  ALTER AVAILABILITY GROUP [$agName] MODIFY REPLICA ON N'sql-ag-rep-1' WITH (SEEDING_MODE = MANUAL);
IF EXISTS (SELECT 1 FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ar.group_id = ag.group_id WHERE ag.name = '$agName' AND ar.replica_server_name = 'sql-ag-rep-2' AND ar.seeding_mode <> 1)
  ALTER AVAILABILITY GROUP [$agName] MODIFY REPLICA ON N'sql-ag-rep-2' WITH (SEEDING_MODE = MANUAL);
-- Take the FULL backup BEFORE adding the DB to the AG. Cold-rebuild fix #33
-- (2026-05-22): ALTER AVAILABILITY GROUP ADD DATABASE on a BRAND-NEW database
-- fails Msg 1475 "...create a full backup on the primary..." -- a DB must have
-- a full backup (recovery/LSN baseline established) before it can join an AG.
-- The forward ratification masked this (nexus_demo already had a backup from
-- the earlier failed auto-seed). Order: full backup -> ADD DATABASE -> log
-- backup (the .bak/.trn pair is the manual-seed base for the replicas).
BACKUP DATABASE nexus_demo TO DISK = 'C:\Windows\Temp\nexus_demo.bak' WITH INIT, FORMAT;
-- add the DB to the AG if not already a member (now allowed -- has a full backup)
IF NOT EXISTS (SELECT 1 FROM sys.availability_databases_cluster adc JOIN sys.availability_groups ag ON adc.group_id = ag.group_id WHERE ag.name = '$agName' AND adc.database_name = 'nexus_demo')
  ALTER AVAILABILITY GROUP [$agName] ADD DATABASE nexus_demo;
BACKUP LOG nexus_demo TO DISK = 'C:\Windows\Temp\nexus_demo.trn' WITH INIT, FORMAT;
SELECT 'BACKUP_DONE';
"@
      Write-Host "[ag-bootstrap] step 6a: ensure nexus_demo + AG membership + backup base on FCI..."
      $o = Invoke-Tsql -ip $sf1Ip -tag 'agdemodb' -sqlServer $fciName -tsql $tsqlDemoDb -timeoutMin 10
      if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] demo DB create/backup failed" }

      # ── Step 6b: transfer the backup base to both replicas via the build host.
      #    Grant the SQL service account read on the pushed backups (RESTORE runs
      #    as the service, NT AUTHORITY\NETWORK SERVICE on the replicas -- same
      #    Msg 15208 ACL gotcha as the endpoint certs in step 2). Lab demo DB.
      $bakDir = Join-Path $env:TEMP "ag-bak-$([System.Guid]::NewGuid().ToString('N'))"
      New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
      foreach ($f in @('nexus_demo.bak', 'nexus_demo.trn')) {
        scp -o ConnectTimeout=60 "$sshUser@$($sf1Ip):C:/Windows/Temp/$f" "$bakDir/$f" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[ag-bootstrap] pull backup $f from FCI failed" }
      }
      foreach ($p in @($participants[1], $participants[2])) {
        foreach ($f in @('nexus_demo.bak', 'nexus_demo.trn')) {
          scp -o ConnectTimeout=60 "$bakDir/$f" "$sshUser@$($p.Ip):C:/Windows/Temp/$f" 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "[ag-bootstrap] push backup $f to $($p.Name) failed" }
        }
        # icacls takes ONE name/wildcard arg (transient #29m at 0.G.7 ratify
        # 2026-05-22: passing two explicit filenames silently no-ops the grant
        # -> RESTORE hit "error 5 (Access is denied)"). Use the nexus_demo.*
        # wildcard so both .bak and .trn get the read grant.
        $grantBak = 'icacls "C:\Windows\Temp\nexus_demo.*" /grant "*S-1-1-0:(R)" /Q'
        ssh -o ConnectTimeout=30 "$sshUser@$($p.Ip)" $grantBak 2>&1 | Out-Null
      }
      Remove-Item -Recurse -Force $bakDir -ErrorAction SilentlyContinue

      # ── Step 6c: on each replica, RESTORE the DB + LOG WITH MOVE (to the
      #    replica's own default data/log dir on C:\) NORECOVERY, then join it to
      #    the AG. Idempotent: skip if already AG-synchronizing on this replica.
      $restoreTsql = @"
DECLARE @dataDir nvarchar(512) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512));
DECLARE @logDir  nvarchar(512) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(512));
IF EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states s JOIN sys.databases d ON s.database_id = d.database_id WHERE d.name = 'nexus_demo')
  PRINT 'nexus_demo already AG-joined on this replica; skipping restore.';
ELSE
BEGIN
  DECLARE @r nvarchar(max) = N'RESTORE DATABASE nexus_demo FROM DISK = ''C:\Windows\Temp\nexus_demo.bak'' WITH MOVE ''nexus_demo'' TO ''' + @dataDir + N'nexus_demo.mdf'', MOVE ''nexus_demo_log'' TO ''' + @logDir + N'nexus_demo_log.ldf'', NORECOVERY, REPLACE;';
  EXEC sp_executesql @r;
  RESTORE LOG nexus_demo FROM DISK = 'C:\Windows\Temp\nexus_demo.trn' WITH NORECOVERY;
  ALTER DATABASE nexus_demo SET HADR AVAILABILITY GROUP = [$agName];
END
"@
      foreach ($p in @($participants[1], $participants[2])) {
        Write-Host "[ag-bootstrap] step 6c: restore + AG-join nexus_demo on $($p.Name)..."
        $o = Invoke-Tsql -ip $p.Ip -tag "agseed-$($p.Tag)" -sqlServer $p.Server -tsql $restoreTsql -timeoutMin 10
        if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-bootstrap] manual seed (restore+join) failed on $($p.Name)" }
      }

      Write-Host "[ag-bootstrap] AG $agName created (FCI primary $fciName + 2 async replicas + nexus_demo DB manually seeded)"
    PWSH
  }
}
