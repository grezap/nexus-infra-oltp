<?xml version="1.0" encoding="utf-8"?>
<!--
  Autounattend.xml.tpl — Packer templatefile() inputs:
    image_name           : install.wim ImageName string
    product_key          : "" for evaluation, XXXXX-XXXXX-... for msdn
    admin_username       : local admin/WinRM account created at OOBE
    admin_password       : build-time-only password (rotated to Vault in Phase 0.D)
    computer_name        : NETBIOS hostname
    bypass_win11_checks  : true for win11ent (LabConfig regkeys to skip
                           Win11 hardware checks during install); false
                           for WS2025 templates (the keys would be no-ops
                           on Server but cleaner to omit them entirely)

  Key design points:
    - UEFI + GPT: ESP + MSR + OS partition. Modern Windows Setup refuses
      legacy BIOS and our vmware-iso source is firmware=efi.
    - No product key on evaluation path (ProductKey block omitted entirely)
      vs msdn (ProductKey present with Key). templatefile() renders one or
      the other via Terraform-style conditional template directives.
    - OOBESystem → FirstLogonCommands runs A:\bootstrap-winrm.ps1 to open
      the WinRM listener for Packer. Runtime remote access is OpenSSH, which
      01-nexus-identity.ps1 installs once we're past OOBE.
    - Win11 install bypass (bypass_win11_checks=true): standalone VMware
      Workstation 25 ignores `managedvm.autoAddVTPM` (vSphere/ESXi-only
      construct) and lacks a headless auto-encryption key provider for a
      real vTPM. Rather than add interactive GUI steps to Packer, we write
      LabConfig\Bypass*Check=1 in the windowsPE pass so Setup skips the
      TPM/Secure-Boot/RAM checks. The OS installs without a TPM device;
      BitLocker is available only in recovery-key mode (TPM-backed mode
      requires real TPM hardware).
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <!-- ─── Phase 1: windowsPE — partition + pick image + product key ── -->
  <settings pass="windowsPE">

    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <!-- EFI System Partition -->
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>260</Size>
            </CreatePartition>
            <!-- Microsoft Reserved Partition -->
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <!-- OS partition (remainder) -->
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>${image_name}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

%{ if product_key != "" ~}
      <UserData>
        <ProductKey>
          <Key>${product_key}</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>NexusPlatform</FullName>
        <Organization>NexusPlatform</Organization>
      </UserData>
%{ else ~}
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>NexusPlatform</FullName>
        <Organization>NexusPlatform</Organization>
      </UserData>
%{ endif ~}

%{ if bypass_win11_checks ~}
      <!-- Win11 install-time hardware-check bypass.
           These regkeys are read by Setup in the windowsPE pass before the
           hardware-eligibility gate. Required because standalone Workstation
           cannot expose a real vTPM via Packer (see template header). -->
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
%{ endif ~}

    </component>
  </settings>

  <!-- ─── Phase 2: specialize — computer name, timezone, autologon prep ─ -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ComputerName>${computer_name}</ComputerName>
      <TimeZone>UTC</TimeZone>
      <RegisteredOrganization>NexusPlatform</RegisteredOrganization>
      <RegisteredOwner>NexusPlatform</RegisteredOwner>
    </component>

    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <!-- Allow RDP so owner can fall back to GUI console if WinRM dies mid-build.
           Firewall rules gate actual access to VMnet11 (03-nexus-firewall.ps1). -->
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
  </settings>

  <!-- ─── Phase 3: oobeSystem — create admin user + first-logon commands ─ -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <UserAccounts>
        <AdministratorPassword>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>${admin_password}</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>NexusPlatform build + runtime admin</Description>
            <DisplayName>${admin_username}</DisplayName>
            <Group>Administrators</Group>
            <Name>${admin_username}</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <!-- AutoLogon so FirstLogonCommands can run without a Ctrl-Alt-Del prompt.
           Count=1 means it runs exactly once; subsequent boots require login. -->
      <AutoLogon>
        <Password>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>${admin_username}</Username>
      </AutoLogon>

      <FirstLogonCommands>
        <!-- Order 1: bring WinRM up so Packer can connect.
             A:\ maps to the floppy Packer attaches via floppy_files. -->
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File A:\bootstrap-winrm.ps1</CommandLine>
          <Description>Enable WinRM listener for Packer</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>

      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>

</unattend>
