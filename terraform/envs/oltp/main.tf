# nexus-infra-oltp / terraform / envs / oltp / main.tf
#
# OLTP data tier env -- Phase 0.G of nexus-platform-plan. Composes one `module.vm`
# block per cluster node + per-cluster role overlays. Body populates as each
# sub-phase ships (Redis 0.G.1, Mongo 0.G.2, Percona 0.G.3, Patroni 0.G.4, SQL
# FCI/AG 0.G.7).
#
# Cross-env prerequisite (hard): nexus-infra-vmware's security env MUST have
# written the per-node AppRole sidecars to $HOME\.nexus\vault-agent-oltp-<host>.json
# BEFORE plan time; this env reads them via filesha256() in the
# role-overlay-*-vault-agents.tf overlays.
#
# Provider, modules, and per-cluster module blocks land per sub-phase. This
# scaffold-only state intentionally has no resources -- `terraform plan` against
# this file returns "No changes" until the first cluster is wired up.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    vmware-desktop = {
      source  = "vmware/vmware-desktop"
      version = "~> 1.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "vmware-desktop" {
  # vmrun path discovered from %ProgramFiles%\VMware\VMware Workstation\vmrun.exe
  # (the same pattern nexus-infra-kafka's kafka env uses; no explicit config
  # needed when vmrun is on PATH).
}

# --- TODO: per-cluster module blocks ----------------------------------------
# Each sub-phase appends one module block per VM in the cluster, e.g.:
#
#   module "redis_1" {
#     count             = var.enable_redis ? 1 : 0
#     source            = "../../modules/vm"
#     vm_name           = "redis-1"
#     template_vmx_path = "${var.template_root}\\oltp-node\\oltp-node.vmx"
#     output_dir        = "${var.vm_output_dir_root}\\05-oltp\\redis-1"
#     mac_vmnet11       = var.mac_redis_1
#     # ... etc.
#   }
#
# Plus role overlays under role-overlay-<cluster>-<concern>.tf per cluster.
