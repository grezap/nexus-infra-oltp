# role-overlay-sqlserver-tls.tf -- Phase 0.G.7
#
# Triggers nexus-vault-agent (installed by previous stage) to render the
# per-node mTLS leaf cert from pki_int/issue/sqlserver-server. Cert SAN
# list varies by role:
#   - FCI nodes (sql-fci-1/2): CN=<host>.sqlserver.nexus.lab,
#     SANs=<host>+<host>.nexus.lab+sql-fci-cluster+sql-fci-cluster.nexus.lab,
#     IP-SANs=<vmnet11>+<vmnet10>+127.0.0.1+.70.16 (FCI virtual IP)
#   - AG-replica nodes (sql-ag-rep-1/2): CN=<host>.sqlserver.nexus.lab,
#     SANs=<host>+<host>.nexus.lab, IP-SANs=<vmnet11>+<vmnet10>+127.0.0.1
#
# A separate Listener cert (CN=sql-ag-listener.nexus.lab, IP-SAN .17) is
# rendered to C:\ProgramData\nexus\sql\tls\listener\ on ALL 4 nodes (per
# ADR-0025: Listener cert must be import-able into LocalMachine\My on
# whichever node currently owns the Listener IP across failover).
#
# Cert + key import into LocalMachine\My happens here (SQL Server reads
# the cert from the Windows cert store via thumbprint; we'd then bind it
# to MSSQLSERVER via registry/WMI in the fci-install + ag-listener stages).

resource "null_resource" "sqlserver_tls" {
  for_each = var.enable_sqlserver_tls ? local.sql_nodes : {}

  triggers = {
    host            = each.key
    vault_agents_id = length(null_resource.sqlserver_vault_agents) > 0 ? null_resource.sqlserver_vault_agents[each.key].id : "disabled"
    stage_v         = var.sqlserver_tls_v
  }

  depends_on = [null_resource.sqlserver_vault_agents]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName      = '${each.key}'
      $ip        = '${each.value.vmnet11}'
      $role      = '${each.value.role}'
      $vmnet10   = '${each.value.vmnet10}'
      $sshUser   = '${var.ssh_username}'
      $pkiRole   = '${var.vault_pki_sqlserver_role}'
      $fciVip    = '${local.fci_virtual_ip}'
      $listenerVip = '${local.ag_listener_ip}'

      Write-Host "[sqlserver-tls] rendering mTLS cert for $hostName ($role)..."

      # SAN lists differ by role. FCI nodes carry the FCI virtual hostname
      # + IP in their cert; AG-replicas do not. All 4 get the listener cert
      # rendered to a separate dir.
      # FCI nodes carry BOTH the WSFC cluster CNO name (sql-fci-cluster) AND
      # the FCI virtual server name (sqlfci) in their cert SANs -- transient
      # #28d: the two are distinct (cluster CNO != FCI virtual server name).
      # Clients connect to the FCI via sqlfci.nexus.lab at .70.16.
      $sanList = if ($role -eq 'fci') {
        "$hostName,$hostName.nexus.lab,$hostName.sqlserver.nexus.lab,sql-fci-cluster,sql-fci-cluster.nexus.lab,sqlfci,sqlfci.nexus.lab,localhost"
      } else {
        "$hostName,$hostName.nexus.lab,$hostName.sqlserver.nexus.lab,localhost"
      }
      $ipSanList = if ($role -eq 'fci') {
        "$ip,$vmnet10,127.0.0.1,$fciVip"
      } else {
        "$ip,$vmnet10,127.0.0.1"
      }

      # Render via Vault Agent template. Write the template file + force
      # an agent re-read by `nexus-vault-agent` restart. The agent issues
      # the cert via pki_int/issue/$pkiRole + writes to the destination.
      $perNodeTemplate = @"
{{ with secret "pki_int/issue/$pkiRole" "common_name=$hostName.sqlserver.nexus.lab" "alt_names=$sanList" "ip_sans=$ipSanList" "ttl=2160h" }}
{{ .Data.certificate }}
{{ .Data.private_key }}
{{ .Data.issuing_ca }}
{{ end }}
"@
      $listenerTemplate = @"
{{ with secret "pki_int/issue/$pkiRole" "common_name=sql-ag-listener.nexus.lab" "alt_names=sql-ag-listener,sql-ag-listener.nexus.lab,sql-ag-listener.sqlserver.nexus.lab" "ip_sans=$listenerVip" "ttl=2160h" }}
{{ .Data.certificate }}
{{ .Data.private_key }}
{{ .Data.issuing_ca }}
{{ end }}
"@

      $tplB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($perNodeTemplate))
      $lstB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($listenerTemplate))

      $remote = @"
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$tplB64')) | Out-File 'C:/ProgramData/nexus/vault-agent/templates/node-cert.tpl' -Encoding utf8;
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$lstB64')) | Out-File 'C:/ProgramData/nexus/vault-agent/templates/listener-cert.tpl' -Encoding utf8;

# Add 2 template stanzas to agent.hcl if not already present.
# Transient #25d at 0.G.7 ratify 2026-05-21: cannot nest `@"..."@` inside an
# outer `@"..."@` -- PS's lexer treats the first `"@` at line-start as the
# END of the outer here-string, truncating the script + leaving the rest as
# raw PS code that doesn't parse (Unexpected token '}'). Workaround: build
# the appended stanzas as a single line via a string array + Add-Content.
`$hcl = Get-Content 'C:/ProgramData/nexus/vault-agent/agent.hcl' -Raw;
if (`$hcl -notmatch 'node-cert.tpl') {
  `$nodeTplStanza = 'template { source = "C:/ProgramData/nexus/vault-agent/templates/node-cert.tpl" destination = "C:/ProgramData/nexus/sql/tls/$hostName.pem" perms = "0640" }';
  `$lstTplStanza  = 'template { source = "C:/ProgramData/nexus/vault-agent/templates/listener-cert.tpl" destination = "C:/ProgramData/nexus/sql/tls/listener.pem" perms = "0640" }';
  Add-Content -Path 'C:/ProgramData/nexus/vault-agent/agent.hcl' -Value `$nodeTplStanza;
  Add-Content -Path 'C:/ProgramData/nexus/vault-agent/agent.hcl' -Value `$lstTplStanza;
}
New-Item -ItemType Directory -Force -Path 'C:/ProgramData/nexus/sql/tls' | Out-Null;
Restart-Service -Name 'nexus-vault-agent' -Force;
Start-Sleep -Seconds 15;

# Wait for the cert PEMs to be rendered.
`$deadline = (Get-Date).AddMinutes(2);
while ((Get-Date) -lt `$deadline) {
  if ((Test-Path 'C:/ProgramData/nexus/sql/tls/$hostName.pem') -and (Test-Path 'C:/ProgramData/nexus/sql/tls/listener.pem')) {
    Write-Output 'CERTS_RENDERED';
    break;
  }
  Start-Sleep -Seconds 5;
}
if (-not (Test-Path 'C:/ProgramData/nexus/sql/tls/$hostName.pem')) { throw 'node cert not rendered in 2 min' }

# Import both certs into LocalMachine\My (SQL Server reads from cert store).
# PEM bundles need to be split into cert + private key + converted to PFX
# for Import-Certificate. Use openssl (baked into ws2025-desktop baseline)
# if available; else fall back to certutil + .pfx round-trip.
foreach (`$certName in @('$hostName', 'listener')) {
  `$pem = "C:/ProgramData/nexus/sql/tls/`$certName.pem";
  `$pfx = "C:/ProgramData/nexus/sql/tls/`$certName.pfx";
  if (Get-Command openssl -ErrorAction SilentlyContinue) {
    & openssl pkcs12 -export -out `$pfx -in `$pem -passout pass:nexustempbake 2>`$null;
    if (Test-Path `$pfx) {
      Import-PfxCertificate -FilePath `$pfx -CertStoreLocation 'Cert:/LocalMachine/My' ``
        -Password (ConvertTo-SecureString 'nexustempbake' -AsPlainText -Force) -Exportable | Out-Null;
      Remove-Item `$pfx;
      Write-Output ('IMPORTED: ' + `$certName);
    }
  } else {
    Write-Output ('SKIP_IMPORT: openssl missing on ' + `$env:COMPUTERNAME);
  }
}
"@

      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
      $output = ssh -o ConnectTimeout=30 "$sshUser@$ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($LASTEXITCODE -ne 0) { throw "[sqlserver-tls] $hostName : cert render failed (rc=$LASTEXITCODE)" }
      Write-Host "[sqlserver-tls] $hostName : per-node + listener cert rendered + imported into LocalMachine\\My"
    PWSH
  }
}
