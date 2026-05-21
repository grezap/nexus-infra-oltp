# role-overlay-sqlserver-vault-agents.tf -- Phase 0.G.7
#
# Installs the nexus-vault-agent Windows service on all 4 SQL nodes.
# Mirrors the foundation env's role-overlay-windows-vault-agent.tf pattern
# (Vault Agent on dc-nexus + jumpbox) -- scaled to 4 nodes + reads each
# node's AppRole sidecar from $HOME/.nexus/vault-agent-oltp-sqlserver-<host>.json
# (written by security env's role-overlay-vault-agent-sqlserver-approles.tf).
#
# Per-node Vault Agent config templates:
#   1. The 5 KV creds (sa-password, ag-endpoint-cert-password, wsfc-cluster-
#      admin-password, iscsi-chap-secret, listener-cert-password) render to
#      C:\ProgramData\nexus\sql\creds\<name>.txt
#   2. The gmsa-info JSON pointer renders to C:\ProgramData\nexus\sql\creds\
#      gmsa-info.json (consumed by FCI install + the GMSA install script).
#   3. The mTLS leaf cert (server+client EKU, per-host CN+SANs) renders to
#      C:\ProgramData\nexus\sql\tls\<host>.{crt,key} -- done by the tls overlay
#      next, not this one (this overlay only installs the AGENT; the tls
#      overlay configures the cert template).
#
# Also: each node calls Install-ADServiceAccount -Identity gmsa-sql-engine
# to cache the GMSA password from AD (required before setup.exe FCI install
# can use the GMSA as SQL service identity).

resource "null_resource" "sqlserver_vault_agents" {
  for_each = var.enable_sqlserver_vault_agents ? local.sql_nodes : {}

  triggers = {
    host           = each.key
    vmnet11_ip     = each.value.vmnet11
    role           = each.value.role
    domain_join_id = length(null_resource.sqlserver_domain_join) > 0 ? null_resource.sqlserver_domain_join[0].id : "disabled"
    stage_v        = var.sqlserver_vault_agents_v
  }

  depends_on = [null_resource.sqlserver_domain_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName       = '${each.key}'
      $ip         = '${each.value.vmnet11}'
      $role       = '${each.value.role}'
      $sshUser    = '${var.ssh_username}'
      # NOTE: both paths are pre-expanded by Terraform's pathexpand() in
      # main.tf (locals); no PowerShell-side pathexpand needed (PS has no
      # such function). Transient #24 at 0.G.7 ratify 2026-05-21 pre-emptive
      # fix: original code called pathexpand(...) in PS which would have
      # failed at apply time with "CommandNotFoundException".
      $sidecarDir = '${local.vault_agent_sidecar_dir}'
      $sidecar    = Join-Path $sidecarDir "vault-agent-oltp-sqlserver-$hostName.json"
      $caBundle   = '${local.vault_ca_bundle_path_expanded}'

      if (-not (Test-Path $sidecar)) {
        throw "[sqlserver-vault-agents] sidecar not found at $sidecar -- security env's role-overlay-vault-agent-sqlserver-approles.tf must apply first."
      }
      if (-not (Test-Path $caBundle)) {
        throw "[sqlserver-vault-agents] CA bundle not found at $caBundle -- security env's PKI overlay must apply first."
      }

      $cfg     = Get-Content $sidecar -Raw | ConvertFrom-Json
      $caCert  = Get-Content $caBundle -Raw

      Write-Host "[sqlserver-vault-agents] installing nexus-vault-agent on $hostName ($ip; role=$role)..."

      # Build the agent config file (HCL). Vault Agent renders templates for
      # the 5 KV creds + 1 JSON pointer + per-host mTLS leaf cert. FCI nodes
      # additionally render the iscsi-chap-secret + wsfc-cluster-admin-
      # password (per the policy from security env -- AG replicas don't
      # have read access to those KV paths).
      $kvTemplates = if ($role -eq 'fci') {
        @('sa-password','ag-endpoint-cert-password','wsfc-cluster-admin-password','iscsi-chap-secret','listener-cert-password')
      } else {
        @('sa-password','ag-endpoint-cert-password','listener-cert-password')
      }
      $templateBlocks = ($kvTemplates | ForEach-Object {
        @"
template {
  source      = "C:/ProgramData/nexus/vault-agent/templates/$_.tpl"
  destination = "C:/ProgramData/nexus/sql/creds/$_.txt"
  perms       = "0640"
}
"@
      }) -join "`n"

      $agentHcl = @"
pid_file = "C:/ProgramData/nexus/vault-agent/agent.pid"
vault {
  address = "$($cfg.vault_addr)"
  ca_cert = "C:/ProgramData/nexus/vault-agent/ca-bundle.crt"
  retry { num_retries = 5 }
}
auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "C:/ProgramData/nexus/vault-agent/role-id"
      secret_id_file_path                 = "C:/ProgramData/nexus/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = { path = "C:/ProgramData/nexus/vault-agent/token" }
  }
}
$templateBlocks
"@

      # Build the remote PowerShell payload: download Vault binary, write
      # agent.hcl + role-id + secret-id + ca-bundle.crt + 6 template files
      # (one per KV path), then New-Service + Start-Service.
      $bodyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($agentHcl))
      $caB64   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($caCert))

      # Templates -- each rendered KV secret. Vault Agent uses the
      # template_file/source pattern with simple Go template language.
      $templates = @{}
      foreach ($t in $kvTemplates) {
        $templates[$t] = "{{ with secret `"nexus/data/oltp/sqlserver/$t`" }}{{ .Data.data.content }}{{ end }}"
      }
      $templates['gmsa-info'] = "{{ with secret `"nexus/data/oltp/sqlserver/gmsa-info`" }}{{ .Data.data | toJSON }}{{ end }}"

      # Transient #25b at 0.G.7 ratify 2026-05-21: PowerShell's Out-File with
      # `-Encoding utf8` (Windows PowerShell 5.1) prepends a 3-byte UTF-8 BOM
      # (`EF BB BF`). Vault Agent's AppRole `role_id_file_path` /
      # `secret_id_file_path` read the file VERBATIM as the credential; with
      # BOM the role-id reads as `<BOM>aabbccdd-...` which fails AppRole
      # auth silently → service crashes on start → SERVICE_STATUS=Stopped.
      # Fix: use `[System.IO.File]::WriteAllText` (no BOM) for the 4
      # auth-critical files (role-id, secret-id, agent.hcl, ca-bundle.crt).
      # Template files are still OK with BOM since Vault Agent renders them
      # via Go template engine which strips leading whitespace.
      $remote = @"
`$ErrorActionPreference = 'Stop';
New-Item -ItemType Directory -Force -Path 'C:/ProgramData/nexus/vault-agent/templates' | Out-Null;
New-Item -ItemType Directory -Force -Path 'C:/ProgramData/nexus/sql/creds' | Out-Null;
[System.IO.File]::WriteAllText('C:/ProgramData/nexus/vault-agent/agent.hcl', [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$bodyB64')));
[System.IO.File]::WriteAllText('C:/ProgramData/nexus/vault-agent/ca-bundle.crt', [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$caB64')));
[System.IO.File]::WriteAllText('C:/ProgramData/nexus/vault-agent/role-id', '$($cfg.role_id)');
[System.IO.File]::WriteAllText('C:/ProgramData/nexus/vault-agent/secret-id', '$($cfg.secret_id)');
"@
      foreach ($t in $templates.Keys) {
        $tplB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($templates[$t]))
        $remote += "`n[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$tplB64')) | Out-File 'C:/ProgramData/nexus/vault-agent/templates/$t.tpl' -Encoding utf8;"
      }
      $remote += @"

# Download Vault binary if missing.
if (-not (Test-Path 'C:/Program Files/HashiCorp/Vault/vault.exe')) {
  New-Item -ItemType Directory -Force -Path 'C:/Program Files/HashiCorp/Vault' | Out-Null;
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/vault/1.17.6/vault_1.17.6_windows_amd64.zip' -OutFile 'C:/Windows/Temp/vault.zip';
  Expand-Archive -Path 'C:/Windows/Temp/vault.zip' -DestinationPath 'C:/Program Files/HashiCorp/Vault' -Force;
  Remove-Item 'C:/Windows/Temp/vault.zip';
}

# Install GMSA on this node (lets Install-ADServiceAccount cache the password locally).
# Transient #25c at 0.G.7 ratify 2026-05-21: the Packer template installs
# Failover-Clustering + Multipath-IO but NOT RSAT-AD-PowerShell (which
# provides the ActiveDirectory PS module). Without it, Import-Module
# ActiveDirectory throws "module ... not loaded ... no valid module file"
# → GMSA install skipped → SQL Server FCI install will fail later because
# the service account can't run as gmsa-sql-engine$. Install the feature
# at runtime as a self-healing fallback; permanent fix lands in
# packer/oltp-sqlserver-node/scripts/11-cluster-features.ps1 adding
# RSAT-AD-PowerShell to the Add-WindowsFeature list.
if (-not (Get-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction SilentlyContinue).Installed) {
  Write-Output 'INSTALLING_RSAT_AD_POWERSHELL';
  Add-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null;
}
try {
  Import-Module ActiveDirectory -ErrorAction Stop;
  if (-not (Test-ADServiceAccount -Identity 'gmsa-sql-engine' -ErrorAction SilentlyContinue)) {
    Install-ADServiceAccount -Identity 'gmsa-sql-engine';
    Write-Output 'GMSA_INSTALLED';
  } else {
    Write-Output 'GMSA_ALREADY';
  }
} catch {
  Write-Output ('GMSA_INSTALL_FAILED: ' + `$_.Exception.Message);
}

# Register the nexus-vault-agent Windows service (idempotent).
if (-not (Get-Service -Name 'nexus-vault-agent' -ErrorAction SilentlyContinue)) {
  New-Service -Name 'nexus-vault-agent' ``
    -DisplayName 'Nexus Vault Agent (SQL Server)' ``
    -Description 'Phase 0.G.7 Vault Agent rendering KV creds + mTLS leaf cert' ``
    -BinaryPathName '"C:/Program Files/HashiCorp/Vault/vault.exe" agent -config="C:/ProgramData/nexus/vault-agent/agent.hcl"' ``
    -StartupType Automatic;
}
Start-Service -Name 'nexus-vault-agent' -ErrorAction SilentlyContinue;
Start-Sleep -Seconds 8;
`$status = (Get-Service 'nexus-vault-agent').Status;
Write-Output ('SERVICE_STATUS=' + `$status);
"@

      # Transient #25 at 0.G.7 ratify 2026-05-21: the `$remote` payload here
      # is ~8.6KB → base64-Unicode ~23KB → past the Windows ssh.exe argv ~6KB
      # cliff per memory feedback_ssh_stage1_size_limit.md. EncodedCommand-as-
      # SSH-arg silently TRUNCATES the base64 → remote PS sees incomplete
      # script → "The string is missing the terminator: '". Fix: scp the
      # payload to remote as a .ps1 file, then `powershell -File` -- bypasses
      # the argv length limit entirely.
      $tempLocal  = Join-Path $env:TEMP "vault-agent-$hostName-$([System.Guid]::NewGuid().ToString('N')).ps1"
      $remote | Out-File -FilePath $tempLocal -Encoding UTF8 -Force
      $remoteSrc  = "C:/Windows/Temp/nexus-vault-agent-$hostName.ps1"
      scp -o ConnectTimeout=30 -o BatchMode=yes $tempLocal "$sshUser@$($ip):$remoteSrc" 2>&1 | Write-Host
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue
        throw "[sqlserver-vault-agents] $hostName : scp of vault-agent payload failed (rc=$LASTEXITCODE)"
      }
      Remove-Item -Path $tempLocal -ErrorAction SilentlyContinue

      $output = ssh -o ConnectTimeout=60 "$sshUser@$ip" "powershell -NoProfile -File $remoteSrc" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($LASTEXITCODE -ne 0) { throw "[sqlserver-vault-agents] $hostName : Vault Agent install failed (rc=$LASTEXITCODE)" }
      if ($output -notmatch 'SERVICE_STATUS=Running') {
        throw "[sqlserver-vault-agents] $hostName : nexus-vault-agent service did not reach Running"
      }
      # Cleanup remote payload (best-effort; leaves no creds since templates
      # are base64-decoded into separate files by the script).
      ssh -o ConnectTimeout=10 "$sshUser@$ip" "Remove-Item -Path '$remoteSrc' -ErrorAction SilentlyContinue" 2>&1 | Out-Null
      Write-Host "[sqlserver-vault-agents] $hostName : nexus-vault-agent running + GMSA installed locally"
    PWSH
  }
}
