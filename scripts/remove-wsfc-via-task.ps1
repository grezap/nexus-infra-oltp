# One-shot: Remove-Cluster -Force -CleanupAD on sql-fci-1 via a schtasks Password-logon
# domain-task as NEXUS\nexusadmin (the cluster owner — plain SSH local nexusadmin lacks
# cluster-admin rights). Recovers a half-formed WSFC cluster left by a suspend-killed
# apply so wsfc_bootstrap can re-create it cleanly. NOT shipped (scratch-grade recovery).
$ErrorActionPreference = 'Stop'
$ip = '192.168.70.11'
$key = "$HOME/.ssh/nexus_gateway_ed25519"
$sshUser = 'nexusadmin'
$cred = Get-Content "$HOME/.nexus/nexusadmin-credentials.json" -Raw | ConvertFrom-Json
$nb = if ($cred.PSObject.Properties['netbios']) { $cred.netbios } else { 'NEXUS' }
$adUser = "$nb\$($cred.username)"; $adPass = $cred.password
$tag = 'rmwsfc'
$logFile = "C:/Windows/Temp/$tag.log"

$orchestrate = @"
`$ErrorActionPreference='Continue';
Start-Transcript -Path '$logFile' -Force | Out-Null;
try { Remove-Cluster -Force -CleanupAD -EA Stop; Write-Output 'RM_OK' }
catch { Write-Output ('RM_ERR ' + `$_.Exception.Message) }
Stop-Transcript | Out-Null;
"@
$wrapper = @"
`$ErrorActionPreference='Continue';
`$sp='C:/Windows/Temp/$tag-o.ps1'; `$lp='$logFile';
Remove-Item `$lp,`$sp -EA SilentlyContinue;
@'
$orchestrate
'@ | Set-Content -Path `$sp -Encoding UTF8;
try { schtasks /Delete /TN $tag /F 2>&1 | Out-Null } catch {};
schtasks /Create /TN $tag /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$sp" /SC ONCE /ST 23:59 /RU '$adUser' /RP '$adPass' /RL HIGHEST /F | Out-Null;
schtasks /Run /TN $tag | Out-Null;
`$dl=(Get-Date).AddMinutes(4);
do { Start-Sleep -Seconds 5; if (Test-Path `$lp) { if ((Get-Content `$lp -Raw -EA SilentlyContinue) -match 'transcript end') { break } } } while ((Get-Date) -lt `$dl);
if (Test-Path `$lp) { Get-Content `$lp -Raw }
try { schtasks /Delete /TN $tag /F 2>&1 | Out-Null } catch {};
Remove-Item `$sp -EA SilentlyContinue;
"@
$tmp = Join-Path $env:TEMP "$tag-w.ps1"
$wrapper | Out-File -FilePath $tmp -Encoding UTF8 -Force
$rs = "C:/Windows/Temp/nexus-$tag-w.ps1"
& scp -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no -i $key $tmp "$sshUser@${ip}:$rs" 2>&1 | Out-Null
Remove-Item $tmp -EA SilentlyContinue
$out = & ssh -o ConnectTimeout=120 -o BatchMode=yes -o StrictHostKeyChecking=no -i $key "$sshUser@$ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $rs" 2>&1 | Out-String
& ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i $key "$sshUser@$ip" "Remove-Item -Path '$rs' -EA SilentlyContinue" 2>&1 | Out-Null
($out -split "`n" | Where-Object { $_ -match 'RM_OK|RM_ERR' }) -join "`n"
