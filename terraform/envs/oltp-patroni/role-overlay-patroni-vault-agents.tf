/*
 * role-overlay-patroni-vault-agents.tf -- Phase 0.G.4
 *
 * Installs Vault Agent as a `nexus-vault-agent` systemd service on each of
 * the 8 patroni-tier clones (3 Patroni + 3 etcd + 2 HAProxy HA pair). Direct
 * port of role-overlay-percona-vault-agents.tf with 8 hosts instead of 5 +
 * patroni-specific sidecar prefix (`oltp-patroni-`).
 *
 * Cross-env coupling: reads the per-host AppRole JSON sidecars at
 * $HOME/.nexus/vault-agent-oltp-patroni-<host>.json (written by
 * nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-
 * patroni-approles.tf). ERROR (not WARN+skip) if absent.
 *
 * Per-host resource (for_each over a filtered map) so each agent is
 * independently `-target`-able.
 *
 * Vault Agent config: directory mode (`-config=/etc/vault-agent/`) merges
 * all *.hcl at startup. This file writes 00-base.hcl (auto_auth approle +
 * sink + vault address). role-overlay-patroni-tls.tf drops the PKI template
 * stanza as 70-template-patroni-tls.hcl + role-specific KV template stanzas
 * (71-* / 72-* / 73-* / 74-*) without rewriting this file.
 *
 * Selective ops: var.enable_patroni_vault_agents (master) AND per-host
 *                var.enable_<host>_vault_agent.
 */

locals {
  patroni_vault_agent_specs = {
    "pg-primary"   = { vm_ip = "192.168.70.61", enabled = var.enable_pg_primary_vault_agent }
    "pg-replica-1" = { vm_ip = "192.168.70.62", enabled = var.enable_pg_replica_1_vault_agent }
    "pg-replica-2" = { vm_ip = "192.168.70.63", enabled = var.enable_pg_replica_2_vault_agent }
    "etcd-1"       = { vm_ip = "192.168.70.64", enabled = var.enable_etcd_1_vault_agent }
    "etcd-2"       = { vm_ip = "192.168.70.65", enabled = var.enable_etcd_2_vault_agent }
    "etcd-3"       = { vm_ip = "192.168.70.66", enabled = var.enable_etcd_3_vault_agent }
    "haproxy-pg-1" = { vm_ip = "192.168.70.67", enabled = var.enable_haproxy_pg_1_vault_agent }
    "haproxy-pg-2" = { vm_ip = "192.168.70.68", enabled = var.enable_haproxy_pg_2_vault_agent }
  }

  patroni_vault_agent_active = {
    for host, spec in local.patroni_vault_agent_specs : host => spec
    if var.enable_patroni_vault_agents && spec.enabled
  }

  patroni_va_creds_dir_expanded = pathexpand(replace(var.vault_agent_patroni_creds_dir, "$HOME", "~"))
  patroni_va_ca_bundle_expanded = pathexpand(replace(var.vault_pki_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "patroni_vault_agent" {
  for_each = local.patroni_vault_agent_active

  triggers = {
    creds_file_path      = "${local.patroni_va_creds_dir_expanded}/vault-agent-oltp-patroni-${each.key}.json"
    creds_file_hash      = filesha256("${local.patroni_va_creds_dir_expanded}/vault-agent-oltp-patroni-${each.key}.json")
    nftables_id          = length(null_resource.patroni_nftables_backplane) > 0 ? null_resource.patroni_nftables_backplane[0].id : "disabled"
    vault_version        = var.vault_agent_version
    patroni_va_overlay_v = "2" # v2 (0.G.4) = initial 8 nodes (3 patroni + 3 etcd + 2 haproxy HA pair). v1 was the abandoned single-HAProxy variant superseded mid-scaffold.

    destroy_vm_ip    = each.value.vm_ip
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.patroni_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName     = '${each.key}'
      $vmIp         = '${each.value.vm_ip}'
      $vaultVersion = '${var.vault_agent_version}'
      $credsFile    = '${local.patroni_va_creds_dir_expanded}/vault-agent-oltp-patroni-${each.key}.json'
      $caBundlePath = '${local.patroni_va_ca_bundle_expanded}'
      $sshUser      = '${var.oltp_node_user}'
      $bootTimeout  = ${var.oltp_cluster_timeout_minutes}

      if (-not (Test-Path $credsFile)) {
        throw "[patroni-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 8 patroni AppRole sidecars."
      }
      $creds     = Get-Content $credsFile | ConvertFrom-Json
      $roleId    = $creds.role_id
      $secretId  = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) {
        throw "[patroni-va $hostName] creds JSON missing role_id or secret_id"
      }
      if (-not (Test-Path $caBundlePath)) {
        throw "[patroni-va $hostName] CA bundle $caBundlePath missing -- run security env apply (PKI distribute) first."
      }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[patroni-va $hostName] waiting for SSH + firstboot marker..."
      $bootDeadline = (Get-Date).AddMinutes($bootTimeout)
      $booted = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $booted = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $booted) { throw "[patroni-va $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[patroni-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[patroni-va $hostName] installing Vault Agent v$vaultVersion"

      $installScript = @"
set -euo pipefail
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "[patroni-va install] /etc/resolv.conf missing resolver; pointing at nexus-gateway dnsmasq"
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi

if [ -x /usr/local/bin/vault ] && /usr/local/bin/vault version 2>/dev/null | grep -qF "Vault v$vaultVersion"; then
  echo "vault binary v$vaultVersion already installed"
else
  cd /tmp
  zip="vault_$${vaultVersion}_linux_amd64.zip"
  sums="vault_$${vaultVersion}_SHA256SUMS"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$zip"  -o "`$zip"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$sums" -o "`$sums"
  grep "`$zip" "`$sums" | sha256sum -c -
  unzip -o "`$zip"
  sudo install -m 755 -o root -g root vault /usr/local/bin/vault
  rm -f "`$zip" "`$sums" vault
  echo "vault binary v$vaultVersion installed"
fi

sudo mkdir -p /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent
sudo chown root:root /etc/vault-agent
sudo chmod 0755 /etc/vault-agent
"@
      $installB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($installScript))
      $installOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$installB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $installOut.Trim()
        throw "[patroni-va $hostName] vault binary install failed (rc=$LASTEXITCODE)"
      }
      Write-Host $installOut.Trim()

      $roleIdTmp   = New-TemporaryFile
      $secretIdTmp = New-TemporaryFile
      try {
        [System.IO.File]::WriteAllText($roleIdTmp.FullName, $roleId)
        [System.IO.File]::WriteAllText($secretIdTmp.FullName, $secretId)

        scp @sshOpts $roleIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/role-id"
        scp @sshOpts $secretIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/secret-id"
        scp @sshOpts $caBundlePath "$${sshUser}@$${vmIp}:/tmp/ca-bundle.crt"

        $stageScript = @"
set -euo pipefail
sudo install -m 0400 -o root -g root /tmp/role-id      /etc/vault-agent/role-id
sudo install -m 0400 -o root -g root /tmp/secret-id    /etc/vault-agent/secret-id
sudo install -m 0644 -o root -g root /tmp/ca-bundle.crt /etc/vault-agent/ca-bundle.crt
sudo rm -f /tmp/role-id /tmp/secret-id /tmp/ca-bundle.crt
"@
        $stageB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stageScript))
        $stageOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stageOut.Trim()
          throw "[patroni-va $hostName] credential staging failed (rc=$LASTEXITCODE)"
        }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      $baseConfig = @"
# 00-base.hcl -- Phase 0.G.4. auto_auth (approle) + sink + vault address.
# role-overlay-patroni-tls.tf drops 70-template-patroni-tls.hcl + KV template
# stanzas (71-* through 74-*; the count depends on role) in this dir.

pid_file = "/var/run/nexus-vault-agent/agent.pid"

vault {
  address = "$vaultAddr"
  ca_cert = "/etc/vault-agent/ca-bundle.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/var/run/nexus-vault-agent/token"
      mode = 0640
    }
  }
}
"@

      $unitFile = @"
[Unit]
Description=Nexus Vault Agent (Phase 0.G.4 -- Patroni + etcd + HAProxy mTLS + cluster creds)
Documentation=https://developer.hashicorp.com/vault/docs/agent
Requires=network-online.target
After=network-online.target oltp-node-firstboot.service
ConditionFileIsExecutable=/usr/local/bin/vault
StartLimitBurst=15
StartLimitIntervalSec=600

[Service]
Type=simple
User=root
Group=root
RuntimeDirectory=nexus-vault-agent
RuntimeDirectoryMode=0755
LogsDirectory=nexus-vault-agent
LogsDirectoryMode=0755
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/
ExecReload=/bin/kill -HUP `$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/nexus-vault-agent/agent.log
StandardError=append:/var/log/nexus-vault-agent/agent.log

[Install]
WantedBy=multi-user.target
"@

      $configB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($baseConfig))
      $unitB64   = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($unitFile))

      $finalScript = @"
set -euo pipefail
echo '$configB64' | base64 -d | sudo tee /etc/vault-agent/00-base.hcl > /dev/null
sudo chown root:root /etc/vault-agent/00-base.hcl
sudo chmod 0644 /etc/vault-agent/00-base.hcl

echo '$unitB64' | base64 -d | sudo tee /etc/systemd/system/nexus-vault-agent.service > /dev/null
sudo chown root:root /etc/systemd/system/nexus-vault-agent.service
sudo chmod 0644 /etc/systemd/system/nexus-vault-agent.service

sudo systemctl daemon-reload
sudo systemctl enable --now nexus-vault-agent.service
"@
      $finalB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($finalScript))
      $finalOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$finalB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $finalOut.Trim()
        throw "[patroni-va $hostName] config/service setup failed (rc=$LASTEXITCODE)"
      }
      Write-Host $finalOut.Trim()

      Start-Sleep -Seconds 5
      $verifyDeadline = (Get-Date).AddSeconds(30)
      $serviceActive = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active nexus-vault-agent.service" 2>&1 | Out-String).Trim()
        if ($status -eq 'active') { $serviceActive = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $serviceActive) {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[patroni-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      Write-Host "[patroni-va $hostName] nexus-vault-agent.service active"

      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[patroni-va $hostName] AppRole login appears to have failed (token sink empty)"
      }
      Write-Host "[patroni-va $hostName] AppRole authenticated; token sink populated"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[patroni-va destroy] $${hostName}: stopping nexus-vault-agent + cleaning install-owned files (keeping /etc/vault-agent/ + TLS/KV templates)"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -f /etc/vault-agent/00-base.hcl /etc/vault-agent/role-id /etc/vault-agent/secret-id /etc/vault-agent/ca-bundle.crt /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}
