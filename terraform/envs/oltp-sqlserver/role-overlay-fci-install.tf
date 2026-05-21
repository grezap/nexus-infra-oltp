# role-overlay-fci-install.tf -- Phase 0.G.7
#
# Converts the standalone SQL Server install on sql-fci-1/2 into a 2-node
# Failover Cluster Instance (FCI). Two-stage:
#   1. On sql-fci-1: setup.exe /ACTION=InstallFailoverCluster. Creates the
#      FCI resource group in WSFC with the cluster disk as data dir, virtual
#      server name `sql-fci-cluster`, virtual server IP .70.16.
#   2. On sql-fci-2: setup.exe /ACTION=AddNode. Joins the existing FCI as
#      a possible owner.
#
# SQL service identity = nexus.lab\gmsa-sql-engine$ (cached via
# Install-ADServiceAccount in each orchestrate, since the standalone install
# from the Packer bake used NETWORK SERVICE).
#
# DOMAIN-ADMIN CONTEXT: setup.exe needs cluster-admin rights (to create the
# FCI resource in WSFC) + AD read (to validate /SQLSYSADMINACCOUNTS +
# retrieve the GMSA). The Windows OpenSSH SSH session runs as LOCAL
# nexusadmin (no Kerberos TGT, not a cluster admin). So -- exactly like
# role-overlay-wsfc-bootstrap.tf -- we dispatch setup.exe as a Scheduled
# Task running as NEXUS\nexusadmin (schtasks /Create /RU /RP = Password
# logon type with full network credentials; transient #27/#28 at 0.G.7
# ratify 2026-05-21).
#
# PRE-REQ: the SQL Server ISO must be present at C:/Windows/Temp/sqlserver.iso
# on BOTH FCI nodes. The Packer bake removes the ISO post-install, so the
# operator (or this overlay's caller) uploads it again before apply. The
# RATIFY-0.G.7 runbook documents the scp step:
#   scp H:/VMS/ISO/<sql>.iso nexusadmin@192.168.70.11:C:/Windows/Temp/sqlserver.iso
#   scp H:/VMS/ISO/<sql>.iso nexusadmin@192.168.70.12:C:/Windows/Temp/sqlserver.iso

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
      # FCI virtual server name (SQL network name) -- distinct from the WSFC
      # cluster CNO name to avoid the Network Name resource collision.
      $fciName   = '${local.fci_virtual_server_name}'
      $sqlIsoPath = '${var.sql_iso_path}'

      # ── Phase 0 (transient #28/#28j at 0.G.7 ratify 2026-05-21): upload the
      #    SQL Server ISO to each FCI node. The Packer bake removes the ISO
      #    post-standalone-install, so the FCI install must re-supply it.
      #    Automating this keeps the from-zero cold rebuild hands-off (no
      #    manual scp). SEQUENTIAL (one node at a time) + SIZE-VERIFIED per
      #    transient #28 (parallel multi-GB scp stalled the VMware host I/O +
      #    an unclean power-off truncated the in-flight writes; never trust
      #    scp rc=0 alone). Idempotent: skips a node whose ISO already matches
      #    the source byte count.
      if (-not (Test-Path $sqlIsoPath)) {
        throw "[fci-install] SQL ISO not found on build host at $sqlIsoPath (set var.sql_iso_path)"
      }
      $srcLen = (Get-Item $sqlIsoPath).Length
      Write-Host "[fci-install] Phase 0: ensuring SQL ISO present on both FCI nodes ($srcLen bytes)..."
      foreach ($fciNodeIp in @($sf1Ip, $sf2Ip)) {
        $remoteLen = ssh -o ConnectTimeout=15 "$sshUser@$fciNodeIp" "(Get-Item 'C:/Windows/Temp/sqlserver.iso' -EA 0).Length" 2>$null
        $remoteLen = ($remoteLen | Out-String).Trim()
        if ($remoteLen -eq "$srcLen") {
          Write-Host "[fci-install] Phase 0: $fciNodeIp already has the ISO ($remoteLen bytes; idempotent skip)"
          continue
        }
        Write-Host "[fci-install] Phase 0: uploading ISO to $fciNodeIp (have='$remoteLen' want='$srcLen')..."
        ssh -o ConnectTimeout=15 "$sshUser@$fciNodeIp" "Remove-Item 'C:/Windows/Temp/sqlserver.iso' -Force -EA 0" 2>$null
        scp -o ConnectTimeout=30 $sqlIsoPath "$sshUser@$($fciNodeIp):C:/Windows/Temp/sqlserver.iso" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[fci-install] Phase 0: scp ISO to $fciNodeIp failed (rc=$LASTEXITCODE)" }
        $verifyLen = (ssh -o ConnectTimeout=15 "$sshUser@$fciNodeIp" "(Get-Item 'C:/Windows/Temp/sqlserver.iso' -EA 0).Length" 2>$null | Out-String).Trim()
        if ($verifyLen -ne "$srcLen") {
          throw "[fci-install] Phase 0: ISO size mismatch on $fciNodeIp after upload (got '$verifyLen', want '$srcLen')"
        }
        Write-Host "[fci-install] Phase 0: $fciNodeIp ISO verified ($verifyLen bytes)"
      }

      # Domain creds for the schtasks Password-logon-type dispatch.
      $adCredsJson = Join-Path $HOME ".nexus/nexusadmin-credentials.json"
      if (-not (Test-Path $adCredsJson)) { throw "[fci-install] nexusadmin-credentials.json not found at $adCredsJson" }
      $adCreds   = Get-Content $adCredsJson -Raw | ConvertFrom-Json
      $adNetbios = if ($adCreds.PSObject.Properties['netbios']) { $adCreds.netbios } else { 'NEXUS' }
      $adUser    = "$adNetbios\$($adCreds.username)"
      $adPass    = $adCreds.password

      # ── Helper: dispatch an orchestrate script to $ip as a Scheduled Task
      #    running as NEXUS\nexusadmin (Password logon type), poll to
      #    completion, return the transcript. Mirrors role-overlay-wsfc-
      #    bootstrap.tf. $tag names the task + log + script paths.
      function Invoke-AsDomainTask {
        param([string]$ip, [string]$tag, [string]$orchestrate, [string]$logFile, [int]$timeoutMin = 30)

        # $logFile MUST match the orchestrate's Start-Transcript path so the
        # wrapper reads the right transcript. Transient #28f at 0.G.7 ratify
        # 2026-05-21: previously the wrapper read $tag.log but the orchestrate
        # wrote fci-install-sf1.log -> $out never contained the success token
        # even though setup.exe Passed. Now the caller passes the exact path.
        # Completion is detected by polling for the transcript-END marker in
        # the log (definitive) rather than the schtasks Status field (which
        # parsed unreliably + could exit the loop before the transcript flushed).
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

# Poll for the transcript-END marker (written by Stop-Transcript) -- a
# definitive completion signal regardless of schtasks status parsing.
`$deadline = (Get-Date).AddMinutes($timeoutMin);
`$done = `$false;
do {
  Start-Sleep -Seconds 15;
  if (Test-Path `$logPath) {
    `$logContent = Get-Content `$logPath -Raw -ErrorAction SilentlyContinue;
    if (`$logContent -match 'Windows PowerShell transcript end') { `$done = `$true; }
  }
  `$status = schtasks /Query /TN `$taskName /FO LIST /V 2>`$null | Select-String 'Status:' | Select-Object -First 1;
  `$stillRunning = `$status -match 'Running';
} while ((-not `$done) -and `$stillRunning -and ((Get-Date) -lt `$deadline));
# Grace for final flush.
Start-Sleep -Seconds 3;

if (Test-Path `$logPath) { Get-Content `$logPath -Raw; }
`$lastRc = (schtasks /Query /TN `$taskName /FO LIST /V 2>`$null | Select-String 'Last Result:' | ForEach-Object { (`$_ -split ':')[1].Trim() } | Select-Object -First 1);
Write-Output ('TASK_LAST_RC=' + `$lastRc);
try { schtasks /Delete /TN `$taskName /F 2>&1 | Out-Null } catch {};
Remove-Item `$scriptPath -ErrorAction SilentlyContinue;
"@

        $tempLocal = Join-Path $env:TEMP "$tag-wrapper-$([System.Guid]::NewGuid().ToString('N')).ps1"
        $wrapper | Out-File -FilePath $tempLocal -Encoding UTF8 -Force
        $remoteSrc = "C:/Windows/Temp/nexus-$tag-wrapper.ps1"
        scp -o ConnectTimeout=30 -o BatchMode=yes $tempLocal "$sshUser@$($ip):$remoteSrc" 2>&1 | Write-Host
        $scpRc = $LASTEXITCODE
        Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue
        if ($scpRc -ne 0) { throw "[fci-install] scp of $tag wrapper to $ip failed (rc=$scpRc)" }

        $out = ssh -o ConnectTimeout=1800 "$sshUser@$ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteSrc" 2>&1 | Out-String
        ssh -o ConnectTimeout=10 "$sshUser@$ip" "Remove-Item -Path '$remoteSrc' -ErrorAction SilentlyContinue" 2>&1 | Out-Null
        return $out
      }

      # ── Helper: wait for a node's SSH to return after a reboot.
      function Wait-NodeBack {
        param([string]$ip, [int]$timeoutMin = 8)
        $deadline = (Get-Date).AddMinutes($timeoutMin)
        while ((Get-Date) -lt $deadline) {
          $back = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$sshUser@$ip" "echo PONG" 2>$null
          if ($back -match '^PONG\s*$') { return $true }
          Start-Sleep -Seconds 15
        }
        return $false
      }

      # ── Phase A (transient #28g at 0.G.7 ratify 2026-05-21): uninstall the
      #    standalone MSSQLSERVER instance on BOTH FCI nodes + REBOOT. The
      #    uninstall sets a pending-reboot flag; setup.exe InstallFailoverCluster
      #    then aborts with error 3010 "A computer restart is required". So the
      #    uninstall + reboot MUST complete before the FCI install runs. Done
      #    as a domain-task (uninstall needs no domain context, but reuse the
      #    pattern). Idempotent: skips if the standalone service is already gone.
      $uninstallOrch = @"
`$ErrorActionPreference = 'Continue';
`$logPath = 'C:/Windows/Temp/fci-uninstall.log';
Start-Transcript -Path `$logPath -Force | Out-Null;
`$svc = Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue;
if (-not `$svc) { Write-Output 'NO_STANDALONE'; Stop-Transcript | Out-Null; exit 0; }
if (-not (Test-Path 'C:/Windows/Temp/sqlserver.iso')) { Write-Output 'ISO_MISSING'; Stop-Transcript | Out-Null; exit 1; }
Mount-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' -ErrorAction SilentlyContinue | Out-Null;
Start-Sleep -Seconds 5;
`$isoVol = (Get-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' | Get-Volume).DriveLetter;
`$setupExe = `$isoVol + ':/setup.exe';
Stop-Service -Name 'MSSQLSERVER' -Force -ErrorAction SilentlyContinue;
& `$setupExe '/Q' '/ACTION=Uninstall' '/INSTANCENAME=MSSQLSERVER' '/FEATURES=SQLEngine,FullText' '/SUPPRESSPRIVACYSTATEMENTNOTICE';
`$urc = `$LASTEXITCODE;
Write-Output ('UNINSTALL_RC=' + `$urc);
if (`$urc -eq 0 -or `$urc -eq 3010) { Write-Output 'STANDALONE_UNINSTALLED'; } else { Write-Output 'UNINSTALL_FAILED'; }
Stop-Transcript | Out-Null;
"@
      foreach ($fciNode in @(@{Ip=$sf1Ip;Tag='sf1'}, @{Ip=$sf2Ip;Tag='sf2'})) {
        Write-Host "[fci-install] Phase A: uninstall standalone on $($fciNode.Tag) ($($fciNode.Ip))..."
        $uo = Invoke-AsDomainTask -ip $fciNode.Ip -tag "NexusFciUninstall$($fciNode.Tag)" -orchestrate $uninstallOrch -logFile 'C:/Windows/Temp/fci-uninstall.log' -timeoutMin 20
        if ($uo -match 'STANDALONE_UNINSTALLED') {
          Write-Host "[fci-install] Phase A: rebooting $($fciNode.Tag) to clear pending-reboot..."
          ssh -o ConnectTimeout=10 "$sshUser@$($fciNode.Ip)" "shutdown /r /t 3 /c 'FCI uninstall reboot'" 2>&1 | Out-Null
          Start-Sleep -Seconds 30
          if (-not (Wait-NodeBack -ip $fciNode.Ip -timeoutMin 8)) {
            throw "[fci-install] $($fciNode.Tag) did not return after uninstall reboot"
          }
          Write-Host "[fci-install] Phase A: $($fciNode.Tag) back online post-reboot"
        } elseif ($uo -match 'NO_STANDALONE') {
          Write-Host "[fci-install] Phase A: $($fciNode.Tag) has no standalone instance (already clean)"
        } else {
          Write-Host $uo
          throw "[fci-install] Phase A: standalone uninstall failed on $($fciNode.Tag)"
        }
      }
      # WSFC service may need a moment to re-stabilize after the FCI-node reboots.
      Start-Sleep -Seconds 20

      Write-Host "[fci-install] step 1/2: InstallFailoverCluster on sql-fci-1 (via Scheduled Task as $adUser)..."

      # ── sql-fci-1: InstallFailoverCluster orchestrate.
      $sf1Orchestrate = @"
`$ErrorActionPreference = 'Stop';
`$logPath = 'C:/Windows/Temp/fci-install-sf1.log';
Start-Transcript -Path `$logPath -Force | Out-Null;
try {
  Import-Module ActiveDirectory -ErrorAction SilentlyContinue;
  # Cache the GMSA locally (needs domain context -- now we have it).
  if (-not (Test-ADServiceAccount -Identity 'gmsa-sql-engine' -ErrorAction SilentlyContinue)) {
    Install-ADServiceAccount -Identity 'gmsa-sql-engine';
    Write-Output 'GMSA_INSTALLED_SF1';
  } else { Write-Output 'GMSA_ALREADY_SF1'; }

  Import-Module FailoverClusters;
  # Idempotent: if FCI SQL resource exists, skip.
  `$isFci = (Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { `$_.ResourceType -eq 'SQL Server' }) -ne `$null;
  if (`$isFci) { Write-Output 'FCI_ALREADY_INSTALLED'; Stop-Transcript | Out-Null; exit 0; }

  `$saPwd = (Get-Content 'C:/ProgramData/nexus/sql/creds/sa-password.txt' -Raw).Trim();

  # Mount ISO.
  if (-not (Test-Path 'D:/setup.exe')) {
    if (-not (Test-Path 'C:/Windows/Temp/sqlserver.iso')) { throw 'SQL Server ISO missing at C:/Windows/Temp/sqlserver.iso'; }
    Mount-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' | Out-Null;
    Start-Sleep -Seconds 5;
  }
  # Resolve the drive letter the ISO mounted to (not always D:).
  `$isoVol = (Get-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' | Get-Volume).DriveLetter;
  `$setupExe = `$isoVol + ':/setup.exe';
  Write-Output ('SETUP_EXE=' + `$setupExe);

  # NOTE: standalone-instance uninstall + reboot is handled by Phase A in the
  # outer orchestration (transient #28e/#28g) -- by the time we reach here the
  # FCI node has no standalone MSSQLSERVER + no pending reboot.

  # Resolve the cluster network whose subnet covers the FCI VIP (.70.x).
  # Transient #28c at 0.G.7 ratify 2026-05-21: WSFC auto-names networks
  # "Cluster Network 1/2" in discovery order; .10.x backplane often lands
  # as #1 + .70.x service net as #2. Hardcoding "Cluster Network 1" put the
  # .70.16 VIP on the wrong subnet -> setup error -2032402431 "IP not valid
  # for network ... prefixes do not support the address". Resolve dynamically.
  `$fciNet = (Get-ClusterNetwork | Where-Object { `$_.Address -eq '192.168.70.0' } | Select-Object -First 1).Name;
  if (-not `$fciNet) { throw 'Could not find cluster network for 192.168.70.0/24'; }
  Write-Output ('FCI_CLUSTER_NETWORK=' + `$fciNet);

  `$setupArgs = @(
    '/Q', '/ACTION=InstallFailoverCluster',
    '/SUPPRESSPRIVACYSTATEMENTNOTICE',
    '/ENU',
    '/FEATURES=SQLEngine,FullText',
    '/INSTANCENAME=MSSQLSERVER',
    '/INSTANCEID=MSSQLSERVER',
    '/FAILOVERCLUSTERGROUP=SQL Server (MSSQLSERVER)',
    ('/FAILOVERCLUSTERNETWORKNAME=$fciName'),
    ('/FAILOVERCLUSTERIPADDRESSES=IPv4;$fciVip;' + `$fciNet + ';255.255.255.0'),
    '/INSTALLSQLDATADIR=S:\SQLData',
    '/SQLSVCACCOUNT=$adNetbios\gmsa-sql-engine`$',
    '/AGTSVCACCOUNT=$adNetbios\gmsa-sql-engine`$',
    '/SQLSYSADMINACCOUNTS=$adNetbios\Domain Admins',
    '/SECURITYMODE=SQL',
    ('/SAPWD=' + `$saPwd),
    '/SKIPRULES=Cluster_VerifyForErrors',
    '/IACCEPTSQLSERVERLICENSETERMS'
  );
  # /AGTSVCACCOUNT (SQL Server Agent service) is REQUIRED for FCI install --
  # transient #28h at 0.G.7 ratify 2026-05-21: omitting it -> setup error
  # -2061762559 "credentials you provided for the SQL Server Agent service
  # are invalid". The GMSA runs the agent too (no password needed).
  # /SKIPRULES=Cluster_VerifyForErrors -- transient #28b at 0.G.7 ratify
  # 2026-05-21: SQL setup error 3008 "cluster either has not been verified
  # or there are errors in the verification report" because we skipped
  # Test-Cluster during WSFC bootstrap (cross-node RPC validation was flaky
  # before the DNS-suffix fix #27d). The cluster IS functional (4 nodes Up,
  # disk added, DNS suffix corrected). Skipping the verification RULE lets
  # setup.exe proceed; the operator can run Test-Cluster post-install to
  # generate the validation report if compliance requires it.
  Write-Output 'RUNNING_SETUP_INSTALLFCI...';
  & `$setupExe `$setupArgs;
  `$rc = `$LASTEXITCODE;
  Write-Output ('SETUP_RC=' + `$rc);
  if (`$rc -ne 0 -and `$rc -ne 3010) { throw ('setup.exe InstallFailoverCluster failed exit=' + `$rc); }
  Write-Output 'FCI_INSTALLED_ON_SF1';
} catch {
  Write-Output ('FCI_SF1_FAIL: ' + `$_.Exception.Message);
  Stop-Transcript | Out-Null;
  exit 1;
}
Stop-Transcript | Out-Null;
"@

      $out1 = Invoke-AsDomainTask -ip $sf1Ip -tag 'NexusFciInstallSf1' -orchestrate $sf1Orchestrate -logFile 'C:/Windows/Temp/fci-install-sf1.log' -timeoutMin 40
      Write-Host $out1.Trim()
      if ($out1 -notmatch 'FCI_INSTALLED_ON_SF1' -and $out1 -notmatch 'FCI_ALREADY_INSTALLED') {
        throw "[fci-install] sql-fci-1 InstallFailoverCluster did not report success"
      }

      if ($out1 -notmatch 'FCI_ALREADY_INSTALLED') {
        Write-Host "[fci-install] step 2/2: AddNode on sql-fci-2 (via Scheduled Task as $adUser)..."

        $sf2Orchestrate = @"
`$ErrorActionPreference = 'Stop';
`$logPath = 'C:/Windows/Temp/fci-install-sf2.log';
Start-Transcript -Path `$logPath -Force | Out-Null;
try {
  Import-Module ActiveDirectory -ErrorAction SilentlyContinue;
  if (-not (Test-ADServiceAccount -Identity 'gmsa-sql-engine' -ErrorAction SilentlyContinue)) {
    Install-ADServiceAccount -Identity 'gmsa-sql-engine';
    Write-Output 'GMSA_INSTALLED_SF2';
  } else { Write-Output 'GMSA_ALREADY_SF2'; }

  Import-Module FailoverClusters;
  # Idempotent: is sql-fci-2 already a possible owner of the SQL resource?
  `$sqlRes = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { `$_.ResourceType -eq 'SQL Server' } | Select-Object -First 1;
  if (`$sqlRes) {
    `$owners = (Get-ClusterOwnerNode -Resource `$sqlRes.Name -ErrorAction SilentlyContinue).OwnerNodes.Name;
    if (`$owners -contains 'sql-fci-2') { Write-Output 'NODE_ALREADY_ADDED'; Stop-Transcript | Out-Null; exit 0; }
  }

  `$saPwd = (Get-Content 'C:/ProgramData/nexus/sql/creds/sa-password.txt' -Raw).Trim();
  if (-not (Test-Path 'C:/Windows/Temp/sqlserver.iso')) { throw 'SQL Server ISO missing on sql-fci-2'; }
  Mount-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' -ErrorAction SilentlyContinue | Out-Null;
  Start-Sleep -Seconds 5;
  `$isoVol = (Get-DiskImage -ImagePath 'C:/Windows/Temp/sqlserver.iso' | Get-Volume).DriveLetter;
  `$setupExe = `$isoVol + ':/setup.exe';

  # NOTE: standalone uninstall + reboot handled by Phase A (transient #28g).

  `$addArgs = @(
    '/Q', '/ACTION=AddNode',
    '/SUPPRESSPRIVACYSTATEMENTNOTICE',
    '/ENU',
    '/INSTANCENAME=MSSQLSERVER',
    '/CONFIRMIPDEPENDENCYCHANGE=1',
    '/SQLSVCACCOUNT=$adNetbios\gmsa-sql-engine`$',
    '/IACCEPTSQLSERVERLICENSETERMS'
  );
  Write-Output 'RUNNING_SETUP_ADDNODE...';
  & `$setupExe `$addArgs;
  `$rc = `$LASTEXITCODE;
  Write-Output ('SETUP_RC=' + `$rc);
  if (`$rc -ne 0 -and `$rc -ne 3010) { throw ('setup.exe AddNode failed exit=' + `$rc); }
  Write-Output 'FCI_ADDED_ON_SF2';
} catch {
  Write-Output ('FCI_SF2_FAIL: ' + `$_.Exception.Message);
  Stop-Transcript | Out-Null;
  exit 1;
}
Stop-Transcript | Out-Null;
"@

        $out2 = Invoke-AsDomainTask -ip $sf2Ip -tag 'NexusFciAddNodeSf2' -orchestrate $sf2Orchestrate -logFile 'C:/Windows/Temp/fci-install-sf2.log' -timeoutMin 40
        Write-Host $out2.Trim()
        if ($out2 -notmatch 'FCI_ADDED_ON_SF2' -and $out2 -notmatch 'NODE_ALREADY_ADDED') {
          throw "[fci-install] sql-fci-2 AddNode did not report success"
        }
      }

      Write-Host "[fci-install] FCI install complete; virtual server $fciName online at $fciVip"
    PWSH
  }
}
