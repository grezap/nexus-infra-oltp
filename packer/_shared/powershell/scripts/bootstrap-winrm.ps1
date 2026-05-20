# bootstrap-winrm.ps1 -- FirstLogonCommands entry point.
#
# Runs ONCE at OOBE on the very first login of the nexusadmin account (see
# AutoLogon + FirstLogonCommands in Autounattend.xml.tpl). Its only job is
# to open a WinRM HTTP listener on 5985 and a matching firewall rule so
# Packer's winrm communicator can connect and take over from here.
#
# The listener is build-time only -- scripts/99-sysprep.ps1 tears it down
# before generalize so clones never ship with plaintext WinRM open.
#
# Logs land in C:\Windows\Temp\bootstrap-winrm.log for post-mortem if the
# Packer build hangs on "Waiting for WinRM to become available".

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\bootstrap-winrm.log'
Start-Transcript -Path $log -Append -Force | Out-Null

try {
    Write-Host "[$(Get-Date -Format s)] bootstrap-winrm.ps1 start"

    # 1. Force every NIC's network category to Private. Win11 OOBE assigns
    #    new connections to "Public" by default, and WinRM refuses to flip
    #    AllowUnencrypted on while any NIC is Public ("WinRM firewall
    #    exception will not work since one of the network connection types
    #    on this machine is set to Public"). Server SKUs default new NICs
    #    to Private, which is why ws2025-* didn't hit this and win11ent did.
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

    # 2. Disable UAC remote-admin token filtering. Win11 (unlike Server SKUs)
    #    hands non-RID-500 local administrators a *filtered* access token
    #    over WinRM, stripping privileges needed for Add-WindowsCapability,
    #    Install-WindowsFeature, DISM, and similar setup-level operations.
    #    Symptom in the provisioner chain: "Add-WindowsCapability : Access
    #    is denied" on Add-WindowsCapability OpenSSH.Server. Setting this
    #    regkey to 1 tells LSA to issue the unfiltered (full-admin) token
    #    over WinRM for local admin members. Standard pattern for Packer +
    #    Win11 client SKUs.
    $lsaKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty -Path $lsaKey -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -Force

    # 3. Make sure WinRM service is running + set to auto-start.
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM

    # 4. Quick-config equivalent -- but scripted so we never wait on a prompt.
    #    -Force suppresses the interactive "this changes firewall rules" prompt.
    winrm quickconfig -quiet -force | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "winrm quickconfig failed (exit $LASTEXITCODE)" }

    # 5. Allow Basic auth + unencrypted -- Packer's default winrm communicator
    #    uses HTTP + Basic. Flipped off again in 99-sysprep.ps1 before sysprep.
    #    The PowerShell-native Set-Item cmdlets are reliable; the older
    #    `winrm set winrm/config/... '@{Foo="bar"}'` syntax has fragile
    #    arg-parsing through the cmd->vbs shim and silently no-ops on Win11
    #    when the inner double-quoted "true" gets stripped.
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic       -Value $true -Force
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
    Set-Item -Path WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 1024 -Force

    # 6. Confirm an HTTP listener exists on :5985. quickconfig usually creates
    #    one, but if the NIC came up after WinRM started the listener can be
    #    missing. Create it idempotently.
    $listeners = winrm enumerate winrm/config/listener 2>$null
    if ($listeners -notmatch 'Transport = HTTP') {
        winrm create winrm/config/Listener?Address=*+Transport=HTTP | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "winrm create listener failed (exit $LASTEXITCODE)" }
    }

    # 7. Firewall rule for 5985 in + 5986 in (5986 unused now, reserved for
    #    HTTPS post-cert rollout). Scope = any during build; 03-nexus-firewall.ps1
    #    re-scopes to VMnet11 only.
    New-NetFirewallRule -Name 'WinRM-HTTP-In-Build' `
        -DisplayName 'WinRM HTTP (build-time)' `
        -Protocol TCP -LocalPort 5985 -Direction Inbound -Action Allow `
        -Profile Any -ErrorAction SilentlyContinue | Out-Null

    # 8. Restart WinRM so the new auth/transport config takes effect on
    #    the live listener (Set-Item edits the config but in-flight listener
    #    behavior can lag until restart).
    Restart-Service -Name WinRM -Force

    Write-Host "[$(Get-Date -Format s)] bootstrap-winrm.ps1 done -- listener up"
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
