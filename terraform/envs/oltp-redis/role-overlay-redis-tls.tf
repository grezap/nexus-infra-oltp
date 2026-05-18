/*
 * role-overlay-redis-tls.tf -- Phase 0.G.1 -- Redis Cluster mTLS cert render
 *
 * Drops a per-host Vault Agent PKI template that renders the TLS materials
 * Redis 7.x needs at /etc/nexus-redis/tls/{server.crt,server.key,ca.crt}.
 * Redis is configured TLS-only from cold start (per chunk 3c design --
 * straight-to-mTLS, no PLAINTEXT->mTLS flip needed since redis.conf isn't
 * rendered + nexus-redis.service isn't started until role-overlay-redis-
 * config.tf, which depends on THIS overlay).
 *
 * Vault Agent rendering choreography (per host, sequential):
 *   1. Install /usr/local/sbin/redis-tls-split.sh (the post-render command).
 *   2. Drop /etc/vault-agent/60-template-redis-tls.hcl (one template stanza
 *      issuing a leaf from pki_int/issue/redis-server; writes
 *      /etc/nexus-redis/tls/bundle.pem then invokes the split script).
 *   3. Restart nexus-vault-agent.service to pick up the new template.
 *   4. Wait for /etc/nexus-redis/tls/bundle.pem to render (Vault Agent
 *      template engine picks up the .hcl file on its 1s scan loop).
 *   5. Manually invoke the split script -- pkiCert results are CACHED by
 *      the Vault Agent so a restart with an unchanged cert does NOT fire
 *      command-on-render; manual invocation is idempotent.
 *   6. Verify the three .pem files exist + the leaf CN matches the host.
 *
 * Why 3 files (not Kafka's PEM keystore.pem + truststore.pem bundle):
 *   Redis 7.x's TLS config takes tls-cert-file (leaf), tls-key-file (private
 *   key), tls-ca-cert-file (CA chain) as three SEPARATE PEM file paths. No
 *   keystore concept (unlike Kafka's Java client). The split script lays
 *   them out in that shape.
 *
 * Key format: PKCS#8. Vault PKI issues PKCS#1 keys; OpenSSL (Redis's TLS
 * impl) accepts both, but we standardize on PKCS#8 to mirror the kafka
 * lesson (memory/feedback_vault_agent_template_hcl_heredoc.md) and to keep
 * a single canonical format across the platform.
 *
 * Idempotency: a re-apply on a host with the template already in place
 * re-runs steps 3-6. Step 3 restart is a no-op-fast; step 4 wait succeeds
 * immediately if bundle.pem is already there; step 5 manual split re-emits
 * identical .pem files; step 6 verification passes.
 *
 * Cert rotation: 90-day TTL per pki_int/roles/redis-server. The Vault Agent
 * renews the leaf mid-life (default check interval), re-renders bundle.pem,
 * and fires the split script. Redis itself does NOT auto-reload TLS certs
 * on file change; reload is handled by the 0.G.x cert-rotate verb in
 * nexus-cli (out of scope for 0.G.1) which does CONFIG SET + CONFIG REWRITE.
 *
 * Reachability invariant: this overlay does not touch the network or open
 * any new ports. Build-host SSH unaffected.
 *
 * Selective ops: var.enable_redis_tls AND var.enable_redis_vault_agents.
 */

locals {
  # Per-host SAN/CN data for the Vault Agent PKI template. The redis-server
  # PKI role's allowed_domains covers <host> + <host>.nexus.lab +
  # <host>.redis.nexus.lab + localhost (per nexus-infra-vmware security env's
  # role-overlay-vault-pki-redis.tf -- 21 allowed_domains entries).
  redis_tls_per_host = {
    "redis-1" = { vmnet10 = "192.168.10.81", vmnet11 = "192.168.70.81" }
    "redis-2" = { vmnet10 = "192.168.10.82", vmnet11 = "192.168.70.82" }
    "redis-3" = { vmnet10 = "192.168.10.83", vmnet11 = "192.168.70.83" }
    "redis-4" = { vmnet10 = "192.168.10.84", vmnet11 = "192.168.70.84" }
    "redis-5" = { vmnet10 = "192.168.10.87", vmnet11 = "192.168.70.87" }
    "redis-6" = { vmnet10 = "192.168.10.89", vmnet11 = "192.168.70.89" }
  }

  redis_tls_active = {
    for host, spec in local.redis_tls_per_host : host => spec
    if(
      var.enable_redis_tls && var.enable_redis_vault_agents
      && lookup(local.redis_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "redis_tls" {
  for_each = local.redis_tls_active

  triggers = {
    va_id         = null_resource.redis_vault_agent[each.key].id
    pki_role_name = var.vault_pki_redis_role_name
    vmnet10       = each.value.vmnet10
    vmnet11       = each.value.vmnet11
    redis_tls_v   = "2" # v2 (0.G.1 ratification fix 2026-05-17) = ca.crt is intermediate + root concatenated (was: intermediate only). OpenSSL strict X509 verify requires walking up to a self-signed trust anchor; the intermediate alone is not a valid trust anchor. The root comes from /etc/vault-agent/ca-bundle.crt which the 0.D.2 distribute step already places on every Vault-Agent-host. Diagnosed during live ratification -- Redis log was spamming "tlsv1 alert unknown ca" + redis-cli PING returned "certificate verify failed". v1 = initial straight-to-mTLS render; ca.crt was just `.CA` from Vault pkiCert (intermediate only) -- works for Java SSL (kafka) but not OpenSSL (redis).

    # Frozen for the destroy provisioner.
    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.redis_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $pkiRole  = '${var.vault_pki_redis_role_name}'
      $sshUser  = '${var.oltp_node_user}'
      $cn       = "$hostName.redis.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$hostName.redis.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[redis-tls $hostName] cert render via Vault Agent PKI template"

      # ─── The split script (single-quoted here-string, all literal) ────────
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/nexus-redis/tls/bundle.pem
DEST=/etc/nexus-redis/tls
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Split bundle.pem into per-PEM-block files. awk increments on each BEGIN.
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
  echo "[redis-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

# Vault PKI issues PKCS#1; standardize on PKCS#8 (idempotent: -topk8 on an
# already-PKCS#8 key re-emits it). Redis's OpenSSL accepts both, but a
# single canonical format avoids subtle bugs and mirrors the platform lesson.
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

# Build the full CA trust chain for ca.crt = intermediate ($CA from the
# pkiCert bundle) + root (from the Vault-Agent-distributed bundle at
# /etc/vault-agent/ca-bundle.crt). OpenSSL strict X509 verification (which
# Redis's TLS uses) requires walking up to a SELF-SIGNED trust anchor; the
# intermediate alone is not a valid anchor and verification fails with
# "unable to get issuer certificate" / "tlsv1 alert unknown ca". Kafka's
# Java SSL stack treats any cert in the trust store as a valid anchor (no
# upchain walk required), which is why kafka's truststore.pem can be the
# intermediate only -- but redis's OpenSSL is stricter. Diagnosed during
# 0.G.1 live ratification (2026-05-17).
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[redis-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first (role-overlay-redis-vault-agents.tf)" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"

# Three separate PEM files per Redis's tls-cert-file / tls-key-file /
# tls-ca-cert-file shape.
install -m 0640 -o root -g redis "$LEAF"              "$DEST/server.crt"
install -m 0640 -o root -g redis "$TMP/key-pkcs8.pem" "$DEST/server.key"
install -m 0640 -o root -g redis "$TMP/ca-chain.pem"  "$DEST/ca.crt"

# Operator-readable copy of the CA chain. /etc/nexus-redis/ is 0750
# root:redis so nexusadmin cannot traverse it; a world-readable copy lets
# a CLI run as nexusadmin still chain-verify if needed.
install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/redis-ca.pem

echo "[redis-tls-split] $(date -u +%FT%TZ) bundle split: server.crt + server.key + ca.crt (intermediate+root) (+ /etc/ssl/certs/redis-ca.pem)"
'@

      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── Per-host Vault Agent PKI template ────────────────────────────────
      # Double-quoted here-string so $pkiRole/$cn/$altNames/$ipSans
      # interpolate; HCL quotes inside the contents block are backtick-
      # escaped per memory/feedback_terraform_heredoc_powershell.md +
      # feedback_vault_agent_template_hcl_heredoc.md.
      $vaultAgentTemplate = @"
# 60-template-redis-tls.hcl -- Phase 0.G.1 (rendered for $hostName).
# Issues a Redis leaf cert from pki_int/roles/$pkiRole and writes one bundle
# file; the post-render command splits it into server.crt + server.key +
# ca.crt (the three files Redis 7.x's TLS config takes).

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/nexus-redis/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "redis"
  command         = "/usr/local/sbin/redis-tls-split.sh"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      # stage: install split script + drop VA template + restart agent + wait
      # + run split. Piped to ssh stdin + `bash -s` per memory/feedback_ssh_
      # stage1_size_limit.md (~6KB argv cliff; well within here but stdin-
      # pipe is the canonical robust transit anyway).
      $stage = @"
set -euo pipefail

# Pre-flight: the redis group MUST exist before the Vault Agent template
# writes bundle.pem with group=redis. oltp-node Packer template's baseline
# creates the redis user+group at bake time; if a clone somehow missing it
# lands here, create the system user defensively.
if ! getent group redis >/dev/null; then
  sudo groupadd --system redis
fi
if ! getent passwd redis >/dev/null; then
  sudo useradd --system --gid redis --no-create-home --shell /usr/sbin/nologin redis
fi

sudo mkdir -p /etc/nexus-redis/tls
sudo chown root:redis /etc/nexus-redis/tls
sudo chmod 0750 /etc/nexus-redis/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/redis-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/redis-tls-split.sh
sudo chmod 0755 /usr/local/sbin/redis-tls-split.sh

echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-redis-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-redis-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-redis-tls.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait for bundle.pem, then run the split manually -- pkiCert results are
# CACHED by the Vault Agent, so a restart with an unchanged cert does NOT
# fire the command-on-render trigger. Manual invocation is idempotent.
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/nexus-redis/tls/bundle.pem && break
  sleep 2
done
if ! sudo test -s /etc/nexus-redis/tls/bundle.pem; then
  echo "[redis-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/redis-tls-split.sh
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[redis-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)"
      }

      # Wait for the cert files + verify the CN.
      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s /etc/nexus-redis/tls/server.crt && sudo test -s /etc/nexus-redis/tls/server.key && sudo test -s /etc/nexus-redis/tls/ca.crt && sudo openssl x509 -in /etc/nexus-redis/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[redis-tls $hostName] cert files not rendered (CN=$cn) within 60s"
      }
      Write-Host "[redis-tls $hostName] cert rendered (CN=$cn); server.crt + server.key + ca.crt in place"
    PWSH
  }

  # Destroy: remove the per-host Vault Agent template + the cert files. The
  # split script stays (cheap to leave; would only matter on a future flip
  # to a different cert layout). Mirrors kafka-tls's surgical destroy.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[redis-tls destroy] $${hostName}: removing 60-template-redis-tls.hcl + cert files + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-redis-tls.hcl /etc/nexus-redis/tls/bundle.pem /etc/nexus-redis/tls/server.crt /etc/nexus-redis/tls/server.key /etc/nexus-redis/tls/ca.crt /etc/ssl/certs/redis-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
