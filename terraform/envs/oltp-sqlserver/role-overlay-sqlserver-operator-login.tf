# role-overlay-sqlserver-operator-login.tf -- Phase 0.G.7 / nexus-cli v0.6.6
#
# Idempotently creates the dedicated `nexus-cluster-admin` SQL Server LOGIN the
# nexus-cli SqlFciAdapter + SqlAgAdapter authenticate as -- the LOCKED Vault-KV
# operator-credential model (ADR-0011 family: ONE dedicated operator per
# password-auth engine, password ONLY in Vault KV, fetched at runtime via
# INexusVaultClient). Mirrors the clickhouse/starrocks/percona/mongo/patroni
# operator-user overlays. Distinct from the engine's built-in `sa`.
#
# AUTH MODEL (decided from the live probe 2026-06-12, nexus-cli v0.6.6):
#   - The FCI (sqlfci) is MIXED MODE (IsIntegratedSecurityOnly=0) -> SQL-auth
#     logins work. The standalone replicas sql-ag-rep-1/2 are WINDOWS-AUTH ONLY
#     (IsIntegratedSecurityOnly=1) -> a SQL login can't connect there.
#   - The adapters therefore use the operator SQL login ONLY against the FCI +
#     the AG Listener (which routes to the FCI primary); direct replica ops (the
#     AG FAILOVER issued on the target secondary) use Windows-auth `-E` (local
#     nexusadmin IS sysadmin on the standalone replicas). So the login is created
#     on the FCI ONLY -- the FCI's master is on the shared iSCSI LUN, so a single
#     CREATE LOGIN covers both sql-fci-1/2.
#
# Created via `sqlcmd -S sqlfci -U sa -C` (sa-pw read on-node from the Vault-Agent-
# rendered C:\ProgramData\nexus\sql\creds\sa-password.txt -- never echoed). The
# operator password is read on the build host via sql-fci-1's AppRole sidecar
# (same pattern as role-overlay-sqlserver-tls.tf) and pushed to the FCI node as a
# base64 T-SQL script (no argv exposure; deleted after).
#
# SID is pinned (0x4E45585553434C41444D494E30303031) + CHECK_POLICY=OFF
# CHECK_EXPIRATION=OFF so the operator login is identical + never expires/locks
# across a cold rebuild (AG-safe if a future enhancement ever maps it to a DB in
# the AG).
#
# Ordered AFTER ag_listener (the last steady-state overlay) -- the operator login
# is a pure-control-plane addition that needs the FCI + AG fully up first.
#
# Selective ops: var.enable_sqlserver_operator_login.

variable "enable_sqlserver_operator_login" {
  description = "Toggle: create the nexus-cluster-admin SQL login on the FCI (the nexus-cli SqlFci/SqlAg adapter operator identity; password from Vault KV nexus/oltp/sqlserver/operator-password). Default true."
  type        = bool
  default     = true
}

variable "kv_operator_password_path" {
  description = "Vault KV-v2 logical path (under mount nexus/) of the operator login password. The HTTP data path inserts /data/."
  type        = string
  default     = "oltp/sqlserver/operator-password"
}

variable "sqlserver_operator_login_v" {
  description = "Operator-login overlay version. Bump to re-run."
  type        = string
  default     = "1"
}

resource "null_resource" "sqlserver_operator_login" {
  count = var.enable_sqlserver_operator_login ? 1 : 0

  triggers = {
    ag_listener_id = length(null_resource.ag_listener) > 0 ? null_resource.ag_listener[0].id : "disabled"
    operator_kv    = var.kv_operator_password_path
    operator_v     = "1" # v1 (0.G.7, nexus-cli v0.6.6) = nexus-cluster-admin SQL login on the FCI, fixed SID, sysadmin, CHECK_POLICY=OFF.
    ssh_user       = var.ssh_username
  }

  depends_on = [null_resource.ag_listener]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ErrorActionPreference = 'Stop'
      $sshUser    = '${var.ssh_username}'
      $fciIp      = '${local.fci_nodes["sql-fci-1"].vmnet11}'
      $opKvData   = '${var.kv_operator_password_path}' # logical path; HTTP data path inserts /data/ below
      $sshOpts    = @('-o','ConnectTimeout=15','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # 1) Read operator-password on the build host via sql-fci-1's AppRole sidecar
      #    (same minted-fresh-on-cold-rebuild sidecar the TLS overlay uses). KV-v2
      #    data path = nexus/data/<logical>.
      $sidecar = Join-Path $HOME ".nexus/vault-agent-oltp-sqlserver-sql-fci-1.json"
      if (-not (Test-Path $sidecar)) { throw "[sqlserver-operator-login] sidecar $sidecar missing (run the security env approle overlay first)" }
      $cfg = Get-Content $sidecar -Raw | ConvertFrom-Json
      $vaultAddr = $cfg.vault_addr.TrimEnd('/')
      $login = Invoke-RestMethod -Method Post -Uri "$vaultAddr/v1/auth/approle/login" -SkipCertificateCheck `
        -Body (@{ role_id = $cfg.role_id; secret_id = $cfg.secret_id } | ConvertTo-Json) -ContentType 'application/json'
      $token = $login.auth.client_token
      $kvResp = Invoke-RestMethod -Method Get -Uri "$vaultAddr/v1/nexus/data/$opKvData" -SkipCertificateCheck `
        -Headers @{ 'X-Vault-Token' = $token }
      $opw = $kvResp.data.data.password
      if ([string]::IsNullOrEmpty($opw)) { throw "[sqlserver-operator-login] operator-password empty at nexus/$opKvData (check security env creds-seed v3)" }
      Write-Host "[sqlserver-operator-login] operator-password read from Vault (len=$($opw.Length))"

      # 2) Build the idempotent CREATE LOGIN T-SQL (fixed SID; pinned so a cold
      #    rebuild reproduces the identical principal). Pushed as base64 -> no
      #    argv exposure of the password.
      $sid = '0x4E45585553434C41444D494E30303031'
      $tsql = "SET NOCOUNT ON; IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='nexus-cluster-admin') CREATE LOGIN [nexus-cluster-admin] WITH PASSWORD='$opw', SID=$sid, CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF, DEFAULT_DATABASE=master; ELSE ALTER LOGIN [nexus-cluster-admin] WITH PASSWORD='$opw'; IF IS_SRVROLEMEMBER('sysadmin','nexus-cluster-admin')=0 ALTER SERVER ROLE [sysadmin] ADD MEMBER [nexus-cluster-admin]; PRINT 'OPERATOR_LOGIN_OK ' + @@SERVERNAME + ' sid=' + CONVERT(varchar(40), SUSER_SID('nexus-cluster-admin'), 1);"
      $tsqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tsql))

      # 3) On the FCI: read sa-pw on-node (never echoed) + run sqlcmd -U sa -C.
      $remoteTmpl = @'
$ErrorActionPreference='Stop'
$env:SQLCMDPASSWORD = (Get-Content 'C:/ProgramData/nexus/sql/creds/sa-password.txt' -Raw).Trim()
$sql = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__TSQL_B64__'))
$out = & sqlcmd -S sqlfci -U sa -C -b -h -1 -W -Q $sql 2>&1 | Out-String
Write-Output $out.Trim()
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'OPERATOR_LOGIN_OK') { Write-Output "OPERATOR_LOGIN_FAIL rc=$LASTEXITCODE"; exit 1 }
'@
      $remote = $remoteTmpl.Replace('__TSQL_B64__', $tsqlB64)
      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
      $out = ssh @sshOpts "$sshUser@$fciIp" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host ("  " + $out.Trim())
      if ($out -notmatch 'OPERATOR_LOGIN_OK') { throw "[sqlserver-operator-login] create/verify failed: $out" }

      # 4) Verify the operator authenticates via SQL-auth (the adapter's path).
      $verifyTmpl = @'
$ErrorActionPreference='Continue'
$env:SQLCMDPASSWORD = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__OPW_B64__'))
$out = & sqlcmd -S sqlfci -U nexus-cluster-admin -C -b -h -1 -W -Q "SELECT 'OPERATOR_AUTH_OK '+SUSER_SNAME()+' sysadmin='+CONVERT(varchar(2),IS_SRVROLEMEMBER('sysadmin'))" 2>&1 | Out-String
Write-Output $out.Trim()
'@
      $opwB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($opw))
      $verify = $verifyTmpl.Replace('__OPW_B64__', $opwB64)
      $vb64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($verify))
      $vout = ssh @sshOpts "$sshUser@$fciIp" "powershell -NoProfile -EncodedCommand $vb64" 2>&1 | Out-String
      Write-Host ("  " + $vout.Trim())
      if ($vout -notmatch 'OPERATOR_AUTH_OK.*sysadmin=1') { throw "[sqlserver-operator-login] operator SQL-auth round-trip failed: $vout" }
      Write-Host "[sqlserver-operator-login] EXIT GATE GREEN -- nexus-cluster-admin created on the FCI + authenticates (sysadmin)"
    PWSH
  }

  # Destroy: drop the operator login (best-effort; a full env destroy tears down
  # the cluster anyway). Uses sa over plain SSH on sql-fci-1.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $fciIp   = '192.168.70.11'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $remote = @'
$env:SQLCMDPASSWORD = (Get-Content 'C:/ProgramData/nexus/sql/creds/sa-password.txt' -Raw).Trim()
& sqlcmd -S sqlfci -U sa -C -h -1 -W -Q "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name='nexus-cluster-admin') DROP LOGIN [nexus-cluster-admin]" 2>&1 | Out-Null
'@
      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
      Write-Host "[sqlserver-operator-login destroy] dropping nexus-cluster-admin (best-effort)"
      ssh @sshOpts "$sshUser@$fciIp" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-Null
      exit 0
    PWSH
  }
}
