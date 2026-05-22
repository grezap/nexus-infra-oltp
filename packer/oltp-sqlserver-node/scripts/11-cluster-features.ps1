# 11-cluster-features.ps1 -- enable WSFC + iSCSI Initiator + MPIO + AlwaysOn
# extensibility + open SQL Server / WSFC firewall ports on Windows Server 2025.
#
# Why all four features at template-bake time (not at terraform apply):
#   - Failover-Clustering, Multipath-IO, iSCSI-Initiator are Windows
#     OPTIONAL FEATURES. Installing them requires a Windows restart. Doing
#     so at template-bake time pays the restart cost once across all 4
#     clones; the alternative (terraform per-node install + restart) adds
#     ~2 min per clone × 4 = ~8 min to every apply.
#   - The features stay DORMANT until terraform configures them:
#       * iSCSI Initiator: dormant until Set-Service msiscsi -Status Running
#         (terraform's role-overlay-iscsi-attach.tf does this on sql-fci-1/2 only).
#       * MPIO: dormant until Enable-MSDSMAutomaticClaim -BusType iSCSI
#         (also in iscsi-attach overlay; only FCI nodes need this).
#       * Failover-Clustering: dormant until New-Cluster (terraform's
#         role-overlay-wsfc-bootstrap.tf does this on sql-fci-1 with all
#         4 nodes as members).
#
# Bake-time install of AG endpoint port (5022/tcp) in Windows Firewall
# is also done here. SQL 1433/tcp is opened by setup.exe's installer per
# /TCPENABLED=1 in 10-sql-install.ps1, but the AG HADR endpoint runs on
# its own port that isn't auto-opened.
#
# AlwaysOn extensibility (the SqlPS module's enable-AlwaysOn cmdlet
# equivalent) is enabled via PowerShell + a SQL service restart -- this
# flips the `HADR enabled` flag in SQL Server, required before any AG
# can be created. We do it at bake time because flipping the flag
# requires a SQL service restart, which is more expensive at apply time
# than at bake (apply time the service is in cluster role + restart
# disrupts FCI failover semantics).

$ErrorActionPreference = 'Stop'

Write-Host "=== 11-cluster-features: installing WSFC + iSCSI + MPIO + opening firewall ==="

# ---------------------------------------------------------------------
# Step 1: Install the 3 Windows optional features.
# Install-WindowsFeature with -IncludeManagementTools pulls in the
# RSAT-Failover-Clustering PowerShell module (FailoverClusters), the
# iSCSI initiator management cmdlets (iSCSI module), and the MPIO
# cmdlets. -Restart $false lets us batch all 3 + take ONE restart at
# the end via Packer's windows-restart provisioner.
# ---------------------------------------------------------------------
# Note: 'iSCSI-Initiator' is NOT a Windows Server 2025 feature name --
# WS2025 ships the iSCSI Initiator service (msiscsi) as built-in by
# default (no separate feature install). Transient #18 at 0.G.7 ratify
# 2026-05-20. So we only need Failover-Clustering + Multipath-IO here;
# msiscsi service activation lives in role-overlay-iscsi-attach.tf
# (terraform apply time, FCI nodes only -- AG replicas don't use iSCSI).
$features = @('Failover-Clustering', 'Multipath-IO', 'RSAT-AD-PowerShell')
# RSAT-AD-PowerShell is the ActiveDirectory PowerShell module (provides
# Install-ADServiceAccount, Test-ADServiceAccount, Get-ADComputer, etc.).
# Required by terraform's role-overlay-sqlserver-vault-agents.tf to
# `Install-ADServiceAccount -Identity gmsa-sql-engine` on each node.
# Transient #25c at 0.G.7 ratify 2026-05-21 -- missing this caused
# GMSA_INSTALL_FAILED on every node + SQL Server FCI install would have
# downstream-failed because the service can't run as gmsa-sql-engine$.
# Baking at template time pays the install cost once across 4 clones.
foreach ($f in $features) {
    $state = (Get-WindowsFeature -Name $f).InstallState
    if ($state -eq 'Installed') {
        Write-Host "  - $f : already installed (idempotent)"
        continue
    }
    Write-Host "  - $f : installing..."
    $result = Install-WindowsFeature -Name $f -IncludeManagementTools -Restart:$false
    if (-not $result.Success) {
        throw "Install-WindowsFeature $f failed: $($result.ExitCode)"
    }
    Write-Host "  - $f : installed (RestartNeeded=$($result.RestartNeeded))"
}

# Verify msiscsi service exists (built-in on WS2025; sanity-check).
$msiscsi = Get-Service -Name 'msiscsi' -ErrorAction SilentlyContinue
if ($msiscsi) {
    Write-Host "  - iSCSI Initiator service (msiscsi) : present + $($msiscsi.StartType) (left as-is; role-overlay-iscsi-attach.tf flips it Automatic on FCI nodes at apply time)"
} else {
    Write-Host "  WARN: msiscsi service not found. iSCSI attach at terraform apply time will fail. May need 'Enable-WindowsOptionalFeature -Online -FeatureName MicrosoftiSCSIInitiator' on WS2025 (different cmdlet, different feature name)."
}

# ---------------------------------------------------------------------
# Step 2: Pre-install iSCSI Initiator service registration. The service
# is installed by the iSCSI-Initiator feature above + set to Manual; we
# leave it Manual at bake time. terraform's role-overlay-iscsi-attach.tf
# flips it to Automatic on FCI nodes only.
# ---------------------------------------------------------------------
Set-Service -Name msiscsi -StartupType Manual

# ---------------------------------------------------------------------
# Step 3: Open SQL Server / WSFC firewall ports in the Windows Firewall
# Domain + Private profiles. The Public profile stays closed (assumes
# no production exposure on a Public-profile network -- the SQL VMs
# live on a domain-joined fleet).
#
# Ports per https://learn.microsoft.com/en-us/sql/sql-server/install/
# configure-the-windows-firewall-to-allow-sql-server-access:
#
#   1433/tcp -- SQL Server default instance (opened by setup.exe;
#               re-asserted here for completeness)
#   1434/udp -- SQL Browser (used by clients to discover named instances;
#               we only have the default instance MSSQLSERVER but Browser
#               is harmless and useful for nexus-cli SqlAgAdapter probes)
#   5022/tcp -- AG HADR endpoint (port we wire in role-overlay-ag-bootstrap)
#   135/tcp  -- WSFC RPC
#   137/udp  -- NetBIOS Name Service (WSFC heartbeat fallback)
#   138/udp  -- NetBIOS Datagram (WSFC heartbeat)
#   139/tcp  -- NetBIOS Session
#   445/tcp  -- SMB (CSV ownership migration, FCI shared-disk metadata)
#   3343/udp -- Cluster Network Driver (NetFT) heartbeat
#   49152-65535/tcp -- ephemeral RPC range for WSFC remote calls
#
# Each rule is created idempotently via -ErrorAction SilentlyContinue
# + Get-NetFirewallRule probe (Set-NetFirewallRule would also work; we
# use New + skip on -DisplayName collision).
# ---------------------------------------------------------------------
$fwRules = @(
    @{ Name = 'NEXUS-SQL-1433-TCP';    Protocol = 'TCP';  Port = 1433;      Display = 'NEXUS: SQL Server engine 1433/tcp' },
    @{ Name = 'NEXUS-SQL-1434-UDP';    Protocol = 'UDP';  Port = 1434;      Display = 'NEXUS: SQL Browser 1434/udp' },
    @{ Name = 'NEXUS-SQL-5022-TCP';    Protocol = 'TCP';  Port = 5022;      Display = 'NEXUS: AG HADR endpoint 5022/tcp' },
    @{ Name = 'NEXUS-WSFC-135-TCP';    Protocol = 'TCP';  Port = 135;       Display = 'NEXUS: WSFC RPC 135/tcp' },
    @{ Name = 'NEXUS-WSFC-137-UDP';    Protocol = 'UDP';  Port = 137;       Display = 'NEXUS: WSFC NetBIOS Name 137/udp' },
    @{ Name = 'NEXUS-WSFC-138-UDP';    Protocol = 'UDP';  Port = 138;       Display = 'NEXUS: WSFC NetBIOS Datagram 138/udp' },
    @{ Name = 'NEXUS-WSFC-139-TCP';    Protocol = 'TCP';  Port = 139;       Display = 'NEXUS: WSFC NetBIOS Session 139/tcp' },
    @{ Name = 'NEXUS-WSFC-445-TCP';    Protocol = 'TCP';  Port = 445;       Display = 'NEXUS: WSFC SMB 445/tcp' },
    @{ Name = 'NEXUS-WSFC-3343-UDP';   Protocol = 'UDP';  Port = 3343;      Display = 'NEXUS: WSFC NetFT 3343/udp' },
    @{ Name = 'NEXUS-WSFC-EPHEMERAL';  Protocol = 'TCP';  Port = '49152-65535'; Display = 'NEXUS: WSFC ephemeral RPC 49152-65535/tcp' }
)
foreach ($r in $fwRules) {
    $existing = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  - firewall rule $($r.Name) : already exists (idempotent)"
        continue
    }
    New-NetFirewallRule -Name $r.Name `
        -DisplayName $r.Display `
        -Direction Inbound `
        -Protocol $r.Protocol `
        -LocalPort $r.Port `
        -Action Allow `
        -Profile Domain,Private | Out-Null
    Write-Host "  - firewall rule $($r.Name) : created ($($r.Protocol)/$($r.Port))"
}

# ---------------------------------------------------------------------
# Step 4: Enable SQL Server AlwaysOn HADR feature.
# Without this flag, CREATE AVAILABILITY GROUP fails with error 35243
# "The HADR feature is not enabled on this SQL Server instance". The
# flag persists across service restarts; terraform's ag-bootstrap
# overlay doesn't need to re-enable it.
#
# Requires a SQL service restart to take effect. We stop the service +
# enable the flag via the WMI provider + start the service.
# Alternative: SqlServer PowerShell module's Enable-SqlAlwaysOn cmdlet
# -- we use the WMI approach to avoid the dependency on the SqlServer
# module (which has its own AOT / version baggage). The WMI provider
# is auto-installed by setup.exe.
# ---------------------------------------------------------------------
Write-Host "=== 11-cluster-features: enabling SQL Server HADR (AlwaysOn) ==="

Stop-Service -Name MSSQLSERVER -Force -ErrorAction SilentlyContinue
# WMI namespace: ROOT\Microsoft\SqlServer\ComputerManagement17 (SQL Server 2025).
# Locate the ServerSettings class instance + set IsHadrEnabled = true.
$wmiNamespace = 'ROOT\Microsoft\SqlServer\ComputerManagement17'
try {
    $serverInstance = Get-CimInstance -Namespace $wmiNamespace `
        -ClassName ServerSettings `
        -Filter "InstanceName='MSSQLSERVER'" `
        -ErrorAction Stop
    Invoke-CimMethod -InputObject $serverInstance `
        -MethodName SetHadrServiceSetting `
        -Arguments @{ HadrEnabled = 1 } | Out-Null
    Write-Host "  - HADR enabled via WMI (ROOT\Microsoft\SqlServer\ComputerManagement17)"
} catch {
    # WMI provider sometimes lags after install -- fallback to registry
    # edit (same effect). Reg path:
    # HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQLServer\HADR
    # value name: HADR_Enabled (DWORD)
    Write-Host "  - WMI HADR enable failed ($($_.Exception.Message)); falling back to registry"
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQLServer\HADR'
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name HADR_Enabled -Value 1 -Type DWord
    Write-Host "  - HADR enabled via registry (fallback)"
}
Start-Service -Name MSSQLSERVER

# Verify HADR is actually enabled via Microsoft.Data.SqlClient (transient
# #17 at 0.G.7 ratify 2026-05-20: SQL 2025 dropped the bundled sqlcmd.exe).
Start-Sleep -Seconds 5
try {
    $sqlClientPath = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'Microsoft.Data.SqlClient.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sqlClientPath) {
        Add-Type -Path $sqlClientPath.FullName -ErrorAction SilentlyContinue
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection "Server=localhost;Integrated Security=true;Database=master;TrustServerCertificate=true;Connection Timeout=15;"
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS hadr_enabled"
        $hadr = $cmd.ExecuteScalar()
        $conn.Close()
        if ($hadr -eq 1) {
            Write-Host "  - HADR enabled (SERVERPROPERTY confirmed via SqlClient)"
        } else {
            Write-Host "WARN: SERVERPROPERTY('IsHadrEnabled') = $hadr (expected 1). HADR may need an additional SQL service restart -- terraform's ag-bootstrap step will retry."
        }
    } else {
        Write-Host "  - SqlClient assembly not found; HADR verify skipped (terraform's ag-bootstrap step will surface any HADR issue)"
    }
} catch {
    Write-Host "WARN: HADR verify failed via SqlClient (non-fatal): $($_.Exception.Message). Terraform's ag-bootstrap step will retry."
}

Write-Host "=== 11-cluster-features: complete; Packer will restart the VM next ==="
