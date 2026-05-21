# role-overlay-iscsi-attach.tf -- Phase 0.G.7
#
# FCI nodes only (sql-fci-1/2). Attaches the iSCSI LUN exported by
# nexus-gateway's tgt target (per nexus-infra-vmware foundation env's
# role-overlay-gateway-iscsi-sqlfci.tf) to both FCI nodes.
#
# Per-node steps:
#   1. Start msiscsi service + set Automatic startup.
#   2. New-IscsiTargetPortal -TargetPortalAddress 192.168.70.1 -InitiatorPortalAddress <vmnet11>.
#   3. Set up CHAP secret (from C:\ProgramData\nexus\sql\creds\iscsi-chap-secret.txt
#      rendered by vault-agents stage; CHAP user = sql-fci-initiator).
#   4. Connect-IscsiTarget -NodeAddress iqn.2026-05.local.nexus:sql-fci.lun1
#      -IsPersistent $true.
#   5. On sql-fci-1 only: Initialize-Disk + New-Partition + Format-Volume
#      (NTFS, 64K cluster size, GPT). The disk becomes the cluster shared
#      volume after WSFC bootstrap.
#   6. On sql-fci-2: just attach the existing partition (no format -- would
#      destroy sql-fci-1's data).
#
# Idempotent: probes for existing session/disk before attempting.

resource "null_resource" "iscsi_attach" {
  for_each = var.enable_iscsi_attach ? local.fci_nodes : {}

  triggers = {
    host    = each.key
    tls_id  = length(null_resource.sqlserver_tls) > 0 ? null_resource.sqlserver_tls[each.key].id : "disabled"
    stage_v = var.iscsi_attach_v
  }

  depends_on = [null_resource.sqlserver_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName      = '${each.key}'
      $ip        = '${each.value.vmnet11}'
      $vmnet10   = '${each.value.vmnet10}'
      $sshUser   = '${var.ssh_username}'

      Write-Host "[iscsi-attach] $hostName : attaching iSCSI LUN from nexus-gateway..."

      # Format-Volume is done on sql-fci-1 ONLY (the lower-IP node);
      # sql-fci-2 just attaches the same LUN.
      #
      # IMPORTANT: $isPrimary is intentionally a STRING ('$true' / '$false'),
      # NOT a boolean. The here-string @"..."@ below interpolates this value
      # at the build-host side; if it were a [bool], it would render as the
      # literal text "True"/"False" which the remote PowerShell would parse
      # as command names (NOT as the built-in $true/$false booleans), making
      # both `if` and `elseif` branches silently fall through. Storing the
      # string '$true' makes the interpolation produce the PS literal token.
      # Pre-emptive fix flagged at 0.G.7 ratify 2026-05-21 during downstream
      # overlay audit.
      $isPrimary = if ($hostName -eq 'sql-fci-1') { '$true' } else { '$false' }

      $remote = @"
`$ErrorActionPreference = 'Stop';
# Stage 1: msiscsi service
Set-Service -Name msiscsi -StartupType Automatic;
Start-Service -Name msiscsi -ErrorAction SilentlyContinue;

# Stage 2: target portal (idempotent)
if (-not (Get-IscsiTargetPortal -TargetPortalAddress 192.168.70.1 -ErrorAction SilentlyContinue)) {
  New-IscsiTargetPortal -TargetPortalAddress 192.168.70.1 -InitiatorPortalAddress $ip;
}

# Stage 3: CHAP secret
`$chapSecret = (Get-Content 'C:/ProgramData/nexus/sql/creds/iscsi-chap-secret.txt' -Raw).Trim();
if (-not `$chapSecret -or `$chapSecret.Length -lt 12) { throw 'iSCSI CHAP secret missing/short -- vault-agents stage failed?' }
Set-IscsiChapSecret -ChapSecret `$chapSecret;

# Stage 4: connect (idempotent)
`$existingSession = Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { `$_.TargetNodeAddress -match 'sql-fci.lun1' };
if (-not `$existingSession) {
  Connect-IscsiTarget -NodeAddress 'iqn.2026-05.local.nexus:sql-fci.lun1' ``
    -TargetPortalAddress 192.168.70.1 ``
    -AuthenticationType ONEWAYCHAP ``
    -ChapUsername 'sql-fci-initiator' ``
    -ChapSecret `$chapSecret ``
    -IsPersistent `$true | Out-Null;
  Write-Output 'CONNECTED_TO_LUN';
} else {
  Write-Output 'ALREADY_CONNECTED';
}
Start-Sleep -Seconds 5;

# Stage 5+6: disk initialization (sql-fci-1 only) or attach (sql-fci-2).
`$disks = Get-Disk | Where-Object { `$_.BusType -eq 'iSCSI' -and `$_.OperationalStatus -ne 'Online' -or `$_.PartitionStyle -eq 'RAW' };
`$rawDisk = `$disks | Select-Object -First 1;
if ($isPrimary -and `$rawDisk) {
  Initialize-Disk -Number `$rawDisk.Number -PartitionStyle GPT;
  `$part = New-Partition -DiskNumber `$rawDisk.Number -UseMaximumSize -DriveLetter S;
  Format-Volume -DriveLetter S -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel 'SQL_FCI_SHARED' -Confirm:`$false | Out-Null;
  Write-Output 'DISK_FORMATTED_S:';
} elseif (-not $isPrimary -and `$rawDisk) {
  # Online the disk on the secondary node (no format).
  Set-Disk -Number `$rawDisk.Number -IsOffline `$false;
  Set-Disk -Number `$rawDisk.Number -IsReadOnly `$false;
  Write-Output 'DISK_ONLINED_SECONDARY';
} else {
  Write-Output 'DISK_ALREADY_INITIALIZED';
}
"@

      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
      $output = ssh -o ConnectTimeout=30 "$sshUser@$ip" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      Write-Host $output.Trim()
      if ($LASTEXITCODE -ne 0) { throw "[iscsi-attach] $hostName : iSCSI attach failed (rc=$LASTEXITCODE)" }
      Write-Host "[iscsi-attach] $hostName : LUN attached (S:\\ SQL_FCI_SHARED)"
    PWSH
  }
}
