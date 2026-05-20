# 00-install-vmware-tools.ps1
#
# tools_mode=attach: Packer attaches VMware Tools windows.iso as a CD-ROM
# device on the VM (no WinRM upload). This script scans optical drives to
# locate it, then runs the silent installer. A follow-up windows-restart
# provisioner reboots so subsequent scripts see the Tools-aware kernel
# shim + time sync.

$ErrorActionPreference = 'Stop'

Write-Host "Scanning optical drives for VMware Tools installer"

# CD-ROM drives on the VM. At minimum: the install ISO CD (already ejected
# by Setup) + the Tools CD just attached by Packer. Drive letters are not
# deterministic across WS2025 builds, so discover by content.
$cds = Get-CimInstance -ClassName Win32_CDROMDrive
foreach ($cd in $cds) {
    Write-Host "  $($cd.Drive) : $($cd.VolumeName) [$($cd.MediaLoaded)]"
}

$toolsRoot = $null
$setupExe  = $null
$toolsMsi  = $null

foreach ($cd in $cds) {
    $root = "$($cd.Drive)\"
    if (-not (Test-Path $root)) { continue }

    $candidateExe = @("${root}setup64.exe", "${root}setup.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1

    $candidateMsi = Get-ChildItem -Path $root -Filter 'VMware-tools-*x86_64.msi' `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

    if ($candidateExe -or $candidateMsi) {
        $toolsRoot = $root
        $setupExe  = $candidateExe
        $toolsMsi  = $candidateMsi
        Write-Host "Found VMware Tools on ${root} (setup=$candidateExe msi=$candidateMsi)"
        # Show full root listing once so audit log captures the ISO layout.
        Get-ChildItem -Path $root -Force |
            Select-Object Name, Length | Format-Table | Out-String | Write-Host
        break
    }
}

if (-not $toolsRoot) {
    Write-Host "No VMware Tools installer found on any optical drive. Drives scanned:"
    foreach ($cd in $cds) {
        $root = "$($cd.Drive)\"
        if (Test-Path $root) {
            Write-Host "--- ${root} ---"
            Get-ChildItem -Path $root -Force -ErrorAction SilentlyContinue |
                Select-Object Name, Length | Format-Table | Out-String | Write-Host
        }
    }
    throw "VMware Tools CD not attached or empty -- check Packer tools_mode"
}

if ($setupExe) {
    Write-Host "Installing VMware Tools via $setupExe (silent, no reboot)"
    $setupArgs = @('/S', '/v', '/qn REBOOT=ReallySuppress')
    $p = Start-Process -FilePath $setupExe -ArgumentList $setupArgs -Wait -PassThru
}
else {
    Write-Host "Installing VMware Tools via MSI: $toolsMsi"
    $msiArgs = @('/i', $toolsMsi, '/qn', '/norestart', 'REBOOT=ReallySuppress')
    $p = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
}

if ($p.ExitCode -notin 0, 3010) {
    throw "VMware Tools install exited with $($p.ExitCode)"
}

Write-Host "VMware Tools install OK (exit=$($p.ExitCode))"
