# nexus-infra-oltp / terraform / envs / oltp-mongo / outputs.tf
# Per-cluster MongoDB Replica Set outputs -- Phase 0.G.3.5b.

output "mongo_endpoints" {
  description = "Per-node MongoDB RS endpoints (TLS on 27017). Replica set name: nexus-rs."
  value = {
    for n in ["mongo-1", "mongo-2", "mongo-3"] : n => {
      service_ip = lookup({
        "mongo-1" = "192.168.70.71"
        "mongo-2" = "192.168.70.72"
        "mongo-3" = "192.168.70.73"
      }, n)
      backplane_ip = lookup({
        "mongo-1" = "192.168.10.71"
        "mongo-2" = "192.168.10.72"
        "mongo-3" = "192.168.10.73"
      }, n)
      tls_port = 27017
      rs_name  = "nexus-rs"
    }
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.G.3.5b envs/oltp-mongo/ state -- 3 mongo VMs + RS overlays.
    Apply order:
      1. nexus-infra-vmware foundation + security envs applied.
      2. packer build packer/oltp-mongo-node.
      3. This env:       pwsh -File scripts/oltp-mongo.ps1 apply (OR: terraform apply from this dir).
      4. Smoke:          pwsh -File scripts/smoke-0.G.2.ps1.
  EOT
}
