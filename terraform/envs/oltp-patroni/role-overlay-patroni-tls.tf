/*
 * role-overlay-patroni-tls.tf -- Phase 0.G.4 -- per-host PKI leaf + KV cred
 * renders for all 8 patroni-tier nodes.
 *
 * Drops Vault Agent template files on each host. Templates differ per role
 * because:
 *   - destination paths differ: /etc/nexus-patroni/tls (patroni nodes),
 *     /etc/nexus-etcd/tls (etcd nodes), /etc/nexus-haproxy/tls (haproxy
 *     pair)
 *   - KV secret set differs:
 *       patroni nodes: etcd-root + patroni-rest + postgres-superuser
 *                      + postgres-replication
 *       etcd nodes:    etcd-root + patroni-rest
 *       haproxy nodes: patroni-rest + haproxy-stats
 *
 * The PKI cert template body (70-*) is structurally identical across
 * roles -- same `pki_int/issue/<patroni_role>` issue call, same per-host
 * CN/SANs -- but each role's `destination =` differs (the role's own
 * tls/bundle.pem path) so the `template { ... }` HCL block is rendered
 * per-role too.
 *
 * Single split script /usr/local/sbin/nexus-patroni-tls-split.sh takes
 * <dest-dir> + <owner-group> as args; same script across all 3 roles.
 *
 * Why the 3-file TLS split: PostgreSQL ssl_cert_file/ssl_key_file/ssl_ca_file
 * + etcd cert-file/key-file/trusted-ca-file + HAProxy crt+ca-file all want
 * separate files (no combined .pem support; vs mongo's tlsCertificateKeyFile
 * which accepts combined). Standardized on PKCS#8 key per lab convention.
 *
 * Why VIP .60 is in haproxy nodes' IP SANs (mirrors 0.G.3 proxysql + VIP
 * .50 pattern): keepalived may land the VIP on either haproxy node. Apps
 * connecting to the VIP perform TLS handshake against the haproxy currently
 * holding it -- the cert MUST cover the VIP for the handshake to validate.
 * Patroni + etcd nodes never hold the VIP, so their certs only cover their
 * own VMnet11 + VMnet10 IPs + 127.0.0.1.
 *
 * Reachability invariant: this overlay does not touch the network.
 *
 * Selective ops: var.enable_patroni_tls AND var.enable_patroni_vault_agents.
 */

locals {
  patroni_tls_per_host = {
    "pg-primary"   = { vmnet10 = "192.168.10.61", vmnet11 = "192.168.70.61", role = "patroni", config_dir = "/etc/nexus-patroni", owner_group = "postgres", vip = "" }
    "pg-replica-1" = { vmnet10 = "192.168.10.62", vmnet11 = "192.168.70.62", role = "patroni", config_dir = "/etc/nexus-patroni", owner_group = "postgres", vip = "" }
    "pg-replica-2" = { vmnet10 = "192.168.10.63", vmnet11 = "192.168.70.63", role = "patroni", config_dir = "/etc/nexus-patroni", owner_group = "postgres", vip = "" }
    "etcd-1"       = { vmnet10 = "192.168.10.64", vmnet11 = "192.168.70.64", role = "etcd", config_dir = "/etc/nexus-etcd", owner_group = "etcd", vip = "" }
    "etcd-2"       = { vmnet10 = "192.168.10.65", vmnet11 = "192.168.70.65", role = "etcd", config_dir = "/etc/nexus-etcd", owner_group = "etcd", vip = "" }
    "etcd-3"       = { vmnet10 = "192.168.10.66", vmnet11 = "192.168.70.66", role = "etcd", config_dir = "/etc/nexus-etcd", owner_group = "etcd", vip = "" }
    "haproxy-pg-1" = { vmnet10 = "192.168.10.67", vmnet11 = "192.168.70.67", role = "haproxy", config_dir = "/etc/nexus-haproxy", owner_group = "haproxy", vip = var.haproxy_vip }
    "haproxy-pg-2" = { vmnet10 = "192.168.10.68", vmnet11 = "192.168.70.68", role = "haproxy", config_dir = "/etc/nexus-haproxy", owner_group = "haproxy", vip = var.haproxy_vip }
  }

  patroni_tls_active = {
    for host, spec in local.patroni_tls_per_host : host => spec
    if(
      var.enable_patroni_tls && var.enable_patroni_vault_agents
      && lookup(local.patroni_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "patroni_tls" {
  for_each = local.patroni_tls_active

  triggers = {
    va_id         = null_resource.patroni_vault_agent[each.key].id
    pki_role_name = var.vault_pki_patroni_role_name
    vmnet10       = each.value.vmnet10
    vmnet11       = each.value.vmnet11
    role          = each.value.role
    config_dir    = each.value.config_dir
    owner_group   = each.value.owner_group
    vip           = each.value.vip
    patroni_tls_v = "2" # v2 (0.G.4) = 8 nodes (3 patroni + 3 etcd + 2 haproxy HA pair); haproxy nodes carry VIP .60 in IP-SANs for VRRP-handshake validation. v1 was the abandoned single-HAProxy variant.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.patroni_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName   = '${each.key}'
      $ip         = '${each.value.vmnet11}'
      $vmnet10    = '${each.value.vmnet10}'
      $role       = '${each.value.role}'
      $configDir  = '${each.value.config_dir}'
      $ownerGroup = '${each.value.owner_group}'
      $vip        = '${each.value.vip}'
      $pkiRole    = '${var.vault_pki_patroni_role_name}'
      $sshUser    = '${var.oltp_node_user}'
      $cn         = "$hostName.patroni.nexus.lab"
      $altNames   = "$hostName,$hostName.nexus.lab,$hostName.patroni.nexus.lab,localhost"
      # HAProxy HA pair nodes carry VIP .60 in IP SANs so handshakes against
      # the floating VIP validate regardless of which haproxy holds it.
      # Patroni + etcd nodes never hold the VIP, so their certs only cover
      # their own VMnet11 + VMnet10 IPs.
      $ipSans     = if ($vip) { "$vmnet10,$ip,$vip,127.0.0.1" } else { "$vmnet10,$ip,127.0.0.1" }
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[patroni-tls $hostName] cert render + KV cred renders via Vault Agent templates (role=$role, configDir=$configDir, ipSans=$ipSans)"

      # ─── Split script (single-quoted literal) ────────────────────────────
      # Takes destDir + ownerGroup as $1 / $2. Same script across all 3 roles.
      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: nexus-patroni-tls-split.sh <dest-dir> <owner-group>}"
OWNER_GROUP="$${2:?usage: nexus-patroni-tls-split.sh <dest-dir> <owner-group>}"
BUNDLE="$DEST/bundle.pem"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

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
  echo "[patroni-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

cat "$LEAF" > "$TMP/server-cert.pem"
cat "$TMP/key-pkcs8.pem" > "$TMP/server-key.pem"

ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[patroni-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca.pem"

install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/server-cert.pem" "$DEST/server-cert.pem"
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/server-key.pem"  "$DEST/server-key.pem"
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/ca.pem"          "$DEST/ca.pem"

install -m 0644 -o root -g root "$TMP/ca.pem" /etc/ssl/certs/patroni-ca.pem

echo "[patroni-tls-split] $(date -u +%FT%TZ) bundle split into $DEST (owner=$OWNER_GROUP)"
'@

      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── 70-template-patroni-tls.hcl ─── per-host PKI leaf ────────────────
      $vaultTlsTemplate = @"
# 70-template-patroni-tls.hcl -- Phase 0.G.4 (rendered for $hostName, role=$role).

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "$configDir/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "$ownerGroup"
  command         = "/usr/local/sbin/nexus-patroni-tls-split.sh $configDir/tls $ownerGroup"
  command_timeout = "30s"
}
"@
      $vaTlsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultTlsTemplate -replace "`r`n","`n")))

      # ─── KV template builder ─────────────────────────────────────────────
      function New-KvTemplate {
        param([string]$Path, [string]$Dest, [string]$OwnerGroup)
        @"
template {
  contents = <<EOT
{{- with secret `"$Path`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "$Dest"
  perms       = "0400"
  user        = "root"
  group       = "$OwnerGroup"
}
"@
      }

      # KV templates depend on role:
      #   patroni: 71 etcd-root, 72 patroni-rest, 73 postgres-superuser, 74 postgres-replication
      #   etcd:    71 etcd-root, 72 patroni-rest
      #   haproxy: 71 patroni-rest, 72 haproxy-stats
      $kvTemplates = @()
      switch ($role) {
        'patroni' {
          $kvTemplates += @{ File = '71-template-etcd-root.hcl';            Body = (New-KvTemplate 'nexus/data/oltp/patroni/etcd-root-password'            "$configDir/etcd-root-password"            $ownerGroup); Dest = "$configDir/etcd-root-password" }
          $kvTemplates += @{ File = '72-template-patroni-rest.hcl';         Body = (New-KvTemplate 'nexus/data/oltp/patroni/patroni-rest-password'         "$configDir/patroni-rest-password"         $ownerGroup); Dest = "$configDir/patroni-rest-password" }
          $kvTemplates += @{ File = '73-template-postgres-superuser.hcl';   Body = (New-KvTemplate 'nexus/data/oltp/patroni/postgres-superuser-password'   "$configDir/postgres-superuser-password"   $ownerGroup); Dest = "$configDir/postgres-superuser-password" }
          $kvTemplates += @{ File = '74-template-postgres-replication.hcl'; Body = (New-KvTemplate 'nexus/data/oltp/patroni/postgres-replication-password' "$configDir/postgres-replication-password" $ownerGroup); Dest = "$configDir/postgres-replication-password" }
        }
        'etcd' {
          $kvTemplates += @{ File = '71-template-etcd-root.hcl';    Body = (New-KvTemplate 'nexus/data/oltp/patroni/etcd-root-password'    "$configDir/etcd-root-password"    $ownerGroup); Dest = "$configDir/etcd-root-password" }
          $kvTemplates += @{ File = '72-template-patroni-rest.hcl'; Body = (New-KvTemplate 'nexus/data/oltp/patroni/patroni-rest-password' "$configDir/patroni-rest-password" $ownerGroup); Dest = "$configDir/patroni-rest-password" }
        }
        'haproxy' {
          $kvTemplates += @{ File = '71-template-patroni-rest.hcl'; Body = (New-KvTemplate 'nexus/data/oltp/patroni/patroni-rest-password' "$configDir/patroni-rest-password" $ownerGroup); Dest = "$configDir/patroni-rest-password" }
          $kvTemplates += @{ File = '72-template-haproxy-stats.hcl'; Body = (New-KvTemplate 'nexus/data/oltp/patroni/haproxy-stats-password' "$configDir/haproxy-stats-password" $ownerGroup); Dest = "$configDir/haproxy-stats-password" }
        }
      }

      # Build the kv-template-drop + wait-render stage script.
      $kvDropLines = @()
      $kvWaitLines = @()
      $kvErrLines  = @()
      foreach ($t in $kvTemplates) {
        $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($t.Body -replace "`r`n","`n")))
        $kvDropLines += "echo '$b64' | base64 -d | sudo tee /etc/vault-agent/$($t.File) > /dev/null"
        $kvDropLines += "sudo chown root:root /etc/vault-agent/$($t.File)"
        $kvDropLines += "sudo chmod 0644 /etc/vault-agent/$($t.File)"
        $kvWaitLines += "&& sudo test -s $($t.Dest)"
        $kvErrLines  += "if ! sudo test -s $($t.Dest); then echo '[patroni-tls stage] ERROR: $($t.Dest) not rendered within 20s' >&2; sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2; exit 1; fi"
      }
      $kvDropBody = ($kvDropLines -join "`n")
      $kvWaitBody = ($kvWaitLines -join " `\\`n     ")
      $kvErrBody  = ($kvErrLines  -join "`n")

      $stage = @"
set -euo pipefail

# Pre-flight: role-specific user/group must exist (apt-installed by Packer
# for postgres/haproxy, useradd by Packer for etcd; defensive create here).
if [ '$ownerGroup' = 'postgres' ]; then
  if ! getent group postgres >/dev/null; then sudo groupadd --system postgres; fi
  if ! getent passwd postgres >/dev/null; then sudo useradd --system --gid postgres --no-create-home --shell /usr/sbin/nologin postgres; fi
elif [ '$ownerGroup' = 'etcd' ]; then
  if ! getent group etcd >/dev/null; then sudo groupadd --system etcd; fi
  if ! getent passwd etcd >/dev/null; then sudo useradd --system --gid etcd --no-create-home --shell /usr/sbin/nologin etcd; fi
else
  if ! getent group haproxy >/dev/null; then sudo groupadd --system haproxy; fi
  if ! getent passwd haproxy >/dev/null; then sudo useradd --system --gid haproxy --no-create-home --shell /usr/sbin/nologin haproxy; fi
fi

sudo mkdir -p $configDir/tls
sudo chown root:$ownerGroup $configDir $configDir/tls
sudo chmod 0750 $configDir $configDir/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/nexus-patroni-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/nexus-patroni-tls-split.sh
sudo chmod 0755 /usr/local/sbin/nexus-patroni-tls-split.sh

echo '$vaTlsB64' | base64 -d | sudo tee /etc/vault-agent/70-template-patroni-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-patroni-tls.hcl
sudo chmod 0644 /etc/vault-agent/70-template-patroni-tls.hcl

$kvDropBody

sudo systemctl restart nexus-vault-agent.service

# Wait for ALL render targets, then manually invoke split.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if sudo test -s $configDir/tls/bundle.pem $kvWaitBody; then break; fi
  sleep 2
done
if ! sudo test -s $configDir/tls/bundle.pem; then
  echo "[patroni-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
$kvErrBody
sudo /usr/local/sbin/nexus-patroni-tls-split.sh $configDir/tls $ownerGroup
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[patroni-tls $hostName] cert + KV creds render stage failed (rc=$LASTEXITCODE)"
      }

      # Verify 3 split TLS files + KV secrets + CN.
      $kvCheckArgs = ($kvTemplates | ForEach-Object { "sudo test -s $($_.Dest)" }) -join " && "
      $verifyDeadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $configDir/tls/server-cert.pem && sudo test -s $configDir/tls/server-key.pem && sudo test -s $configDir/tls/ca.pem && $kvCheckArgs && sudo openssl x509 -in $configDir/tls/server-cert.pem -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[patroni-tls $hostName] cert + KV secrets not rendered (CN=$cn) within 60s"
      }
      Write-Host "[patroni-tls $hostName] rendered: server-cert.pem (CN=$cn) + server-key.pem (PKCS#8) + ca.pem (intermediate+root) + $($kvTemplates.Count) KV secrets"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName  = '${each.key}'
      $vmIp      = '${self.triggers.destroy_vm_ip}'
      $configDir = '${self.triggers.config_dir}'
      $sshUser   = '${self.triggers.destroy_ssh_user}'
      $sshOpts   = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[patroni-tls destroy] $${hostName}: removing 70-74 templates + cert/keys + KV secret files + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-patroni-tls.hcl /etc/vault-agent/71-template-*.hcl /etc/vault-agent/72-template-*.hcl /etc/vault-agent/73-template-*.hcl /etc/vault-agent/74-template-*.hcl $configDir/tls/bundle.pem $configDir/tls/server-cert.pem $configDir/tls/server-key.pem $configDir/tls/ca.pem $configDir/etcd-root-password $configDir/patroni-rest-password $configDir/postgres-superuser-password $configDir/postgres-replication-password $configDir/haproxy-stats-password /etc/ssl/certs/patroni-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
