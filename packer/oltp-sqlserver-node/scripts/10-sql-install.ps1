# 10-sql-install.ps1 -- SQL Server 2025 Enterprise Developer Edition silent install.
#
# Inputs (environment vars, set by Packer's powershell provisioner):
#   NEXUS_SQL_VERSION   = '2025'  (informational; not actually used by
#                                  setup.exe since the binaries are version-
#                                  specific anyway)
#   NEXUS_SQL_EDITION   = 'Developer'
#   NEXUS_SQL_FEATURES  = 'SQLEngine,FullText'
#   NEXUS_SQL_INSTANCE  = 'MSSQLSERVER'
#   NEXUS_ISO_PATH      = 'C:\Windows\Temp\sqlserver.iso'  (uploaded by Packer
#                                                          file provisioner)
#
# Why silent (/Q) over passive (/QS): /QS shows a progress dialog, which
# Packer's powershell provisioner can't dismiss. /Q is fully unattended
# (logs only).
#
# Why /ACTION=Install (vs InstallFailoverCluster): at bake time we install
# a STANDALONE SQL instance on every node. The FCI pair (sql-fci-1/2) gets
# their instance re-configured as FCI at terraform apply time by
# role-overlay-fci-install.tf, which re-runs setup.exe with /ACTION=
# InstallFailoverCluster pointing at the iSCSI cluster shared volume. The
# AG-replica nodes (sql-ag-rep-1/2) keep the standalone install + just
# join the AG.
#
# Service account at bake time: NT AUTHORITY\NETWORK SERVICE (local).
# Terraform apply later flips this to nexus.lab\gmsa-sql-engine$ after the
# nodes domain-join + are added to nexus-sql-cluster-members (per the GMSA
# overlay).
#
# Authentication mode at bake time: Mixed (Windows + SQL). Why mixed:
# AG endpoint certificate-based auth (ADR-0027) doesn't itself need mixed
# mode, but the emergency `sa` access path requires SQL auth enabled. The
# `sa` login is created with the KV-seeded password at terraform-apply
# time via T-SQL, NOT at bake time -- /SECURITYMODE=SQL only enables the
# mode; the actual `sa` password is set later.

$ErrorActionPreference = 'Stop'

$sqlEdition  = $env:NEXUS_SQL_EDITION
$sqlFeatures = $env:NEXUS_SQL_FEATURES
$sqlInstance = $env:NEXUS_SQL_INSTANCE
$isoPath     = $env:NEXUS_ISO_PATH
$isoUrl      = $env:NEXUS_ISO_URL

if (-not $sqlEdition)  { throw 'NEXUS_SQL_EDITION env var missing' }
if (-not $sqlFeatures) { throw 'NEXUS_SQL_FEATURES env var missing' }
if (-not $sqlInstance) { throw 'NEXUS_SQL_INSTANCE env var missing' }
if (-not $isoPath)     { throw 'NEXUS_ISO_PATH env var missing' }
if (-not $isoUrl)      { throw 'NEXUS_ISO_URL env var missing (should be Packer http_directory URL)' }

# Stage 0: download the ISO from Packer's HTTP server. Bypasses the WinRM
# file-provisioner channel which has a hard limit on large files (transient
# #11 at 0.G.7 ratify 2026-05-20 -- MaxShellsPerUser=30 on the guest +
# winrmcp opens a fresh shell per chunk -> exhaustion on a 1.2 GB ISO).
# Invoke-WebRequest over HTTP from the Packer host's served dir is the
# canonical Packer pattern for large files.
if (Test-Path $isoPath) {
    $existingSize = (Get-Item $isoPath).Length
    Write-Host "=== 10-sql-install: ISO already at $isoPath ($existingSize bytes); skipping download ==="
} else {
    Write-Host "=== 10-sql-install: downloading SQL ISO from $isoUrl ==="
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # ProgressPreference=SilentlyContinue makes Invoke-WebRequest fast on PS5
    # (the progress bar costs huge CPU on large files; well-known PS quirk).
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    } catch {
        throw "ISO download failed: $($_.Exception.Message). Verify Packer http_directory points at the dir containing the ISO + the basename in NEXUS_ISO_URL matches the filename on disk."
    }
    $sw.Stop()
    $size = (Get-Item $isoPath).Length
    Write-Host ("=== 10-sql-install: download complete -- {0:N1} MB in {1:N1} sec ({2:N1} MB/s) ===" -f ($size/1MB), $sw.Elapsed.TotalSeconds, (($size/1MB)/$sw.Elapsed.TotalSeconds))
}

Write-Host "=== 10-sql-install: mounting $isoPath ==="

# Mount the ISO as a virtual CD-ROM. PowerShell's Mount-DiskImage is
# idempotent -- if already mounted it returns the existing image. The
# drive letter assignment is automatic; we pick it up via Get-Volume.
$image = Mount-DiskImage -ImagePath $isoPath -PassThru
$volume = ($image | Get-Volume)
$driveLetter = $volume.DriveLetter
if (-not $driveLetter) {
    # Race: Get-Volume sometimes returns null on a fresh mount. Wait + retry.
    Start-Sleep -Seconds 5
    $volume = (Get-DiskImage -ImagePath $isoPath | Get-Volume)
    $driveLetter = $volume.DriveLetter
}
if (-not $driveLetter) { throw "Failed to assign drive letter to mounted ISO at $isoPath" }
$setupExe = "${driveLetter}:\setup.exe"
if (-not (Test-Path $setupExe)) { throw "setup.exe not found at $setupExe (ISO content unexpected)" }

Write-Host "=== 10-sql-install: ISO mounted at ${driveLetter}: ; setup.exe at $setupExe ==="

# setup.exe arguments per
# https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt
# /TCPENABLED=1 -- canonical for remote SQL clients (the Listener at
#     .70.17 + the FCI virtual server at .70.16 + the AG replica clients
#     all connect via 1433/TCP).
# /NPENABLED=0 -- named pipes off (legacy; nothing in NexusPlatform uses them).
# /SQLSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE" -- bake-time identity;
#     terraform changes this to gmsa-sql-engine after domain-join.
# /SQLSYSADMINACCOUNTS="BUILTIN\Administrators" -- bake-time admin
#     allowlist; terraform adds nexus.lab\Domain Admins + the AG-specific
#     service principals after domain-join.
# /SECURITYMODE=SQL -- mixed mode (Windows + SQL auth). Required so the
#     `sa` login can be enabled later by terraform for emergency operator
#     access. /SAPWD is the bake-time placeholder; terraform OVERWRITES
#     this immediately via T-SQL after the node first boots, with the
#     KV-seeded sa-password.
# /UPDATEENABLED=0 -- don't pull CU/SP updates during bake (deterministic
#     image; CUs applied post-bake as a separate step if needed).
# /IACCEPTSQLSERVERLICENSETERMS -- silent EULA accept.
# /SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS -- canonical SQL Server
#     default (case-insensitive, accent-sensitive). Portfolio demos don't
#     need a different collation; this matches what most SSMS-clicked
#     installs land on.

$setupArgs = @(
    "/Q"
    "/ACTION=Install"
    "/FEATURES=$sqlFeatures"
    "/INSTANCENAME=$sqlInstance"
    "/SQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`""
    "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`""
    # NOTE -- /SECURITYMODE=SQL + /SAPWD INTENTIONALLY OMITTED at bake time.
    # Transient #15 at 0.G.7 ratify 2026-05-20: SQL 2025 setup.exe failed
    # at FinalCalculateSettings with `System.Security.Cryptography.
    # CryptographicException @ -2147024891 (0x80070005 ACCESS_DENIED)` --
    # SQL 2025 uses CNG providers to encrypt the SA password into the
    # ConfigurationFile.ini, and the CNG operation needs TPM-backed key
    # storage which VMware Workstation 25 doesn't expose at bake time.
    # Fix: install with Windows auth only at bake; SA password gets set
    # later via T-SQL by terraform's role-overlay-fci-install.tf using
    # the KV-seeded sa-password at apply time. SA is enabled then.
    "/TCPENABLED=1"
    "/NPENABLED=0"
    "/UPDATEENABLED=0"
    "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS"
    "/IACCEPTSQLSERVERLICENSETERMS"
    # SQL Server 2025-specific required args (transient #14 at 0.G.7 ratify
    # 2026-05-20). Memory limits mandatory + Software-Assurance opt-out.
    "/USESQLRECOMMENDEDMEMORYLIMITS=true"
    "/PRODUCTCOVEREDBYSA=False"
) -join ' '

# Transient #16 at 0.G.7 ratify 2026-05-20: SQL 2025 Setup's
# DataStoreService.SerializeObject calls ProtectedData.Protect (DPAPI)
# to encrypt the entire config datastore -- even with no SA password +
# Windows-only auth. DPAPI Protect fails with 0x80070005 ACCESS_DENIED
# because nexusadmin's DPAPI master key isn't initialized yet (Packer's
# WinRM session is non-interactive; the OOBE auto-logon was brief +
# may not have fully initialized the user's CryptoAPI state).
# Force DPAPI initialization explicitly for both scopes before setup.exe.
# Diagnostic: any throw here surfaces the EXACT scope that's broken.
Write-Host "=== 10-sql-install: initializing DPAPI master keys (workaround for SQL 2025 SerializeObject) ==="
Add-Type -AssemblyName System.Security
$dummy = [System.Text.Encoding]::UTF8.GetBytes("dpapi-init-$(Get-Random)")
try {
    $protected_user = [System.Security.Cryptography.ProtectedData]::Protect($dummy, $null, 'CurrentUser')
    Write-Host "  - CurrentUser scope: OK ($($protected_user.Length) bytes)"
} catch {
    Write-Host "  - CurrentUser scope: FAILED -- $($_.Exception.Message)"
}
try {
    $protected_machine = [System.Security.Cryptography.ProtectedData]::Protect($dummy, $null, 'LocalMachine')
    Write-Host "  - LocalMachine scope: OK ($($protected_machine.Length) bytes)"
} catch {
    Write-Host "  - LocalMachine scope: FAILED -- $($_.Exception.Message)"
}

Write-Host "=== 10-sql-install: launching setup.exe (silent, ~18 min) ==="
Write-Host "    Edition: $sqlEdition"
Write-Host "    Features: $sqlFeatures"
Write-Host "    Instance: $sqlInstance"
Write-Host "    (Logs land at C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log\)"

# Transient #16 confirmed: Packer's WinRM-spawned PS session has NO access
# to the CurrentUser DPAPI scope ("Access is denied" on
# ProtectedData.Protect). SQL Setup uses CurrentUser scope at
# DataStoreService.SerializeObject -> hard fail at FinalCalculateSettings.
# Fix: run setup.exe via a scheduled task as SYSTEM. SYSTEM has its own
# DPAPI key container that's always accessible + this is the Microsoft-
# documented workaround for SQL Setup over WinRM. The task fires once
# immediately + we poll until completion + grab LastTaskResult for the
# exit code. Standard pattern; same shape as the deferred-sysprep dance
# in _shared/powershell/scripts/99-sysprep.ps1.
$taskName = 'NexusSqlInstall'
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

$action    = New-ScheduledTaskAction -Execute $setupExe -Argument $setupArgs
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 45)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "    Scheduled task $taskName registered + started; waiting for completion (poll every 30s; cap at 45 min)..."
$pollDeadline = (Get-Date).AddMinutes(45)
$lastReportMinute = -1
while ((Get-Date) -lt $pollDeadline) {
    Start-Sleep -Seconds 30
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "Scheduled task $taskName disappeared mid-flight"
    }
    if ($task.State -ne 'Running') {
        Write-Host "    Task state transitioned to: $($task.State)"
        break
    }
    # Lightweight progress ticker so the bake log shows life every minute.
    $elapsed = [int]((Get-Date) - (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime).TotalMinutes
    if ($elapsed -ne $lastReportMinute) {
        Write-Host "    [${elapsed}m] still running..."
        $lastReportMinute = $elapsed
    }
}

$info = Get-ScheduledTaskInfo -TaskName $taskName
$exitCode = $info.LastTaskResult
Write-Host "    Task LastTaskResult (exit code): $exitCode"

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# 0 = success; 3010 = success but reboot required (Windows feature
# install + WMI provider). Treat 3010 as success here -- the next stage
# (11-cluster-features.ps1) is followed by a windows-restart provisioner
# anyway.
if ($exitCode -ne 0 -and $exitCode -ne 3010) {
    # Surface the most recent setup log paths. SQL Setup writes:
    #   - Summary.txt: human-readable summary (created late in install; may
    #     not exist if setup.exe died at CLI-arg-validation -- which is
    #     transient #14's failure mode).
    #   - Detail.txt: every line setup.exe printed (created early; almost
    #     always present even on early failures). This is the actual diag.
    #   - Detail_*_<feature>_<timestamp>.txt: per-feature install logs.
    $logRoot = 'C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log'
    if (Test-Path $logRoot) {
        $latest = Get-ChildItem $logRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-Host "ERROR: setup.exe exited $exitCode -- latest log dir: $($latest.FullName)"

        $summary = Join-Path $latest.FullName 'Summary.txt'
        if (Test-Path $summary) {
            Write-Host "`n--- Summary.txt (full) ---"
            Get-Content $summary | Write-Host
        } else {
            Write-Host "`n(Summary.txt not present -- setup.exe died before install phase)"
        }

        $detail = Join-Path $latest.FullName 'Detail.txt'
        if (Test-Path $detail) {
            Write-Host "`n--- Detail.txt (last 80 lines) ---"
            Get-Content $detail -Tail 80 | Write-Host
        } else {
            Write-Host "`n(Detail.txt not present -- check $($latest.FullName) for any other .txt)"
            Get-ChildItem $latest.FullName -Filter '*.txt' | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }
        }

        # Also check the bootstrap-level log (one above the timestamped dir)
        # which captures CLI-arg-parse errors that fire before the per-run
        # timestamped log dir is created.
        $bootstrap = Join-Path $logRoot 'Bootstrap.log'
        if (Test-Path $bootstrap) {
            Write-Host "`n--- Bootstrap.log (last 40 lines) ---"
            Get-Content $bootstrap -Tail 40 | Write-Host
        }
    } else {
        Write-Host "ERROR: setup.exe exited $exitCode but $logRoot doesn't exist (setup.exe didn't even create the log root)."
    }
    throw "SQL Server setup.exe failed (exit=$exitCode). See logs above."
}

Write-Host "=== 10-sql-install: setup.exe completed (exit=$exitCode) ==="

# Dismount the ISO (frees the drive letter; the ISO file itself is
# deleted by the final cleanup stage in oltp-sqlserver-node.pkr.hcl).
Dismount-DiskImage -ImagePath $isoPath | Out-Null

# Verify the engine actually responds. SQL Server 2025 dropped the bundled
# sqlcmd.exe (Microsoft replaced it with the separate Go-based sqlcmd tool
# that must be installed via `winget install sqlcmd` or similar). Transient
# #17 at 0.G.7 ratify 2026-05-20. So we can't shell out to sqlcmd at bake
# time -- use the .NET SqlClient via PowerShell + Microsoft.Data.SqlClient
# (which IS bundled with SQL Server 2025 install). If that's also absent,
# fall back to TCP-port probe + Get-Service.
function Test-SqlEngineReachable {
    param([string]$instance = 'MSSQLSERVER')
    # First check: service Running.
    $svc = Get-Service -Name $instance -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    if ($svc.Status -ne 'Running') {
        Start-Service -Name $instance -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        $svc = Get-Service -Name $instance
        if ($svc.Status -ne 'Running') { return $false }
    }
    # Second check: TCP 1433 reachable on localhost (proves the engine
    # accepted at least 1 TDS connection initialization).
    $tcp = Test-NetConnection -ComputerName localhost -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $tcp) { return $false }
    # Third check (best-effort): open a SqlConnection via the bundled
    # Microsoft.Data.SqlClient assembly. Don't fail bake if assembly
    # absent -- service-up + TCP-up is sufficient proof for the bake.
    try {
        $sqlClientPath = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'Microsoft.Data.SqlClient.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sqlClientPath) {
            Add-Type -Path $sqlClientPath.FullName -ErrorAction SilentlyContinue
            $conn = New-Object Microsoft.Data.SqlClient.SqlConnection "Server=localhost;Integrated Security=true;Database=master;TrustServerCertificate=true;Connection Timeout=15;"
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT CONCAT(SERVERPROPERTY('ProductVersion'),' ',SERVERPROPERTY('Edition'))"
            $ver = $cmd.ExecuteScalar()
            $conn.Close()
            Write-Host "  - SqlClient probe: $ver"
        } else {
            Write-Host "  - SqlClient assembly not found; falling back to service+TCP probe (still sufficient)"
        }
    } catch {
        Write-Host "  - SqlClient probe failed (non-fatal): $($_.Exception.Message)"
    }
    return $true
}

Write-Host "=== 10-sql-install: verifying engine reachability ==="
Start-Sleep -Seconds 10  # give the service a moment to settle after install
$ok = Test-SqlEngineReachable -instance $sqlInstance
if (-not $ok) {
    Start-Sleep -Seconds 15
    $ok = Test-SqlEngineReachable -instance $sqlInstance
}
if (-not $ok) {
    throw "MSSQLSERVER service did not reach Running + TCP-1433-listening within 30s"
}
Write-Host "=== 10-sql-install: engine reachable (service Running + TCP/1433 accepting) ==="

# ── Install ODBC Driver 18 + the Command Line Utilities (sqlcmd/bcp) ──────────
# COLD-REBUILD-CRITICAL (transient #30 at 0.G.7 ratify 2026-05-22): SQL Server
# 2025 dropped the bundled sqlcmd.exe (#17), but EVERY terraform apply overlay
# (fci-install, ag-bootstrap, ag-listener) AND smoke-0.G.7.ps1 shell out to
# `sqlcmd` via the schtasks domain-task. During the first live ratification
# sqlcmd + ODBC Driver 18 were installed MANUALLY -- a from-zero cold-rebuild
# gap (a fresh template would have no sqlcmd, so fci-install would fail at its
# first T-SQL call). Bake them into the template instead. We install the legacy
# ODBC-based sqlcmd (Microsoft Command Line Utilities) -- NOT go-sqlcmd -- to
# match the proven flag semantics the overlays use (`-E -C/-N -h -1 -W -b -i`).
# The bake host has internet (it pulled windows_exporter + can reach
# go.microsoft.com); pinned fwlink permalinks resolve to the latest GA MSI.
$odbcMsiUrl   = $env:NEXUS_ODBC18_MSI_URL;   if (-not $odbcMsiUrl)   { $odbcMsiUrl   = 'https://go.microsoft.com/fwlink/?linkid=2358430' }  # ODBC Driver 18 x64 (18.6.x GA)
$cmdlnMsiUrl  = $env:NEXUS_SQLCMD_MSI_URL;    if (-not $cmdlnMsiUrl)  { $cmdlnMsiUrl  = 'https://go.microsoft.com/fwlink/?linkid=2230791' }  # Command Line Utilities 15 x64 (sqlcmd + bcp)
$dl = 'C:\Windows\Temp\nexus-sqltools'
New-Item -ItemType Directory -Force -Path $dl | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Install-MsiFromUrl {
    param([string]$url, [string]$fileName, [string]$extraProps)
    $msi = Join-Path $dl $fileName
    Write-Host "  - downloading $fileName ..."
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    if (-not (Test-Path $msi) -or (Get-Item $msi).Length -lt 100000) { throw "download of $fileName failed or too small" }
    $log = Join-Path $dl ($fileName + '.log')
    $msiArgs = "/i `"$msi`" /qn /norestart $extraProps /l*v `"$log`""
    Write-Host "  - msiexec $fileName ($extraProps) ..."
    $p = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "$fileName install failed (exit=$($p.ExitCode); see $log)" }
}

Write-Host "=== 10-sql-install: installing ODBC Driver 18 + sqlcmd Command Line Utilities ==="
Install-MsiFromUrl -url $odbcMsiUrl  -fileName 'msodbcsql18.msi'     -extraProps 'IACCEPTMSODBCSQLLICENSETERMS=YES'
Install-MsiFromUrl -url $cmdlnMsiUrl -fileName 'MsSqlCmdLnUtils.msi' -extraProps 'IACCEPTMSSQLCMDLNUTILSLICENSETERMS=YES'

# Refresh this session's PATH from the machine env (the MSIs append to it) +
# verify sqlcmd resolves + runs. Fail the bake loudly if not -- a template
# without sqlcmd would silently break every downstream apply overlay.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
$sqlcmdCmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $sqlcmdCmd) {
    # Fallback: probe the canonical ODBC Tools location directly.
    $probe = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC' -Recurse -Filter 'sqlcmd.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($probe) { $sqlcmdCmd = $probe }
}
if (-not $sqlcmdCmd) { throw "sqlcmd.exe not found on PATH after installing the Command Line Utilities -- bake aborted (downstream apply overlays require sqlcmd)" }
$sqlcmdPath = if ($sqlcmdCmd.Source) { $sqlcmdCmd.Source } else { $sqlcmdCmd.FullName }
Write-Host "=== 10-sql-install: sqlcmd installed at $sqlcmdPath ==="
Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue
