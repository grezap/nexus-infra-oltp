/*
 * role-overlay-percona-tls.tf -- Phase 0.G.3 (chunk 3b) -- Percona +
 *   ProxySQL mTLS cert render + 4 KV cluster-creds render
 *
 * Drops Vault Agent template files on each of the 5 percona-tier hosts:
 *
 *   - 70-template-percona-tls.hcl  -- per-host PKI leaf from pki_int/issue/
 *     percona-server. Renders /etc/nexus-percona/tls/bundle.pem; the post-
 *     render command splits into THREE files (vs mongo's combined .pem):
 *       - server-cert.pem  = LEAF only
 *       - server-key.pem   = PKCS#8 KEY
 *       - ca.pem           = intermediate ({{ .CA }}) + root (from
 *                            /etc/vault-agent/ca-bundle.crt)
 *     MySQL + ProxySQL both require 3 separate files (ssl-cert / ssl-key /
 *     ssl-ca my.cnf directives). Mongo took a combined .pem; Percona/
 *     MySQL needs them split.
 *
 *   - 71-template-cluster-password.hcl  -- KV pull of nexus/data/oltp/
 *     percona/cluster-password.content. Used as the wsrep_sst_auth user
 *     password by PXC nodes; used as the backend mysql_users password by
 *     ProxySQL nodes. Both roles read the same secret.
 *
 *   - 72-template-monitor-password.hcl  -- KV pull of nexus/data/oltp/
 *     percona/monitor-password.content. Used by the clustercheck user that
 *     ProxySQL queries via mysql_galera_hostgroups to detect node health.
 *     Both roles read the same secret.
 *
 *   - 73 (role-dependent):
 *       PXC nodes:        73-template-root-password.hcl
 *                         (KV pull nexus/data/oltp/percona/root-password,
 *                          used by initial mysql_secure_installation +
 *                          operator ops)
 *       ProxySQL nodes:   73-template-proxysql-admin-password.hcl
 *                         (KV pull nexus/data/oltp/percona/proxysql-admin-
 *                          password, used by ProxySQL :6032 admin auth)
 *
 * Why the 3-file TLS split (vs mongo's combined .pem):
 *   MySQL + ProxySQL both require three separate directives:
 *     ssl-cert = /etc/nexus-percona/tls/server-cert.pem
 *     ssl-key  = /etc/nexus-percona/tls/server-key.pem
 *     ssl-ca   = /etc/nexus-percona/tls/ca.pem
 *   The combined .pem (mongo's tlsCertificateKeyFile) isn't supported.
 *   Same Vault PKI source, different post-render assembly.
 *
 * Why PKCS#8 (vs MySQL's accepted PKCS#1):
 *   Lab convention -- all 0.G clusters standardize on PKCS#8 (redis +
 *   mongo precedent). MySQL accepts both PKCS#1 and PKCS#8 since 5.7;
 *   ProxySQL accepts both since 2.0.
 *
 * Why the VIP IP SAN for ProxySQL nodes (192.168.70.50):
 *   keepalived may land the VIP on either ProxySQL node at any moment.
 *   Apps connecting to the VIP perform TLS handshake against the
 *   ProxySQL node currently holding it -- the cert MUST cover the VIP
 *   for the handshake to validate. PXC nodes never hold the VIP, so
 *   their cert only covers their own VMnet11 IP + VMnet10 backplane IP.
 *
 * Choreography (per host, sequential):
 *   1. Install /usr/local/sbin/percona-tls-split.sh.
 *   2. Drop the 4 template stanzas (70 + 71 + 72 + role-dependent 73).
 *   3. Restart nexus-vault-agent.service to pick up the new templates.
 *   4. Wait for bundle.pem + 3 KV secrets to render.
 *   5. Manually invoke the split script (pkiCert is cached -- restart
 *      with unchanged cert does NOT fire command-on-render).
 *   6. Verify the 3 split files exist + leaf CN matches.
 *
 * Idempotency: a re-apply re-runs steps 3-6. Step 3 restart is
 * no-op-fast; step 4 wait succeeds immediately if files exist; step 5
 * manual split re-emits identical files; step 6 verification passes.
 *
 * Cert rotation: 90-day TTL per pki_int/roles/percona-server. The
 * Vault Agent renews the leaf mid-life, re-renders bundle.pem, fires
 * the split script. MySQL/Percona auto-reloads TLS certs on
 * `ALTER INSTANCE RELOAD TLS` (handled by the 0.G.x cert-rotate verb
 * in nexus-cli, out of scope here). ProxySQL auto-reloads on SIGHUP.
 *
 * Reachability invariant: this overlay does not touch the network.
 *
 * Selective ops: var.enable_percona_tls AND var.enable_percona_vault_agents.
 */

locals {
  percona_tls_per_host = {
    "pxc-node-1" = { vmnet10 = "192.168.10.51", vmnet11 = "192.168.70.51", role = "pxc", vip = "" }
    "pxc-node-2" = { vmnet10 = "192.168.10.52", vmnet11 = "192.168.70.52", role = "pxc", vip = "" }
    "pxc-node-3" = { vmnet10 = "192.168.10.53", vmnet11 = "192.168.70.53", role = "pxc", vip = "" }
    "proxysql-1" = { vmnet10 = "192.168.10.54", vmnet11 = "192.168.70.54", role = "proxysql", vip = "192.168.70.50" }
    "proxysql-2" = { vmnet10 = "192.168.10.55", vmnet11 = "192.168.70.55", role = "proxysql", vip = "192.168.70.50" }
  }

  percona_tls_active = {
    for host, spec in local.percona_tls_per_host : host => spec
    if(
      var.enable_percona_tls && var.enable_percona_vault_agents
      && lookup(local.percona_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "percona_tls" {
  for_each = local.percona_tls_active

  triggers = {
    va_id         = null_resource.percona_vault_agent[each.key].id
    pki_role_name = var.vault_pki_percona_role_name
    vmnet10       = each.value.vmnet10
    vmnet11       = each.value.vmnet11
    role          = each.value.role
    vip           = each.value.vip
    percona_tls_v = "1" # v1 (0.G.3) = initial 3-file TLS split (server-cert + server-key + ca) + 4 template stanzas (TLS + 3 KV secrets per role). ProxySQL nodes get VIP 192.168.70.50 in IP SANs; PXC nodes don't.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.percona_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $role     = '${each.value.role}'
      $vip      = '${each.value.vip}'
      $pkiRole  = '${var.vault_pki_percona_role_name}'
      $sshUser  = '${var.oltp_node_user}'
      $cn       = "$hostName.percona.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$hostName.percona.nexus.lab,localhost"
      # ProxySQL nodes: include VIP .50 in IP SANs so handshakes against the
      # floating VIP validate regardless of which node currently holds it.
      # PXC nodes: just their own IPs (they never hold the VIP).
      $ipSans   = if ($vip) { "$vmnet10,$ip,$vip,127.0.0.1" } else { "$vmnet10,$ip,127.0.0.1" }
      # Owner group differs by role -- mysql for PXC (apt installs the mysql
      # group with percona-xtradb-cluster-server), proxysql for ProxySQL.
      $ownerGroup = if ($role -eq 'pxc') { 'mysql' } else { 'proxysql' }
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[percona-tls $hostName] cert render + 3 KV cred renders via Vault Agent templates (role=$role, ipSans=$ipSans)"

      # ─── Split script (single-quoted literal) ────────────────────────────
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/nexus-percona/tls/bundle.pem
DEST=/etc/nexus-percona/tls
OWNER_GROUP="$${1:-mysql}"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Split bundle.pem into per-PEM-block files.
awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

LEAF=""
KEY=""
CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*)
      KEY=$f
      ;;
    *"BEGIN CERTIFICATE"*)
      if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi
      ;;
  esac
done

if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[percona-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

# Standardize key on PKCS#8 (lab convention; MySQL accepts PKCS#1 too).
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

# Three-file split: server-cert + server-key + ca (intermediate+root).
# MySQL + ProxySQL both require 3 separate ssl-* directives.
cat "$LEAF" > "$TMP/server-cert.pem"
cat "$TMP/key-pkcs8.pem" > "$TMP/server-key.pem"

ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[percona-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first (role-overlay-percona-vault-agents.tf)" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca.pem"

# Install with role-specific group ownership ($1 from template post-cmd).
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/server-cert.pem" "$DEST/server-cert.pem"
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/server-key.pem"  "$DEST/server-key.pem"
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/ca.pem"          "$DEST/ca.pem"

# Operator-readable CA at /etc/ssl/certs/ (mirrors redis + mongo lesson).
install -m 0644 -o root -g root "$TMP/ca.pem" /etc/ssl/certs/percona-ca.pem

echo "[percona-tls-split] $(date -u +%FT%TZ) bundle split (owner=$OWNER_GROUP): server-cert.pem + server-key.pem (PKCS#8) + ca.pem (intermediate+root)"
'@

      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── 70-template-percona-tls.hcl ─── per-host PKI leaf ────────────────
      $vaultTlsTemplate = @"
# 70-template-percona-tls.hcl -- Phase 0.G.3 (rendered for $hostName, role=$role).
# Issues a Percona/ProxySQL leaf cert from pki_int/roles/$pkiRole and writes
# one bundle file; the post-render command splits into 3 files (server-cert
# + server-key + ca) owned by $ownerGroup.

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/nexus-percona/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "$ownerGroup"
  command         = "/usr/local/sbin/percona-tls-split.sh $ownerGroup"
  command_timeout = "30s"
}
"@
      $vaTlsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultTlsTemplate -replace "`r`n","`n")))

      # ─── 71-template-cluster-password.hcl ─── KV pull (both roles) ───────
      $vaClusterPwdTemplate = @"
# 71-template-cluster-password.hcl -- Phase 0.G.3 (rendered for $hostName, role=$role).
# Pulls the 32-char hex wsrep_sst password from KV at
# nexus/oltp/percona/cluster-password (sticky-seeded by nexus-infra-vmware
# security env's role-overlay-vault-percona-cluster-creds-seed.tf).
# PXC: used by wsrep_sst_auth mysql user for Galera SST/IST.
# ProxySQL: used by mysql_users to dial PXC backends.

template {
  contents = <<EOT
{{- with secret `"nexus/data/oltp/percona/cluster-password`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "/etc/nexus-percona/cluster-password"
  perms       = "0400"
  user        = "root"
  group       = "$ownerGroup"
}
"@
      $vaClusterPwdB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaClusterPwdTemplate -replace "`r`n","`n")))

      # ─── 72-template-monitor-password.hcl ─── KV pull (both roles) ───────
      $vaMonitorPwdTemplate = @"
# 72-template-monitor-password.hcl -- Phase 0.G.3 (rendered for $hostName, role=$role).
# Pulls the 32-char hex clustercheck monitor password from KV at
# nexus/oltp/percona/monitor-password. ProxySQL's mysql_galera_hostgroups
# uses this user to detect PXC node health via wsrep_local_state_comment.
# PXC: createUser at galera-bootstrap time.
# ProxySQL: mysql-monitor_password admin var.

template {
  contents = <<EOT
{{- with secret `"nexus/data/oltp/percona/monitor-password`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "/etc/nexus-percona/monitor-password"
  perms       = "0400"
  user        = "root"
  group       = "$ownerGroup"
}
"@
      $vaMonitorPwdB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaMonitorPwdTemplate -replace "`r`n","`n")))

      # ─── 73-template-<role-specific>-password.hcl ─── KV pull (role-split) ─
      # PXC nodes: root-password (for initial mysql_secure_installation +
      # operator ops). ProxySQL nodes: proxysql-admin-password (for the
      # :6032 admin interface).
      if ($role -eq 'pxc') {
        $vaThirdPwdTemplate = @"
# 73-template-root-password.hcl -- Phase 0.G.3 (rendered for $hostName).
# Pulls the 32-char hex mysql root password from KV at
# nexus/oltp/percona/root-password (sticky-seeded by nexus-infra-vmware
# security env). Used by the galera-cluster-bootstrap overlay for the
# initial mysql_secure_installation-equivalent flow + later operator ops.
# NEVER written into my.cnf directly -- read-only file consumed by the
# bootstrap script + later by operator-level rotate flows.

template {
  contents = <<EOT
{{- with secret `"nexus/data/oltp/percona/root-password`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "/etc/nexus-percona/root-password"
  perms       = "0400"
  user        = "root"
  group       = "$ownerGroup"
}
"@
        $vaThirdPwdFile = "73-template-root-password.hcl"
        $vaThirdPwdDest = "/etc/nexus-percona/root-password"
      } else {
        $vaThirdPwdTemplate = @"
# 73-template-proxysql-admin-password.hcl -- Phase 0.G.3 (rendered for $hostName).
# Pulls the 32-char hex ProxySQL :6032 admin password from KV at
# nexus/oltp/percona/proxysql-admin-password (sticky-seeded by nexus-
# infra-vmware security env). Used by the proxysql-config overlay
# (chunk 3d) to set admin-admin_credentials at config-render time.

template {
  contents = <<EOT
{{- with secret `"nexus/data/oltp/percona/proxysql-admin-password`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "/etc/nexus-percona/proxysql-admin-password"
  perms       = "0400"
  user        = "root"
  group       = "$ownerGroup"
}
"@
        $vaThirdPwdFile = "73-template-proxysql-admin-password.hcl"
        $vaThirdPwdDest = "/etc/nexus-percona/proxysql-admin-password"
      }
      $vaThirdPwdB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaThirdPwdTemplate -replace "`r`n","`n")))

      # Stage: install split + drop all 4 templates + restart vault-agent +
      # wait for all 4 render targets + manual split.
      $stage = @"
set -euo pipefail

# Pre-flight: role-specific user/group must exist (apt-installed by Packer
# at chunk 4 -- defensive create here in case the apt install hasn't run
# yet on a partial apply).
if [ '$ownerGroup' = 'mysql' ]; then
  if ! getent group mysql >/dev/null; then sudo groupadd --system mysql; fi
  if ! getent passwd mysql >/dev/null; then sudo useradd --system --gid mysql --no-create-home --shell /usr/sbin/nologin mysql; fi
else
  if ! getent group proxysql >/dev/null; then sudo groupadd --system proxysql; fi
  if ! getent passwd proxysql >/dev/null; then sudo useradd --system --gid proxysql --no-create-home --shell /usr/sbin/nologin proxysql; fi
fi

sudo mkdir -p /etc/nexus-percona/tls
sudo chown root:$ownerGroup /etc/nexus-percona /etc/nexus-percona/tls
sudo chmod 0750 /etc/nexus-percona /etc/nexus-percona/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/percona-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/percona-tls-split.sh
sudo chmod 0755 /usr/local/sbin/percona-tls-split.sh

echo '$vaTlsB64' | base64 -d | sudo tee /etc/vault-agent/70-template-percona-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-percona-tls.hcl
sudo chmod 0644 /etc/vault-agent/70-template-percona-tls.hcl

echo '$vaClusterPwdB64' | base64 -d | sudo tee /etc/vault-agent/71-template-cluster-password.hcl > /dev/null
sudo chown root:root /etc/vault-agent/71-template-cluster-password.hcl
sudo chmod 0644 /etc/vault-agent/71-template-cluster-password.hcl

echo '$vaMonitorPwdB64' | base64 -d | sudo tee /etc/vault-agent/72-template-monitor-password.hcl > /dev/null
sudo chown root:root /etc/vault-agent/72-template-monitor-password.hcl
sudo chmod 0644 /etc/vault-agent/72-template-monitor-password.hcl

echo '$vaThirdPwdB64' | base64 -d | sudo tee /etc/vault-agent/$vaThirdPwdFile > /dev/null
sudo chown root:root /etc/vault-agent/$vaThirdPwdFile
sudo chmod 0644 /etc/vault-agent/$vaThirdPwdFile

sudo systemctl restart nexus-vault-agent.service

# Wait for ALL FOUR render targets, then manually invoke split.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if sudo test -s /etc/nexus-percona/tls/bundle.pem \
     && sudo test -s /etc/nexus-percona/cluster-password \
     && sudo test -s /etc/nexus-percona/monitor-password \
     && sudo test -s $vaThirdPwdDest; then break; fi
  sleep 2
done
if ! sudo test -s /etc/nexus-percona/tls/bundle.pem; then
  echo "[percona-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
if ! sudo test -s /etc/nexus-percona/cluster-password; then
  echo "[percona-tls stage] ERROR: cluster-password not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
if ! sudo test -s /etc/nexus-percona/monitor-password; then
  echo "[percona-tls stage] ERROR: monitor-password not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
if ! sudo test -s $vaThirdPwdDest; then
  echo "[percona-tls stage] ERROR: $vaThirdPwdDest not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/percona-tls-split.sh $ownerGroup
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[percona-tls $hostName] cert + KV creds render stage failed (rc=$LASTEXITCODE)"
      }

      # Verify 3 split TLS files + 3 KV secrets + CN.
      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s /etc/nexus-percona/tls/server-cert.pem && sudo test -s /etc/nexus-percona/tls/server-key.pem && sudo test -s /etc/nexus-percona/tls/ca.pem && sudo test -s /etc/nexus-percona/cluster-password && sudo test -s /etc/nexus-percona/monitor-password && sudo test -s $vaThirdPwdDest && sudo openssl x509 -in /etc/nexus-percona/tls/server-cert.pem -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[percona-tls $hostName] cert+3 KV secrets not rendered (CN=$cn) within 60s"
      }
      Write-Host "[percona-tls $hostName] rendered: server-cert.pem (CN=$cn) + server-key.pem (PKCS#8) + ca.pem (intermediate+root) + 3 KV secrets"
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
      Write-Host "[percona-tls destroy] $${hostName}: removing 70-73 templates + cert/keys + 3 KV secret files + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-percona-tls.hcl /etc/vault-agent/71-template-cluster-password.hcl /etc/vault-agent/72-template-monitor-password.hcl /etc/vault-agent/73-template-root-password.hcl /etc/vault-agent/73-template-proxysql-admin-password.hcl /etc/nexus-percona/tls/bundle.pem /etc/nexus-percona/tls/server-cert.pem /etc/nexus-percona/tls/server-key.pem /etc/nexus-percona/tls/ca.pem /etc/nexus-percona/cluster-password /etc/nexus-percona/monitor-password /etc/nexus-percona/root-password /etc/nexus-percona/proxysql-admin-password /etc/ssl/certs/percona-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
