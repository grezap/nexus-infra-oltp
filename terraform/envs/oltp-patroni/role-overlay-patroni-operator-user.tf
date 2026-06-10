/*
 * role-overlay-patroni-operator-user.tf -- nexus-cli v0.6.3 PatroniAdapter
 * operator-credential bootstrap (mirrors the 0.G.2 mongo + 0.G.3 percona
 * operator-user model).
 *
 * One-shot, idempotent CREATE ROLE of the dedicated operator role
 * `nexus-cluster-admin` that the nexus-cli PatroniAdapter authenticates as for
 * its read/admin verbs (status / health / topology / failover / scale-out /
 * backup / cert-rotate / acl / chaos against the Patroni + etcd + HAProxy
 * cluster).
 *
 * Why a dedicated operator role (least-priv, NOT superuser):
 *   - postgres + nexusops are SUPERUSER identities bootstrapped via
 *     patroni.yml; their passwords are the postgres-superuser KV secret used
 *     internally by Patroni for cluster ops -- not the operator surface, and
 *     superuser is more dangerous than the verb set needs.
 *   - replicator/rewind are narrow streaming-replication service accounts.
 *   - nexus-cluster-admin gets LOGIN CREATEROLE CREATEDB REPLICATION + member
 *     of pg_monitor + pg_read_all_data + pg_write_all_data -- the operator-admin
 *     identity covering the whole verb surface (pg_stat_replication +
 *     pg_is_in_recovery for status/health/topology; CREATE ROLE for acl;
 *     pg_dump/pg_basebackup for backup; read/write for round-trips) WITHOUT
 *     being a PostgreSQL superuser. Patroni-level verbs (switchover/failover/
 *     restart/reinitialize) go via the REST API + on-node sudo, not this role.
 *
 * Credential model (the standard locked with Greg 2026-06-05 for all
 * password-auth adapters -- identical to mongo + percona operator-user):
 *   - The password lives ONLY in Vault KV at nexus/oltp/patroni/operator-password
 *     (sticky-seeded by role-overlay-vault-patroni-cluster-creds-seed.tf v2 in
 *     nexus-infra-vmware/envs/security). It is NEVER rendered to a node file.
 *   - This bootstrap discovers the current Patroni LEADER (via nexus-patronictl),
 *     reads the password on that leader node via the node's OWN Vault Agent
 *     token (`vault kv get`, granted by patroni agent-policy v3's
 *     operator-password read), then CREATE ROLEs it via the leader's local
 *     postgres unix socket (peer auth, no password). The role is a global
 *     object -- it replicates to the 2 streaming replicas via WAL. The password
 *     is held only in an on-node shell variable.
 *   - At RUNTIME the PatroniAdapter fetches the same KV value via the existing
 *     INexusVaultClient + VAULT_TOKEN and passes it to psql over SSH.
 *
 * Cross-env ordering (hard): nexus-infra-vmware/envs/security must apply FIRST
 * so (a) nexus/oltp/patroni/operator-password is seeded and (b) the patroni
 * agent policy v3 grants read on it. Then this oltp-patroni env apply runs.
 *
 * Selective ops: var.enable_patroni_operator_user AND var.enable_patroni_bootstrap.
 */

resource "null_resource" "patroni_operator_user" {
  count = (
    var.enable_patroni_operator_user && var.enable_patroni_bootstrap
    && length(local.patroni_nodes_active) == 3
  ) ? 1 : 0

  triggers = {
    bootstrap_id    = null_resource.patroni_bootstrap[0].id
    scope           = var.patroni_scope
    operator_user_v = "1" # v1 (nexus-cli v0.6.3 PatroniAdapter, 2026-06-11) = idempotent CREATE ROLE nexus-cluster-admin (LOGIN CREATEROLE CREATEDB REPLICATION + pg_monitor/pg_read_all_data/pg_write_all_data); password read on the leader via the node's own Vault Agent token (never to disk); peer-auth postgres unix socket; replicates to streaming replicas via WAL.
  }

  depends_on = [null_resource.patroni_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.oltp_node_user}'
      $sshOpts = @('-o','ConnectTimeout=15','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @(
%{for host, m in local.patroni_nodes_active~}
        @{ Host='${host}'; VmIp='${m.vm_ip}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      Write-Host ""
      Write-Host "[patroni-operator-user] discovering current Patroni leader via nexus-patronictl..."

      # ─── Discover the current leader (writes -- incl. CREATE ROLE -- must go
      #     to the leader; the role then replicates to replicas via WAL). ─────
      $leaderIp   = $null
      $leaderHost = $null
      foreach ($n in $nodes) {
        $listOut = (ssh @sshOpts "$sshUser@$($n.VmIp)" "sudo /usr/local/sbin/nexus-patronictl list --format json 2>/dev/null" 2>&1 | Out-String).Trim()
        if ($listOut -match '^\[') {
          try {
            $cluster = $listOut | ConvertFrom-Json
            $leader  = $cluster | Where-Object { $_.Role -eq 'Leader' } | Select-Object -First 1
            if ($leader) { $leaderIp = $leader.Host; $leaderHost = $leader.Member; break }
          } catch { }
        }
      }
      if (-not $leaderIp) { throw "[patroni-operator-user] could not determine Patroni leader from any node" }
      Write-Host "[patroni-operator-user] leader = $leaderHost ($leaderIp) ; creating nexus-cluster-admin (LOGIN CREATEROLE CREATEDB REPLICATION + pg_monitor/read_all/write_all)"

      # Runs ON the leader so the operator password (read from Vault KV via the
      # node's own agent token) is never returned to the build host nor written
      # to disk. Single-quoted PS here-string => NO PowerShell interpolation;
      # every bash $VAR / $(...) stays literal for the remote shell. NOTE: keep
      # bash to $VAR form (no $${...}) so terraform does not try to interpolate.
      $bash = @'
set -euo pipefail

# 1. Read the operator password from Vault KV via THIS node's own agent token
#    (patroni agent policy v3 grants read on nexus/data/oltp/patroni/operator-password).
T=$(sudo cat /run/nexus-vault-agent/token 2>/dev/null)
if [ -z "$T" ]; then echo "ERR_NO_AGENT_TOKEN"; exit 6; fi
OPPWD=$(sudo env VAULT_ADDR=https://192.168.70.121:8200 VAULT_TOKEN="$T" VAULT_CACERT=/etc/nexus-patroni/tls/ca.pem /usr/local/bin/vault kv get -field=content nexus/oltp/patroni/operator-password 2>/dev/null)
if [ -z "$OPPWD" ]; then echo "ERR_NO_OPERATOR_PASSWORD"; exit 7; fi

# 2. CREATE ROLE + grants via the leader's local postgres unix socket (peer
#    auth as the postgres superuser; no TLS/pwd needed). Idempotent DO-block:
#    CREATE if absent else ALTER converges attributes + password. The role is
#    a global object -- it replicates to the 2 streaming replicas via WAL.
#    Password is single-quoted into the SQL; operator-password is 32-char hex
#    (no quote/backslash metachar risk).
SOCK_DIR=/var/run/nexus-patroni
SQL=$(cat <<SQLEOF
DO \$do\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nexus-cluster-admin') THEN
    CREATE ROLE "nexus-cluster-admin" LOGIN CREATEROLE CREATEDB REPLICATION PASSWORD '$OPPWD';
  ELSE
    ALTER ROLE "nexus-cluster-admin" WITH LOGIN CREATEROLE CREATEDB REPLICATION PASSWORD '$OPPWD';
  END IF;
END
\$do\$;
GRANT pg_monitor       TO "nexus-cluster-admin";
GRANT pg_read_all_data  TO "nexus-cluster-admin";
GRANT pg_write_all_data TO "nexus-cluster-admin";
SELECT 'OPER_OK' AS status;
SQLEOF
)
OUT=$(printf '%s' "$SQL" | sudo -u postgres psql -h "$SOCK_DIR" -U postgres -d postgres -v ON_ERROR_STOP=1 -tA 2>&1)
echo "$OUT"
echo "$OUT" | grep -q 'OPER_OK' || { echo "ERR_CREATE_FAILED"; exit 10; }
echo "[patroni-operator-user] nexus-cluster-admin created/converged (replicating to streaming replicas via WAL)"

# 3. Verify the operator role authenticates over TLS + scram-sha-256 against
#    the leader's VMnet11 listener (pg_hba: hostssl all all 192.168.0.0/16
#    scram-sha-256 -- a genuine password test, unlike the 127.0.0.1 trust line).
#    Run under sudo so root can read the 0640 root:postgres ca.pem.
LEADER_IP=$(hostname -I | tr ' ' '\n' | grep -E '^192\.168\.70\.' | head -1)
if [ -z "$LEADER_IP" ]; then echo "ERR_NO_LEADER_IP"; exit 8; fi
VER=$(sudo env PGPASSWORD="$OPPWD" psql "host=$LEADER_IP port=5432 sslmode=verify-ca sslrootcert=/etc/nexus-patroni/tls/ca.pem user=nexus-cluster-admin dbname=postgres" -tAc "SELECT 'recovery=' || pg_is_in_recovery()::text;" 2>&1)
echo "$VER"
echo "$VER" | grep -q 'recovery=false' || { echo "ERR_VERIFY"; exit 11; }
echo "[patroni-operator-user] OK -- nexus-cluster-admin verified over TLS+scram against leader $LEADER_IP (pg_is_in_recovery=false)"
'@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      $output = ssh @sshOpts "$sshUser@$leaderIp" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[patroni-operator-user] CREATE ROLE/verify failed on leader $leaderIp (rc=$rc). See output above + handbook s3.x (patroni operator-user troubleshooting)."
      }
      Write-Host "[patroni-operator-user] OK -- nexus-cluster-admin ready for the nexus-cli PatroniAdapter"
    PWSH
  }

  # No destroy provisioner: the role lives in pg_authid (replicated via WAL to
  # all Patroni nodes); full env destroy via modules/vm takes the VMs + disks.
}
