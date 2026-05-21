# role-overlay-sqlserver-tls.tf -- Phase 0.G.7
#
# Provisions each node's UNIFIED SQL Server TLS leaf cert (+ full CA chain)
# from Vault PKI (pki_int/issue/sqlserver-server) and imports it into the
# Windows cert store so SQL Server can present it at the TLS handshake.
#
# Cert SAN list varies by role (one cert per instance carries EVERY name the
# instance answers to -- SQL binds a single SuperSocketNetLib\Certificate):
#   - FCI nodes (sql-fci-1/2): CN=<host>.sqlserver.nexus.lab; SANs add the WSFC
#     CNO (sql-fci-cluster), the FCI virtual server name (sqlfci) + .70.16, and
#     the AG Listener (sql-ag-listener) + .70.17; IP-SANs add .16 + .17.
#   - AG-replica nodes (sql-ag-rep-1/2): CN=<host>.sqlserver.nexus.lab; SANs add
#     the AG Listener + .70.17 (the Listener IP follows the AG primary, which
#     can land on a replica after an AG failover -- HA-promise-covers-LB-tier).
#
# WHY build-host issuance (not on-node Vault Agent render + openssl convert):
# Transients at 0.G.7 ratify 2026-05-22 --
#   #29s: ws2025-desktop has NO openssl, so the original on-node PEM->PFX->store
#         conversion silently fell through (SKIP_IMPORT) -> the cert never
#         reached LocalMachine\My -> the Listener TLS bind found nothing. There
#         is no pure-PowerShell-5.1 way to import a PKCS#1 PEM key (no
#         ImportRSAPrivateKey in .NET Framework 4.8). So the build host (which
#         runs this local-exec under pwsh 7) issues the cert via the node's
#         AppRole over the Vault HTTP API, builds the PFX with
#         X509Certificate2.CreateFromPemFile + Export, and ships the PFX -- the
#         node imports it with the native Import-PfxCertificate (no openssl).
#   #29t: the leaf chains leaf -> NexusPlatform Intermediate CA -> Root CA, but
#         SQL/Schannel only presents the leaf. The Intermediate must be in the
#         node's LocalMachine\CA (so Schannel sends it) and the Root in
#         LocalMachine\Root (so clients validate). Both are imported here.
# A clean cold rebuild mints a fresh AppRole secret-id (security env), so the
# sidecar JSON the build host reads is always valid.
#
# The cert is a 90-day leaf (ttl=2160h); renewal = re-apply this overlay.

resource "null_resource" "sqlserver_tls" {
  for_each = var.enable_sqlserver_tls ? local.sql_nodes : {}

  triggers = {
    host    = each.key
    stage_v = var.sqlserver_tls_v
  }

  depends_on = [null_resource.sqlserver_vault_agents]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ErrorActionPreference = 'Stop'
      $hostName    = '${each.key}'
      $ip          = '${each.value.vmnet11}'
      $role        = '${each.value.role}'
      $vmnet10     = '${each.value.vmnet10}'
      $sshUser     = '${var.ssh_username}'
      $pkiRole     = '${var.vault_pki_sqlserver_role}'
      $fciVip      = '${local.fci_virtual_ip}'
      $listenerVip = '${local.ag_listener_ip}'

      Write-Host "[sqlserver-tls] issuing unified mTLS cert for $hostName ($role) via build-host AppRole..."

      # Read this node's AppRole sidecar (minted by the security env; fresh on a
      # cold rebuild). Login -> token with the node's pki issue policy.
      $sidecar = Join-Path $HOME ".nexus/vault-agent-oltp-sqlserver-$hostName.json"
      if (-not (Test-Path $sidecar)) { throw "[sqlserver-tls] sidecar $sidecar missing (run the security env approle overlay first)" }
      $cfg = Get-Content $sidecar -Raw | ConvertFrom-Json
      $vaultAddr = $cfg.vault_addr.TrimEnd('/')
      $login = Invoke-RestMethod -Method Post -Uri "$vaultAddr/v1/auth/approle/login" -SkipCertificateCheck `
        -Body (@{ role_id = $cfg.role_id; secret_id = $cfg.secret_id } | ConvertTo-Json) -ContentType 'application/json'
      $token = $login.auth.client_token

      # Role-specific SAN lists (unified per-node cert).
      if ($role -eq 'fci') {
        $alt   = "$hostName,$hostName.nexus.lab,$hostName.sqlserver.nexus.lab,sql-fci-cluster,sql-fci-cluster.nexus.lab,sqlfci,sqlfci.nexus.lab,sql-ag-listener,sql-ag-listener.nexus.lab,localhost"
        $ipsan = "$ip,$vmnet10,127.0.0.1,$fciVip,$listenerVip"
      } else {
        $alt   = "$hostName,$hostName.nexus.lab,$hostName.sqlserver.nexus.lab,sql-ag-listener,sql-ag-listener.nexus.lab,localhost"
        $ipsan = "$ip,$vmnet10,127.0.0.1,$listenerVip"
      }

      $issue = Invoke-RestMethod -Method Post -Uri "$vaultAddr/v1/pki_int/issue/$pkiRole" -SkipCertificateCheck `
        -Headers @{ 'X-Vault-Token' = $token } `
        -Body (@{ common_name = "$hostName.sqlserver.nexus.lab"; alt_names = $alt; ip_sans = $ipsan; ttl = '2160h' } | ConvertTo-Json) -ContentType 'application/json'

      # Build PFX on the build host (pwsh 7) -- no openssl on the node.
      $work = Join-Path $env:TEMP "sqltls-$hostName-$([System.Guid]::NewGuid().ToString('N'))"
      New-Item -ItemType Directory -Force -Path $work | Out-Null
      $certFile  = Join-Path $work 'leaf.crt'
      $pemFile   = Join-Path $work 'leaf-with-key.pem'
      $interFile = Join-Path $work 'intermediate.crt'
      $rootFile  = Join-Path $work 'root.crt'
      $bundleFile = Join-Path $work "$hostName.pem"
      [IO.File]::WriteAllText($certFile, $issue.data.certificate)
      [IO.File]::WriteAllText($pemFile, ($issue.data.certificate + "`n" + $issue.data.private_key))
      [IO.File]::WriteAllText($interFile, $issue.data.ca_chain[0])
      [IO.File]::WriteAllText($rootFile, $issue.data.ca_chain[1])
      # On-disk material bundle (cert + key + CA) for smoke §4 + ops use.
      [IO.File]::WriteAllText($bundleFile, ($issue.data.certificate + "`n" + $issue.data.private_key + "`n" + $issue.data.issuing_ca))

      $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($certFile, $pemFile)
      $pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'nexustempbake')
      $pfxFile = Join-Path $work "$hostName.pfx"
      [IO.File]::WriteAllBytes($pfxFile, $pfxBytes)

      # Ship the material to the node + import (leaf -> My, intermediate -> CA,
      # root -> Root). Small EncodedCommand (no embedded PEM -> under the ssh
      # argv cliff; transient #29m): the certs travel as scp'd files.
      ssh -o ConnectTimeout=30 "$sshUser@$ip" "New-Item -ItemType Directory -Force -Path 'C:/ProgramData/nexus/sql/tls' | Out-Null" 2>&1 | Out-Null
      scp -o ConnectTimeout=30 $pfxFile    "$sshUser@$($ip):C:/Windows/Temp/nx-sqltls.pfx" 2>&1 | Out-Null
      scp -o ConnectTimeout=30 $interFile  "$sshUser@$($ip):C:/Windows/Temp/nx-sqltls-inter.crt" 2>&1 | Out-Null
      scp -o ConnectTimeout=30 $rootFile   "$sshUser@$($ip):C:/Windows/Temp/nx-sqltls-root.crt" 2>&1 | Out-Null
      scp -o ConnectTimeout=30 $bundleFile "$sshUser@$($ip):C:/ProgramData/nexus/sql/tls/$hostName.pem" 2>&1 | Out-Null
      $scpRc = $LASTEXITCODE
      Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
      if ($scpRc -ne 0) { throw "[sqlserver-tls] $hostName : scp of cert material failed (rc=$scpRc)" }

      $importScript = @'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
Import-PfxCertificate -FilePath 'C:/Windows/Temp/nx-sqltls.pfx' -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString 'nexustempbake' -AsPlainText -Force) -Exportable -EA Stop | Out-Null
Import-Certificate -FilePath 'C:/Windows/Temp/nx-sqltls-inter.crt' -CertStoreLocation Cert:\LocalMachine\CA   -EA SilentlyContinue | Out-Null
Import-Certificate -FilePath 'C:/Windows/Temp/nx-sqltls-root.crt'  -CertStoreLocation Cert:\LocalMachine\Root -EA SilentlyContinue | Out-Null
Remove-Item 'C:/Windows/Temp/nx-sqltls.pfx','C:/Windows/Temp/nx-sqltls-inter.crt','C:/Windows/Temp/nx-sqltls-root.crt' -EA SilentlyContinue
$leaf = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq ('CN=__HOST__.sqlserver.nexus.lab') -and $_.HasPrivateKey -and ($_.DnsNameList.Unicode -contains 'sql-ag-listener.nexus.lab') } | Sort-Object NotBefore -Descending | Select-Object -First 1
if ($leaf) { Write-Output ('TLS_IMPORTED thumb=' + $leaf.Thumbprint) } else { Write-Output 'TLS_IMPORT_FAIL' }
'@
      $importScript = $importScript.Replace('__HOST__', $hostName)
      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($importScript))
      $out = ssh -o ConnectTimeout=60 "$sshUser@$ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host ("  " + $out.Trim())
      if ($out -notmatch 'TLS_IMPORTED') { throw "[sqlserver-tls] $hostName : cert import failed: $out" }
      Write-Host "[sqlserver-tls] $hostName : unified cert + CA chain imported (My + CA + Root); PEM at C:\ProgramData\nexus\sql\tls\$hostName.pem"
    PWSH
  }
}
