#!/bin/bash
# DevShot Orchestrator entrypoint — x86_64
# Boots QEMU (x86_64) → Xen hypervisor → Dom0 agent. No SSH.
# Uses KVM when available, falls back to TCG.
set -u

# ── Validate required env vars ──────────────────────────────────────────────

: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required.}"
: "${DEVSHOT_TUNNEL_URL:?ERROR: DEVSHOT_TUNNEL_URL is required.}"

# ── Detect hardware acceleration ──────────────────────────────────────────

QEMU_ACCEL="tcg,thread=multi"
QEMU_CPU="max"
ACCEL_LABEL="TCG (software — no KVM)"

if [ -w /dev/kvm ]; then
  QEMU_ACCEL="kvm"
  QEMU_CPU="host"
  ACCEL_LABEL="KVM (hardware virtualization)"
fi

# ── Detect hardware ──────────────────────────────────────────────────────

TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
CPU_CORES=$(nproc)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
[ -z "$CPU_MODEL" ] && CPU_MODEL="unknown"

# ── Auto-size Xen to host ────────────────────────────────────────────────
# Defaults hand the full machine to Xen, then give Dom0 80% of that budget
# (the heavy workload runs in Dom0 itself; the DomU pool gets the remaining
# 20%). Users can pin explicit values with
#   -e XEN_MEM=... / -e XEN_CPUS=... / -e DOM0_MEM=... / -e DOM0_DISK=...

# Xen memory: leave at least 1 GB for the container runtime (QEMU heap,
# orchestrator, Go agent), give everything else to Xen.
HARD_CAP=$(( TOTAL_RAM_MB - 1024 ))
[ "$HARD_CAP" -lt 1024 ] && HARD_CAP=1024
XEN_MEM="${XEN_MEM:-$HARD_CAP}"
if [ "$XEN_MEM" -gt "$HARD_CAP" ] && [ "$HARD_CAP" -gt 0 ]; then
  echo "WARNING: XEN_MEM=${XEN_MEM}MB leaves <1GB for host (${TOTAL_RAM_MB}MB total)."
  echo "  Capping to ${HARD_CAP}MB. Set XEN_MEM explicitly to override."
  XEN_MEM="$HARD_CAP"
fi

# CPUs: default to every host core. Cap at nproc so we never oversubscribe.
XEN_CPUS="${XEN_CPUS:-$CPU_CORES}"
if [ "$XEN_CPUS" -gt "$CPU_CORES" ]; then
  echo "WARNING: XEN_CPUS=${XEN_CPUS} exceeds host cores (${CPU_CORES})."
  echo "  Capping to ${CPU_CORES}."
  XEN_CPUS="$CPU_CORES"
fi

# Dom0 memory: 80% of Xen budget by default — keeps the bulk of the machine
# in Dom0 itself, where the user's interactive workload lives. Floor at
# 1536 MB so tiny hosts still boot. The DomU pool gets the remaining 20%.
AUTO_DOM0_MEM=$(( XEN_MEM * 80 / 100 ))
[ "$AUTO_DOM0_MEM" -lt 1536 ] && AUTO_DOM0_MEM=1536
DOM0_MEM="${DOM0_MEM:-$AUTO_DOM0_MEM}"
if [ "$DOM0_MEM" -ge "$XEN_MEM" ]; then
  echo "WARNING: DOM0_MEM=${DOM0_MEM}MB >= XEN_MEM=${XEN_MEM}MB; no room for DomUs."
  DOM0_MEM=$(( XEN_MEM * 80 / 100 ))
  echo "  Capping DOM0_MEM to ${DOM0_MEM}MB (80% of Xen budget)."
fi

echo "════════════════════════════════════════════════════════"
echo "  DevShot Orchestrator starting (x86_64)"
echo "════════════════════════════════════════════════════════"
echo "  CPU:        ${CPU_MODEL}"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  ${POOL_SIZE:-2}"
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
POOL_SIZE=${POOL_SIZE:-2}
READY_TIMEOUT=${READY_TIMEOUT:-300000}
LOG_LEVEL=${LOG_LEVEL:-info}
ENV

echo "[1/3] Agent env written to /xen/agent.env (mode 0600)"

# ── Boot QEMU with Xen (x86_64) ────────────────────────────────────────────

echo "[2/3] Booting Xen hypervisor via QEMU x86_64 (${ACCEL_LABEL})..."

[ -f /xen/dom0-rootfs-work.qcow2 ] || \
  qemu-img create -f qcow2 -b /xen/dom0-rootfs.qcow2 -F qcow2 /xen/dom0-rootfs-work.qcow2

# DOM0_DISK runtime resize (e.g. -e DOM0_DISK=16G). Grows the qcow2 here;
# the actual ext4 grow happens inside Dom0 via the dom0-resize-rootfs.service
# unit (see roles/dom0/files/configure-dom0.sh) which calls resize2fs on
# /dev/vda once on every boot. resize2fs is idempotent so the no-op case is
# safe. qemu-img resize itself refuses to shrink without --shrink, so a
# DOM0_DISK smaller than the current image is silently ignored with a warn.
if [ -n "${DOM0_DISK:-}" ]; then
  if qemu-img resize /xen/dom0-rootfs-work.qcow2 "$DOM0_DISK" >/tmp/resize.log 2>&1; then
    echo "  Dom0 disk resized to ${DOM0_DISK}"
  else
    echo "  WARNING: Could not resize Dom0 disk to ${DOM0_DISK}: $(cat /tmp/resize.log)"
    echo "  (qemu-img resize cannot shrink qcow2 without --shrink; current size kept)"
  fi
fi

qemu-system-x86_64 \
  -accel "${QEMU_ACCEL}" \
  -machine q35 \
  -cpu "${QEMU_CPU}" \
  -smp "${XEN_CPUS}" \
  -m "${XEN_MEM}" \
  -display none \
  -daemonize \
  -kernel /xen/xen \
  -append "dom0_mem=${DOM0_MEM}M,max:${DOM0_MEM}M loglvl=all guest_loglvl=all console=com1 com1=115200,8n1" \
  -initrd "/xen/vmlinuz console=hvc0 earlyprintk=xen root=/dev/vda rw" \
  -drive file=/xen/dom0-rootfs-work.qcow2,format=qcow2,if=none,id=hd0 \
  -device virtio-blk-pci,drive=hd0 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -fsdev local,id=xen_fs,path=/xen,security_model=none \
  -device virtio-9p-pci,fsdev=xen_fs,mount_tag=xen_shared \
  -fsdev local,id=orch_fs,path=/opt/devshot,security_model=none \
  -device virtio-9p-pci,fsdev=orch_fs,mount_tag=orchestrator \
  -serial unix:/tmp/qemu-console.sock,server,nowait \
  -monitor unix:/tmp/qemu-monitor.sock,server,nowait \
  -device virtio-serial-pci \
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

sleep 1
echo 'cont' | socat - UNIX-CONNECT:/tmp/qemu-monitor.sock,connect-timeout=3 >/dev/null 2>&1 || true
echo "  QEMU started (pid=$(cat /tmp/qemu.pid), accel=${QEMU_ACCEL%%,*})"

# ── Wait for agent ──────────────────────────────────────────────────────────

echo "[3/3] Waiting for Dom0 agent to start..."
echo "  (Dom0 systemd auto-mounts 9p and starts the agent)"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Orchestrator booting (x86_64)"
echo "  Accel:        ${ACCEL_LABEL}"
echo "  Server ID:    ${DEVSHOT_SERVER_ID}"
echo "  Tunnel:       ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:    ${POOL_SIZE:-2}"
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

# Hold open
wait "$(cat /tmp/qemu.pid)" 2>/dev/null || tail -f /dev/null
