#!/bin/bash
# DevShot Orchestrator entrypoint — ARM64 (Apple Silicon + Raspberry Pi + cloud ARM)
# Boots QEMU → Xen hypervisor → Dom0 agent. No SSH.
# Uses KVM when available (RPi, Graviton, Apple Silicon Docker Desktop),
# falls back to TCG when not (slower but functional).
set -u

# ── Validate required env vars ──────────────────────────────────────────────

: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required.}"
: "${DEVSHOT_TUNNEL_URL:?ERROR: DEVSHOT_TUNNEL_URL is required.}"

# ── Detect hardware acceleration ──────────────────────────────────────────

QEMU_ACCEL="tcg,thread=multi"
QEMU_CPU="max"
QEMU_GIC="3"
ACCEL_LABEL="TCG (software — no KVM)"

if [ -w /dev/kvm ]; then
  QEMU_ACCEL="kvm"
  QEMU_CPU="host"
  QEMU_GIC="host"
  ACCEL_LABEL="KVM (hardware virtualization)"
fi

# ── Detect ARM hardware ───────────────────────────────────────────────────

ARM_MODEL="unknown"
if [ -f /sys/firmware/devicetree/base/model ]; then
  ARM_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
elif [ -f /proc/device-tree/model ]; then
  ARM_MODEL=$(tr -d '\0' < /proc/device-tree/model)
fi

# Detect Apple Silicon Docker Desktop
if [ "$ARM_MODEL" = "unknown" ] && uname -r 2>/dev/null | grep -qi 'linuxkit'; then
  ARM_MODEL="Apple Silicon (Docker Desktop)"
fi

TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
CPU_CORES=$(nproc)

# ── Auto-tune resources based on available hardware ───────────────────────

DOM0_MEM="${DOM0_MEM:-1024}"

# Guard: don't let Xen consume more than 80% of total RAM
MAX_XEN_MEM=$(( TOTAL_RAM_MB * 80 / 100 ))
XEN_MEM="${XEN_MEM:-3072}"
if [ "$XEN_MEM" -gt "$MAX_XEN_MEM" ]; then
  echo "WARNING: XEN_MEM=${XEN_MEM}MB exceeds 80% of ${TOTAL_RAM_MB}MB total RAM."
  echo "  Capping to ${MAX_XEN_MEM}MB. Set XEN_MEM explicitly to override."
  XEN_MEM="$MAX_XEN_MEM"
fi

# Cap CPUs to available cores
XEN_CPUS="${XEN_CPUS:-$CPU_CORES}"
if [ "$XEN_CPUS" -gt "$CPU_CORES" ]; then
  XEN_CPUS="$CPU_CORES"
fi

echo "════════════════════════════════════════════════════════"
echo "  DevShot Orchestrator starting (ARM64)"
echo "════════════════════════════════════════════════════════"
echo "  Hardware:   ${ARM_MODEL}"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  ${POOL_SIZE:-1}"
echo "  Xen memory: ${XEN_MEM}MB  CPUs: ${XEN_CPUS}"
echo "  Dom0 mem:   ${DOM0_MEM}MB"
echo "  Accel:      ${ACCEL_LABEL}"

if [ "$QEMU_ACCEL" = "tcg,thread=multi" ]; then
  echo ""
  echo "  TIP: For full hardware power, run with --device /dev/kvm"
  echo "    docker run --privileged --device /dev/kvm ..."
fi
echo ""

# ── Graceful shutdown ────────────────────────────────────────────────────────

cleanup() {
  echo ""
  echo "Shutting down..."
  [ -f /tmp/qemu.pid ] && kill "$(cat /tmp/qemu.pid)" 2>/dev/null || true
  wait 2>/dev/null || true
  echo "Orchestrator stopped."
  exit 0
}
trap cleanup TERM INT

# ── Write agent env vars to shared 9p volume ─────────────────────────────────

install -m 0600 /dev/null /xen/agent.env
cat > /xen/agent.env <<ENV
XS_REAL=1
RUN_AS_USER=devshot
DEVSHOT_SERVER_ID=${DEVSHOT_SERVER_ID}
DEVSHOT_HMAC_SECRET=${DEVSHOT_HMAC_SECRET}
DEVSHOT_TUNNEL_URL=${DEVSHOT_TUNNEL_URL}
DEVSHOT_TLS_SKIP=${DEVSHOT_TLS_SKIP:-0}
POOL_SIZE=${POOL_SIZE:-1}
READY_TIMEOUT=${READY_TIMEOUT:-300000}
LOG_LEVEL=${LOG_LEVEL:-info}
ENV

echo "[1/3] Agent env written to /xen/agent.env (mode 0600)"

# ── Boot QEMU with Xen ──────────────────────────────────────────────────────

echo "[2/3] Booting Xen hypervisor via QEMU (${ACCEL_LABEL})..."

[ -f /xen/dom0-rootfs-work.qcow2 ] || \
  qemu-img create -f qcow2 -b /xen/dom0-rootfs.qcow2 -F qcow2 /xen/dom0-rootfs-work.qcow2

qemu-system-aarch64 \
  -accel "${QEMU_ACCEL}" \
  -machine virt,gic-version=${QEMU_GIC},virtualization=true \
  -cpu "${QEMU_CPU}" \
  -smp "${XEN_CPUS}" \
  -m "${XEN_MEM}" \
  -display none \
  -daemonize \
  -kernel /xen/xen \
  -append "dom0_mem=${DOM0_MEM}M,max:${DOM0_MEM}M loglvl=all guest_loglvl=all console=dtuart" \
  -device guest-loader,addr=0x49000000,kernel=/xen/Image,bootargs="console=hvc0 root=/dev/vda rw earlyprintk=xenboot" \
  -drive file=/xen/dom0-rootfs-work.qcow2,format=qcow2,if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -fsdev local,id=xen_fs,path=/xen,security_model=none \
  -device virtio-9p-device,fsdev=xen_fs,mount_tag=xen_shared \
  -fsdev local,id=orch_fs,path=/opt/devshot,security_model=none \
  -device virtio-9p-device,fsdev=orch_fs,mount_tag=orchestrator \
  -monitor unix:/tmp/qemu-monitor.sock,server,nowait \
  -serial unix:/tmp/qemu-console.sock,server,nowait \
  -device virtio-serial-device \
  -chardev socket,id=qga0,path=/tmp/qemu-ga.sock,server=on,wait=off \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -chardev socket,id=recovery0,path=/tmp/qemu-recovery.sock,server=on,wait=off \
  -device virtserialport,chardev=recovery0,name=org.devshot.recovery \
  -pidfile /tmp/qemu.pid

sleep 1
if [ ! -f /tmp/qemu.pid ] || ! kill -0 "$(cat /tmp/qemu.pid)" 2>/dev/null; then
  echo "ERROR: QEMU failed to start"
  exit 1
fi

# Ensure QEMU is running
sleep 1
echo 'cont' | socat - UNIX-CONNECT:/tmp/qemu-monitor.sock,connect-timeout=3 >/dev/null 2>&1 || true
echo "  QEMU started (pid=$(cat /tmp/qemu.pid), accel=${QEMU_ACCEL%%,*})"

# ── Wait for agent ──────────────────────────────────────────────────────────

echo "[3/3] Waiting for Dom0 agent to start..."
echo "  (Dom0 systemd auto-mounts 9p and starts the agent)"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Orchestrator booting on ${ARM_MODEL}"
echo "  Accel:        ${ACCEL_LABEL}"
echo "  Server ID:    ${DEVSHOT_SERVER_ID}"
echo "  Tunnel:       ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:    ${POOL_SIZE:-1}"
echo "  Xen:          ${XEN_MEM}MB / ${XEN_CPUS} CPUs"
echo "  Console:      socat - UNIX-CONNECT:/tmp/qemu-console.sock"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Start QEMU tunnel agent (serial console) ────────────────────────────────

mkdir -p /tmp/xenstore-qemu

xs_qemu_write() {
  local path="$1" value="$2"
  local file="${path#/}"
  file="${file//\//__}"
  printf '%s' "$value" > "/tmp/xenstore-qemu/${file}"
}

QEMU_VM_NAME="qemu-${DEVSHOT_SERVER_ID:0:8}"
QEMU_VM_TOKEN=$(printf "vm:%s" "$QEMU_VM_NAME" | openssl dgst -sha256 -hmac "$DEVSHOT_HMAC_SECRET" -hex 2>/dev/null | awk '{print $NF}')

xs_qemu_write "/local/domain/0/data/magic-key"  "$DEVSHOT_HMAC_SECRET"
xs_qemu_write "/local/domain/0/data/tunnel-url" "$DEVSHOT_TUNNEL_URL"
xs_qemu_write "/local/domain/0/data/server-id"  "$DEVSHOT_SERVER_ID"
xs_qemu_write "/local/domain/0/data/vm-token"   "$QEMU_VM_TOKEN"
xs_qemu_write "/local/domain/0/data/vm-name"    "$QEMU_VM_NAME"

ROLE=qemu \
DOMID=0 \
XS_ROOT=/tmp/xenstore-qemu \
RUN_AS_USER=root \
DEVSHOT_SERVER_ID="${DEVSHOT_SERVER_ID}" \
DEVSHOT_HMAC_SECRET="${DEVSHOT_HMAC_SECRET}" \
DEVSHOT_TUNNEL_URL="${DEVSHOT_TUNNEL_URL}" \
DEVSHOT_TLS_SKIP="${DEVSHOT_TLS_SKIP:-0}" \
DEVSHOT_VM_NAME="${QEMU_VM_NAME}" \
QEMU_CONSOLE_SOCK=/tmp/qemu-console.sock \
QEMU_RECOVERY_SOCK=/tmp/qemu-recovery.sock \
LOG_LEVEL="${LOG_LEVEL:-info}" \
/opt/devshot/agent &

echo "  QEMU agent started as ${QEMU_VM_NAME}"

# Hold open — QEMU runs in background, agent runs inside Dom0
wait "$(cat /tmp/qemu.pid)" 2>/dev/null || tail -f /dev/null
