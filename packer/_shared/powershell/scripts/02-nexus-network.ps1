# 02-nexus-network.ps1  --  Windows analog of _shared/ansible/roles/nexus_network
#
# Linux equivalent tasks + their Windows mapping:
#   en*->nic0 (systemd .link)      -> Rename-NetAdapter on the single NIC
#   systemd-networkd DHCP          -> Windows defaults to DHCP on e1000e; no-op
#   chrony client -> 192.168.70.1   -> W32Time service peerlist
#
# The NIC rename is mostly cosmetic on Windows (adapter names aren't as
# ceremony-laden as Linux ens*/enp*), but keeping the 'nic0' label gives us
# consistent metric labels across the fleet when Prometheus + windows_exporter
# report per-interface stats.

$ErrorActionPreference = 'Stop'

# -- 1. NIC rename: whatever the single active Ethernet adapter is -> nic0 --
# @(...) wrap: empty pipeline yields $null, not a 0-length array; without @()
# $adapters.Count prints blank and the comparison misbehaves.
$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' })
if ($adapters.Count -eq 0) {
    # Fallback: relax the Physical filter -- VMware e1000e sometimes classifies
    # oddly right after a VMware Tools install + restart. Accept any Up Ethernet.
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' })
    Write-Host "Primary -Physical filter empty; relaxed fallback found $($adapters.Count) adapter(s)"
}

if ($adapters.Count -ne 1) {
    # Packer build runs with a single NAT NIC. If we see more/less, log + skip
    # instead of failing -- Terraform modules/vm/ will reassign at clone time.
    Write-Host "WARN: expected 1 active Ethernet adapter, found $($adapters.Count). Skipping rename."
}
else {
    $nic = $adapters[0]
    if ($nic.Name -ne 'nic0') {
        Write-Host "Renaming '$($nic.Name)' -> nic0"
        Rename-NetAdapter -Name $nic.Name -NewName 'nic0'
    } else {
        Write-Host "NIC already named nic0 -- skipping rename"
    }
}

# -- 2. W32Time -> chrony-equivalent client pointed at the gateway ----------
# During build we have NAT -> internet, so using the gateway IP (192.168.70.1)
# would fail (not routable from NAT). Configure W32Time with the gateway as
# the manual peer + time.windows.com fallback; the service re-syncs on the
# first post-clone boot when VMnet11 is the live NIC.
#
# Implementation note: /update requires w32time to be RUNNING (it's a SCM
# notify-reconfig call). Starting it first, not stopping it. Older pattern of
# "Stop-Service; w32tm /config /update" yields 0x80070426 ERROR_SERVICE_NOT_ACTIVE
# and leaks that exit code via $LastExitCode.

Write-Host "Configuring W32Time for runtime: gateway (192.168.70.1) primary, time.windows.com fallback"

# Ensure w32time is running so /config /update can reconfigure the live service.
Set-Service -Name w32time -StartupType Automatic
Start-Service -Name w32time -ErrorAction SilentlyContinue

# Manual peer list -- gateway first, time.windows.com as safety net.
# Swallow output but check exit code explicitly so it doesn't leak to Packer.
$null = & w32tm /config /manualpeerlist:"192.168.70.1,0x8 time.windows.com,0x9" `
    /syncfromflags:manual /reliable:no /update 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARN: w32tm /config exited $LASTEXITCODE -- template runtime will re-sync on first boot"
    # Reset so the wrapper's `exit $LastExitCode` doesn't propagate this.
    $global:LASTEXITCODE = 0
}

# -- 3. DNS -- point at the gateway's dnsmasq (192.168.70.1) ----------------
# During build the NAT DHCP supplies its own DNS, which is fine. We bake the
# gateway DNS into the NIC profile via netsh so that when the NIC is re-homed
# to VMnet11 the right resolver is used immediately. systemd-networkd does
# the same thing on the Linux templates via [Network] DNS=.
#
# Use a registry-level setting so it survives the NIC renumber at clone time.
$primaryNic = Get-NetAdapter -Name 'nic0' -ErrorAction SilentlyContinue
if ($primaryNic) {
    # Leave DHCP enabled for IP but override DNS to the gateway.
    Set-DnsClientServerAddress -InterfaceIndex $primaryNic.IfIndex `
        -ServerAddresses @('192.168.70.1') -ErrorAction SilentlyContinue
}

Write-Host "=== 02-nexus-network: OK ==="
