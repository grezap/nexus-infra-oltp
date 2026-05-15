# nexus-infra-oltp / terraform / envs / oltp / outputs.tf
#
# Per-cluster outputs land per sub-phase, mirroring nexus-infra-kafka's
# pattern: a summary table emitted at apply completion + a `next_step` hint
# pointing at the appropriate smoke gate.

output "next_step" {
  value = <<-EOT
    Phase 0.G.1 (Redis Cluster) scaffold lands in the next commit.
    Until then this env applies clean (zero resources).
    See docs/handbook.md s1 for the planned apply-flow.
  EOT
}
