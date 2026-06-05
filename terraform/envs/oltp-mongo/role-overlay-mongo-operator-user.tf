/*
 * role-overlay-mongo-operator-user.tf -- nexus-cli v0.6.1 MongoAdapter
 * operator-credential bootstrap.
 *
 * One-shot, idempotent createUser of the dedicated operator user
 * `nexus-cluster-admin` (roles clusterMonitor + clusterManager + backup +
 * restore + userAdminAnyDatabase on `admin`) that the nexus-cli MongoAdapter
 * authenticates as for its read/admin verbs (status / health / topology /
 * failover / scale-out / backup / restore / acl).
 *
 * Why a dedicated operator user:
 *   - __system (the keyFile-derived cluster identity) is "discouraged for
 *     operator use" per MongoDB docs; the adapter's auto-mode classifier
 *     correctly refuses to use it for queries.
 *   - smoke-rw has only `readWrite on nexus_smoke` -- it cannot run
 *     rs.status() (needs replSetGetStatus, in clusterMonitor) nor rs.stepDown
 *     / rs.add / rs.remove (needs clusterManager).
 *   - nexus-cluster-admin gets clusterMonitor + clusterManager + backup +
 *     restore + userAdminAnyDatabase: the least privilege that covers the whole
 *     MongoAdapter verb surface (read/admin + mongodump/mongorestore + acl
 *     getUsers/createUser) without using the root-equivalent __system identity.
 *
 * Credential model (the standard locked with Greg 2026-06-05 for all
 * password-auth adapters):
 *   - The password lives ONLY in Vault KV at nexus/oltp/mongo/operator-password
 *     (sticky-seeded by role-overlay-vault-mongo-operator-user-seed.tf in
 *     nexus-infra-vmware/envs/security). It is NEVER written to a node file.
 *   - This bootstrap reads the password on the bootstrap node via that node's
 *     OWN Vault Agent token (`vault kv get` against the mongo-agent policy's
 *     operator-password read grant, added in v3 of
 *     role-overlay-vault-agent-mongo-policies.tf). The whole createUser runs
 *     inside one base64-dispatched bash script on the node -- the password is
 *     held only in an on-node shell variable, never returned to the build
 *     host, never persisted to disk.
 *   - At RUNTIME the nexus-cli MongoAdapter fetches the same KV value via the
 *     existing VaultClient + VAULT_TOKEN and passes it to mongosh over SSH.
 *
 * createUser path: auth as __system (keyFile content as SCRAM password) --
 * the same root-equivalent bootstrap identity rs-initiate uses -- and route
 * the write to the current PRIMARY via the RS connection string. Idempotent:
 * if the user already exists (re-apply), verify the seeded password still
 * authenticates AND can run rs.status() (proves clusterMonitor took effect).
 *
 * Cross-env ordering (hard): nexus-infra-vmware/envs/security must apply
 * FIRST so (a) nexus/oltp/mongo/operator-password is seeded and (b) the
 * mongo-agent policy grants read on it. Then this oltp-mongo env apply runs.
 *
 * Selective ops: var.enable_mongo_operator_user AND var.enable_mongo_rs_initiate.
 */

locals {
  # Reuses local.mongo_rs_members + local.mongo_bootstrap_ip from
  # role-overlay-mongo-rs-initiate.tf (same module/env -- locals are shared).
  mongo_operator_rs_uri = format(
    "mongodb://%s/admin?replicaSet=nexus-rs",
    join(",", [for ip in local.mongo_rs_members : "${ip}:27017"])
  )
}

resource "null_resource" "mongo_operator_user" {
  count = (
    var.enable_mongo_operator_user && var.enable_mongo_rs_initiate
    && length(local.mongo_rs_members) == 3
  ) ? 1 : 0

  triggers = {
    rs_initiate_id  = null_resource.mongo_rs_initiate[0].id
    bootstrap_ip    = local.mongo_bootstrap_ip
    rs_uri          = local.mongo_operator_rs_uri
    operator_user_v = "2" # v2 (nexus-cli v0.6.1 MongoAdapter, 2026-06-05) = full operator role set clusterMonitor+clusterManager+backup+restore+userAdminAnyDatabase (covers status/failover/scale-out + backup/restore + acl verbs) + idempotent grantRolesToUser on re-apply. v1 = clusterMonitor+clusterManager only. Password read on-node via the node's own Vault Agent token (never to disk); __system keyFile bootstrap auth; RS-URI routes write to PRIMARY.
  }

  depends_on = [null_resource.mongo_rs_initiate]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $bootIp  = '${local.mongo_bootstrap_ip}'
      $sshUser = '${var.oltp_node_user}'

      Write-Host ""
      Write-Host "[mongo-operator-user] bootstrap node = $bootIp ; creating nexus-cluster-admin (clusterMonitor + clusterManager + backup + restore + userAdminAnyDatabase)"

      # Entire createUser runs ON the node so the operator password (read from
      # Vault KV via the node's own agent token) is never returned to the build
      # host nor written to disk. Single-quoted PS here-string => NO PowerShell
      # interpolation; terraform injects its interpolations at plan time; every
      # bash $VAR / $(...) stays literal for the remote shell.
      $bash = @'
set -euo pipefail

# 1. Read the operator password from Vault KV via THIS node's own agent token
#    (mongo-agent policy v3 grants read on nexus/data/oltp/mongo/operator-password).
T=$(sudo cat /run/nexus-vault-agent/token 2>/dev/null)
if [ -z "$T" ]; then echo "ERR_NO_AGENT_TOKEN"; exit 6; fi
OPPWD=$(sudo env VAULT_ADDR=https://192.168.70.121:8200 VAULT_TOKEN="$T" VAULT_CACERT=/etc/nexus-mongo/tls/ca.crt /usr/local/bin/vault kv get -field=content nexus/oltp/mongo/operator-password 2>/dev/null)
if [ -z "$OPPWD" ]; then echo "ERR_NO_OPERATOR_PASSWORD"; exit 7; fi

# 2. __system cluster auth (keyFile content as SCRAM password) -- the same
#    root-equivalent bootstrap identity rs-initiate uses for createUser.
KF=$(sudo cat /etc/nexus-mongo/keyfile 2>/dev/null | tr -d '\n')
if [ "$${#KF}" -lt 100 ]; then echo "ERR_NO_KEYFILE"; exit 8; fi

TLS="--tls --tlsCAFile /etc/nexus-mongo/tls/ca.crt --tlsCertificateKeyFile /etc/nexus-mongo/tls/server.pem"
RSURI="__RS_URI__"

# 3. createUser routes to PRIMARY via the RS URI. Idempotent: catch dup-user.
#    Roles = the least privilege covering the full nexus-cli MongoAdapter verb
#    surface: clusterMonitor (rs.status / health / topology), clusterManager
#    (rs.stepDown / rs.add / rs.remove), backup (mongodump), restore
#    (mongorestore), userAdminAnyDatabase (acl getUsers / createUser / grantRoles).
ROLES="[{role:'clusterMonitor',db:'admin'},{role:'clusterManager',db:'admin'},{role:'backup',db:'admin'},{role:'restore',db:'admin'},{role:'userAdminAnyDatabase',db:'admin'}]"
EVAL="try{db.getSiblingDB('admin').createUser({user:'nexus-cluster-admin',pwd:'$OPPWD',roles:$ROLES});print('CREATE_OK')}catch(e){if(e.codeName==='Location51003'||(e.message&&e.message.indexOf('already exists')>=0)){print('USER_EXISTS')}else{print('CREATE_ERROR:'+e.message)}}"
OUT=$(sudo mongosh --quiet $TLS --username __system --password "$KF" --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256 "$RSURI" --eval "$EVAL" 2>&1)
echo "$OUT"

case "$OUT" in
  *CREATE_OK*)
    echo "[mongo-operator-user] nexus-cluster-admin created with the full operator role set"
    ;;
  *USER_EXISTS*)
    echo "[mongo-operator-user] nexus-cluster-admin already exists (idempotent re-apply) -- converging roles + verifying auth..."
    # grantRolesToUser is idempotent (granting an already-held role is a no-op);
    # this makes a role-set change in this overlay take effect on re-apply.
    GRANT="db.getSiblingDB('admin').grantRolesToUser('nexus-cluster-admin',$ROLES);print('ROLES_OK')"
    GOUT=$(sudo mongosh --quiet $TLS --username __system --password "$KF" --authenticationDatabase local --authenticationMechanism SCRAM-SHA-256 "$RSURI" --eval "$GRANT" 2>&1)
    echo "$GOUT"
    case "$GOUT" in *ROLES_OK*) : ;; *) echo "ERR_GRANT_ROLES"; exit 12 ;; esac
    PROBE=$(sudo mongosh --quiet $TLS --username nexus-cluster-admin --password "$OPPWD" --authenticationDatabase admin "$RSURI" --eval "print('RSOK='+rs.status().ok)" 2>&1)
    echo "$PROBE"
    case "$PROBE" in
      *RSOK=1*) echo "[mongo-operator-user] nexus-cluster-admin auth + rs.status OK -- user in sync with Vault KV" ;;
      *) echo "ERR_AUTH_MISMATCH"; exit 9 ;;
    esac
    ;;
  *)
    echo "ERR_CREATE_FAILED"; exit 10
    ;;
esac

# 4. Final assertion: operator user can run rs.status() (clusterMonitor proof).
FINAL=$(sudo mongosh --quiet $TLS --username nexus-cluster-admin --password "$OPPWD" --authenticationDatabase admin "$RSURI" --eval "var s=rs.status();var p=0;s.members.forEach(function(m){if(m.stateStr=='PRIMARY')p++});print('PRIMARIES='+p+' MEMBERS='+s.members.length)" 2>&1)
echo "$FINAL"
case "$FINAL" in
  *"PRIMARIES=1 MEMBERS=3"*) echo "[mongo-operator-user] OK -- nexus-cluster-admin verified against the live RS (1 PRIMARY, 3 members)" ;;
  *) echo "ERR_FINAL_RSSTATUS"; exit 11 ;;
esac
'@

      # Inject the terraform-computed RS URI via a placeholder so the
      # single-quoted bash body stays free of terraform-interpolation tokens.
      $bash = $bash.Replace('__RS_URI__', '${local.mongo_operator_rs_uri}')

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      $sshOpts = @('-o','ConnectTimeout=20','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $output = ssh @sshOpts "$sshUser@$bootIp" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[mongo-operator-user] createUser/verify failed on $bootIp (rc=$rc). See output above + handbook s3.x (mongo operator-user troubleshooting)."
      }
      Write-Host "[mongo-operator-user] OK -- nexus-cluster-admin ready for the nexus-cli MongoAdapter"
    PWSH
  }

  # No destroy provisioner: the user lives in admin.system.users (preserved
  # with the RS data); full env destroy via modules/vm takes the VMs + disks.
}
