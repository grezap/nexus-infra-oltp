# 05-windows-baseline.ps1  --  Windows-specific baseline (no Linux parallel)
#
# The OS-tail equivalent of debian_base / ubuntu_base. Things that only make
# sense on Windows:
#   - Windows Update policy -- defer feature updates, auto-install quality updates
#   - Telemetry minimised to "Security" (lowest possible on WS Standard)
#   - PowerShell execution policy: RemoteSigned (needed for future Vault/Consul
#     signed scripts) -- NOT Unrestricted.
#   - Login banner (LegalNoticeCaption / LegalNoticeText) -- the Windows
#     equivalent of /etc/motd.
#   - Disable automatic Server Manager launch on login (Core has no Server
#     Manager GUI anyway, but the scheduled task still fires).
#   - Disable Customer Experience Improvement Program task.
#   - TLS 1.2+ enforced at SCHANNEL (WS2025 default, but belt-and-braces).

$ErrorActionPreference = 'Stop'

Write-Host "=== 05-windows-baseline ==="

# -- 1. Windows Update: security auto, feature deferred ------------------
# We set the registry-level "WindowsUpdate" policy keys so the behaviour
# persists through sysprep. Options:
#   AUOptions=4           -> auto download + install at scheduled time
#   ScheduledInstallDay=0 -> every day
#   NoAutoRebootWithLoggedOnUsers=1
$wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (-not (Test-Path $wuKey)) { New-Item -Path $wuKey -Force | Out-Null }
Set-ItemProperty -Path $wuKey -Name 'NoAutoUpdate'                  -Value 0 -Type DWord
Set-ItemProperty -Path $wuKey -Name 'AUOptions'                     -Value 4 -Type DWord
Set-ItemProperty -Path $wuKey -Name 'ScheduledInstallDay'           -Value 0 -Type DWord
Set-ItemProperty -Path $wuKey -Name 'ScheduledInstallTime'          -Value 3 -Type DWord
Set-ItemProperty -Path $wuKey -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord

# -- 2. Telemetry -> Security (value 0). Enterprise only; Std coerces to 1. --
$dcKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
if (-not (Test-Path $dcKey)) { New-Item -Path $dcKey -Force | Out-Null }
Set-ItemProperty -Path $dcKey -Name 'AllowTelemetry' -Value 0 -Type DWord

# -- 3. PS execution policy -----------------------------------------------
# Write the machine-scope policy directly to the registry rather than via
# Set-ExecutionPolicy. Packer invokes provisioners with `-ExecutionPolicy
# Bypass`, which sets Process scope; Set-ExecutionPolicy -Scope LocalMachine
# then emits a non-terminating "override" warning that $ErrorActionPreference
# promotes to terminating. The registry write achieves the same persistence
# (applies to future non-Packer sessions) without the warning.
$psPolicyKey = 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
if (-not (Test-Path $psPolicyKey)) { New-Item -Path $psPolicyKey -Force | Out-Null }
Set-ItemProperty -Path $psPolicyKey -Name 'ExecutionPolicy' -Value 'RemoteSigned' -Type String

# -- 4. Login banner (Windows equivalent of /etc/motd) --------------------
# Per-template stamp: NEXUS_TEMPLATE_NAME and NEXUS_PHASE are set in each
# Packer template's powershell-provisioner environment_vars block. Fall
# back to '<unset>' so this script still runs when invoked directly outside
# Packer (e.g., manual re-runs during debugging).
$tmplName = if ($env:NEXUS_TEMPLATE_NAME) { $env:NEXUS_TEMPLATE_NAME } else { '<unset>' }
$phase    = if ($env:NEXUS_PHASE)         { $env:NEXUS_PHASE }         else { '<unset>' }
$bannerLine = ('     Template: {0}  Phase: {1}' -f $tmplName, $phase).PadRight(62)
$lsaKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $lsaKey -Name 'LegalNoticeCaption' -Value 'NexusPlatform'
Set-ItemProperty -Path $lsaKey -Name 'LegalNoticeText' -Value @"
#==============================================================#
#                      NexusPlatform                           #
#     Authorized access only. All activity is logged.          #
#$bannerLine#
#==============================================================#
"@

# -- 5. Disable Server Manager auto-launch scheduled task -----------------
$sm = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' `
    -TaskName 'ServerManager' -ErrorAction SilentlyContinue
if ($sm) { Disable-ScheduledTask -InputObject $sm | Out-Null }

# Disable CEIP
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' `
    -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null

# -- 6. TLS hardening -- disable SSL 3.0 + TLS 1.0/1.1, keep 1.2/1.3 --------
$tlsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
$deprecated = @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')
foreach ($proto in $deprecated) {
    foreach ($side in 'Client', 'Server') {
        $k = "$tlsRoot\$proto\$side"
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        Set-ItemProperty -Path $k -Name 'Enabled'           -Value 0 -Type DWord
        Set-ItemProperty -Path $k -Name 'DisabledByDefault' -Value 1 -Type DWord
    }
}

# -- 7. Pagefile sanity -- fixed 4 GB (default "system managed" grows
# unpredictably on VMs with thin disks). Disable managed, set explicit.
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.AutomaticManagedPagefile) {
    $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
}
$pf = Get-CimInstance -ClassName Win32_PageFileSetting
if ($pf) {
    $pf | Set-CimInstance -Property @{ InitialSize = 4096; MaximumSize = 4096 }
}
else {
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{
        Name        = 'C:\pagefile.sys'
        InitialSize = 4096
        MaximumSize = 4096
    } | Out-Null
}

Write-Host "=== 05-windows-baseline: OK ==="
