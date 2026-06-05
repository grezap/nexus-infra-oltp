/*
 * role-overlay-percona-operator-user.tf -- nexus-cli v0.6.2 PerconaAdapter
 * operator-credential bootstrap (mirrors the 0.G.2 mongo operator-user model).
 *
 * One-shot, idempotent CREATE USER of the dedicated operator user
 * `nexus-cluster-admin`@'%' that the nexus-cli PerconaAdapter authenticates as
 * for its read/admin verbs (status / health / topology / failover / scale-out /
 * backup / cert-rotate / acl / chaos against the PXC + ProxySQL cluster).
 *
 * Why a dedicated operator user:
 *   - root@localhost is auth_socket / KV-rendered + remote login is disabled
 *     (in-band only) -- not usable as a remote operator identity.
 *   - wsrep_sst / clustercheck are narrow service accounts; smoke-rw has only
 *     ALL on nexus_smoke.* (can't SHOW STATUS cluster-wide, manage users, or
 *     back up other schemas).
 *   - nexus-cluster-admin gets ALL PRIVILEGES ON *.* WITH GRANT OPTION -- the
 *     operator-admin identity covering the whole verb surface (wsrep status +
 *     mysqldump/xtrabackup + CREATE USER/GRANT for acl) without being root.
 *
 * Credential model (the standard locked with Greg 2026-06-05 for all
 * password-auth adapters -- identical to the mongo operator-user):
 *   - The password lives ONLY in Vault KV at nexus/oltp/percona/operator-password
 *     (sticky-seeded by role-overlay-vault-percona-cluster-creds-seed.tf v2 in
 *     nexus-infra-vmware/envs/security). It is NEVER rendered to a node file.
 *   - This bootstrap reads the password on the bootstrap PXC node via that
 *     node's OWN Vault Agent token (`vault kv get`, granted by percona-agent
 *     policy v2's operator-password read), then creates the user via the
 *     root-socket `nexus-pxc-mysql` wrapper. Galera replicates the user to all
 *     3 PXC nodes. The password is held only in an on-node shell variable.
 *   - At RUNTIME the PerconaAdapter fetches the same KV value via the existing
 *     VaultClient + VAULT_TOKEN and passes it to the mysql client over SSH.
 *
 * Cross-env ordering (hard): nexus-infra-vmware/envs/security must apply FIRST
 * so (a) nexus/oltp/percona/operator-password is seeded and (b) the percona
 * PXC agent policy grants read on it. Then this oltp-percona env apply runs.
 *
 * Selective ops: var.enable_percona_operator_user AND var.enable_galera_cluster_bootstrap.
 */

resource "null_resource" "percona_operator_user" {
  count = (
    var.enable_percona_operator_user && var.enable_galera_cluster_bootstrap
    && length(local.percona_pxc_members) == 3
  ) ? 1 : 0

  triggers = {
    galera_bootstrap_id = null_resource.percona_galera_bootstrap[0].id
    bootstrap_ip        = local.percona_bootstrap_ip
    operator_user_v     = "1" # v1 (nexus-cli v0.6.2 PerconaAdapter, 2026-06-05) = idempotent CREATE USER nexus-cluster-admin@'%' (ALL PRIVILEGES WITH GRANT OPTION); password read on-node via the node's own Vault Agent token (never to disk); root-socket nexus-pxc-mysql wrapper; Galera replicates to all 3 PXC nodes.
  }

  depends_on = [null_resource.percona_galera_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $bootIp  = '${local.percona_bootstrap_ip}'
      $sshUser = '${var.oltp_node_user}'

      Write-Host ""
      Write-Host "[percona-operator-user] bootstrap node = $bootIp ; creating nexus-cluster-admin@'%' (ALL PRIVILEGES WITH GRANT OPTION)"

      # Runs ON the node so the operator password (read from Vault KV via the
      # node's own agent token) is never returned to the build host nor written
      # to disk. Single-quoted PS here-string => NO PowerShell interpolation;
      # terraform injects its interpolations at plan time; every bash $VAR /
      # $(...) stays literal for the remote shell.
      $bash = @'
set -euo pipefail

# 1. Read the operator password from Vault KV via THIS node's own agent token
#    (percona-agent policy v2 grants read on nexus/data/oltp/percona/operator-password).
T=$(sudo cat /run/nexus-vault-agent/token 2>/dev/null)
if [ -z "$T" ]; then echo "ERR_NO_AGENT_TOKEN"; exit 6; fi
OPPWD=$(sudo env VAULT_ADDR=https://192.168.70.121:8200 VAULT_TOKEN="$T" VAULT_CACERT=/etc/nexus-percona/tls/ca.pem /usr/local/bin/vault kv get -field=content nexus/oltp/percona/operator-password 2>/dev/null)
if [ -z "$OPPWD" ]; then echo "ERR_NO_OPERATOR_PASSWORD"; exit 7; fi

# 2. CREATE USER + grants via the root-socket nexus-pxc-mysql wrapper (no TLS/pwd
#    needed; runs as root over the local socket). Galera replicates to all nodes.
#    Idempotent: CREATE IF NOT EXISTS + ALTER USER converges the password.
SQL="CREATE USER IF NOT EXISTS 'nexus-cluster-admin'@'%' IDENTIFIED WITH mysql_native_password BY '$OPPWD'; ALTER USER 'nexus-cluster-admin'@'%' IDENTIFIED WITH mysql_native_password BY '$OPPWD'; GRANT ALL PRIVILEGES ON *.* TO 'nexus-cluster-admin'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES; SELECT 'OPER_OK' AS status;"
OUT=$(printf '%s' "$SQL" | sudo /usr/local/sbin/nexus-pxc-mysql 2>&1)
echo "$OUT"
echo "$OUT" | grep -q 'OPER_OK' || { echo "ERR_CREATE_FAILED"; exit 10; }
echo "[percona-operator-user] nexus-cluster-admin created + granted (replicating via Galera)"

# 3. Verify the operator user authenticates over TLS + can read cluster status.
VER=$(sudo mysql -h 127.0.0.1 -u nexus-cluster-admin -p"$OPPWD" --ssl-ca=/etc/nexus-percona/tls/ca.pem --ssl-mode=VERIFY_CA -BNe "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>&1)
echo "$VER"
echo "$VER" | grep -qE 'wsrep_cluster_size[[:space:]]+[0-9]+' || { echo "ERR_VERIFY"; exit 11; }
echo "[percona-operator-user] OK -- nexus-cluster-admin verified over TLS (SHOW STATUS wsrep_cluster_size)"
'@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      $sshOpts = @('-o','ConnectTimeout=20','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $output = ssh @sshOpts "$sshUser@$bootIp" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[percona-operator-user] createUser/verify failed on $bootIp (rc=$rc). See output above + handbook s3.x (percona operator-user troubleshooting)."
      }
      Write-Host "[percona-operator-user] OK -- nexus-cluster-admin ready for the nexus-cli PerconaAdapter"
    PWSH
  }

  # No destroy provisioner: the user lives in mysql.user (replicated via Galera
  # to all PXC nodes); full env destroy via modules/vm takes the VMs + disks.
}
