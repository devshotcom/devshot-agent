#!/bin/bash
# DevShot Firecracker backend entrypoint
# Boots pool VMs as Firecracker microVMs via jailer — smallest TCB,
# strongest sandbox. No Xen, no QEMU, no Dom0 VM.
#
# Spec 038 FR-004, FR-015, FR-020.
set -u

# ── Load mounted credentials before validation ─────────────────────────────
. /opt/devshot/load-credentials.sh

# ── Validate required env vars ──────────────────────────────────────────────
: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required.}"
: "${DEVSHOT_TUNNEL_URL:?ERROR: DEVSHOT_TUNNEL_URL is required.}"

# ── Force backend selection ─────────────────────────────────────────────────
export DEVSHOT_HYPERVISOR=firecracker
export ROLE=dom0
export LAMP_RELEASE_INDEX_URL="${LAMP_RELEASE_INDEX_URL:-https://github.com/devshotcom/devshot-agent/releases/download/lamp-matrix-latest/lamp-matrix-index-v2.json}"
export LAMP_SYNC_INTERVAL="${LAMP_SYNC_INTERVAL:-5m}"
export LAMP_SYNC_DOWNLOAD_TIMEOUT="${LAMP_SYNC_DOWNLOAD_TIMEOUT:-30m}"
export XS_REAL=0
export XS_ROOT=/tmp/xenstore-dom0
export GUESTS_DIR="${GUESTS_DIR:-/xen/guests}"

# Keep prebaked templates available even when /xen/guests is bind-mounted.
/opt/devshot/sync-templates.sh

# ── Verify prerequisites ───────────────────────────────────────────────────
if [ ! -w /dev/kvm ]; then
  echo "ERROR: /dev/kvm not accessible — Firecracker requires KVM"
  echo "  Run with --device /dev/kvm"
  exit 1
fi
if ! command -v firecracker >/dev/null 2>&1; then
  echo "ERROR: firecracker binary not found in PATH"
  exit 1
fi
if ! command -v jailer >/dev/null 2>&1; then
  echo "ERROR: jailer binary not found in PATH (required for sandbox enforcement)"
  exit 1
fi

# ── Load required kernel modules ────────────────────────────────────────────
modprobe nbd max_part=8 nbds_max=1024 2>/dev/null || true
modprobe tun 2>/dev/null || true
modprobe bridge 2>/dev/null || true
modprobe vsock 2>/dev/null || true
modprobe vhost_vsock 2>/dev/null || true

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

# ── Status banner ──────────────────────────────────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
CPU_CORES=$(nproc 2>/dev/null || echo "?")

echo "════════════════════════════════════════════════════════"
echo "  DevShot Firecracker backend"
echo "════════════════════════════════════════════════════════"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  (set by console — pushed via tunnel config on connect)"
echo "  Bridge:     ${BRIDGE}"
echo "  Backend:    ${DEVSHOT_HYPERVISOR}"
echo "  TCB:        ~50k LoC Rust (Firecracker + jailer)"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Launch the Go agent ─────────────────────────────────────────────────────
exec /opt/devshot/agent
