# 10-sql-install.ps1 -- SQL Server 2025 Enterprise Developer Edition silent install.
#
# Inputs (environment vars, set by Packer's powershell provisioner):
#   NEXUS_SQL_VERSION   = '2022'  (informational; not actually used by
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

Write-Host "=== 10-sql-install: launching setup.exe (silent, ~18 min) ==="
Write-Host "    Edition: $sqlEdition"
Write-Host "    Features: $sqlFeatures"
Write-Host "    Instance: $sqlInstance"
Write-Host "    (Logs land at C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log\)"

$proc = Start-Process -FilePath $setupExe -ArgumentList $setupArgs `
    -Wait -PassThru -NoNewWindow
$exitCode = $proc.ExitCode

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

# Verify the engine actually responds. sqlcmd is on PATH after install.
# -E uses Windows auth (Local Administrator is in the BUILTIN\Administrators
# sysadmin role per the /SQLSYSADMINACCOUNTS arg above).
$null = & sqlcmd -E -S "localhost\$sqlInstance" -Q "SELECT @@VERSION" -h -1 -W 2>&1
if ($LASTEXITCODE -ne 0) {
    # First-install sometimes needs a few seconds for the service to fully
    # initialize even after Start-Service returns. Retry once after 10s.
    Start-Sleep -Seconds 10
    $verOut = & sqlcmd -E -S "localhost\$sqlInstance" -Q "SELECT @@VERSION" -h -1 -W 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd against MSSQLSERVER failed (exit=$LASTEXITCODE). Output: $verOut"
    }
}

$verOut = & sqlcmd -E -S "localhost\$sqlInstance" -Q "SELECT CONCAT(SERVERPROPERTY('ProductVersion'),' ',SERVERPROPERTY('Edition'))" -h -1 -W
Write-Host "=== 10-sql-install: engine reachable -- $verOut ==="
