# nexus-infra-oltp / terraform / envs / oltp-mongo / main.tf
#
# Per-cluster Terraform state for the MongoDB Replica Set (3 nodes:
# mongo-1/2/3 at .71/.72/.73). Phase 0.G.3.5b refactor split from the
# monolithic envs/oltp/.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── MongoDB module.vm blocks (3 nodes) ────────────────────────────────────

module "mongo_1" {
  source = "../../modules/vm"
  count  = var.enable_mongo_1 ? 1 : 0

  vm_name           = "mongo-1"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mongo_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mongo_1_secondary
}

module "mongo_2" {
  source = "../../modules/vm"
  count  = var.enable_mongo_2 ? 1 : 0

  vm_name           = "mongo-2"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mongo_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mongo_2_secondary
}

module "mongo_3" {
  source = "../../modules/vm"
  count  = var.enable_mongo_3 ? 1 : 0

  vm_name           = "mongo-3"
  template_vmx_path = "${var.template_root}/oltp-mongo-node/oltp-mongo-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/05-oltp/mongo-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_mongo_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_mongo_3_secondary
}
