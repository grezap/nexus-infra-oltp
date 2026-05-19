# role-overlay-sqlserver-domain-join.tf -- Phase 0.G.7
#
# Joins all 4 SQL nodes to the `nexus.lab` AD domain + populates the
# `nexus-sql-cluster-members` AD group (created empty by security env's
# role-overlay-dc-gmsa-sqlserver.tf) with the 4 computer accounts.
#
# Mirrors the pattern from nexus-infra-vmware/terraform/envs/foundation/
# role-overlay-jumpbox-domainjoin.tf:53-144 (the existing canonical
# domain-join recipe per the Explore agent's findings):
#   1. Probe Win32_ComputerSystem.PartOfDomain (idempotent skip if joined).
#   2. Add-Computer -DomainName nexus.lab -Credential <NEXUS\nexusadmin>
#      -Force -Restart (dispatched via base64-encoded PowerShell over SSH).
#   3. Wait for the node to come back up post-restart.
#   4. From dc-nexus: Add-ADGroupMember nexus-sql-cluster-members <host>$.
#
# The nexusadmin credential is sourced from $HOME/.nexus/vault-ad-bind.json
# (foundation env's vault-ad-bind.json sidecar that holds the Vault-managed
# nexusadmin password). Same indirection as the existing jumpbox overlay.
#
# After membership is granted, the 4 computer accounts can retrieve the
# gmsa-sql-engine$ managed password via Install-ADServiceAccount (done by
# the vault-agents overlay on the next stage).

resource "null_resource" "sqlserver_domain_join" {
  count = var.enable_sqlserver_domain_join ? 1 : 0

  triggers = {
    nodes                 = jsonencode(local.sql_nodes)
    nftables_backplane_id = length(null_resource.sqlserver_nftables_backplane) > 0 ? null_resource.sqlserver_nftables_backplane[0].id : "disabled"
    ad_domain             = var.ad_domain_name
    dc_ip                 = var.ad_dc_ip
    stage_v               = var.sqlserver_domain_join_v
  }

  depends_on = [null_resource.sqlserver_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes    = ConvertFrom-Json '${jsonencode(local.sql_nodes)}' -AsHashtable
      $sshUser  = '${var.ssh_username}'
      $adDomain = '${var.ad_domain_name}'
      $dcIp     = '${var.ad_dc_ip}'
      $adBindJson = Join-Path $HOME ".nexus/vault-ad-bind.json"

      if (-not (Test-Path $adBindJson)) {
        throw "[sqlserver-domain-join] vault-ad-bind.json not found at $adBindJson -- foundation env must apply first (Vault AD integration overlay writes this sidecar)."
      }
      $adBind = Get-Content $adBindJson -Raw | ConvertFrom-Json
      $adUser = "$adDomain\\nexusadmin"
      $adPass = $adBind.nexusadmin_password
      if (-not $adPass) { throw "[sqlserver-domain-join] nexusadmin_password missing from vault-ad-bind.json" }

      # ── Per-node domain-join (parallel-safe; we run sequentially for
      #    clearer logs; ~3-5 min per node including restart).
      foreach ($entry in $nodes.GetEnumerator()) {
        $host = $entry.Key
        $ip   = $entry.Value.vmnet11
        Write-Host "[sqlserver-domain-join] joining $host ($ip) to $adDomain..."

        # Idempotency probe: PartOfDomain skip.
        $probe = ssh -o ConnectTimeout=15 -o BatchMode=yes "$sshUser@$ip" `
          "if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Write-Output 'JOINED' } else { Write-Output 'NOTJOINED' }" 2>$null
        if ($probe -match 'JOINED') {
          Write-Host "  - $host : already domain-joined (idempotent skip)"
          continue
        }

        # Base64-encoded Add-Computer payload over SSH.
        $remote = @"
`$cred = New-Object System.Management.Automation.PSCredential('$adUser', (ConvertTo-SecureString '$adPass' -AsPlainText -Force));
Add-Computer -DomainName '$adDomain' -Credential `$cred -Force -Restart -PassThru;
"@
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
        $b64   = [Convert]::ToBase64String($bytes)
        ssh -o ConnectTimeout=30 -o BatchMode=yes "$sshUser@$ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String | Write-Host

        # Wait for the node to come back after the auto-restart triggered
        # by Add-Computer. WSFC-style fleets wait ~3-4 min for a Windows
        # restart cycle (BIOS POST + Windows boot + domain credentials cache).
        Write-Host "  - $host : waiting for SSH back post-restart..."
        $deadline = (Get-Date).AddMinutes(8)
        while ((Get-Date) -lt $deadline) {
          $back = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$sshUser@$ip" "echo PONG" 2>$null
          if ($back -match 'PONG') {
            Write-Host "  - $host : back online; verifying domain status..."
            $verify = ssh -o ConnectTimeout=10 "$sshUser@$ip" `
              "(Get-CimInstance Win32_ComputerSystem).Domain" 2>$null
            if ($verify -match '^nexus\.lab$') {
              Write-Host "  - $host : domain=$verify (joined OK)"
              break
            }
          }
          Start-Sleep -Seconds 15
        }
        if ((Get-Date) -ge $deadline) {
          throw "[sqlserver-domain-join] $host did not return after restart within 8 min"
        }
      }

      # ── Populate nexus-sql-cluster-members AD group from dc-nexus.
      Write-Host "[sqlserver-domain-join] adding 4 computer accounts to nexus-sql-cluster-members on $dcIp..."
      $hostnames = ($nodes.Keys | ForEach-Object { "'$_$'" }) -join ','
      $remoteAd = @"
Import-Module ActiveDirectory;
`$members = @($hostnames);
foreach (`$m in `$members) {
  try {
    Add-ADGroupMember -Identity 'nexus-sql-cluster-members' -Members `$m -ErrorAction Stop;
    Write-Output ('ADDED: ' + `$m);
  } catch [Microsoft.ActiveDirectory.Management.ADException] {
    if (`$_.Exception.Message -match 'already a member') {
      Write-Output ('SKIP: ' + `$m + ' (already member; idempotent)');
    } else { throw }
  }
}
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remoteAd)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 "$sshUser@$dcIp" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($LASTEXITCODE -ne 0) { throw "[sqlserver-domain-join] AD group population failed (rc=$LASTEXITCODE)" }

      Write-Host "[sqlserver-domain-join] all 4 nodes joined nexus.lab + added to nexus-sql-cluster-members"
    PWSH
  }
}
