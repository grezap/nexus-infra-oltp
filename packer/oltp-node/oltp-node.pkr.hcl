# nexus-infra-oltp / packer / oltp-node / oltp-node.pkr.hcl
#
# Parametric Debian 13 template baking ALL OLTP-tier role packages (Redis 7.x,
# MongoDB 7.0, Percona XtraDB 8.0 + ProxySQL 2.7, Postgres 16 + Patroni 4 + etcd
# 3.5 + HAProxy 2.8). All systemd-disabled at bake time; the per-VM role is
# selected at firstboot via an IP-to-role map (the kafka-node pattern).
#
# Substantive content lands per cluster sub-phase as the role's package +
# Ansible role is added:
#   - 0.G.1: Redis 7.x
#   - 0.G.2: MongoDB 7.0
#   - 0.G.3: Percona XtraDB Cluster 8.0 + ProxySQL 2.7
#   - 0.G.4: PostgreSQL 16 + Patroni 4 + etcd 3.5 + HAProxy 2.8
#
# This scaffold is intentionally non-buildable -- `packer init .` + `packer
# validate .` will fail until the first role's source + provisioner blocks
# land. That's the explicit exit-criterion for 0.G.1 substantive: this
# template builds + produces an oltp-node.vmx in H:\VMS\NexusPlatform\_templates\.

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = "~> 1.0"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = "~> 1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# TODO 0.G.1: add source "vmware-iso" "oltp_node" + build block. Mirror
# nexus-infra-kafka/packer/kafka-node/kafka-node.pkr.hcl shape (deb13 ISO,
# preseed.cfg, ansible-local provisioner pointing at the shared ansible roles
# under ../../_shared/ansible/ + this template's own ./ansible/playbook.yml).
