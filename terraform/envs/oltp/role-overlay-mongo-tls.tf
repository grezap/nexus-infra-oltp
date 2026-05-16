/*
 * role-overlay-mongo-tls.tf -- Phase 0.G.2 -- MongoDB RS mTLS cert render
 *                              + replica set keyFile render
 *
 * Drops TWO Vault Agent template files on each of the 3 mongo nodes:
 *
 *   1. 70-template-mongo-tls.hcl  -- per-host PKI leaf from pki_int/issue/
 *      mongo-server. Renders /etc/nexus-mongo/tls/bundle.pem; the post-
 *      render command splits into:
 *        - server.pem  = LEAF + PKCS#8 KEY (combined PEM, mongod's
 *                        required --tlsCertificateKeyFile shape)
 *        - ca.crt      = intermediate (from {{ .CA }}) + root (from
 *                        /etc/vault-agent/ca-bundle.crt). The intermediate+
 *                        root fix that 0.G.1 ratification surfaced --
 *                        OpenSSL strict X509 verify requires walking up to
 *                        a self-signed trust anchor. MongoDB's TLS stack is
 *                        OpenSSL on Linux so the same fix applies.
 *
 *   2. 71-template-mongo-keyfile.hcl -- pulls
 *      nexus/data/oltp/mongo/keyfile.content (KV-v2 path) → renders
 *      /etc/nexus-mongo/keyfile (1024-char base64). MongoDB replica set
 *      internal auth uses this shared secret. Mode 0400 mongodb:mongodb
 *      (mongod refuses to start otherwise).
 *
 * Why server.pem combined (vs Redis's 3 separate files):
 *   MongoDB's `--tlsCertificateKeyFile` parameter takes ONE PEM file
 *   containing both the cert and the private key concatenated. Redis 7.x
 *   takes three separate files (`tls-cert-file` / `tls-key-file` /
 *   `tls-ca-cert-file`). Same Vault PKI source, different post-render
 *   assembly. The PKCS#8 key conversion is shared with redis (mongo's
 *   OpenSSL accepts both PKCS#1 and PKCS#8 but PKCS#8 is the platform
 *   canonical).
 *
 * Choreography (per host, sequential):
 *   1. Install /usr/local/sbin/mongo-tls-split.sh (post-render command).
 *   2. Drop 70-template-mongo-tls.hcl + 71-template-mongo-keyfile.hcl.
 *   3. Restart nexus-vault-agent.service to pick up the new templates.
 *   4. Wait for bundle.pem + keyfile to render (Vault Agent template
 *      scan loop ~1s).
 *   5. Manually invoke the split script (pkiCert results are cached --
 *      a restart with unchanged cert does NOT fire command-on-render).
 *   6. Verify the 3 .pem files exist + leaf CN matches.
 *
 * Idempotency: a re-apply re-runs steps 3-6. Step 3 restart is
 * no-op-fast; step 4 wait succeeds immediately if files exist; step 5
 * manual split re-emits identical files; step 6 verification passes.
 *
 * Cert rotation: 90-day TTL per pki_int/roles/mongo-server. The Vault
 * Agent renews the leaf mid-life, re-renders bundle.pem, fires the
 * split script. mongod does NOT auto-reload TLS certs on file change --
 * reload requires `db.adminCommand({rotateCertificates: 1})` via mongosh,
 * handled by the 0.G.x cert-rotate verb in nexus-cli (out of scope here).
 *
 * Reachability invariant: this overlay does not touch the network.
 *
 * Selective ops: var.enable_mongo_tls AND var.enable_mongo_vault_agents.
 */

locals {
  mongo_tls_per_host = {
    "mongo-1" = { vmnet10 = "192.168.10.71", vmnet11 = "192.168.70.71" }
    "mongo-2" = { vmnet10 = "192.168.10.72", vmnet11 = "192.168.70.72" }
    "mongo-3" = { vmnet10 = "192.168.10.73", vmnet11 = "192.168.70.73" }
  }

  mongo_tls_active = {
    for host, spec in local.mongo_tls_per_host : host => spec
    if(
      var.enable_mongo && var.enable_mongo_tls && var.enable_mongo_vault_agents
      && lookup(local.mongo_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "mongo_tls" {
  for_each = local.mongo_tls_active

  triggers = {
    va_id         = null_resource.mongo_vault_agent[each.key].id
    pki_role_name = var.vault_pki_mongo_role_name
    vmnet10       = each.value.vmnet10
    vmnet11       = each.value.vmnet11
    mongo_tls_v   = "2" # v2 (0.G.2 ratification fix 2026-05-17) = +3rd template stanza renders /etc/nexus-mongo/smoke-user-password from KV nexus/oltp/mongo/smoke-user-password (sticky-seeded by nexus-infra-vmware security env's role-overlay-vault-mongo-smoke-user-seed.tf). Used by the rs-initiate overlay to create the smoke-rw RBAC user + by the smoke gate to auth as that user. v1 = initial straight-to-mTLS render with server.pem + ca.crt + keyfile only.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.mongo_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $pkiRole  = '${var.vault_pki_mongo_role_name}'
      $sshUser  = '${var.oltp_node_user}'
      $cn       = "$hostName.mongo.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$hostName.mongo.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[mongo-tls $hostName] cert render + keyFile render via Vault Agent templates"

      # ─── Split script (single-quoted literal) ────────────────────────────
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/nexus-mongo/tls/bundle.pem
DEST=/etc/nexus-mongo/tls
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
  echo "[mongo-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

# Standardize key on PKCS#8 (same as redis; idempotent).
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

# server.pem = LEAF + PKCS#8 KEY (combined; mongod's tlsCertificateKeyFile
# shape). Order matters: leaf first, key second is the canonical layout
# (mongod accepts both orders but leaf-first is operator-friendly).
cat "$LEAF" "$TMP/key-pkcs8.pem" > "$TMP/server.pem"

# ca.crt = intermediate ($CA from pkiCert bundle) + root (from the Vault
# Agent CA bundle). OpenSSL strict X509 verify needs to walk to a self-
# signed root anchor; the intermediate alone is not enough. Same fix as
# the 0.G.1 redis-tls-split.sh (memory/feedback_redis_tls_chain not yet
# saved -- the lesson lives in nexus-infra-oltp/docs/handbook.md §3.x).
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[mongo-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first (role-overlay-mongo-vault-agents.tf)" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"

# Install with mongodb group ownership (the apt-installed mongodb-org
# package creates the mongodb user+group; nexus-mongo.service runs as that
# user).
install -m 0640 -o root -g mongodb "$TMP/server.pem"   "$DEST/server.pem"
install -m 0640 -o root -g mongodb "$TMP/ca-chain.pem" "$DEST/ca.crt"

# Operator-readable CA at /etc/ssl/certs/ (mirrors redis lesson).
install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/mongo-ca.pem

echo "[mongo-tls-split] $(date -u +%FT%TZ) bundle split: server.pem (combined leaf+key) + ca.crt (intermediate+root) (+ /etc/ssl/certs/mongo-ca.pem)"
'@

      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── 70-template-mongo-tls.hcl ─── per-host PKI leaf ─────────────────
      $vaultTlsTemplate = @"
# 70-template-mongo-tls.hcl -- Phase 0.G.2 (rendered for $hostName).
# Issues a MongoDB leaf cert from pki_int/roles/$pkiRole and writes one
# bundle file; the post-render command splits into server.pem (combined
# leaf+key) + ca.crt (intermediate+root).

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/nexus-mongo/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "mongodb"
  command         = "/usr/local/sbin/mongo-tls-split.sh"
  command_timeout = "30s"
}
"@
      $vaTlsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultTlsTemplate -replace "`r`n","`n")))

      # ─── 71-template-mongo-keyfile.hcl ─── KV pull, no post-cmd ──────────
      # KV-v2 path is nexus/data/oltp/mongo/keyfile (the policy/template
      # path); .Data.data.content is the value field. Vault Agent's template
      # engine handles the KV-v2 envelope.
      $vaKeyfileTemplate = @"
# 71-template-mongo-keyfile.hcl -- Phase 0.G.2 (rendered for $hostName).
# Pulls the 1024-char base64 RS internal-auth keyFile from KV at
# nexus/oltp/mongo/keyfile (seeded by nexus-infra-vmware/security/
# role-overlay-vault-mongo-keyfile-seed.tf). Used by mongod's
# security.keyFile directive for replica set authentication.

template {
  contents = <<EOT
{{- with secret `"nexus/data/oltp/mongo/keyfile`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "/etc/nexus-mongo/keyfile"
  perms       = "0400"
  user        = "mongodb"
  group       = "mongodb"
}
"@
      $vaKeyfileB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaKeyfileTemplate -replace "`r`n","`n")))

      # ─── 72-template-mongo-smoke-user-password.hcl ─── KV pull, no post-cmd ─
      # 0.G.2 ratification fix: pulls the smoke-rw user's password from KV
      # at nexus/oltp/mongo/smoke-user-password. Consumed by the rs-initiate
      # overlay's createUser flow + by the smoke gate's auth.
      $vaSmokePwdTemplate = @"
# 72-template-mongo-smoke-user-password.hcl -- Phase 0.G.2 ratification fix.
# Pulls the 32-char base64 smoke-rw user password from KV at
# nexus/oltp/mongo/smoke-user-password (seeded by nexus-infra-vmware
# security env's role-overlay-vault-mongo-smoke-user-seed.tf). Used by the
# rs-initiate overlay to create the smoke-rw user during the localhost-
# auth-bypass bootstrap window, and by the smoke gate to auth as that user.

template {
  contents = <<EOT
{{- with secret `"nexus/data/oltp/mongo/smoke-user-password`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "/etc/nexus-mongo/smoke-user-password"
  perms       = "0400"
  user        = "mongodb"
  group       = "mongodb"
}
"@
      $vaSmokePwdB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaSmokePwdTemplate -replace "`r`n","`n")))

      # Stage: install split + drop all three templates + restart vault-agent +
      # wait for all three files + manual split.
      $stage = @"
set -euo pipefail

# Pre-flight: mongodb group must exist (apt-installed mongodb-org creates
# it). Defensive create if a clone somehow missing it lands here.
if ! getent group mongodb >/dev/null; then
  sudo groupadd --system mongodb
fi
if ! getent passwd mongodb >/dev/null; then
  sudo useradd --system --gid mongodb --no-create-home --shell /usr/sbin/nologin mongodb
fi

sudo mkdir -p /etc/nexus-mongo/tls
sudo chown root:mongodb /etc/nexus-mongo /etc/nexus-mongo/tls
sudo chmod 0750 /etc/nexus-mongo /etc/nexus-mongo/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/mongo-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/mongo-tls-split.sh
sudo chmod 0755 /usr/local/sbin/mongo-tls-split.sh

echo '$vaTlsB64' | base64 -d | sudo tee /etc/vault-agent/70-template-mongo-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-mongo-tls.hcl
sudo chmod 0644 /etc/vault-agent/70-template-mongo-tls.hcl

echo '$vaKeyfileB64' | base64 -d | sudo tee /etc/vault-agent/71-template-mongo-keyfile.hcl > /dev/null
sudo chown root:root /etc/vault-agent/71-template-mongo-keyfile.hcl
sudo chmod 0644 /etc/vault-agent/71-template-mongo-keyfile.hcl

echo '$vaSmokePwdB64' | base64 -d | sudo tee /etc/vault-agent/72-template-mongo-smoke-user-password.hcl > /dev/null
sudo chown root:root /etc/vault-agent/72-template-mongo-smoke-user-password.hcl
sudo chmod 0644 /etc/vault-agent/72-template-mongo-smoke-user-password.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait for ALL THREE render targets, then manually invoke split.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if sudo test -s /etc/nexus-mongo/tls/bundle.pem \
     && sudo test -s /etc/nexus-mongo/keyfile \
     && sudo test -s /etc/nexus-mongo/smoke-user-password; then break; fi
  sleep 2
done
if ! sudo test -s /etc/nexus-mongo/tls/bundle.pem; then
  echo "[mongo-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
if ! sudo test -s /etc/nexus-mongo/keyfile; then
  echo "[mongo-tls stage] ERROR: keyfile not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
if ! sudo test -s /etc/nexus-mongo/smoke-user-password; then
  echo "[mongo-tls stage] ERROR: smoke-user-password not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/mongo-tls-split.sh
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[mongo-tls $hostName] cert + keyFile render stage failed (rc=$LASTEXITCODE)"
      }

      # Verify cert files + keyFile + smoke-user-password + CN.
      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s /etc/nexus-mongo/tls/server.pem && sudo test -s /etc/nexus-mongo/tls/ca.crt && sudo test -s /etc/nexus-mongo/keyfile && sudo test -s /etc/nexus-mongo/smoke-user-password && sudo openssl x509 -in /etc/nexus-mongo/tls/server.pem -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[mongo-tls $hostName] cert+keyFile+smoke-pwd not rendered (CN=$cn) within 60s"
      }
      Write-Host "[mongo-tls $hostName] rendered: server.pem (CN=$cn) + ca.crt (intermediate+root) + keyfile (1024-char base64) + smoke-user-password (32-char)"
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
      Write-Host "[mongo-tls destroy] $${hostName}: removing 70+71+72 templates + cert/keyfile/smoke-pwd + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-mongo-tls.hcl /etc/vault-agent/71-template-mongo-keyfile.hcl /etc/vault-agent/72-template-mongo-smoke-user-password.hcl /etc/nexus-mongo/tls/bundle.pem /etc/nexus-mongo/tls/server.pem /etc/nexus-mongo/tls/ca.crt /etc/nexus-mongo/keyfile /etc/nexus-mongo/smoke-user-password /etc/ssl/certs/mongo-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
