# Changelog

All notable changes to `nexus-infra-oltp` are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Phase 0.G.1 scaffold (2026-05-16)

- **Repo scaffold** mirroring `nexus-infra-kafka`: `terraform/{envs/oltp,modules/vm}`, `packer/{_shared,oltp-node}`, `scripts/`, `docs/{handbook,adr,verification}/`. Shared parts (`modules/vm`, `packer/_shared/ansible`, `scripts/configure-vm-nic.ps1`, `ansible.cfg`, `.gitignore`, `LICENSE`) reused verbatim from `nexus-infra-kafka` per `feedback_dry_single_source_of_truth.md`.
- **`scripts/oltp.ps1`** — operator wrapper (verbs `apply` · `destroy` · `smoke` · `cycle` · `plan` · `validate`) mirroring `nexus-infra-kafka/scripts/kafka.ps1` per `feedback_build_host_pwsh_native.md` (no GNU make on the build host; pwsh wrappers are canonical).
- **Placeholder `packer/oltp-node/` template** — `oltp-node.pkr.hcl` + `variables.pkr.hcl` + empty `ansible/` + `files/` + `http/` subdirectories. Substantive Ansible roles + package installs land per cluster sub-phase: Redis 7.x in 0.G.1, MongoDB 7.0 in 0.G.2, Percona 8.0 + ProxySQL in 0.G.3, Postgres 16 + Patroni + etcd + HAProxy in 0.G.4.
- **Placeholder `terraform/envs/oltp/`** — `main.tf` (`vmware-desktop` provider boilerplate) + `variables.tf` (`enable_*` toggle scaffolding, defaults to `true` per `feedback_selective_provisioning.md` + `feedback_terraform_partial_apply_destroys_resources.md`) + `outputs.tf`. Substantive `module.<vm>` blocks + role overlays land per sub-phase.
- **Placeholder `docs/handbook.md`** with the 9-section structure mandated by `feedback_handbook_standard.md` invariant 2 (§0 prereqs · §1.1 Packer build · §1.2 cross-env operator order · §1.3 apply · §1.4 verify · §1.5 selective ops · §1.6 destroy · §2 phase status · §3 operator runbooks). Body populates as sub-phases close.
- **Placeholder `docs/adr/index.md`** — empty registry. Per-cluster ADRs land per sub-phase (Redis Cluster topology · MongoDB X.509 auth · Percona Galera SST tuning · Patroni leader election · SQL FCI shared-storage strategy).

This is the scaffold-only milestone. The first cluster (Redis) lands as the next commit; smoke gate `smoke-0.G.1.ps1` ratifies the exit.
