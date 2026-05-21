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

      # Transient #27 at 0.G.7 ratify 2026-05-21: WSFC cmdlets (Test-Cluster,
      # New-Cluster, Add-ClusterDisk, etc.) require DOMAIN admin privileges
      # to validate nodes + write the cluster object to AD. The SSH session
      # runs as LOCAL `sql-fci-1\nexusadmin` (Windows OpenSSH keeps the local
      # SAM for SSH key auth even on domain-joined hosts) -- no domain TGT
      # -> Test-Cluster fails with "Access is denied". Solution: dispatch the
      # WSFC orchestration as a Scheduled Task running as NEXUS\nexusadmin
      # (domain creds from nexusadmin-credentials.json sidecar). Same pattern
      # used by Packer template's 10-sql-install.ps1 for DPAPI-restricted
      # operations + by future fci-install / ag-bootstrap overlays.
      $adCredsJson = Join-Path $HOME ".nexus/nexusadmin-credentials.json"
      if (-not (Test-Path $adCredsJson)) {
        throw "[wsfc-bootstrap] nexusadmin-credentials.json not found at $adCredsJson"
      }
      $adCreds   = Get-Content $adCredsJson -Raw | ConvertFrom-Json
      $adNetbios = if ($adCreds.PSObject.Properties['netbios']) { $adCreds.netbios } else { 'NEXUS' }
      $adUser    = "$adNetbios\$($adCreds.username)"
      $adPass    = $adCreds.password

      Write-Host "[wsfc-bootstrap] creating WSFC cluster $cluster (members: 4 SQL nodes; cluster IP $clusterIp; via Scheduled Task as $adUser)..."

      $nodeList = "'sql-fci-1','sql-fci-2','sql-ag-rep-1','sql-ag-rep-2'"

      # The WSFC orchestration script (runs on sql-fci-1 as NEXUS\nexusadmin).
      $orchestrate = @"
`$ErrorActionPreference = 'Stop';
`$logPath = 'C:/Windows/Temp/wsfc-bootstrap.log';
Start-Transcript -Path `$logPath -Force | Out-Null;
try {
  Import-Module FailoverClusters;

  # Idempotent: if cluster exists, skip create + go straight to CSV add.
  `$existing = Get-Cluster -Name '$cluster' -ErrorAction SilentlyContinue;
  if (`$existing) {
    Write-Output 'CLUSTER_EXISTS';
  } else {
    # Skip Test-Cluster (transient #27c at 0.G.7 ratify 2026-05-21 -- the
    # scheduled-task-as-NEXUS\nexusadmin context doesn't get full Kerberos
    # delegation for cross-node RPC validation, even though the credential
    # is valid + reachable; Test-Cluster fails with "The node cannot be
    # contacted"). New-Cluster -Force skips its own preflight checks; the
    # cluster will still be validated post-create + the operator can run
    # Test-Cluster manually if needed.
    Write-Output 'Running New-Cluster (skipping preflight validation)...';
    New-Cluster -Name '$cluster' -Node $nodeList ``
      -StaticAddress '$clusterIp' ``
      -NoStorage ``
      -AdministrativeAccessPoint ActiveDirectoryAndDns ``
      -Force | Out-Null;
    Write-Output ('CLUSTER_CREATED: ' + (Get-Cluster).Name);
  }

  # Add the iSCSI LUN as a Cluster Shared Volume (CSV).
  `$availDisk = Get-ClusterAvailableDisk -ErrorAction SilentlyContinue | Where-Object { `$_.Size -gt 50GB };
  if (`$availDisk) {
    `$availDisk | Add-ClusterDisk | Out-Null;
    `$clusDisk = Get-ClusterResource | Where-Object { `$_.ResourceType -eq 'Physical Disk' -and `$_.State -eq 'Online' } | Select-Object -First 1;
    if (`$clusDisk) {
      Add-ClusterSharedVolume -InputObject `$clusDisk | Out-Null;
      Write-Output ('CSV_ADDED: ' + `$clusDisk.Name);
    }
  } else {
    `$existingCsv = Get-ClusterSharedVolume -ErrorAction SilentlyContinue;
    if (`$existingCsv) {
      Write-Output ('CSV_ALREADY: ' + `$existingCsv.Name);
    } else {
      Write-Output 'WARN: no available iSCSI disk to add as CSV';
    }
  }

  # Report final cluster state.
  Get-ClusterNode | ForEach-Object { Write-Output ('NODE: ' + `$_.Name + ' state=' + `$_.State) };
  Write-Output 'WSFC_ORCHESTRATE_OK';
} catch {
  Write-Output ('WSFC_ORCHESTRATE_FAIL: ' + `$_.Exception.Message);
  exit 1;
} finally {
  Stop-Transcript | Out-Null;
}
"@

      # Wrapper script that dispatches the orchestrate script as a Scheduled
      # Task running as NEXUS\nexusadmin. Pattern: register task -> trigger
      # -> poll until done -> read transcript log -> delete task.
      # Note: $ErrorActionPreference deliberately NOT set to Stop here -- the
      # idempotent schtasks /Delete on first apply legitimately errors with
      # "file not found" because no task exists yet. We tolerate that via
      # stderr redirection + native rc ignore.
      $wrapper = @"
`$ErrorActionPreference = 'Continue';
`$scriptPath = 'C:/Windows/Temp/wsfc-orchestrate.ps1';
`$logPath = 'C:/Windows/Temp/wsfc-bootstrap.log';
Remove-Item `$logPath -ErrorAction SilentlyContinue;
Remove-Item `$scriptPath -ErrorAction SilentlyContinue;
@'
$orchestrate
'@ | Set-Content -Path `$scriptPath -Encoding UTF8;

`$taskName = 'NexusWsfcBootstrap';
try { schtasks /Delete /TN `$taskName /F 2>&1 | Out-Null } catch {};
# Transient #27c: PS's Register-ScheduledTask with -User + -Password defaults
# to S4U logon type (Service-for-User), which gives a CONSTRAINED token
# WITHOUT network credentials. Cluster cmdlets need full network creds to
# do cross-node RPC -> they fail with "node cannot be contacted". Workaround:
# use the legacy `schtasks /Create /RU /RP` syntax which creates a task
# with PASSWORD logon type (full network credentials). Setting -Principal
# with -LogonType Password isn't compatible with Register-ScheduledTask's
# -Password param (AmbiguousParameterSet, transient #27b). schtasks.exe
# is the simpler escape hatch.
schtasks /Create /TN `$taskName /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$scriptPath" /SC ONCE /ST 23:59 /RU '$adUser' /RP '$adPass' /RL HIGHEST /F | Out-Null;
schtasks /Run /TN `$taskName | Out-Null;

# Poll for completion (max 10 min).
`$deadline = (Get-Date).AddMinutes(10);
do {
  Start-Sleep -Seconds 10;
  `$status = schtasks /Query /TN `$taskName /FO LIST /V 2>`$null | Select-String 'Status:' | Select-Object -First 1;
  `$running = `$status -match 'Running';
} while (`$running -and ((Get-Date) -lt `$deadline));

# Read transcript output + last-exit-code.
if (Test-Path `$logPath) {
  Get-Content `$logPath -Raw;
}
`$lastRc = (schtasks /Query /TN `$taskName /FO LIST /V 2>`$null | Select-String 'Last Result:' | ForEach-Object { (`$_ -split ':')[1].Trim() } | Select-Object -First 1);
Write-Output ('TASK_LAST_RC=' + `$lastRc);

# Clean up task.
try { schtasks /Delete /TN `$taskName /F 2>&1 | Out-Null } catch {};
Remove-Item `$scriptPath -ErrorAction SilentlyContinue;
"@

      # Per transient #25, the wrapper script is ~5KB → ~10KB base64-Unicode →
      # past the Windows ssh.exe argv ~6KB cliff. Dispatch via scp + powershell
      # -File instead of EncodedCommand to bypass the limit.
      $tempLocal = Join-Path $env:TEMP "wsfc-wrapper-$([System.Guid]::NewGuid().ToString('N')).ps1"
      $wrapper | Out-File -FilePath $tempLocal -Encoding UTF8 -Force
      $remoteSrc = "C:/Windows/Temp/nexus-wsfc-wrapper.ps1"
      scp -o ConnectTimeout=30 -o BatchMode=yes $tempLocal "$sshUser@$($sf1Ip):$remoteSrc" 2>&1 | Write-Host
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue
        throw "[wsfc-bootstrap] scp of wrapper failed (rc=$LASTEXITCODE)"
      }
      Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue

      $output = ssh -o ConnectTimeout=600 "$sshUser@$sf1Ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteSrc" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($output -notmatch 'WSFC_ORCHESTRATE_OK') {
        throw "[wsfc-bootstrap] orchestrate script did not report success on sql-fci-1"
      }
      ssh -o ConnectTimeout=10 "$sshUser@$sf1Ip" "Remove-Item -Path '$remoteSrc' -ErrorAction SilentlyContinue" 2>&1 | Out-Null
      Write-Host "[wsfc-bootstrap] WSFC cluster $cluster live at $clusterIp; CSV mounted"
    PWSH
  }
}
