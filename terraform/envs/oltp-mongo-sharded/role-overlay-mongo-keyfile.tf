# Phase 0.N -- shared keyFile distribution.
#
# Simpler than the 0.G.2 per-host Vault Agent pattern: fetch the keyFile
# content from Vault KV (nexus/oltp/mongo/keyfile, sticky-seeded by the
# security env in 0.G.2) on the build host, then SCP to each of the 11
# sharded-mongo nodes. The same keyFile is shared across the entire sharded
# cluster (config-server RS + shard-1 RS + shard-2 RS + mongos all auth each
# other with this secret -- MongoDB requirement).
#
# Why no Vault Agent (0.N.1 enhancement):
#   The 0.G.2 RS uses per-host Vault Agent + AppRole to render keyFile and
#   per-host PKI leaf certs. Extending that pattern to 11 nodes would require
#   provisioning 11 new AppRoles + 11 JSON sidecars in the security env --
#   substantial scope. 0.N v1 distributes the keyFile directly from the build
#   host (operator has Vault CLI + root token). 0.N.1 adds per-host Vault
#   Agent + mTLS to bring the sharded cluster to parity with the 0.G.2 RS
#   posture.

locals {
  # The KV path holding the shared MongoDB RS keyFile. Sticky-seeded by
  # nexus-infra-vmware/terraform/envs/security/role-overlay-vault-mongo-keyfile-seed.tf
  # in 0.G.2 -- the 1024-char base64 content is the same canonical value.
  mongo_keyfile_kv_path = "nexus/oltp/mongo/keyfile"

  # pathexpand for the Vault token + CA bundle.
  vault_ca_bundle_expanded = pathexpand(replace(var.vault_ca_bundle_path, "$HOME", "~"))
  vault_init_keys_expanded = pathexpand(replace(var.vault_init_keys_path, "$HOME", "~"))
}

resource "null_resource" "mongo_keyfile" {
  for_each = var.enable_mongo_keyfile ? local.sharded_nodes_active : {}

  triggers = {
    nftables_id      = null_resource.mongo_nftables[each.key].id
    kv_path          = local.mongo_keyfile_kv_path
    vmnet11          = each.value.vmnet11
    overlay_v        = "1"
    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.oltp_node_user
  }

  depends_on = [null_resource.mongo_nftables]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName    = '${each.key}'
      $ip          = '${each.value.vmnet11}'
      $sshUser     = '${var.oltp_node_user}'
      $vaultAddr   = '${var.vault_addr}'
      $caBundle    = '${local.vault_ca_bundle_expanded}'
      $initKeys    = '${local.vault_init_keys_expanded}'
      $kvPath      = '${local.mongo_keyfile_kv_path}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      if (-not (Test-Path $initKeys)) { throw "[keyfile $hostName] vault-init.json missing at $initKeys" }
      if (-not (Test-Path $caBundle)) { throw "[keyfile $hostName] vault CA bundle missing at $caBundle" }
      $rootToken = (Get-Content $initKeys | ConvertFrom-Json).root_token
      if (-not $rootToken) { throw "[keyfile $hostName] no root_token in $initKeys" }

      # Fetch keyFile content from Vault KV via the build-host Vault CLI.
      # The seeded KV-v2 path has field "content" (1024-char base64).
      $env:VAULT_ADDR   = $vaultAddr
      $env:VAULT_CACERT = $caBundle
      $env:VAULT_TOKEN  = $rootToken
      $keyfileContent = (& vault kv get -field=content $kvPath 2>&1 | Out-String).Trim()
      if (-not $keyfileContent -or $keyfileContent.Length -lt 100) {
        throw "[keyfile $hostName] vault kv get $kvPath returned short/empty content ($($keyfileContent.Length) chars). Seed nexus-infra-vmware security env first."
      }
      Write-Host "[keyfile $hostName] fetched $($keyfileContent.Length)-char keyfile from KV"

      # Stage to a tmpfile then SCP to /tmp/keyfile, then install with proper perms.
      $tmpFile = New-TemporaryFile
      try {
        [System.IO.File]::WriteAllText($tmpFile.FullName, $keyfileContent)
        scp @sshOpts $tmpFile.FullName "$${sshUser}@$${ip}:/tmp/keyfile"
        if ($LASTEXITCODE -ne 0) { throw "[keyfile $hostName] scp failed (rc=$LASTEXITCODE)" }
      } finally {
        Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
      }

      $stage = @"
set -euo pipefail
sudo install -d -o mongodb -g mongodb -m 0750 /etc/nexus-mongo
sudo install -m 0400 -o mongodb -g mongodb /tmp/keyfile /etc/nexus-mongo/keyfile
sudo rm -f /tmp/keyfile
echo KEYFILE_OK
"@
      $stageLf = $stage -replace "`r`n", "`n"
      $out = ($stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      if ($out -notmatch 'KEYFILE_OK') { throw "[keyfile $hostName] install failed -- $out" }
      Write-Host "[keyfile $hostName] /etc/nexus-mongo/keyfile installed (0400 mongodb:mongodb)"
    PWSH
  }

  # No destroy provisioner: keyfile lives at /etc/nexus-mongo/keyfile;
  # the modules/vm destroy takes the whole VM with it.
}
