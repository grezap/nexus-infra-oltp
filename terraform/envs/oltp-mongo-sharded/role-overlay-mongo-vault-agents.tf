/*
 * role-overlay-mongo-vault-agents.tf -- Phase 0.N.1
 *
 * Installs Vault Agent as a `nexus-vault-agent` systemd service on each of
 * the 11 sharded-mongo clones (3 config-server + 6 shardsvr + 2 mongos).
 * Copy-adapted from oltp-mongo/role-overlay-mongo-vault-agents.tf with 11
 * hosts (keyed by hostname from local.sharded_nodes_active) instead of 3 +
 * a sharded-specific sidecar prefix.
 *
 * Cross-env coupling: reads the per-host AppRole JSON sidecars at
 * $HOME/.nexus/vault-agent-oltp-mongo-sharded-<host>.json (written by
 * nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-
 * mongo-sharded-approles.tf). ERROR (not WARN+skip) if absent.
 *
 * Per-host resource (for_each over local.sharded_nodes_active) so each agent
 * is independently `-target`-able.
 *
 * Vault Agent config: directory mode (`-config=/etc/vault-agent/`) merges
 * all *.hcl at startup. This file writes 00-base.hcl (auto_auth approle +
 * sink + vault address). role-overlay-mongo-tls.tf drops the PKI template
 * stanza as 70-template-mongo-tls.hcl without rewriting this file (the
 * replica-set keyFile is distributed separately by role-overlay-mongo-
 * keyfile.tf, build-host scp).
 *
 * Selective ops: var.enable_mongo_vault_agents (master). The per-VM enable
 * toggles are already honored by local.sharded_nodes_active (main.tf).
 *
 * Reachability invariant: Vault Agent runs as root, binds no network ports
 * (sink "file" only). No firewall changes.
 */

locals {
  # Terraform pathexpand() only handles `~`, NOT `$HOME`. Substitute first.
  mongo_sharded_va_creds_dir_expanded = pathexpand(replace(var.vault_agent_mongo_sharded_creds_dir, "$HOME", "~"))
  mongo_sharded_va_ca_bundle_expanded = pathexpand(replace(var.vault_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "mongo_sharded_vault_agent" {
  for_each = var.enable_mongo_vault_agents ? local.sharded_nodes_active : {}

  triggers = {
    creds_file_path    = "${local.mongo_sharded_va_creds_dir_expanded}/vault-agent-oltp-mongo-sharded-${each.key}.json"
    creds_file_hash    = filesha256("${local.mongo_sharded_va_creds_dir_expanded}/vault-agent-oltp-mongo-sharded-${each.key}.json")
    nftables_id        = var.enable_nftables_backplane ? null_resource.mongo_nftables[each.key].id : "disabled"
    vault_version      = var.vault_agent_version
    mongo_va_overlay_v = "1" # v1 (0.N.1) = initial 11-node sharded-mongo mTLS.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.mongo_nftables]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName     = '${each.key}'
      $vmIp         = '${each.value.vmnet11}'
      $vaultVersion = '${var.vault_agent_version}'
      $credsFile    = '${local.mongo_sharded_va_creds_dir_expanded}/vault-agent-oltp-mongo-sharded-${each.key}.json'
      $caBundlePath = '${local.mongo_sharded_va_ca_bundle_expanded}'
      $sshUser      = '${var.oltp_node_user}'
      $bootTimeout  = ${var.oltp_cluster_timeout_minutes}

      if (-not (Test-Path $credsFile)) {
        throw "[mongo-sharded-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 11 sharded-mongo AppRole sidecars."
      }
      $creds     = Get-Content $credsFile | ConvertFrom-Json
      $roleId    = $creds.role_id
      $secretId  = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) {
        throw "[mongo-sharded-va $hostName] creds JSON missing role_id or secret_id"
      }
      if (-not (Test-Path $caBundlePath)) {
        throw "[mongo-sharded-va $hostName] CA bundle $caBundlePath missing -- run security env apply (PKI distribute) first."
      }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[mongo-sharded-va $hostName] waiting for SSH + firstboot marker..."
      $bootDeadline = (Get-Date).AddMinutes($bootTimeout)
      $booted = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $booted = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $booted) { throw "[mongo-sharded-va $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[mongo-sharded-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[mongo-sharded-va $hostName] installing Vault Agent v$vaultVersion"

      $installScript = @"
set -euo pipefail
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "[mongo-sharded-va install] /etc/resolv.conf missing resolver; pointing at nexus-gateway dnsmasq"
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
        throw "[mongo-sharded-va $hostName] vault binary install failed (rc=$LASTEXITCODE)"
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
          throw "[mongo-sharded-va $hostName] credential staging failed (rc=$LASTEXITCODE)"
        }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      $baseConfig = @"
# 00-base.hcl -- Phase 0.N.1. auto_auth (approle) + sink + vault address.
# role-overlay-mongo-tls.tf drops 70-template-mongo-tls.hcl in this dir to
# add the PKI cert template stanza without rewriting this file (the replica-
# set keyFile is distributed separately by role-overlay-mongo-keyfile.tf).

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
Description=Nexus Vault Agent (Phase 0.N.1 -- sharded MongoDB mTLS)
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
        throw "[mongo-sharded-va $hostName] config/service setup failed (rc=$LASTEXITCODE)"
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
        throw "[mongo-sharded-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      Write-Host "[mongo-sharded-va $hostName] nexus-vault-agent.service active"

      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[mongo-sharded-va $hostName] AppRole login appears to have failed (token sink empty)"
      }
      Write-Host "[mongo-sharded-va $hostName] AppRole authenticated; token sink populated"
    PWSH
  }

  # Surgical destroy: removes install-owned files only. The TLS template
  # (dropped by role-overlay-mongo-tls.tf) survives an agent re-install
  # (e.g. on creds_file_hash rotation).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[mongo-sharded-va destroy] $${hostName}: stopping nexus-vault-agent + cleaning install-owned files (keeping /etc/vault-agent/ + TLS templates)"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -f /etc/vault-agent/00-base.hcl /etc/vault-agent/role-id /etc/vault-agent/secret-id /etc/vault-agent/ca-bundle.crt /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}
