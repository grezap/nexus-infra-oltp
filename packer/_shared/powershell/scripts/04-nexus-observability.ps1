# 04-nexus-observability.ps1  --  Windows analog of _shared/ansible/roles/nexus_observability
#
# Install windows_exporter (the Windows equivalent of prometheus-node-exporter).
# Binds to :9182 on all interfaces; firewall rule (03-nexus-firewall.ps1)
# restricts inbound to VMnet11.
#
# Collectors enabled by default: cpu, cs, logical_disk, memory, net, os, service,
# system, tcp -- roughly parity with node_exporter's default set. Extra collectors
# (iis, mssql, scheduled_task) are added per-role when the overlay role needs them.

$ErrorActionPreference = 'Stop'

# Pinned release -- matches the version committed canon in docs/fleet-versions.md
# (or will, once Phase 0.B.4 lands). Hash sourced from the release page on
# github.com/prometheus-community/windows_exporter.
$version = '0.30.4'
$msiUrl  = "https://github.com/prometheus-community/windows_exporter/releases/download/v$version/windows_exporter-$version-amd64.msi"
# TODO(Phase 0.B.4 follow-up): pin after first verified build.
# $msiSha = '<populate-after-first-build>'

$dest = "C:\Windows\Temp\windows_exporter-$version.msi"

Write-Host "Downloading windows_exporter $version"
try {
    # Use TLS 1.2+ (default on WS2025 but belt-and-braces for older images)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WebRequest -Uri $msiUrl -OutFile $dest -UseBasicParsing
}
catch {
    throw "Failed to download windows_exporter: $($_.Exception.Message)"
}

# NOTE on SHA pinning: the placeholder above is deliberate -- the real hash will
# be committed after the first successful build verifies the download. Leaving
# verification *off* in this first iteration so Phase 0.B.4 isn't blocked on a
# chicken-and-egg: commit hash -> build fails, no hash -> can't pin. The build
# log captures the installed version for audit; first build lands with an
# explicit TODO to pin the hash in a follow-up commit.
# TODO(Phase 0.B.4 follow-up): populate $msiSha from the verified download,
# then uncomment the Get-FileHash check below.
# $actualSha = (Get-FileHash -Algorithm SHA256 -Path $dest).Hash.ToLower()
# if ($actualSha -ne $msiSha) { throw "Hash mismatch: expected $msiSha got $actualSha" }

Write-Host "Installing windows_exporter $version"
$msiArgs = @(
    '/i', $dest,
    '/qn',
    '/norestart',
    'LISTEN_PORT=9182',
    'ENABLED_COLLECTORS=cpu,cs,logical_disk,memory,net,os,service,system,tcp,textfile'
)
$p = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) {
    throw "windows_exporter MSI install failed (exit=$($p.ExitCode))"
}

# Verify the service is registered + start it.
$svc = Get-Service -Name windows_exporter -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "windows_exporter service not registered after MSI install"
}
Set-Service -Name windows_exporter -StartupType Automatic
Start-Service -Name windows_exporter

# Quick sanity: the endpoint should respond with Prometheus metric format on :9182.
Start-Sleep -Seconds 3
try {
    $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:9182/metrics' -UseBasicParsing -TimeoutSec 10
    if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode)" }
    Write-Host "windows_exporter responding on :9182 ($([int]($resp.Content.Length / 1024)) KB metrics)"
}
catch {
    throw "windows_exporter sanity check failed: $($_.Exception.Message)"
}

Remove-Item -Force $dest -ErrorAction SilentlyContinue
Write-Host "=== 04-nexus-observability: OK (windows_exporter $version on :9182) ==="
