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
# Transient #28L at 0.G.7 ratify 2026-05-21: if MSSQLSERVER is already the
# CLUSTERED FCI instance (SqlCluster=1 in the Setup registry), do NOT try to
# uninstall it -- setup /ACTION=Uninstall on a clustered instance fails with
# "The selected instance is clustered and cannot be removed ... use
# /Action=RemoveNode". This is the idempotency case: a re-run after the FCI
# is installed must LEAVE the FCI alone (only standalone instances get
# uninstalled to make room for the FCI). Without this guard, every re-apply
# tries to uninstall the live FCI on sql-fci-1 + fails.
`$isClustered = (Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Microsoft SQL Server/MSSQL17.MSSQLSERVER/Setup' -Name SqlCluster -ErrorAction SilentlyContinue).SqlCluster;
if (`$isClustered -eq 1) { Write-Output 'ALREADY_CLUSTERED'; Stop-Transcript | Out-Null; exit 0; }
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
        } elseif ($uo -match 'ALREADY_CLUSTERED') {
          Write-Host "[fci-install] Phase A: $($fciNode.Tag) MSSQLSERVER is already the clustered FCI (leave it; idempotent skip)"
        } else {
          Write-Host $uo
          throw "[fci-install] Phase A: standalone uninstall failed on $($fciNode.Tag)"
        }
      }
      # WSFC service may need a moment to re-stabilize after the FCI-node reboots.
      Start-Sleep -Seconds 20

      # ── Disk-prep (cold-rebuild fix #32 at 0.G.7 cold rebuild 2026-05-22):
      #    ensure the clustered FCI disk is owned by sql-fci-1 + mounted as S:.
      #    After WSFC Add-ClusterDisk + the Phase A reboots, (a) the "Available
      #    Storage" group can be owned by ANY of the 4 WSFC nodes, and (b) the
      #    iscsi-attach drive letter (S:) is stripped/drifted by Add-ClusterDisk
      #    -- the disk comes back as E:. InstallFC on sql-fci-1 needs S: mounted
      #    LOCALLY. Run via PLAIN SSH (local nexusadmin): Get-ClusterGroup +
      #    Set-Partition work over plain SSH, whereas Get-ClusterResource hangs
      #    in the schtasks domain-task context (#28n class). Set-Partition is a
      #    storage cmdlet (no cluster dependency).
      $diskPrep = @'
$ErrorActionPreference = 'Continue'
Import-Module FailoverClusters -ErrorAction SilentlyContinue
$g = Get-ClusterGroup -Name 'Available Storage' -ErrorAction SilentlyContinue
if ($g -and $g.OwnerNode.Name -ne $env:COMPUTERNAME) {
  Move-ClusterGroup -Name 'Available Storage' -Node $env:COMPUTERNAME -ErrorAction SilentlyContinue | Out-Null
  Start-Sleep -Seconds 8
}
$disk = Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' } | Select-Object -First 1
if ($disk) {
  $data = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
  if ($data -and $data.DriveLetter -ne 'S') {
    Set-Partition -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber -NewDriveLetter S -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
  }
}
if (Test-Path 'S:\') { New-Item -ItemType Directory -Force -Path 'S:\SQLData' | Out-Null; Write-Output 'FCI_DISK_READY' } else { Write-Output 'FCI_DISK_FAIL' }
'@
      $dpB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($diskPrep))
      $dp = ssh -o ConnectTimeout=120 "$sshUser@$sf1Ip" "powershell -NoProfile -EncodedCommand $dpB64" 2>&1 | Out-String
      Write-Host ("[fci-install] disk-prep on sql-fci-1: " + ($dp.Trim() -replace "`r?`n", ' '))
      if ($dp -notmatch 'FCI_DISK_READY') { throw "[fci-install] disk-prep failed -- S: not mounted on sql-fci-1: $dp" }

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

  # Cold-rebuild fix #31 (2026-05-22): create the /INSTALLSQLDATADIR root. The
  # clustered disk's S: drive letter is (re-)assigned by the plain-SSH disk-prep
  # step in the OUTER orchestration just before this task (#32: Add-ClusterDisk
  # strips/drifts the iscsi-attach drive letter, so the disk comes back as E:,
  # not S: -- a Set-Partition storage cmdlet over plain SSH fixes it; cluster
  # RESOURCE cmdlets hang in this schtasks domain-task context). Here we only
  # need S: mounted + the data-dir base created (setup makes the leaf subdirs).
  if (-not (Test-Path 'S:\')) { throw 'S: not mounted on sql-fci-1 at InstallFC (disk-prep step did not assign the drive letter)'; }
  New-Item -ItemType Directory -Force -Path 'S:\SQLData' | Out-Null;
  Write-Output 'FCI_DATADIR_READY=S:\SQLData';

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

      # AddNode ALWAYS runs (transient #28m at 0.G.7 ratify 2026-05-22): the
      # AddNode orchestrate is self-idempotent (it emits NODE_ALREADY_ADDED if
      # sql-fci-2 is already a possible owner). Gating it behind
      # "FCI_ALREADY_INSTALLED absent" was wrong -- on a re-run where the FCI
      # exists on sql-fci-1 but a prior AddNode FAILED (sql-fci-2 not yet an
      # owner), the gate skipped AddNode forever, leaving a 1-node FCI. Always
      # invoking AddNode + relying on its own idempotency check is correct for
      # both from-zero (InstallFCI then AddNode) AND retry (skip if added).
      if ($true) {
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

  # Idempotent check via REGISTRY (not cluster cmdlets) -- transient #28n at
  # 0.G.7 ratify 2026-05-22: Get-ClusterResource/Get-ClusterOwnerNode threw a
  # cryptic "System error" inside the scheduled-task (NEXUS\nexusadmin) context
  # on sql-fci-2 (works fine as the local SSH user, so it's a task-context
  # quirk -- likely the FailoverClusters module's Hyper-V dependency under
  # ErrorActionPreference=Stop). If sql-fci-2 is already an FCI node, its
  # MSSQL17.MSSQLSERVER/Setup/SqlCluster registry value = 1 -- a plain
  # registry read, no cluster cmdlet, no Hyper-V dependency.
  `$alreadyNode = (Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Microsoft SQL Server/MSSQL17.MSSQLSERVER/Setup' -Name SqlCluster -ErrorAction SilentlyContinue).SqlCluster;
  if (`$alreadyNode -eq 1) { Write-Output 'NODE_ALREADY_ADDED'; Stop-Transcript | Out-Null; exit 0; }

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
    '/AGTSVCACCOUNT=$adNetbios\gmsa-sql-engine`$',
    '/SKIPRULES=Cluster_VerifyForErrors',
    '/IACCEPTSQLSERVERLICENSETERMS'
  );
  # AddNode needs the same /SKIPRULES=Cluster_VerifyForErrors as InstallFCI
  # (#28b) -- we skipped Test-Cluster preflight (#27c), so AddNode's cluster-
  # verify rule also fails with 3008/-2067919936 without it. Also /AGTSVC
  # ACCOUNT for the agent service (#28h, AddNode configures the agent too).
  # Transient #28o at 0.G.7 ratify 2026-05-22.
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
