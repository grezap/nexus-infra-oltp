# 01-nexus-identity.ps1  --  Windows analog of _shared/ansible/roles/nexus_identity
#
# Responsibilities (parallel to the Linux role):
#   1. Ensure the nexusadmin local user exists (Autounattend already created
#      it, but we reconcile just in case) + is a member of Administrators.
#   2. Install the OpenSSH Server Windows Capability so the runtime remote
#      access path is SSH (key-only), just like every other NexusPlatform VM.
#   3. Deploy the owner's ed25519 pubkey to nexusadmin's authorized_keys,
#      using the Windows-specific dual-ACL pattern (administrators get an
#      extra administrators_authorized_keys file; non-admins use ~/.ssh).
#   4. Harden sshd_config -- PubkeyAuthentication yes, PasswordAuthentication no,
#      AllowUsers nexusadmin, PermitRootLogin no.
#   5. Set sshd service to auto-start + start it now.
#
# The shared-role parallel is deliberate: when ws2025-desktop lands at Phase
# 0.B.5, the common bits from this file and the ws2025-desktop copy extract
# into packer/_shared/powershell/modules/NexusIdentity.psm1 (or a shared
# scripts/_shared/ dir -- decide at extraction time with two call sites).

$ErrorActionPreference = 'Stop'
$user = $env:NEXUS_ADMIN_USERNAME
if (-not $user) { $user = 'nexusadmin' }

Write-Host "=== 01-nexus-identity: target user = $user ==="

# 1. User exists + in Administrators (Autounattend should have done this already;
#    this is idempotency insurance).
$u = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
if (-not $u) {
    throw "Expected local user '$user' (created by Autounattend). Not found -- Autounattend likely misfired."
}
if (-not (Get-LocalGroupMember -Group Administrators -Member $user -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group Administrators -Member $user
}

# 2. OpenSSH Server: WS2025 ships the FOD payload in install.wim so
#    Add-WindowsCapability completes quickly. Win11 client SKUs do *not*,
#    and Add-WindowsCapability over Windows Update routinely takes 20+
#    minutes and trips Packer's WinRM timeouts -- so win11ent's
#    05-install-openssh.ps1 runs ahead of this script and registers sshd
#    via the Win32-OpenSSH GitHub release. We honor that pre-install if
#    present, otherwise fall back to FOD for the Server SKU path.
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    Write-Host "Installing OpenSSH.Server capability via FOD"
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

# 3. Deploy owner pubkey to nexusadmin's authorized_keys.
#    Windows OpenSSH quirk: for users in the Administrators group, sshd ignores
#    ~\.ssh\authorized_keys and instead reads C:\ProgramData\ssh\administrators_authorized_keys
#    (ACL'd to SYSTEM + Administrators). So we write to BOTH -- user-level for
#    future non-admin compat, admin-file for the immediate nexusadmin login.
$src = 'C:\Windows\Temp\nexusadmin-authorized_keys'
if (-not (Test-Path $src)) {
    throw "Expected staged authorized_keys at $src (Packer file provisioner should have uploaded it)."
}
$pubkey = (Get-Content -Raw -Path $src).TrimEnd("`r", "`n") + "`n"

# 3a. User-profile copy
$userHome = (Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$user" }).LocalPath
if (-not $userHome) { $userHome = "C:\Users\$user" }
$sshDir = Join-Path $userHome '.ssh'
New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
$userAK = Join-Path $sshDir 'authorized_keys'
Set-Content -Path $userAK -Value $pubkey -NoNewline -Encoding ascii

# Lock down user-profile .ssh ACL: owner-only (nexusadmin) + SYSTEM.
icacls $sshDir    /inheritance:r /grant:r "${user}:(OI)(CI)F" "SYSTEM:(OI)(CI)F"       | Out-Null
icacls $userAK    /inheritance:r /grant:r "${user}:F"        "SYSTEM:F"                | Out-Null

# 3b. Admin-group copy (the one sshd actually reads for admin users).
$adminAKDir = 'C:\ProgramData\ssh'
New-Item -Path $adminAKDir -ItemType Directory -Force | Out-Null
$adminAK = Join-Path $adminAKDir 'administrators_authorized_keys'
Set-Content -Path $adminAK -Value $pubkey -NoNewline -Encoding ascii
icacls $adminAK /inheritance:r /grant "Administrators:F" "SYSTEM:F"                    | Out-Null

# 4. sshd_config hardening -- drop-in via the full file (no /etc/ssh/sshd_config.d
#    behavior on Windows OpenSSH). Preserve Windows-specific includes.
#
# Notable absences vs. the Linux equivalent:
#
#   * No `Match Group administrators` block. Win32-OpenSSH treats users in
#     the Administrators group specially (always reads
#     C:\ProgramData\ssh\administrators_authorized_keys regardless of
#     AuthorizedKeysFile), so the Match block is informational at best --
#     and on Win11 24H2 (build 26200) clones post-sysprep, the Match-
#     triggered config-reprocess pass crashes sshd-session/sshd children
#     with STATUS_ACCESS_VIOLATION (0xC0000005) before the SSH protocol
#     can begin. We set AuthorizedKeysFile globally instead.
#
#   * No KerberosAuthentication / GSSAPIAuthentication / Challenge
#     ResponseAuthentication. Win32-OpenSSH (the standalone GitHub fork
#     that win11ent uses) does not support these directives -- they
#     parse-warn on initial config load and crash during reprocess.
#     Server SKUs use the FOD-installed sshd which DOES support them,
#     but keeping a single sshd_config across all NexusPlatform Windows
#     templates is more important than the directive nuance.
$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
$config = @'
# sshd_config -- NexusPlatform Windows baseline
# Managed by packer/_shared/powershell/scripts/01-nexus-identity.ps1

Port 22
AddressFamily inet
ListenAddress 0.0.0.0

# Auth
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
PermitEmptyPasswords no

AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys

# Session
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30

# Allow only our admin user
AllowUsers nexusadmin

# Subsystems (keep sftp for Ansible file module compatibility later)
Subsystem sftp sftp-server.exe
'@
Set-Content -Path $sshdConfig -Value $config -Encoding ascii

# 5. Enable + start the service
Set-Service -Name sshd -StartupType Automatic
Restart-Service -Name sshd -Force

# Also start ssh-agent (needed if we ever use host-based auth later)
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service -Name ssh-agent

Write-Host "=== 01-nexus-identity: OK (sshd=Running, authorized_keys deployed) ==="
