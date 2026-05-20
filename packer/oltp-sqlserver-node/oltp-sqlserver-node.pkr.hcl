/*
 * oltp-sqlserver-node -- SQL Server FCI + Always On AG node template (Phase 0.G.7).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 4 clones at terraform apply time:
 *   sql-fci-1, sql-fci-2 -- WSFC FCI pair sharing iSCSI LUN at .70.16
 *   sql-ag-rep-1, sql-ag-rep-2 -- AG async replicas (local storage)
 *
 *   - OS: Windows Server 2025 Standard (Desktop Experience) -- built end-to-end
 *     from ISO via vmware-iso. Mirrors nexus-infra-vmware/packer/ws2025-desktop
 *     verbatim; the 5 shared baseline scripts are copied into
 *     nexus-infra-oltp/packer/_shared/powershell/ (one-time DRY violation;
 *     self-contained; matches the per-engine canon shape).
 *   - SQL Server: 2025 Enterprise Developer Edition (free for dev/test; full
 *     Enterprise features incl. AlwaysOn AG sync-commit, encryption,
 *     columnstore, Iceberg lakehouse-native query). Per ADR-0144 (MSDN).
 *     Silent install via setup.exe. Decision sealed 2026-05-20.
 *   - Windows features added: Failover-Clustering, Multipath-IO,
 *     iSCSI-Initiator. Needed by WSFC bootstrap (all 4 nodes) + FCI pair's
 *     iSCSI session against nexus-gateway.
 *
 * Why vmware-iso (not vmware-vmx clone-from-baked-ws2025-desktop):
 *   The vmware-vmx clone approach (initial 0.G.7 scaffold attempt) hit a wall
 *   at ratify-time -- Packer's vmware-vmx builder doesn't auto-add NICs the
 *   way vmware-iso does, and the source ws2025-desktop.vmx is baked with
 *   vmx_remove_ethernet_interfaces=true so the clone had ZERO NICs -> no IP
 *   -> 30:30 SSH timeout. Even vmx_data NIC injection didn't survive the
 *   clone+sysprep+OOBE chain. The vmware-vmx pattern works for terraform/
 *   modules/vm (vmrun clone + configure-vm-nic.ps1 + power on) but NOT for
 *   Packer's pipeline. Transient #8 at 0.G.7 ratify 2026-05-20 -- pivoted to
 *   vmware-iso 2026-05-20 (~3-4h rewrite).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): vmware-iso install of WS2025 from ISO,
 *     Autounattend-automated OOBE, 5 shared Nexus baseline scripts (identity
 *     +network+firewall+observability+windows-baseline), 3 SQL-specific
 *     provisioners (sql-install + cluster-features + firstboot-stage), then
 *     99-sysprep /generalize /oobe /shutdown. Output:
 *     H:/VMS/NexusPlatform/_templates/oltp-sqlserver-node/oltp-sqlserver-node.vmx
 *   - Clone-time (terraform/modules/vm): vmrun clone + configure-vm-nic.ps1
 *     adds dual-NIC (VMnet11 + VMnet10) post-clone -- exactly like dc-nexus
 *     and the jumpbox.
 *   - First-boot (C:\ProgramData\nexus\sql\firstboot.ps1 + NexusSqlFirstboot
 *     scheduled task -- staged by 12-firstboot-stage.ps1): MAC-OUI-byte-5
 *     NIC discovery + IP-to-hostname mapping + computer rename + VMnet10
 *     static IP.
 *
 * Build:   cd packer/oltp-sqlserver-node; packer init .; packer build .
 * Bake time: ~60 min real-time (WS install ~25 min + baseline ~10 min +
 *   SQL install ~18 min + cluster features ~5 min + sysprep ~2 min).
 *
 * See: nexus-infra-oltp/docs/handbook.md §1.1 + §3.5 for the build matrix
 *      + the transient chronology (12 transients during 0.G.7 ratify).
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

# ─── Derived locals: ISO + image + product key per product_source ─────────
# Same product_source contract as ws2025-desktop:
#   product_source = "evaluation" -> "Windows Server 2025 Standard Evaluation (Desktop Experience)"
#   product_source = "msdn"        -> "Windows Server 2025 Standard (Desktop Experience)"
locals {
  iso_path = (
    var.product_source == "msdn"
    ? var.iso_path_msdn
    : var.iso_path_evaluation
  )

  iso_checksum = (
    var.product_source == "msdn"
    ? var.iso_checksum_msdn
    : var.iso_checksum_evaluation
  )

  image_name = (
    var.product_source == "msdn"
    ? "Windows Server 2025 Standard (Desktop Experience)"
    : "Windows Server 2025 Standard Evaluation (Desktop Experience)"
  )

  # bootstrap_keys_file is a pre-Phase-0.D fallback JSON shape (same as
  # ws2025-desktop's). MSDN key landed here under the "ws2025-desktop" key
  # since this template reuses the WS2025 Desktop install.wim image.
  product_key = (
    var.product_source == "evaluation"
    ? ""
    : var.bootstrap_keys_file != ""
    ? jsondecode(file(var.bootstrap_keys_file))["ws2025-desktop"]["key"]
    : ""
  )

  # Render the Autounattend.xml from the shared template (same one ws2025-
  # desktop uses; copied into nexus-infra-oltp/packer/_shared/powershell/
  # floppy/ during the 0.G.7 ratify pivot 2026-05-20).
  #
  # computer_name = var.bake_computer_name -- NOT var.vm_name, because
  # var.vm_name ("oltp-sqlserver-node", 19 chars) exceeds the NetBIOS
  # 15-char limit + Windows Setup rejects the Autounattend during the
  # specialize pass (hrResult 0x80220005 "Value is invalid" against
  # Microsoft-Windows-Shell-Setup). Transient #10 at 0.G.7 ratify
  # 2026-05-20 -- per memory/feedback_windows_ssh_automation.md the
  # NetBIOS-15-char limit is the first of 5 structural patterns. The
  # template VM's computer name is irrelevant at runtime; clones rename
  # to sql-fci-1/2/sql-ag-rep-1/2 (11-12 chars, all NetBIOS-valid) via
  # firstboot.ps1 + Rename-Computer.
  autounattend_xml = templatefile("${path.root}/../_shared/powershell/floppy/Autounattend.xml.tpl", {
    image_name          = local.image_name
    product_key         = local.product_key
    admin_username      = var.admin_username
    admin_password      = var.admin_password
    computer_name       = var.bake_computer_name
    bypass_win11_checks = false
  })
}

# ─── Source: WS2025 (Desktop Experience), VMware Workstation builder ─────
source "vmware-iso" "oltp_sqlserver_node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = local.iso_path
  iso_checksum = local.iso_checksum

  guest_os_type = "windows2022srv-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0
  # WS2025 WinPE has no PVSCSI driver in-box -- same constraint as ws2025-desktop.
  disk_adapter_type = "lsisas1068"

  network_adapter_type = "e1000e"
  network              = "nat"

  version  = "20"
  firmware = "efi"

  floppy_content = {
    "Autounattend.xml" = local.autounattend_xml
  }
  floppy_files = [
    "../_shared/powershell/scripts/bootstrap-winrm.ps1"
  ]

  # Transient #11 at 0.G.7 ratify 2026-05-20: WinRM file-provisioner upload
  # of the 1.2 GB SQL ISO hits "Couldn't create shell: received error
  # response" -- WinRM's MaxShellsPerUser=30 exhausts quickly because
  # Packer's winrmcp opens a fresh shell per chunk. WinRM file uploads
  # for files >500 MB are fundamentally brittle. Canonical Packer
  # workaround: serve large files over HTTP via http_directory + use
  # Invoke-WebRequest inside the guest (skips the WinRM channel entirely).
  # Pointing at H:/VMS/ISO makes ALL ISOs in that dir HTTP-accessible
  # during the bake; only the SQL one is consumed by 10-sql-install.ps1.
  http_directory = "H:/VMS/ISO"

  # Same EFI Boot Manager -> CDROM nav as ws2025-desktop; WS2025 ISOs behave
  # identically across editions.
  boot_wait = "90s"
  boot_command = [
    "<down><down><enter>",
    "<wait3><spacebar>",
    "<wait5><enter>",
  ]

  communicator   = "winrm"
  winrm_username = var.admin_username
  winrm_password = var.admin_password
  winrm_insecure = true
  winrm_use_ssl  = false
  winrm_timeout  = var.winrm_timeout
  winrm_port     = 5985

  shutdown_command = "powershell -NoProfile -Command \"Write-Host 'sysprep handled shutdown; waiting'\""
  shutdown_timeout = "30m"

  # headless=true is the canonical bake mode (matches ws2025-desktop + the
  # deb13/oltp-* templates). During the 0.G.7 ratify debug cycle 2026-05-20
  # this was flipped to false for VNC-driven specialize-pass diagnosis
  # (transient #10); now flipped back to true since the install + OOBE +
  # baseline path is proven through transient #11 (the SQL-ISO HTTP fix).
  headless = true

  tools_mode        = "attach"
  tools_source_path = "C:/Program Files (x86)/VMware/VMware Workstation/windows.iso"

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "oltp-sqlserver-node template (Phase 0.G.7) -- built by Packer; SQL Server ${var.sql_version} ${var.sql_edition} + Failover-Clustering + Multipath-IO + iSCSI-Initiator on top of WS2025 Desktop"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + shared baseline + SQL + sysprep ──────────────────
build {
  name    = "oltp-sqlserver-node"
  sources = ["source.vmware-iso.oltp_sqlserver_node"]

  # ── Stage authorized_keys (shared file) ──
  provisioner "file" {
    source      = "../_shared/powershell/files/nexusadmin-authorized_keys"
    destination = "C:/Windows/Temp/nexusadmin-authorized_keys"
  }

  # ── VMware Tools first ──
  provisioner "powershell" {
    scripts = [
      "../_shared/powershell/scripts/00-install-vmware-tools.ps1"
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ── Shared Nexus baseline (same 5 scripts as ws2025-desktop) ──
  provisioner "powershell" {
    scripts = [
      "../_shared/powershell/scripts/01-nexus-identity.ps1",
      "../_shared/powershell/scripts/02-nexus-network.ps1",
      "../_shared/powershell/scripts/03-nexus-firewall.ps1",
      "../_shared/powershell/scripts/04-nexus-observability.ps1",
      "../_shared/powershell/scripts/05-windows-baseline.ps1",
    ]
    environment_vars = [
      "NEXUS_ADMIN_USERNAME=${var.admin_username}",
      "NEXUS_TEMPLATE_NAME=${var.vm_name}",
      "NEXUS_PHASE=0.G.7",
    ]
  }

  # ── SQL Server 2025 Enterprise Developer silent install ──
  # ISO is fetched from Packer's HTTP server (http_directory = H:/VMS/ISO)
  # via Invoke-WebRequest INSIDE 10-sql-install.ps1 -- canonical Packer
  # pattern for large files that bypasses the WinRM-shell-creation limit
  # entirely. Transient #11 at 0.G.7 ratify 2026-05-20 (was a `file`
  # provisioner upload that hit MaxShellsPerUser=30 on the 1.2 GB ISO).
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
      # ISO source: Packer's HTTP server, populated from http_directory
      # = H:/VMS/ISO. The basename of the ISO becomes the URL path.
      # Transient #12 at 0.G.7 ratify 2026-05-20: legacy `{{ .HTTPIP }}` Go-
      # template syntax is JSON-template-only -- silently renders as
      # literal "<no value>" in HCL2. HCL2 syntax is `${build.HTTPIP}` +
      # `${build.HTTPPort}` (Packer injects the `build` var into provisioner
      # blocks at apply time).
      "NEXUS_ISO_URL=http://${build.HTTPIP}:${build.HTTPPort}/SqlServer2025EnterpriseDeveloperEdition.iso",
    ]
  }

  # Stage 3: WSFC + iSCSI Initiator + MPIO features + open SQL/cluster
  # firewall ports + enable AlwaysOn HADR. Needs a Windows restart at the
  # end (the 3 Windows features require it).
  provisioner "powershell" {
    scripts = [
      "scripts/11-cluster-features.ps1"
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # Stage 4: stage firstboot scripts at C:/ProgramData/nexus/sql/. The
  # terraform/envs/oltp-sqlserver/role-overlay-*.tf overlays will invoke
  # these scripts on the cloned VMs over SSH at apply time.
  provisioner "powershell" {
    scripts = [
      "scripts/12-firstboot-stage.ps1"
    ]
  }

  # Stage 5: cleanup + sysprep (shared 99-sysprep handles WinRM teardown +
  # generalize). Same pattern as ws2025-desktop.
  provisioner "powershell" {
    inline = [
      "# Stop SQL Server -- clones start it under GMSA after WSFC bootstrap",
      "Stop-Service -Name MSSQLSERVER -Force -ErrorAction SilentlyContinue",
      "Set-Service -Name MSSQLSERVER -StartupType Manual",
      "# Wipe staged ISO + Temp",
      "Remove-Item -Force -ErrorAction SilentlyContinue C:/Windows/Temp/sqlserver.iso",
      "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'C:/Windows/Temp/*' -Exclude 'packer-*'",
      "Clear-DnsClientCache",
      "Write-Host '=== oltp-sqlserver-node bake complete; handing to 99-sysprep ==='"
    ]
  }

  # Shared sysprep (same script as ws2025-desktop). Tears down WinRM
  # listener + clears event logs + sysprep /generalize /oobe /shutdown.
  # Clones boot via mini-OOBE + land as nexusadmin with the known password.
  provisioner "powershell" {
    scripts = [
      "../_shared/powershell/scripts/99-sysprep.ps1"
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
