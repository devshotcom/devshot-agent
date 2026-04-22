#!/bin/bash
# DevShot QEMU/KVM backend entrypoint
# Boots pool VMs as direct QEMU subprocesses — single level of virtualization.
# No Xen, no Dom0 VM. The Go agent runs directly in the container and
# spawns QEMU children for each pool VM.
#
# Spec 038 FR-003, FR-020.
set -u

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

# ── Detect acceleration ─────────────────────────────────────────────────────
if [ -w /dev/kvm ]; then
  echo "  Accel:      KVM (hardware virtualization)"
else
  echo "  WARNING: /dev/kvm not accessible — QEMU will fall back to TCG (slow!)"
  echo "  TIP: Run with --device /dev/kvm to enable hardware acceleration."
fi

# ── Load required kernel modules ────────────────────────────────────────────
modprobe nbd max_part=8 nbds_max=1024 2>/dev/null || true
modprobe tun 2>/dev/null || true
modprobe bridge 2>/dev/null || true

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
echo "  Pool size:  ${POOL_SIZE:-2}"
echo "  Bridge:     ${BRIDGE}"
echo "  Backend:    ${DEVSHOT_HYPERVISOR}"
echo "  Guests dir: ${GUESTS_DIR}"
echo "  Config dir: ${CONFIGS_DIR}"
echo "  Data dir:   ${DEVSHOT_DATA_DIR}"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Launch the Go agent ─────────────────────────────────────────────────────
exec /opt/devshot/agent
