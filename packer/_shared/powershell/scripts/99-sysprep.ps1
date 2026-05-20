# 99-sysprep.ps1  --  final generalize before template shutdown
#
# Before running sysprep we:
#   1. Tear down the build-time WinRM HTTP listener + firewall rule (the
#      runtime remote-access path is OpenSSH, set up in 01-nexus-identity).
#   2. Clear event logs.
#   3. Remove Packer's working dir residue (uploaded files in C:\Windows\Temp).
#   4. Clear DNS cache so clones don't inherit the build-time NAT resolver.
#
# Then sysprep /generalize /oobe /shutdown leaves the VM powered off with a
# fresh SID + cloneable identity. Packer sees the VM power down and finalizes
# the .vmx.

$ErrorActionPreference = 'Continue'   # don't hard-fail on log-clear noise

Write-Host "=== 99-sysprep: teardown + generalize ==="

# -- 1. WinRM teardown is DEFERRED to the post-cleanup scheduled task.
# Doing it inline kills Packer's per-provisioner cleanup upload (HTTP 401 ->
# "Couldn't create shell"). The deferred task at the bottom of this script
# tears down the listener + firewall rule + auth knobs immediately before
# launching sysprep, by which point Packer has finished cleanup and is in
# its shutdown wait phase.

# -- 2. Clear event logs --------------------------------------------------
wevtutil el | ForEach-Object {
    try { wevtutil cl "$_" 2>$null } catch { Write-Verbose "skip log $_" }
}

# -- 3. Nuke Packer working files -----------------------------------------
Remove-Item -Recurse -Force 'C:\Windows\Temp\*' -Exclude 'packer-*' -ErrorAction SilentlyContinue

# -- 4. Clear DNS cache --------------------------------------------------
Clear-DnsClientCache

# -- 5. sysprep /generalize /oobe /shutdown -------------------------------
# Clone-time unattend that mini-OOBE consumes on the cloned VM's first
# boot. Two design points:
#
#   (a) UserAccounts block re-applies nexusadmin's password through
#       /generalize. Without it, sysprep clears local-account passwords
#       and clones boot into a login screen no one can satisfy. The
#       admin_username/admin_password come from each template's
#       environment_vars passed by the powershell provisioner. If the
#       env vars aren't set (e.g., a future template invokes 99-sysprep
#       without wiring them through), we fall back to the bare-OOBE
#       unattend and accept the clear-on-generalize behavior.
#
#   (b) Plaintext password lands on the cloned disk in
#       C:\Windows\System32\Sysprep\unattend.xml until mini-OOBE consumes
#       and redacts it (Win11 moves the consumed copy to
#       C:\Windows\Panther\unattend.xml with the password stripped).
#       Acceptable pre-Phase-0.D because Terraform post-clone rotates
#       the password before the VM is networked outside the build host.
$adminUser = $env:NEXUS_ADMIN_USERNAME
$adminPass = $env:NEXUS_ADMIN_PASSWORD
if ($adminUser -and $adminPass) {
    $userAccountsXml = @"
      <UserAccounts>
        <AdministratorPassword>
          <Value>$adminPass</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$adminPass</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>NexusPlatform admin (re-applied via 99-sysprep unattend)</Description>
            <DisplayName>$adminUser</DisplayName>
            <Group>Administrators</Group>
            <Name>$adminUser</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
"@
    Write-Host "99-sysprep: preserving $adminUser password through generalize"
}
else {
    $userAccountsXml = ''
    Write-Host "99-sysprep: NEXUS_ADMIN_USERNAME/PASSWORD not both set -- clone passwords will be cleared by /generalize"
}

$sysprepUnattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
$userAccountsXml
      <TimeZone>UTC</TimeZone>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
$unattendPath = 'C:\Windows\System32\Sysprep\unattend.xml'
Set-Content -Path $unattendPath -Value $sysprepUnattend -Encoding utf8

# Sysprep launch is *deferred* via a one-shot scheduled task that fires 90s
# in the future. Why: sysprep tears down the WinRM listener as part of
# /generalize. If we invoke it inline, Packer's per-provisioner cleanup
# phase (which uploads packer-cleanup-XXXX.ps1 to delete this script's
# remnants on C:\Windows\Temp) hits a dead listener and the build errors
# out with HTTP 401 -> connection-refused. By the time the deferred task
# fires, Packer has long since finished cleanup and entered shutdown_command
# wait, so it just observes the VM power off normally.
#
# 90s is conservative -- empirically Packer's post-script cleanup completes
# in <5s on this host, but the cost of overshooting is just a slightly later
# shutdown.
# Composite command: tear down WinRM listener/auth, then run sysprep. This
# runs as SYSTEM at T+90s, well after Packer's cleanup window has closed.
$deferredCmd = @"
try {
    `$listeners = & winrm enumerate winrm/config/listener 2>`$null
    if (`$listeners -match 'Transport = HTTP\s') {
        & winrm delete 'winrm/config/Listener?Address=*+Transport=HTTP' 2>`$null | Out-Null
    }
    Remove-NetFirewallRule -Name 'WinRM-HTTP-In-Build' -ErrorAction SilentlyContinue
    & winrm set winrm/config/service/auth '@{Basic=\"false\"}' 2>`$null | Out-Null
    & winrm set winrm/config/service '@{AllowUnencrypted=\"false\"}' 2>`$null | Out-Null
} catch { }
& "`$env:WINDIR\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet /unattend:"$unattendPath"
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deferredCmd))

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(90)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

Write-Host "Scheduling deferred sysprep /generalize /oobe /shutdown (T+90s)"
Register-ScheduledTask -TaskName 'NexusDeferredSysprep' `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Force | Out-Null

Write-Host "=== 99-sysprep: scheduled; returning so Packer cleanup can drain ==="
