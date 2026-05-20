/*
 * oltp-sqlserver-node -- SQL Server FCI + Always On AG node template (Phase 0.G.7).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 4 clones at terraform apply time:
 *   sql-fci-1, sql-fci-2 -- WSFC FCI pair sharing iSCSI LUN at .70.16
 *   sql-ag-rep-1, sql-ag-rep-2 -- AG async replicas (local storage)
 *
 *   - OS: Windows Server 2025 Desktop Experience -- cloned from the
 *     ws2025-desktop.vmx baked by nexus-infra-vmware Phase 0.B.5. Inherits:
 *       * OpenSSH server + nexusadmin authorized_keys (per
 *         _shared/powershell/scripts/01-nexus-identity.ps1)
 *       * Windows Firewall baseline (per 03-nexus-firewall.ps1)
 *       * node_exporter for Prometheus (per 04-nexus-observability.ps1)
 *       * Windows baseline tweaks (per 05-windows-baseline.ps1)
 *   - SQL Server: 2025 Enterprise Developer Edition (free for dev/test;
 *     full Enterprise features incl. AlwaysOn AG sync-commit, encryption,
 *     columnstore, Iceberg lakehouse-native query). Decision sealed
 *     2026-05-20 -- SQL 2025 picked over 2022 to align with WS2025 OS +
 *     leverage newest AG enhancements. Per ADR-0144 (MSDN). Silent
 *     install via setup.exe.
 *   - Windows features added: Failover-Clustering, Multipath-IO,
 *     iSCSI-Initiator. Needed by the WSFC bootstrap (all 4 nodes) + FCI
 *     pair's iSCSI session against nexus-gateway.
 *   - Default RAM at bake time: 4 GB (per memory/feedback_prefer_less_memory.md).
 *     Steady-state per vms.yaml is 16 GB (FCI nodes) / 12 GB (AG replicas)
 *     -- set at clone time by terraform once modules/vm gains the
 *     memory_mb resize step (currently reserved-not-applied per
 *     modules/vm/README.md).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): vmware-vmx clone of ws2025-desktop.vmx,
 *     boot through OOBE (sysprep-rendered unattend.xml), SSH in as
 *     nexusadmin, run 3 provisioners (SQL install, cluster features,
 *     firstboot stage), sysprep again, shutdown. Template artifact lands
 *     at H:/VMS/NexusPlatform/_templates/oltp-sqlserver-node/.
 *   - Clone-time (terraform/modules/vm): clone the .vmx; modules/vm needs
 *     the Windows path extension (added at Phase 0.G.7 stage 5) to wait
 *     for SSH instead of cloud-init firstboot marker.
 *   - First-boot (C:\\ProgramData\\nexus\\sql\\firstboot.ps1, staged by this
 *     template's 12-firstboot-stage.ps1): MAC-OUI-byte-5 NIC discovery +
 *     IP-to-hostname mapping (cluster=sqlserver; writes node-identity.env
 *     + computes whether this node is sql-fci-1/2/sql-ag-rep-1/2 from its
 *     VMnet11 IP). Runs as a scheduled task on first OOBE boot only.
 *   - Cluster bring-up (terraform/envs/oltp-sqlserver/role-overlay-*.tf):
 *     sqlserver-nftables-backplane -> sqlserver-domain-join ->
 *     sqlserver-vault-agents -> sqlserver-tls -> iscsi-attach (FCI only)
 *     -> wsfc-bootstrap -> fci-install (FCI only) -> ag-bootstrap ->
 *     ag-listener. See nexus-infra-oltp/docs/handbook.md §1.2 for the full
 *     cross-env operator order.
 *
 * Build:   cd packer/oltp-sqlserver-node; packer init .; packer build .
 * Spot-check (after bake completes):
 *   vmrun start <output_dir>/oltp-sqlserver-node.vmx nogui
 *   ssh nexusadmin@<dhcp-IP>  # password: nexus-packer-build-only
 *   Get-Service MSSQLSERVER          # -> Running (DISABLED at clone time)
 *   sqlcmd -E -Q "SELECT @@VERSION"  # -> 2022 Developer
 *   Get-WindowsFeature Failover-Clustering,Multipath-IO,iSCSI-Initiator  # all Installed
 *
 * See: nexus-infra-oltp/docs/handbook.md §1.1 for the build matrix.
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

source "vmware-vmx" "oltp-sqlserver-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  # Clone from the ws2025-desktop.vmx baked at Phase 0.B.5. The source VMX
  # is sysprep'd (generalize /oobe /shutdown) -- our boot here runs through
  # mini-OOBE which consumes the unattend.xml left in C:\\Windows\\System32\\
  # Sysprep\\unattend.xml by the source bake's 99-sysprep step. That unattend
  # reapplies the nexusadmin Local Administrator password (from the source
  # bake's env vars), so our SSH/WinRM connection lands as nexusadmin with
  # the known password.
  source_path = var.source_vmx
  linked      = false # full clone -- avoids dependency on the source VMX
  # at clone time + keeps the per-engine template
  # standalone for the per-cluster apply.

  vmx_data = {
    "annotation"           = "oltp-sqlserver-node template (Phase 0.G.7) -- built by Packer; SQL Server ${var.sql_version} ${var.sql_edition} + Failover-Clustering + Multipath-IO + iSCSI-Initiator on top of ws2025-desktop"
    "tools.upgrade.policy" = "useGlobal"
    # Packer HCL2 has no tostring() function (Terraform does; Packer doesn't).
    # Use ${} interpolation which converts number -> string. Transient #7 at
    # 0.G.7 ratify 2026-05-20.
    "memsize"  = "${var.memory_mb}"
    "numvcpus" = "${var.cpus}"

    # Transient #8 at 0.G.7 ratify: source ws2025-desktop.vmx was baked with
    # vmx_remove_ethernet_interfaces=true so the cloned VM had ZERO NICs ->
    # no IP -> Packer SSH timed out at 30:30. The vmware-vmx builder does
    # NOT auto-add NICs like vmware-iso does. Add a build-time NAT NIC via
    # vmx_data so the OOBE-completed VM can reach DHCP + Packer can find it
    # via VMware Tools' IP report.
    "ethernet0.present"        = "TRUE"
    "ethernet0.connectionType" = "nat"
    "ethernet0.virtualDev"     = "e1000e"
    "ethernet0.addressType"    = "generated"
    "ethernet0.startConnected" = "TRUE"
  }

  # Strip the build-time NIC from the OUTPUT VMX so terraform/modules/vm's
  # configure-vm-nic.ps1 can add the dual-NIC config at clone time (VMnet11
  # + VMnet10) per the canon pattern. Same as ws2025-desktop's bake.
  vmx_remove_ethernet_interfaces = true

  # OOBE completes within ~3-5 min after power-on; SSH provisioner waits.
  # The source's 01-nexus-identity.ps1 auto-starts sshd + injects
  # nexusadmin's authorized_keys, so SSH-with-password is available as a
  # fallback once the service starts. Communicator is SSH (matches the
  # ADR-0024 SSH-shell-out invariant for runtime ops -- WinRM is bake-time
  # only and is torn down at sysprep).
  communicator = "ssh"
  ssh_username = var.admin_username
  ssh_password = var.admin_password
  ssh_timeout  = var.ssh_timeout
  ssh_pty      = false # Windows OpenSSH doesn't need PTY allocation.

  shutdown_command = "shutdown /s /t 5 /f /d p:4:1 /c \"oltp-sqlserver-node bake complete -- packer shutdown\""
  shutdown_timeout = "10m"

  headless        = true
  skip_compaction = false
}

build {
  name    = "oltp-sqlserver-node"
  sources = ["source.vmware-vmx.oltp-sqlserver-node"]

  # ---------------------------------------------------------------------
  # Stage 1: upload the SQL Server ISO to the guest. Packer's file
  # provisioner uploads via SCP over the SSH session. ISO is ~3.5 GB so
  # the upload takes ~2-3 min over local VMnet8 (NAT).
  #
  # Alternative considered: mounting the ISO as a CD at clone time via
  # vmx_data \"sata0:0.fileName\" = var.sql_iso_path. Rejected because
  # vmware-vmx's vmx_data merge happens BEFORE clone, but the source VMX
  # already has a tools-iso attached -- adding our SQL ISO conflicts. The
  # SCP upload approach is slower but isolates the per-engine layer.
  # ---------------------------------------------------------------------
  provisioner "file" {
    source      = var.sql_iso_path
    destination = "C:/Windows/Temp/sqlserver.iso"
  }

  # ---------------------------------------------------------------------
  # Stage 2: SQL Server silent install. Mounts the uploaded ISO via
  # Mount-DiskImage, runs setup.exe with /Q /ACTION=Install /IACCEPT
  # SQLSERVERLICENSETERMS, waits for completion, validates the engine
  # responds to sqlcmd -E.
  # ---------------------------------------------------------------------
  provisioner "powershell" {
    scripts = [
      "scripts/10-sql-install.ps1"
    ]
    environment_vars = [
      "NEXUS_SQL_VERSION=${var.sql_version}",
      "NEXUS_SQL_EDITION=${var.sql_edition}",
      "NEXUS_SQL_FEATURES=${var.sql_install_features}",
      "NEXUS_SQL_INSTANCE=${var.sql_instance_name}",
      "NEXUS_ISO_PATH=C:/Windows/Temp/sqlserver.iso",
    ]
  }

  # ---------------------------------------------------------------------
  # Stage 3: WSFC + iSCSI Initiator + MPIO features. These Windows
  # optional features need a restart to fully take effect; the
  # windows-restart provisioner triggers the reboot + waits for the
  # SSH service to come back.
  # ---------------------------------------------------------------------
  provisioner "powershell" {
    scripts = [
      "scripts/11-cluster-features.ps1"
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
    # Default check command works for OpenSSH-reachable Windows; Packer
    # waits for SSH to respond on :22 again.
  }

  # ---------------------------------------------------------------------
  # Stage 4: stage firstboot scripts at C:\\ProgramData\\nexus\\sql\\.
  # The terraform/envs/oltp-sqlserver/role-overlay-*.tf overlays will
  # invoke these scripts on the cloned VMs over SSH to do cluster-time
  # work (TLS material render, WSFC bootstrap, AG creation, etc.).
  # ---------------------------------------------------------------------
  provisioner "powershell" {
    scripts = [
      "scripts/12-firstboot-stage.ps1"
    ]
  }

  # ---------------------------------------------------------------------
  # Stage 5: cleanup + re-sysprep.
  # - Stop MSSQLSERVER service + set it to Manual (cluster bring-up
  #   re-enables it after the GMSA service identity is set).
  # - Wipe Temp + ISO upload.
  # - Run sysprep /generalize /oobe /shutdown via the SAME deferred-task
  #   pattern as ws2025-desktop's 99-sysprep.ps1, so that clones boot
  #   through mini-OOBE + land as nexusadmin with the known password.
  # The valid_exit_codes mirror ws2025-desktop -- sysprep emits non-zero
  # under several harmless conditions (already-generalized component
  # store, etc.) but Windows still completes the operation correctly.
  # ---------------------------------------------------------------------
  provisioner "powershell" {
    inline = [
      "# Stop SQL Server -- clones start it under the GMSA after WSFC bootstrap",
      "Stop-Service -Name MSSQLSERVER -Force -ErrorAction SilentlyContinue",
      "Set-Service -Name MSSQLSERVER -StartupType Manual",
      "# Wipe staged ISO + Temp",
      "Remove-Item -Force -ErrorAction SilentlyContinue C:/Windows/Temp/sqlserver.iso",
      "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'C:/Windows/Temp/*' -Exclude 'packer-*'",
      "Clear-DnsClientCache",
      "Write-Host '=== oltp-sqlserver-node bake complete; deferring sysprep ==='"
    ]
    environment_vars = [
      "NEXUS_ADMIN_USERNAME=${var.admin_username}",
      "NEXUS_ADMIN_PASSWORD=${var.admin_password}",
    ]
  }

  # Re-run the shared sysprep via Packer's powershell -- the deferred task
  # pattern from ws2025-desktop's 99-sysprep is what actually fires the
  # generalize. The script lives in the SOURCE repo (nexus-infra-vmware);
  # we INLINE a simplified version here since the cross-repo path doesn't
  # resolve in the CI checkout of nexus-infra-oltp. The simplified version
  # writes the unattend.xml + schedules sysprep via Register-ScheduledTask.
  provisioner "powershell" {
    inline = [
      "$adminUser = $env:NEXUS_ADMIN_USERNAME",
      "$adminPass = $env:NEXUS_ADMIN_PASSWORD",
      "if (-not $adminUser -or -not $adminPass) { throw 'NEXUS_ADMIN_USERNAME/PASSWORD must be set for sysprep unattend' }",
      "$unattend = @\"",
      "<?xml version='1.0' encoding='utf-8'?>",
      "<unattend xmlns='urn:schemas-microsoft-com:unattend' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>",
      "  <settings pass='oobeSystem'>",
      "    <component name='Microsoft-Windows-Shell-Setup' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS'>",
      "      <OOBE>",
      "        <HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>",
      "        <NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE>",
      "      </OOBE>",
      "      <UserAccounts><AdministratorPassword><Value>$adminPass</Value><PlainText>true</PlainText></AdministratorPassword><LocalAccounts><LocalAccount wcm:action='add'><Password><Value>$adminPass</Value><PlainText>true</PlainText></Password><Description>NexusPlatform admin</Description><DisplayName>$adminUser</DisplayName><Group>Administrators</Group><Name>$adminUser</Name></LocalAccount></LocalAccounts></UserAccounts>",
      "      <TimeZone>UTC</TimeZone>",
      "    </component>",
      "    <component name='Microsoft-Windows-International-Core' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS'><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>",
      "  </settings>",
      "</unattend>",
      "\"@",
      "$unattendPath = 'C:\\Windows\\System32\\Sysprep\\unattend.xml'",
      "Set-Content -Path $unattendPath -Value $unattend -Encoding utf8",
      "$deferredCmd = \"& '$env:WINDIR\\System32\\Sysprep\\sysprep.exe' /generalize /oobe /shutdown /quiet /unattend:'$unattendPath'\"",
      "$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deferredCmd))",
      "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument \"-NoProfile -WindowStyle Hidden -EncodedCommand $encoded\"",
      "$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(60)",
      "$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount",
      "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable",
      "Register-ScheduledTask -TaskName 'NexusDeferredSysprep-SQL' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null",
      "Write-Host '=== oltp-sqlserver-node sysprep scheduled (T+60s); returning so Packer can drain ==='"
    ]
    environment_vars = [
      "NEXUS_ADMIN_USERNAME=${var.admin_username}",
      "NEXUS_ADMIN_PASSWORD=${var.admin_password}",
    ]
    valid_exit_codes = [0, 1, 2, 259, 2147942402]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
