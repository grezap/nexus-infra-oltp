# role-overlay-ag-listener.tf -- Phase 0.G.7
#
# Creates the AG Listener (`sql-ag-listener`) at 192.168.70.17. Per
# ADR-0025, the Listener IS the LB-tier HA primitive for AG: client
# connection strings target the Listener IP, and WSFC migrates the IP
# atomically with the AG primary across failover. No external LB needed
# (vs the Linux clusters that need keepalived + VRRP).
#
# Two stages:
#   1. ADD LISTENER via T-SQL on the AG primary (the FCI). Runs through the
#      schtasks Password-logon domain-task (NEXUS\nexusadmin is the only
#      sysadmin on the FCI) + sqlcmd -C, same as ag-bootstrap. Transient #29o
#      at 0.G.7 ratify 2026-05-22: the original `sqlcmd -E` over plain SSH ran
#      as LOCAL nexusadmin (not a sysadmin on the FCI) -> "Login failed", and
#      lacked -C so ODBC Driver 18 rejected the server cert chain.
#   2. Bind each node's UNIFIED per-node TLS cert (rendered by the
#      sqlserver-tls overlay with the listener name + .17 in its SAN) to the
#      SQL Server TLS wire via SuperSocketNetLib\Certificate, so whichever node
#      owns the Listener IP after failover presents a cert that validates for
#      sql-ag-listener.nexus.lab + .17 (Encrypt=True;TrustServerCertificate=
#      False). Transients at 0.G.7 ratify 2026-05-22:
#        #29p: the registry instance key is MSSQL17.MSSQLSERVER (SQL 2025), not
#              MSSQL16 (the original hardcode was for SQL 2022).
#        #29q: the FCI SQL instance is cluster-managed -- a direct Restart-
#              Service races the cluster (it restarts/fails the resource). The
#              cert binding is applied by cycling the SQL Server cluster GROUP
#              (Stop/Start-ClusterGroup) on the FCI; replicas restart directly.
#        #29r: bind the per-node cert (one cert per instance), NOT a separate
#              listener cert -- SQL has a single SuperSocketNetLib\Certificate
#              slot; the unified per-node cert carries every SAN the instance
#              serves (node + FCI virtual + listener).
#
# Read-only routing (ApplicationIntent=ReadOnly -> replicas) is documented but
# deferred per the plan (a 0.G.7.1 follow-up if Greg wants it smoke-gated).

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
      $sshUser      = '${var.ssh_username}'
      $sf1Ip        = '${local.sql_nodes["sql-fci-1"].vmnet11}'
      $sf2Ip        = '${local.sql_nodes["sql-fci-2"].vmnet11}'
      $listenerName = '${local.ag_listener_name}'
      $listenerIp   = '${local.ag_listener_ip}'
      $agName       = '${local.ag_name}'
      $fciName      = '${local.fci_virtual_server_name}'

      # The 4 nodes with their role + the SQL service account that needs read
      # on the bound cert's private key (gmsa on the FCI, NETWORK SERVICE on
      # the standalone replicas).
      $nodes = @(
        @{ Ip = '${local.sql_nodes["sql-fci-1"].vmnet11}';    Host = 'sql-fci-1';    Role = 'fci';        Svc = 'NEXUS\gmsa-sql-engine$' },
        @{ Ip = '${local.sql_nodes["sql-fci-2"].vmnet11}';    Host = 'sql-fci-2';    Role = 'fci';        Svc = 'NEXUS\gmsa-sql-engine$' },
        @{ Ip = '${local.sql_nodes["sql-ag-rep-1"].vmnet11}'; Host = 'sql-ag-rep-1'; Role = 'ag-replica'; Svc = 'NT AUTHORITY\NETWORK SERVICE' },
        @{ Ip = '${local.sql_nodes["sql-ag-rep-2"].vmnet11}'; Host = 'sql-ag-rep-2'; Role = 'ag-replica'; Svc = 'NT AUTHORITY\NETWORK SERVICE' }
      )

      # Domain creds for the schtasks Password-logon-type dispatch.
      $adCredsJson = Join-Path $HOME ".nexus/nexusadmin-credentials.json"
      if (-not (Test-Path $adCredsJson)) { throw "[ag-listener] nexusadmin-credentials.json not found at $adCredsJson" }
      $adCreds   = Get-Content $adCredsJson -Raw | ConvertFrom-Json
      $adNetbios = if ($adCreds.PSObject.Properties['netbios']) { $adCreds.netbios } else { 'NEXUS' }
      $adUser    = "$adNetbios\$($adCreds.username)"
      $adPass    = $adCreds.password

      # ── Helper: run a T-SQL batch on $ip as NEXUS\nexusadmin via a Scheduled
      #    Task (sysadmin everywhere). Mirrors ag-bootstrap's Invoke-Tsql.
      function Invoke-Tsql {
        param([string]$ip, [string]$tag, [string]$sqlServer, [string]$tsql, [int]$timeoutMin = 10)
        $tsqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tsql))
        $logFile = "C:/Windows/Temp/$tag.log"
        $orchestrate = @"
`$ErrorActionPreference = 'Continue';
Start-Transcript -Path '$logFile' -Force | Out-Null;
`$tsql = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$tsqlB64'));
`$tmpSql = 'C:\Windows\Temp\$tag.sql';
Set-Content -Path `$tmpSql -Value `$tsql -Encoding UTF8;
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
        if ($scpRc -ne 0) { throw "[ag-listener] scp of $tag wrapper to $ip failed (rc=$scpRc)" }
        $out = ssh -o ConnectTimeout=120 "$sshUser@$ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteSrc" 2>&1 | Out-String
        ssh -o ConnectTimeout=10 "$sshUser@$ip" "Remove-Item -Path '$remoteSrc' -ErrorAction SilentlyContinue" 2>&1 | Out-Null
        return $out
      }

      # ── Helper: run an arbitrary PowerShell block on $ip as NEXUS\nexusadmin
      #    (domain admin) via a Scheduled Task -- needed for setspn (writes AD
      #    servicePrincipalName, which LOCAL nexusadmin over plain SSH cannot).
      function Invoke-DomainPs {
        param([string]$ip, [string]$tag, [string]$psBody, [int]$timeoutMin = 5)
        $bodyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($psBody))
        $logFile = "C:/Windows/Temp/$tag.log"
        $orchestrate = @"
`$ErrorActionPreference = 'Continue';
Start-Transcript -Path '$logFile' -Force | Out-Null;
`$body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$bodyB64'));
Invoke-Expression `$body;
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
do {
  Start-Sleep -Seconds 6;
  if (Test-Path `$logPath) { `$lc = Get-Content `$logPath -Raw -EA SilentlyContinue; if (`$lc -match 'Windows PowerShell transcript end') { break; } }
} while ((Get-Date) -lt `$deadline);
Start-Sleep -Seconds 2;
if (Test-Path `$logPath) { Get-Content `$logPath -Raw; }
try { schtasks /Delete /TN `$taskName /F 2>&1 | Out-Null } catch {};
Remove-Item `$scriptPath -ErrorAction SilentlyContinue;
"@
        $tempLocal = Join-Path $env:TEMP "$tag-wrap-$([System.Guid]::NewGuid().ToString('N')).ps1"
        $wrapper | Out-File -FilePath $tempLocal -Encoding UTF8 -Force
        $remoteSrc = "C:/Windows/Temp/nexus-$tag-wrap.ps1"
        scp -o ConnectTimeout=30 -o BatchMode=yes $tempLocal "$sshUser@$($ip):$remoteSrc" 2>&1 | Out-Null
        Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue
        $out = ssh -o ConnectTimeout=120 "$sshUser@$ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteSrc" 2>&1 | Out-String
        ssh -o ConnectTimeout=10 "$sshUser@$ip" "Remove-Item -Path '$remoteSrc' -ErrorAction SilentlyContinue" 2>&1 | Out-Null
        return $out
      }

      Write-Host "[ag-listener] creating Listener $listenerName at $listenerIp..."

      # ── Step 1: ALTER AVAILABILITY GROUP ... ADD LISTENER on the primary.
      $tsqlAddListener = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.availability_group_listeners WHERE dns_name = '$listenerName')
  ALTER AVAILABILITY GROUP [$agName]
    ADD LISTENER N'$listenerName' (
      WITH IP ((N'$listenerIp', N'255.255.255.0')),
      PORT = 1433
    );
SELECT 'LISTENER_OK';
"@
      Write-Host "[ag-listener] step 1: ADD LISTENER on FCI primary..."
      $o = Invoke-Tsql -ip $sf1Ip -tag 'aglistener' -sqlServer $fciName -tsql $tsqlAddListener -timeoutMin 8
      if ($o -notmatch 'TSQL_OK') { Write-Host $o; throw "[ag-listener] ALTER AG ADD LISTENER failed" }

      # ── Step 1b: register Kerberos SPNs for the FCI virtual server + the AG
      #    Listener on the SQL service account (gmsa-sql-engine$). Transient #29u
      #    at 0.G.7 ratify 2026-05-22: SQL Server can't auto-register SPNs for
      #    virtual names (FCI + Listener), so without these a remote client
      #    connecting to sql-ag-listener via Windows auth (-E) gets Kerberos-
      #    unavailable -> NTLM -> "Login failed for NT AUTHORITY\ANONYMOUS
      #    LOGON". setspn writes AD servicePrincipalName, which requires a domain
      #    admin -> run via the schtasks domain-task (NEXUS\nexusadmin). setspn
      #    -S is idempotent (checks for duplicates before adding).
      $spnPs = @'
$spns = @(
  'MSSQLSvc/sqlfci.nexus.lab:1433',
  'MSSQLSvc/sqlfci.nexus.lab',
  'MSSQLSvc/sql-ag-listener.nexus.lab:1433',
  'MSSQLSvc/sql-ag-listener.nexus.lab'
)
foreach ($s in $spns) { & setspn -S $s 'nexus\gmsa-sql-engine$' 2>&1 | Out-Null }
Write-Output ('SPN_COUNT=' + ((& setspn -L 'nexus\gmsa-sql-engine$' 2>&1 | Select-String 'MSSQLSvc/').Count))
'@
      Write-Host "[ag-listener] step 1b: register FCI + Listener SPNs on gmsa-sql-engine`$..."
      $spnOut = Invoke-DomainPs -ip $sf1Ip -tag 'agspn' -psBody $spnPs -timeoutMin 4
      $spnLine = ($spnOut -split "`n") | Where-Object { $_ -match 'SPN_COUNT=' } | Select-Object -First 1
      Write-Host ("  " + ($spnLine).Trim())
      if ($spnOut -notmatch 'SPN_COUNT=[1-9]') { Write-Host "[ag-listener] WARN: SPN registration reported no MSSQLSvc SPNs (may need domain-admin review)" }

      # ── Step 2: bind each node's unified per-node cert to SQL Server TLS.
      #    Sets the registry only (no restart) -- the restart that applies it is
      #    step 3 (replicas direct; FCI via cluster-group cycle).
      $bindTemplate = @'
$ErrorActionPreference = 'Stop'
$hostFqdn = '__HOSTFQDN__'
$svcAcct  = '__SVCACCT__'
# Pick the NEWEST per-node cert (CN=<host>.sqlserver.nexus.lab) that carries
# the listener SAN + has a private key -- guarantees the unified v2 cert, not a
# stale render or the standalone listener cert.
$cert = Get-ChildItem Cert:\LocalMachine\My |
  Where-Object { $_.Subject -like ('CN=' + $hostFqdn) -and $_.HasPrivateKey -and ($_.DnsNameList.Unicode -contains 'sql-ag-listener.nexus.lab') } |
  Sort-Object NotBefore -Descending | Select-Object -First 1
if (-not $cert) { Write-Output 'BIND_FAIL: no unified per-node cert with listener SAN'; exit 1 }
$thumb = $cert.Thumbprint.ToLower()
$reg = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
New-ItemProperty -Path $reg -Name 'Certificate' -Value $thumb -PropertyType String -Force | Out-Null
New-ItemProperty -Path $reg -Name 'ForceEncryption' -Value 1 -PropertyType DWord -Force | Out-Null
# Grant the SQL service account read on the cert's private key (CNG key under
# Crypto\Keys for Import-PfxCertificate; MachineKeys fallback for legacy CSP).
try {
  $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
  $keyName = $rsa.Key.UniqueName
  $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $keyName
  if (-not (Test-Path $keyPath)) { $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $keyName }
  if (Test-Path $keyPath) {
    $acl = Get-Acl $keyPath
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($svcAcct, 'Read', 'Allow')))
    Set-Acl $keyPath $acl
  }
} catch { Write-Output ('KEYACL_WARN: ' + $_.Exception.Message) }
Write-Output ('BOUND=' + $thumb.Substring(0,8) + ' SVC=' + $svcAcct)
'@
      foreach ($n in $nodes) {
        Write-Host "[ag-listener] step 2: bind per-node cert on $($n.Host)..."
        $script = $bindTemplate.Replace('__HOSTFQDN__', "$($n.Host).sqlserver.nexus.lab").Replace('__SVCACCT__', $n.Svc)
        $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $out = ssh -o ConnectTimeout=60 "$sshUser@$($n.Ip)" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        Write-Host ("  " + $out.Trim())
        if ($out -notmatch 'BOUND=') { throw "[ag-listener] cert bind failed on $($n.Host): $out" }
      }

      # ── Step 3: apply the binding (SuperSocketNetLib changes need a SQL
      #    restart). Replicas restart directly; the FCI cycles its cluster GROUP
      #    so the active instance re-reads the registry without racing the
      #    cluster resource monitor.
      foreach ($n in $nodes | Where-Object { $_.Role -eq 'ag-replica' }) {
        Write-Host "[ag-listener] step 3: restart MSSQLSERVER on $($n.Host) (apply cert)..."
        ssh -o ConnectTimeout=30 "$sshUser@$($n.Ip)" "Restart-Service -Name MSSQLSERVER -Force; Start-Sleep -Seconds 6; (Get-Service MSSQLSERVER).Status" 2>&1 | Out-String | ForEach-Object { Write-Host ("  " + $_.Trim()) }
      }
      Write-Host "[ag-listener] step 3: cycle the FCI SQL Server cluster group (apply cert)..."
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
      if ($cyc -notmatch 'SQLRES_STATE=Online') { throw "[ag-listener] FCI 'SQL Server' resource not Online after cert-bind cycle: $cyc" }

      # ── Step 4: verify the Listener answers + reports the AG primary.
      Start-Sleep -Seconds 8
      $verifyTsql = "SET NOCOUNT ON; SELECT 'LISTENER_PRIMARY=' + @@SERVERNAME;"
      $v = Invoke-Tsql -ip $sf1Ip -tag 'aglverify' -sqlServer $listenerName -tsql $verifyTsql -timeoutMin 5
      Write-Host ("[ag-listener] verify via Listener: " + (($v -split "`n") | Where-Object { $_ -match 'LISTENER_PRIMARY=' } | Select-Object -First 1))
      if ($v -notmatch 'LISTENER_PRIMARY=') { Write-Host $v; throw "[ag-listener] Listener did not answer sqlcmd -S $listenerName" }

      Write-Host "[ag-listener] Listener $listenerName live at $listenerIp; unified per-node cert bound on all 4 nodes; AG primary serves on 1433"
    PWSH
  }
}
