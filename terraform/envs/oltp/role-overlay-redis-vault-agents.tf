/*
 * role-overlay-redis-vault-agents.tf -- Phase 0.G.1
 *
 * Installs Vault Agent as a `nexus-vault-agent` systemd service on each of
 * the 6 redis-node clones. Linear port of nexus-infra-kafka's
 * role-overlay-kafka-vault-agents.tf shape, with two divergences:
 *
 *   1. Sidecar filename uses the `vault-agent-oltp-redis-<host>.json` prefix
 *      (vs kafka's bare `vault-agent-<host>.json`) -- namespaces per tier+
 *      cluster so future 0.G.* oltp clusters share $HOME/.nexus without
 *      collisions. See nexus-infra-vmware/terraform/envs/security/
 *      role-overlay-vault-agent-redis-approles.tf for the producer side.
 *
 *   2. firstboot marker is `/var/lib/oltp-node-firstboot-done` (vs kafka's
 *      `/var/lib/kafka-node-firstboot-done`). Marker is written by the
 *      oltp-node Packer template's firstboot script in 3d.
 *
 * Each agent authenticates to vault-1 via its narrow AppRole (provisioned by
 * nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-redis-
 * approles.tf, which writes per-host JSON sidecars).
 *
 * Cross-env coupling: reads the AppRole creds JSON sidecars. ERROR (not
 * WARN+skip) if absent -- a silent skip leaves terraform thinking the agent
 * was installed when it wasn't. Operator order:
 *   1. nexus-infra-vmware: pwsh -File scripts/security.ps1 apply
 *      (creates the 6 redis sidecars + the redis-server PKI role)
 *   2. nexus-infra-oltp:   pwsh -File scripts/oltp.ps1 apply
 *
 * Per-host resource (for_each over a filtered map) so each agent is
 * independently `-target`-able for iteration.
 *
 * Vault Agent config: directory mode (`-config=/etc/vault-agent/`) merges
 * all *.hcl at startup. This file writes 00-base.hcl (auto_auth approle +
 * sink + vault address). role-overlay-redis-tls.tf drops the PKI template
 * stanza as 60-template-redis-tls.hcl without rewriting the base.
 *
 * Selective ops: var.enable_redis_vault_agents (master) AND per-host
 *                var.enable_redis_<n>_vault_agent.
 *
 * Reachability invariant: Vault Agent runs as root, binds no network ports
 * (sink "file" only). No firewall changes. SSH from the build host
 * unaffected (per memory/feedback_lab_host_reachability.md).
 */

locals {
  # One spec per redis-node Vault Agent. Single 6-node cluster (vs kafka's
  # east/west split) -- no per-cluster axis.
  redis_vault_agent_specs = {
    "redis-1" = { vm_ip = "192.168.70.81", enabled = var.enable_redis_1_vault_agent }
    "redis-2" = { vm_ip = "192.168.70.82", enabled = var.enable_redis_2_vault_agent }
    "redis-3" = { vm_ip = "192.168.70.83", enabled = var.enable_redis_3_vault_agent }
    "redis-4" = { vm_ip = "192.168.70.84", enabled = var.enable_redis_4_vault_agent }
    "redis-5" = { vm_ip = "192.168.70.87", enabled = var.enable_redis_5_vault_agent }
    "redis-6" = { vm_ip = "192.168.70.89", enabled = var.enable_redis_6_vault_agent }
  }

  redis_vault_agent_active = {
    for host, spec in local.redis_vault_agent_specs : host => spec
    if var.enable_redis && var.enable_redis_vault_agents && spec.enabled
  }

  # Terraform's pathexpand() only handles `~`, NOT `$HOME`. Variable defaults
  # are `$HOME/.nexus/...` (matches the PowerShell-side convention used by
  # nexus-infra-vmware security overlays), so substitute $HOME -> ~ before
  # expansion.
  redis_va_creds_dir_expanded = pathexpand(replace(var.vault_agent_redis_creds_dir, "$HOME", "~"))
  redis_va_ca_bundle_expanded = pathexpand(replace(var.vault_pki_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "redis_vault_agent" {
  for_each = local.redis_vault_agent_active

  triggers = {
    creds_file_path = "${local.redis_va_creds_dir_expanded}/vault-agent-oltp-redis-${each.key}.json"
    # Re-run when the security env rotates the secret-id (every apply does).
    creds_file_hash = filesha256("${local.redis_va_creds_dir_expanded}/vault-agent-oltp-redis-${each.key}.json")
    # Chain after the nftables overlay so the network is sane before we
    # install the agent.
    nftables_id        = length(null_resource.oltp_nftables_backplane) > 0 ? null_resource.oltp_nftables_backplane[0].id : "disabled"
    vault_version      = var.vault_agent_version
    redis_va_overlay_v = "1" # v1 (0.G.1) = original. Systemd unit ships with RuntimeDirectory=nexus-vault-agent (per memory/feedback_systemd_runtime_directory_tmpfs.md).

    # Frozen for the destroy provisioner -- terraform restricts destroy
    # provisioners to `self`, `count.index`, `each.key`.
    destroy_vm_ip    = each.value.vm_ip
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.oltp_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName     = '${each.key}'
      $vmIp         = '${each.value.vm_ip}'
      $vaultVersion = '${var.vault_agent_version}'
      $credsFile    = '${local.redis_va_creds_dir_expanded}/vault-agent-oltp-redis-${each.key}.json'
      $caBundlePath = '${local.redis_va_ca_bundle_expanded}'
      $sshUser      = '${var.oltp_node_user}'
      $bootTimeout  = ${var.oltp_cluster_timeout_minutes}

      # Pre-flight: AppRole creds JSON must exist (security env writes it).
      # ERROR (not WARN+skip) -- matches the 0.E.2 v2 + 0.H.2 lesson.
      if (-not (Test-Path $credsFile)) {
        throw "[redis-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 6 redis AppRole sidecars."
      }
      $creds     = Get-Content $credsFile | ConvertFrom-Json
      $roleId    = $creds.role_id
      $secretId  = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) {
        throw "[redis-va $hostName] creds JSON missing role_id or secret_id"
      }

      # Pre-flight: CA bundle must exist (PKI root distributed to build host
      # at 0.D.2). The Vault Agent uses it to verify the vault server cert.
      if (-not (Test-Path $caBundlePath)) {
        throw "[redis-va $hostName] CA bundle $caBundlePath missing -- run security env apply (PKI distribute) first."
      }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Wait for SSH + the oltp-node firstboot marker.
      Write-Host "[redis-va $hostName] waiting for SSH + firstboot marker..."
      $bootDeadline = (Get-Date).AddMinutes($bootTimeout)
      $booted = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -f /var/lib/oltp-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $booted = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $booted) { throw "[redis-va $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

      # Step 1: probe -- already installed + active?
      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[redis-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[redis-va $hostName] installing Vault Agent v$vaultVersion"

      # Step 2: install vault binary (skip if already at expected version).
      $installScript = @"
set -euo pipefail

# Step 2.0: ensure DNS resolution works before any outbound HTTP. The deb13
# baseline can land with an empty /etc/resolv.conf on fresh clones (per
# memory/feedback_deb13_baseline_dns_resolver.md). nexus-gateway's dnsmasq
# is the canonical lab resolver at 192.168.70.1.
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "[redis-va install] /etc/resolv.conf has no working resolver; pointing at nexus-gateway dnsmasq"
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

# Step 3: directories + ownership. Agent runs as root; redis runs as the
# redis user. role-overlay-redis-tls.tf creates /etc/nexus-redis/tls/ later
# with redis-readable perms (0750 root:redis).
sudo mkdir -p /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent
sudo chown root:root /etc/vault-agent
sudo chmod 0755 /etc/vault-agent
"@
      $installB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($installScript))
      $installOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$installB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $installOut.Trim()
        throw "[redis-va $hostName] vault binary install failed (rc=$LASTEXITCODE)"
      }
      Write-Host $installOut.Trim()

      # Step 4: stage role-id + secret-id + CA bundle
      $roleIdTmp   = New-TemporaryFile
      $secretIdTmp = New-TemporaryFile
      try {
        # Write the credentials WITHOUT a trailing newline -- Vault Agent reads
        # the entire file content as the credential value; a trailing newline
        # becomes part of the role-id/secret-id and breaks AppRole auth.
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
          throw "[redis-va $hostName] credential staging failed (rc=$LASTEXITCODE)"
        }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      # Step 5: write 00-base.hcl + nexus-vault-agent.service
      $baseConfig = @"
# 00-base.hcl -- Phase 0.G.1. auto_auth (approle) + sink + vault address.
# role-overlay-redis-tls.tf drops 60-template-redis-tls.hcl in this dir to
# add the PKI cert template stanza without rewriting this file.

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
Description=Nexus Vault Agent (Phase 0.G.1 -- Redis Cluster mTLS)
Documentation=https://developer.hashicorp.com/vault/docs/agent
Requires=network-online.target
After=network-online.target oltp-node-firstboot.service
ConditionFileIsExecutable=/usr/local/bin/vault

[Service]
Type=simple
User=root
Group=root
# RuntimeDirectory= -- systemd auto-creates /run/nexus-vault-agent on every
# service start (per memory/feedback_systemd_runtime_directory_tmpfs.md;
# /var/run is tmpfs and an install-time mkdir does not survive reboot).
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
        throw "[redis-va $hostName] config/service setup failed (rc=$LASTEXITCODE)"
      }
      Write-Host $finalOut.Trim()

      # Step 6: verify service active + token sink populated
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
        throw "[redis-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      Write-Host "[redis-va $hostName] nexus-vault-agent.service active"

      # Token sink populated? (proves AppRole auth succeeded)
      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[redis-va $hostName] AppRole login appears to have failed (token sink empty)"
      }
      Write-Host "[redis-va $hostName] AppRole authenticated; token sink populated"
    PWSH
  }

  # Destroy: stop + disable + remove the agent. SURGICAL -- removes only the
  # files THIS overlay installs (00-base.hcl + role-id/secret-id/ca-bundle +
  # the systemd unit). It deliberately does NOT `rm -rf /etc/vault-agent/`,
  # because role-overlay-redis-tls.tf drops 60-template-redis-tls.hcl in that
  # same dir (the same surgical-destroy lesson as kafka-vault-agents).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[redis-va destroy] $${hostName}: stopping nexus-vault-agent + cleaning install-owned files (keeping /etc/vault-agent/ + TLS template)"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -f /etc/vault-agent/00-base.hcl /etc/vault-agent/role-id /etc/vault-agent/secret-id /etc/vault-agent/ca-bundle.crt /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}
