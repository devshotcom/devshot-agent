#!/bin/bash
# DevShot Orchestrator entrypoint
# Boots QEMU/Xen, Dom0 auto-starts the Go agent via systemd. No SSH.
set -u

# ── Load mounted credentials before validation ─────────────────────────────
. /opt/devshot/load-credentials.sh

# ── Validate required env vars ──────────────────────────────────────────────

: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required.}"
: "${DEVSHOT_TUNNEL_URL:?ERROR: DEVSHOT_TUNNEL_URL is required.}"

# Keep prebaked templates available even when /xen/guests is bind-mounted.
/opt/devshot/sync-templates.sh

# ── Detect hardware acceleration ───────────────────────────────────────────
# Prefer KVM when /dev/kvm is available (Linux with VT-x/AMD-V),
# fall back to TCG software emulation otherwise.

QEMU_ACCEL="tcg,thread=multi"
QEMU_CPU="max"
ACCEL_LABEL="TCG (software — no KVM)"
if [ -w /dev/kvm ]; then
  QEMU_ACCEL="kvm"
  QEMU_CPU="host"
  ACCEL_LABEL="KVM (hardware virtualization)"
fi

# ── Detect host hardware ─────────────────────────────────────────────────
# With --network=host/--privileged the container sees real host resources.

TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
CPU_CORES=$(nproc)
CPU_MODEL=$(grep -m1 'model name\|Processor' /proc/cpuinfo | cut -d: -f2 | xargs)
[ -z "$CPU_MODEL" ] && CPU_MODEL="arm64"

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
echo "  DevShot Orchestrator starting (arm64)"
echo "════════════════════════════════════════════════════════"
echo "  CPU:        ${CPU_MODEL}"
echo "  Host RAM:   ${TOTAL_RAM_MB}MB  CPUs: ${CPU_CORES}"
echo "  Server ID:  ${DEVSHOT_SERVER_ID}"
echo "  Tunnel URL: ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:  (set by console — pushed via tunnel config on connect)"
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
# Dom0 systemd reads /xen/agent.env on boot

install -m 0600 /dev/null /xen/agent.env
cat > /xen/agent.env <<ENV
XS_REAL=1
RUN_AS_USER=devshot
DEVSHOT_SERVER_ID=${DEVSHOT_SERVER_ID}
DEVSHOT_HMAC_SECRET=${DEVSHOT_HMAC_SECRET}
DEVSHOT_TUNNEL_URL=${DEVSHOT_TUNNEL_URL}
DEVSHOT_TLS_SKIP=${DEVSHOT_TLS_SKIP:-0}
# POOL_SIZE intentionally NOT written: agent reads its target from
# the console's `config` push (servers.pool_size). See
# apps/agent/go/vmmanager.go.
READY_TIMEOUT=${READY_TIMEOUT:-300000}
LOG_LEVEL=${LOG_LEVEL:-info}
LAMP_RELEASE_INDEX_URL=${LAMP_RELEASE_INDEX_URL:-https://github.com/devshotcom/devshot-agent/releases/download/lamp-matrix-latest/lamp-matrix-index-v2.json}
LAMP_SYNC_INTERVAL=${LAMP_SYNC_INTERVAL:-5m}
LAMP_SYNC_DOWNLOAD_TIMEOUT=${LAMP_SYNC_DOWNLOAD_TIMEOUT:-30m}
S3_ENDPOINT=${S3_ENDPOINT:-}
S3_BUCKET=${S3_BUCKET:-}
S3_ACCESS_KEY=${S3_ACCESS_KEY:-}
S3_SECRET_KEY=${S3_SECRET_KEY:-}
S3_REGION=${S3_REGION:-us-east-1}
ENV

echo "[1/3] Agent env written to /xen/agent.env (mode 0600)"

# ── Boot QEMU with Xen ──────────────────────────────────────────────────────

echo "[2/3] Booting Xen hypervisor via QEMU..."

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

# Launch QEMU (daemonized). Returns 0 on success, non-zero if QEMU fails to start.
# Writes its PID to /tmp/qemu.pid. Cleans up stale sockets before starting so
# restarts don't trip on leftover /tmp/qemu-*.sock files.
start_qemu() {
  rm -f /tmp/qemu-monitor.sock /tmp/qemu-console.sock /tmp/qemu-ga.sock /tmp/qemu-recovery.sock /tmp/qemu.pid 2>/dev/null || true

  qemu-system-aarch64 \
    -accel "${QEMU_ACCEL}" \
    -machine virt,gic-version=3,virtualization=true \
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
    return 1
  fi

  # Ensure QEMU is running (may start paused on some platforms)
  sleep 1
  echo 'cont' | socat - UNIX-CONNECT:/tmp/qemu-monitor.sock,connect-timeout=3 >/dev/null 2>&1 || true
  echo "  QEMU started (pid=$(cat /tmp/qemu.pid))"
  return 0
}

if ! start_qemu; then
  exit 1
fi

# ── Wait for agent ──────────────────────────────────────────────────────────
# Dom0 boots → systemd mounts 9p → starts devshot-agent → connects to tunnel

echo "[3/3] Waiting for Dom0 agent to start..."
echo "  (Dom0 systemd auto-mounts 9p and starts the agent)"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Orchestrator booting. Agent will connect when Dom0 is ready."
echo "  Server ID:    ${DEVSHOT_SERVER_ID}"
echo "  Tunnel:       ${DEVSHOT_TUNNEL_URL}"
echo "  Pool size:    (set by console — pushed via tunnel config on connect)"
echo "  Xen:          ${XEN_MEM}MB / ${XEN_CPUS} CPUs"
echo "  Console:      socat - UNIX-CONNECT:/tmp/qemu-console.sock"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Start QEMU tunnel agent (KVM serial console) ────────────────────────────
# Runs at the container level (not inside the VM). Connects to the tunnel
# as "qemu-<serverID[:8]>" and bridges terminal opens to the QEMU serial socket.

mkdir -p /tmp/xenstore-qemu

# Seed xenstore for the QEMU agent
xs_qemu_write() {
  local path="$1" value="$2"
  local file="${path#/}"
  file="${file//\//__}"
  printf '%s' "$value" > "/tmp/xenstore-qemu/${file}"
}

QEMU_VM_NAME="qemu-${DEVSHOT_SERVER_ID:0:8}"
QEMU_VM_TOKEN_TS=$(date +%s)
QEMU_VM_TOKEN=$(printf "vm:%s:%s" "$QEMU_VM_NAME" "$QEMU_VM_TOKEN_TS" | openssl dgst -sha256 -hmac "$DEVSHOT_HMAC_SECRET" -hex 2>/dev/null | awk '{print $NF}')

xs_qemu_write "/local/domain/0/data/magic-key"  "$DEVSHOT_HMAC_SECRET"
xs_qemu_write "/local/domain/0/data/tunnel-url" "$DEVSHOT_TUNNEL_URL"
xs_qemu_write "/local/domain/0/data/server-id"  "$DEVSHOT_SERVER_ID"
xs_qemu_write "/local/domain/0/data/vm-token"   "$QEMU_VM_TOKEN"
xs_qemu_write "/local/domain/0/data/vm-token-ts" "$QEMU_VM_TOKEN_TS"
xs_qemu_write "/local/domain/0/data/vm-name"    "$QEMU_VM_NAME"

# Launch the container-level qemu-role agent. Keeps its PID in QEMU_AGENT_PID
# so the supervisor loop below can detect crashes and restart it.
start_qemu_agent() {
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
  QEMU_AGENT_PID=$!
}

start_qemu_agent
echo "  QEMU agent started as ${QEMU_VM_NAME} (pid=${QEMU_AGENT_PID})"

# ── Supervisor loop ────────────────────────────────────────────────────────
# Both QEMU (the emulator running the dom0 VM) and the container-level qemu
# agent can crash. Previously the entrypoint would `wait` on QEMU and then
# fall back to `tail -f /dev/null`, leaving the container alive but with a
# dead VM and no dom0-* agent in the tunnel.
#
# Here we poll both processes every few seconds and restart whichever died:
#   - QEMU gone      → re-launch via start_qemu (rebuilds sockets, restarts VM)
#   - qemu agent gone → re-launch via start_qemu_agent
# An exponential backoff (up to 30s) prevents tight crash loops.

SUPERVISE_INTERVAL=5
QEMU_BACKOFF=1
AGENT_BACKOFF=1
MAX_BACKOFF=30

while true; do
  sleep "$SUPERVISE_INTERVAL"

  # ── QEMU check ──
  QEMU_PID="$(cat /tmp/qemu.pid 2>/dev/null || true)"
  if [ -z "$QEMU_PID" ] || ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo ""
    echo "[supervisor] QEMU process is gone (was pid=${QEMU_PID:-?}) — restarting in ${QEMU_BACKOFF}s"
    sleep "$QEMU_BACKOFF"
    if start_qemu; then
      echo "[supervisor] QEMU restarted successfully"
      QEMU_BACKOFF=1
    else
      echo "[supervisor] QEMU failed to restart — will retry"
      QEMU_BACKOFF=$(( QEMU_BACKOFF * 2 ))
      [ "$QEMU_BACKOFF" -gt "$MAX_BACKOFF" ] && QEMU_BACKOFF=$MAX_BACKOFF
    fi
  else
    QEMU_BACKOFF=1
  fi

  # ── qemu agent check ──
  if ! kill -0 "$QEMU_AGENT_PID" 2>/dev/null; then
    echo ""
    echo "[supervisor] qemu agent (pid=${QEMU_AGENT_PID}) exited — restarting in ${AGENT_BACKOFF}s"
    sleep "$AGENT_BACKOFF"
    start_qemu_agent
    echo "[supervisor] qemu agent restarted (pid=${QEMU_AGENT_PID})"
    AGENT_BACKOFF=$(( AGENT_BACKOFF * 2 ))
    [ "$AGENT_BACKOFF" -gt "$MAX_BACKOFF" ] && AGENT_BACKOFF=$MAX_BACKOFF
  else
    AGENT_BACKOFF=1
  fi
done
