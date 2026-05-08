#!/bin/bash
# DevShot QEMU/KVM backend entrypoint
# Boots pool VMs as direct QEMU subprocesses — single level of virtualization.
# No Xen, no Dom0 VM. The Go agent runs directly in the container and
# spawns QEMU children for each pool VM.
#
# Spec 038 FR-003, FR-020.
set -u

# ── Load mounted credentials before validation ─────────────────────────────
. /opt/devshot/load-credentials.sh

# ── Validate required env vars ──────────────────────────────────────────────
: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required.}"
: "${DEVSHOT_TUNNEL_URL:?ERROR: DEVSHOT_TUNNEL_URL is required.}"

# ── Force backend selection ─────────────────────────────────────────────────
export DEVSHOT_HYPERVISOR=qemu
export ROLE=dom0
export XS_REAL=0
export XS_ROOT=/tmp/xenstore-dom0
export GUESTS_DIR="${GUESTS_DIR:-/xen/guests}"
export CONFIGS_DIR="${CONFIGS_DIR:-/xen/configs}"
export DEVSHOT_DATA_DIR="${DEVSHOT_DATA_DIR:-/var/lib/devshot}"

# Runtime installs bind-mount GUESTS_DIR over /xen/guests, hiding templates
# that were copied there during image build. Re-materialize them before the
# agent validates pool-set-base-image requests.
/opt/devshot/sync-templates.sh

# ── Detect acceleration ─────────────────────────────────────────────────────
if [ -w /dev/kvm ]; then
  echo "  Accel:      KVM (hardware virtualization)"
else
  echo "  WARNING: /dev/kvm not accessible — QEMU will fall back to TCG (slow!)"
  echo "  TIP: Run with --device /dev/kvm to enable hardware acceleration."
fi

# ── Load required kernel modules ────────────────────────────────────────────
# Requires `kmod` package (provides modprobe) and `/lib/modules` from the
# host bind-mounted (set by the install command's
# `-v /lib/modules:/lib/modules:ro`). Without those, modprobe fails silently
# and the operator must load the modules on the host before starting this
# container.
NBD_COUNT="${DEVSHOT_NBD_COUNT:-16}"
modprobe nbd "max_part=8" "nbds_max=${NBD_COUNT}" 2>/dev/null || true
modprobe tun 2>/dev/null || true
modprobe bridge 2>/dev/null || true

# ── Materialise /dev/nbdN nodes inside the container ───────────────────────
# Docker's --privileged mode does NOT auto-populate /dev/nbd* even after
# the host loads the nbd module — the container's /dev is a tmpfs. We
# mknod the devices ourselves (major 43 = NBD).
#
# Minor numbering: NBD reserves a stride of 16 minors per device (driven by
# max_part=8 → max_part_shift=4 → 1<<4 = 16 partition slots). So:
#   nbd0 → minor  0
#   nbd1 → minor 16
#   nbdN → minor N*16
# Using a flat minor=N would create files that look right but qemu-nbd
# would fail to open them with ENXIO ("No such device or address").
NBD_MADE=0
for i in $(seq 0 $((NBD_COUNT - 1))); do
  if [ ! -e "/dev/nbd${i}" ]; then
    if mknod -m 660 "/dev/nbd${i}" b 43 $((i * 16)) 2>/dev/null; then
      NBD_MADE=$((NBD_MADE + 1))
    fi
  fi
done
NBD_VISIBLE=$(ls /dev/nbd* 2>/dev/null | wc -l)
echo "  NBD:        ${NBD_VISIBLE} block devices ready (mknod'd ${NBD_MADE} new)"

# ── Writable /run/lock and /var/tmp inside read-only container ──────────────
# qemu-nbd uses /var/lock/qemu-nbd-nbd<N> as its bind-socket lock and
# creates temp files in /var/tmp during overlay open. Both paths are
# unwritable in our --read-only image:
#   • /var/lock is a symlink to /run/lock; /run is tmpfs but /run/lock
#     is not auto-created by Debian's slim image, so qemu-nbd hits
#     "No such file or directory".
#   • /var/tmp is a regular dir on the read-only rootfs.
# Bind-mounting /tmp onto /var/tmp (both writable, both purged on
# container restart) gives qemu-nbd a writable scratch path without
# adding another --tmpfs flag to every install command.
mkdir -p /run/lock
chmod 1777 /run/lock
if ! mountpoint -q /var/tmp 2>/dev/null; then
  mkdir -p /var/tmp
  mount --bind /tmp /var/tmp 2>/dev/null || true
fi

# ── Create the VM bridge ────────────────────────────────────────────────────
BRIDGE="${BRIDGE:-xenbr0}"
GATEWAY_IP="${GATEWAY_IP:-10.10.0.1}"
BRIDGE_CIDR="${BRIDGE_CIDR:-16}"
BRIDGE_SUBNET="${BRIDGE_SUBNET:-10.10.0.0/16}"

if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  ip link add name "$BRIDGE" type bridge
  ip addr add "${GATEWAY_IP}/${BRIDGE_CIDR}" dev "$BRIDGE"
  ip link set "$BRIDGE" up
  echo "  Bridge:     ${BRIDGE} created (${GATEWAY_IP}/${BRIDGE_CIDR})"
else
  echo "  Bridge:     ${BRIDGE} already exists"
fi

# ── Enable IP forwarding + NAT ──────────────────────────────────────────────
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
iptables -t nat -C POSTROUTING -s "$BRIDGE_SUBNET" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$BRIDGE_SUBNET" ! -o "$BRIDGE" -j MASQUERADE

# ── Recursive DNS forwarder for pool guests (security logging) ──────────────
# Pool VMs ship with `nameserver ${GATEWAY_IP}` in /etc/resolv.conf, so every
# guest DNS query lands on this dnsmasq. We don't run a host resolver
# (systemd-resolved binds to loopback only inside the container's host net
# namespace), so without this dnsmasq guest lookups silently fail and break
# anything that relies on DNS — most visibly WebRTC ICE gathering, which
# can't allocate TURN candidates without resolving turn.cloudflare.com.
#
# Why a real forwarder rather than baking nameservers into the guest image:
#   • Centrally controlled — change upstream from one place via env var.
#   • Security logging — every query is attributed to its source VM IP and
#     surfaced in `docker logs` for the dom0 container, prefixed `[dnsmasq]`
#     so an audit pipeline can scrape it.
#   • Failure visibility — a broken upstream shows up here, not as opaque
#     guest-side timeouts.
#
# Configuration:
#   DEVSHOT_DNS_UPSTREAM   comma-separated upstream resolvers
#                          (default: 1.1.1.1,1.0.0.1)
#   DEVSHOT_DNS_LOG        1 = log every query, 0 = no per-query logs
#                          (default: 1)
#   DEVSHOT_DNS_DISABLE    1 = skip dnsmasq entirely (operator runs their
#                          own resolver elsewhere on ${GATEWAY_IP}:53)
DNS_DISABLE="${DEVSHOT_DNS_DISABLE:-0}"
if [ "$DNS_DISABLE" != "1" ]; then
  DNS_UPSTREAM="${DEVSHOT_DNS_UPSTREAM:-1.1.1.1,1.0.0.1}"
  DNS_LOG="${DEVSHOT_DNS_LOG:-1}"

  DNSMASQ_ARGS=(
    --no-daemon
    --listen-address="${GATEWAY_IP}"
    --bind-interfaces
    --no-resolv
    --no-hosts
    --cache-size=1000
    --pid-file=
  )
  IFS=',' read -ra _DNS_UPS <<< "$DNS_UPSTREAM"
  for u in "${_DNS_UPS[@]}"; do
    [ -n "$u" ] && DNSMASQ_ARGS+=("--server=$u")
  done
  if [ "$DNS_LOG" = "1" ]; then
    DNSMASQ_ARGS+=(--log-queries --log-facility=-)
  fi

  # Run dnsmasq under tini supervision (PID 1 = tini, reaps zombies).
  # `sed -u` line-buffers so query logs flush in real time. Logs go to
  # stderr → docker logs → operator's collection pipeline.
  dnsmasq "${DNSMASQ_ARGS[@]}" 2>&1 | sed -u 's/^/[dnsmasq] /' &
  DNSMASQ_PID=$!
  echo "  DNS:        forwarder started (pid=${DNSMASQ_PID}, listen=${GATEWAY_IP}:53, upstream=${DNS_UPSTREAM}, log=${DNS_LOG})"
else
  echo "  DNS:        forwarder disabled (DEVSHOT_DNS_DISABLE=1)"
fi

# ── Load system-wide AppArmor parent profile ────────────────────────────────
if command -v apparmor_parser >/dev/null 2>&1; then
  if [ -f /etc/apparmor.d/devshot-vmm-qemu.parent ]; then
    apparmor_parser -r /etc/apparmor.d/devshot-vmm-qemu.parent 2>/dev/null || true
    echo "  AppArmor:   parent profile loaded"
  fi
fi

# ── Verify prerequisites ───────────────────────────────────────────────────
if ! command -v qemu-system-aarch64 >/dev/null 2>&1 && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "ERROR: no qemu-system-* binary found in PATH"
  exit 1
fi

# ── Status banner ──────────────────────────────────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
CPU_CORES=$(nproc 2>/dev/null || echo "?")

echo "════════════════════════════════════════════════════════"
echo "  DevShot QEMU/KVM backend"
echo "════════════════════════════════════════════════════════"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  (set by console — pushed via tunnel config on connect)"
echo "  Bridge:     ${BRIDGE}"
echo "  Backend:    ${DEVSHOT_HYPERVISOR}"
echo "  Guests dir: ${GUESTS_DIR}"
echo "  Config dir: ${CONFIGS_DIR}"
echo "  Data dir:   ${DEVSHOT_DATA_DIR}"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Launch the Go agent ─────────────────────────────────────────────────────
exec /opt/devshot/agent
