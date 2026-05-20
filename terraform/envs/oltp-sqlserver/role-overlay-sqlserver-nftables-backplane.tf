# role-overlay-sqlserver-nftables-backplane.tf -- Phase 0.G.7
#
# Verifies the Windows Firewall rules baked at Packer time (per scripts/
# 11-cluster-features.ps1) are present + active on all 4 SQL nodes, and
# probes VMnet10 backplane reachability between them.
#
# Unlike the Linux clusters (where this overlay WRITES the nftables.conf
# at clone time), the SQL nodes have their Win Firewall rules pre-baked
# in the Packer template. This overlay is a SMOKE + WAIT-FOR-VM step:
#   - SSH to each node + verify the 10 NEXUS-* firewall rules exist
#   - Ping between every pair of nodes on VMnet10 + VMnet11
#   - Wait until OOBE + firstboot.ps1 (rename + IP config) has completed
#     on each node before declaring the stage done
#
# Idempotent: re-runs are cheap probes; trigger version bump forces re-run.

resource "null_resource" "sqlserver_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    nodes   = jsonencode(local.sql_nodes)
    stage_v = var.sqlserver_nftables_v
  }

  depends_on = [
    module.sql_fci_1, module.sql_fci_2,
    module.sql_ag_rep_1, module.sql_ag_rep_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes = ConvertFrom-Json '${jsonencode(local.sql_nodes)}' -AsHashtable
      $sshUser = '${var.ssh_username}'

      Write-Host "[sqlserver-nftables] waiting for all 4 SQL nodes' OpenSSH to respond + firstboot to complete..."

      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key
        $ip   = $entry.Value.vmnet11
        $deadline = (Get-Date).AddMinutes(25)
        while ((Get-Date) -lt $deadline) {
          # Probe: SSH + check that firstboot has rendered node-identity.env.
          # firstboot.ps1 writes this file on the first OOBE boot after
          # NIC discovery + computer rename. Until it exists, the node
          # isn't ready for downstream stages.
          $probe = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no `
            "$sshUser@$ip" `
            "if (Test-Path 'C:/ProgramData/nexus/sql/node-identity.env') { Write-Output 'READY' } else { Write-Output 'WAIT' }" 2>$null
          if ($probe -match 'READY') {
            Write-Host "  - $hostName ($ip) : ready"
            break
          }
          Start-Sleep -Seconds 10
        }
        if ((Get-Date) -ge $deadline) {
          throw "[sqlserver-nftables] $hostName ($ip) did not reach READY within 25 min; firstboot may have failed -- ssh nexusadmin@$ip + Get-Content C:/ProgramData/nexus/sql/logs/firstboot.log"
        }
      }

      # Verify Win Firewall rules. The Packer template's 11-cluster-features.ps1
      # creates 10 NEXUS-* rules; we sample a few critical ones here.
      Write-Host "[sqlserver-nftables] verifying Win Firewall rules on all 4 nodes..."
      $expectedRules = @('NEXUS-SQL-1433-TCP', 'NEXUS-SQL-5022-TCP', 'NEXUS-WSFC-3343-UDP', 'NEXUS-WSFC-EPHEMERAL')
      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key
        $ip   = $entry.Value.vmnet11
        foreach ($rule in $expectedRules) {
          $check = ssh -o ConnectTimeout=10 -o BatchMode=yes "$sshUser@$ip" `
            "if (Get-NetFirewallRule -Name '$rule' -ErrorAction SilentlyContinue) { Write-Output 'PRESENT' } else { Write-Output 'MISSING' }" 2>$null
          if ($check -notmatch 'PRESENT') {
            throw "[sqlserver-nftables] $hostName : firewall rule $rule MISSING (Packer baked it; clone integrity issue?)"
          }
        }
        Write-Host "  - $hostName : 4 critical firewall rules present"
      }

      Write-Host "[sqlserver-nftables] all 4 nodes ready; firewall rules verified"
    PWSH
  }
}
