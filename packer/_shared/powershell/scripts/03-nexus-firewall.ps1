# 03-nexus-firewall.ps1  --  Windows analog of _shared/ansible/roles/nexus_firewall
#
# Parallel to the nftables baseline on Linux:
#   - Default inbound DENY (all profiles)
#   - Allow SSH/22 from VMnet11 (192.168.70.0/24)
#   - Allow windows_exporter/9182 from VMnet11
#   - Allow RDP/3389 from VMnet11 (Windows-only -- Linux templates don't have RDP)
#   - Outbound allowed (so updates + windows_exporter -> Prometheus work)
#
# WinRM port 5985 (build-time plaintext) is NOT opened here -- the listener
# rule created by bootstrap-winrm.ps1 is scoped 'Any' for the build only,
# and 99-sysprep.ps1 removes it before generalize.

$ErrorActionPreference = 'Stop'
$vmnet11 = '192.168.70.0/24'

Write-Host "=== 03-nexus-firewall: baseline + VMnet11 allowlist ==="

# -- 1. Set default-deny inbound on every profile --------------------------
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -DefaultInboundAction Block `
    -DefaultOutboundAction Allow `
    -Enabled True `
    -LogAllowed False `
    -LogBlocked True `
    -LogFileName '%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log'

# -- 2. Disable the sprawl of stock inbound rules we don't want ------------
# Windows Server ships with a lot of "Allow from Any" rules for features we
# don't use (File & Printer Sharing over SMB-in from Any, etc). Rather than
# enumerate every one, we just trust DefaultInboundAction=Block and add our
# own allow rules below -- unmatched traffic dies at the policy default.
# The pre-shipped rules are still *present* (for possible future use) but
# they don't open anything beyond the default-block because the profile
# default wins when no explicit allow rule matches. Leave them be.

# -- 3. Explicit allow rules scoped to VMnet11 -----------------------------
$rules = @(
    @{ Name='Nexus-SSH-In';              DisplayName='Nexus SSH (22) from VMnet11';              Port=22;   Protocol='TCP' },
    @{ Name='Nexus-WindowsExporter-In';  DisplayName='Nexus windows_exporter (9182) from VMnet11'; Port=9182; Protocol='TCP' },
    @{ Name='Nexus-RDP-In';              DisplayName='Nexus RDP (3389) from VMnet11';             Port=3389; Protocol='TCP' }
)

foreach ($r in $rules) {
    # Remove any same-name rule first so re-running this script is idempotent.
    Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -Name $r.Name `
        -DisplayName $r.DisplayName `
        -Direction Inbound `
        -Action Allow `
        -Protocol $r.Protocol `
        -LocalPort $r.Port `
        -RemoteAddress $vmnet11 `
        -Profile Domain,Public,Private `
        -Enabled True | Out-Null
    Write-Host "  + $($r.Name) $($r.Protocol)/$($r.Port) from $vmnet11"
}

# -- 4. ICMPv4 Echo (ping) from VMnet11 -- makes host-side "is it up yet?"
#    probes work during Terraform smoke without opening ping to the world.
Remove-NetFirewallRule -Name 'Nexus-ICMPv4-In' -ErrorAction SilentlyContinue
New-NetFirewallRule `
    -Name 'Nexus-ICMPv4-In' `
    -DisplayName 'Nexus ICMPv4 Echo from VMnet11' `
    -Direction Inbound `
    -Action Allow `
    -Protocol ICMPv4 `
    -IcmpType 8 `
    -RemoteAddress $vmnet11 `
    -Profile Domain,Public,Private `
    -Enabled True | Out-Null

Write-Host "=== 03-nexus-firewall: OK ==="
