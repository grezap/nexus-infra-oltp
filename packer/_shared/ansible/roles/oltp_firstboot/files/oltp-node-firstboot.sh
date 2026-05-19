#!/bin/bash
# oltp-node-firstboot.sh -- runs once at first boot per oltp-node clone.
#
# Linear port of kafka-node-firstboot.sh, scaled to the full 0.G OLTP tier.
# Same NIC discrimination by MAC OUI byte 5 (0x00 primary VMnet11, 0x01
# secondary VMnet10), same /etc/hosts pattern, same hostname renaming, same
# VMnet10 backplane .link MAC-match.
#
# KEY DIFFERENCE from kafka-node-firstboot.sh: the IP-to-role map covers
# ALL 0.G.* clusters (redis / mongo / percona pxc+proxysql / patroni). In 0.G.1 only
# the redis-1..6 IPs are populated; later sub-phases extend this map as
# their foundation reservations + Packer role tasks land. A clone landing
# on an unmapped IP fails fast with a clear error.
#
# Like kafka-node-firstboot.sh: this script does NOT enable any role
# service. The Terraform role-overlays render per-host config (which needs
# Terraform-time per-host data -- e.g. redis's cluster-announce-ip) and
# enable exactly one role service per node.
#
# Idempotent: marker file at /var/lib/oltp-node-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/oltp-node-firstboot-done
LOG_PREFIX="[oltp-node-firstboot]"
# IDENTITY_DIR is derived per-cluster after the IP→role map (step 4)
# because each Terraform overlay expects node-identity.env at the
# cluster's own config dir (/etc/nexus-redis/ for redis nodes,
# /etc/nexus-mongo/ for mongo nodes, etc.). Initialised empty here.
IDENTITY_DIR=""
IDENTITY_FILE=""

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- oltp tier requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# ─── 2. Ensure nic0 == primary, nic1 == secondary ──────────────────────────
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 DHCP ─────────────────────────────────────────────────
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map IP -> hostname + VMnet10 IP + role + cluster ─────────────────
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: redis +
# cluster: mongo + percona so far; patroni extends per sub-phase).
# Convention: VMnet10 third octet = 10; fourth octet matches VMnet11.
HOSTNAME=""; VMNET10_IP=""; ROLE=""; CLUSTER=""
case "$VMNET11_IP" in
  # ─── 0.G.1 -- Redis Cluster (6 nodes) ─────────────────────────────────
  192.168.70.81) HOSTNAME=redis-1; VMNET10_IP=192.168.10.81; ROLE=redis; CLUSTER=redis ;;
  192.168.70.82) HOSTNAME=redis-2; VMNET10_IP=192.168.10.82; ROLE=redis; CLUSTER=redis ;;
  192.168.70.83) HOSTNAME=redis-3; VMNET10_IP=192.168.10.83; ROLE=redis; CLUSTER=redis ;;
  192.168.70.84) HOSTNAME=redis-4; VMNET10_IP=192.168.10.84; ROLE=redis; CLUSTER=redis ;;
  192.168.70.87) HOSTNAME=redis-5; VMNET10_IP=192.168.10.87; ROLE=redis; CLUSTER=redis ;;
  192.168.70.89) HOSTNAME=redis-6; VMNET10_IP=192.168.10.89; ROLE=redis; CLUSTER=redis ;;

  # ─── 0.G.2 -- MongoDB Replica Set (3 nodes) ──────────────────────────
  192.168.70.71) HOSTNAME=mongo-1; VMNET10_IP=192.168.10.71; ROLE=mongo; CLUSTER=mongo ;;
  192.168.70.72) HOSTNAME=mongo-2; VMNET10_IP=192.168.10.72; ROLE=mongo; CLUSTER=mongo ;;
  192.168.70.73) HOSTNAME=mongo-3; VMNET10_IP=192.168.10.73; ROLE=mongo; CLUSTER=mongo ;;

  # ─── 0.G.3 -- Percona XtraDB Cluster + ProxySQL (5 nodes) ────────────
  192.168.70.51) HOSTNAME=pxc-node-1; VMNET10_IP=192.168.10.51; ROLE=pxc; CLUSTER=percona ;;
  192.168.70.52) HOSTNAME=pxc-node-2; VMNET10_IP=192.168.10.52; ROLE=pxc; CLUSTER=percona ;;
  192.168.70.53) HOSTNAME=pxc-node-3; VMNET10_IP=192.168.10.53; ROLE=pxc; CLUSTER=percona ;;
  # ProxySQL nodes are in the same envs/oltp-percona/ TF state as PXC but
  # are their own engine cluster -- CLUSTER=proxysql (not percona) so the
  # IDENTITY_DIR mapping below routes to /etc/nexus-proxysql with the
  # proxysql group (proxysql nodes don't have the mysql group, only
  # apt-shipped proxysql group). Fixed in 0.G.3.5c chunk 1 ratification
  # 2026-05-18 (transient #19 in handbook s3.x).
  192.168.70.54) HOSTNAME=proxysql-1; VMNET10_IP=192.168.10.54; ROLE=proxysql; CLUSTER=proxysql ;;
  192.168.70.55) HOSTNAME=proxysql-2; VMNET10_IP=192.168.10.55; ROLE=proxysql; CLUSTER=proxysql ;;

  # ─── 0.G.4 -- Patroni PostgreSQL HA + etcd DCS + HAProxy HA pair (8 nodes) ─
  # 3 Patroni nodes share CLUSTER=patroni (identity dir /etc/nexus-patroni,
  # group postgres). 3 etcd nodes are their own engine cluster CLUSTER=etcd
  # (/etc/nexus-etcd, group etcd). 2 HAProxy nodes CLUSTER=haproxy
  # (/etc/nexus-haproxy, group haproxy) -- an HA pair with keepalived-floated
  # VIP .60 mirroring the 0.G.3 proxysql-1/2 + VIP .50 pattern. All 3 templates
  # carry mTLS leaf certs via the same Vault PKI role `patroni-server`; the
  # haproxy nodes additionally carry the VIP .60 in their cert IP-SANs.
  192.168.70.61) HOSTNAME=pg-primary;   VMNET10_IP=192.168.10.61; ROLE=patroni; CLUSTER=patroni ;;
  192.168.70.62) HOSTNAME=pg-replica-1; VMNET10_IP=192.168.10.62; ROLE=patroni; CLUSTER=patroni ;;
  192.168.70.63) HOSTNAME=pg-replica-2; VMNET10_IP=192.168.10.63; ROLE=patroni; CLUSTER=patroni ;;
  192.168.70.64) HOSTNAME=etcd-1;       VMNET10_IP=192.168.10.64; ROLE=etcd;    CLUSTER=etcd    ;;
  192.168.70.65) HOSTNAME=etcd-2;       VMNET10_IP=192.168.10.65; ROLE=etcd;    CLUSTER=etcd    ;;
  192.168.70.66) HOSTNAME=etcd-3;       VMNET10_IP=192.168.10.66; ROLE=etcd;    CLUSTER=etcd    ;;
  192.168.70.67) HOSTNAME=haproxy-pg-1; VMNET10_IP=192.168.10.67; ROLE=haproxy; CLUSTER=haproxy ;;
  192.168.70.68) HOSTNAME=haproxy-pg-2; VMNET10_IP=192.168.10.68; ROLE=haproxy; CLUSTER=haproxy ;;

  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' -- not a 0.G OLTP tier IP" >&2
    echo "$LOG_PREFIX recognised IPs: redis-1..6 (.81/.82/.83/.84/.87/.89); mongo-1..3 (.71/.72/.73); pxc-node-1..3 (.51/.52/.53); proxysql-1..2 (.54/.55); pg-{primary,replica-1,replica-2} (.61/.62/.63); etcd-1..3 (.64/.65/.66); haproxy-pg-{1,2} (.67/.68); other 0.G.* clusters land later sub-phases." >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE cluster=$CLUSTER VMnet10=$VMNET10_IP/24"

# Derive per-cluster identity dir + owning group (the Terraform overlay
# for the cluster owns the dir + the service runs as the cluster-named
# user; firstboot just writes the env file into the dir).
case "$CLUSTER" in
  redis)    IDENTITY_DIR=/etc/nexus-redis;    IDENTITY_GROUP=redis ;;
  mongo)    IDENTITY_DIR=/etc/nexus-mongo;    IDENTITY_GROUP=mongodb ;;
  percona)  IDENTITY_DIR=/etc/nexus-percona;  IDENTITY_GROUP=mysql ;;
  proxysql) IDENTITY_DIR=/etc/nexus-proxysql; IDENTITY_GROUP=proxysql ;;
  patroni)  IDENTITY_DIR=/etc/nexus-patroni;  IDENTITY_GROUP=postgres ;;
  etcd)     IDENTITY_DIR=/etc/nexus-etcd;     IDENTITY_GROUP=etcd ;;
  haproxy)  IDENTITY_DIR=/etc/nexus-haproxy;  IDENTITY_GROUP=haproxy ;;
  # NOTE: percona cluster covers pxc-node-N hosts only (PXC nodes own
  # /etc/nexus-percona as group mysql). ProxySQL nodes get their own
  # /etc/nexus-proxysql owned by group proxysql (apt-shipped) -- they
  # were previously lumped into cluster=percona which broke chown at
  # firstboot because the mysql group only exists on PXC nodes.
  # the shared TLS material. Group=mysql is fine for both since the dir
  # is mode 0750 root:mysql + ProxySQL nodes additionally get
  # /etc/nexus-percona/proxysql-admin-password (mode 0400 root:proxysql)
  # rendered separately by chunk 3b TLS overlay.
  *)
    echo "$LOG_PREFIX ERROR: unknown CLUSTER '$CLUSTER' -- no identity dir mapping" >&2
    exit 1
    ;;
esac
IDENTITY_FILE="$IDENTITY_DIR/node-identity.env"

# ─── 5. Hostname + /etc/hosts ──────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# ─── 6. VMnet10 backplane config (.link MAC-match + .network static) ───────
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match. Without this, on every reboot AFTER firstboot the
# udev lex-order match leaves nic1 on its kernel-default name, the static
# .network never applies, the backplane has no IP.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# ─── 7. Write the node-identity env file for the Terraform role-overlays ───
# IDENTITY_DIR is per-cluster (e.g. /etc/nexus-redis for redis nodes,
# /etc/nexus-mongo for mongo nodes). Each cluster's Terraform role-
# overlays expect node-identity.env at their own config dir.
mkdir -p "$IDENTITY_DIR"
cat > "$IDENTITY_FILE" <<EOF
# Generated by oltp-node-firstboot.sh -- do not edit by hand.
NEXUS_HOSTNAME=$HOSTNAME
NEXUS_ROLE=$ROLE
NEXUS_CLUSTER=$CLUSTER
NEXUS_VMNET11_IP=$VMNET11_IP
NEXUS_VMNET10_IP=$VMNET10_IP
EOF
chown "root:$IDENTITY_GROUP" "$IDENTITY_FILE"
chmod 640 "$IDENTITY_FILE"
echo "$LOG_PREFIX wrote $IDENTITY_FILE (group=$IDENTITY_GROUP)"

# ─── 8. Mark complete ──────────────────────────────────────────────────────
# No Redis service is enabled here -- the Terraform role-overlays render
# redis.conf (which needs Terraform-time per-host cluster-announce-ip)
# then enable nexus-redis.service per node.
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role in $CLUSTER cluster on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"
