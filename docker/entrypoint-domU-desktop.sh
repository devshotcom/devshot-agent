#!/bin/bash
set -eu

# ── Tunnel env vars are optional (standalone mode) ─────────────────────────

DEVSHOT_SERVER_ID="${DEVSHOT_SERVER_ID:-}"
DEVSHOT_HMAC_SECRET="${DEVSHOT_HMAC_SECRET:-}"
DEVSHOT_TUNNEL_URL="${DEVSHOT_TUNNEL_URL:-}"
STANDALONE=false
if [ -z "$DEVSHOT_SERVER_ID" ] || [ -z "$DEVSHOT_HMAC_SECRET" ] || [ -z "$DEVSHOT_TUNNEL_URL" ]; then
  STANDALONE=true
fi

# ── Derive VM identity ──────────────────────────────────────────────────────

DOMID="${DOMID:-1}"
XS_ROOT="${XS_ROOT:-/tmp/xenstore}"

if [ "$STANDALONE" = false ]; then
  VM_NAME="${DEVSHOT_VM_NAME:-domu-${DEVSHOT_SERVER_ID:0:8}}"
  VM_TOKEN_TS=$(date +%s)
  VM_TOKEN=$(printf "vm:%s:%s" "$VM_NAME" "$VM_TOKEN_TS" | openssl dgst -sha256 -hmac "$DEVSHOT_HMAC_SECRET" -hex 2>/dev/null | awk '{print $NF}')
fi

echo "════════════════════════════════════════════════════════"
echo "  DevShot DomU Desktop (Openbox + VNC + noVNC)"
echo "════════════════════════════════════════════════════════"
if [ "$STANDALONE" = true ]; then
  echo "  Mode:    Standalone (no tunnel)"
else
  echo "  Mode:    Tunnel"
  echo "  Server:  ${DEVSHOT_SERVER_ID}"
  echo "  VM:      ${VM_NAME}"
  echo "  Tunnel:  ${DEVSHOT_TUNNEL_URL}"
fi
echo "  VNC:     :0 (port ${VNC_PORT:-5900}, ${VNC_GEOMETRY:-1280x800})"
echo "  noVNC:   http://0.0.0.0:${NOVNC_PORT:-6080}/vnc.html"
echo ""

# ── Seed file-backed xenstore (tunnel mode only) ───────────────────────────

mkdir -p "$XS_ROOT"

if [ "$STANDALONE" = false ]; then
  xs_write() {
    local path="$1" value="$2"
    local file="${path#/}"
    file="${file//\//__}"
    printf '%s' "$value" > "${XS_ROOT}/${file}"
  }

  BASE="/local/domain/${DOMID}"
  xs_write "${BASE}/data/magic-key"  "$DEVSHOT_HMAC_SECRET"
  xs_write "${BASE}/data/tunnel-url" "$DEVSHOT_TUNNEL_URL"
  xs_write "${BASE}/data/server-id"  "$DEVSHOT_SERVER_ID"
  xs_write "${BASE}/data/vm-token"   "$VM_TOKEN"
  xs_write "${BASE}/data/vm-token-ts" "$VM_TOKEN_TS"
  xs_write "${BASE}/data/vm-name"    "$VM_NAME"
  xs_write "${BASE}/data/launch-nonce" "$(openssl rand -hex 16)"
  echo "  Xenstore seeded (${XS_ROOT})"
fi

# ── Start D-Bus ─────────────────────────────────────────────────────────────

mkdir -p /run/dbus
if [ ! -f /run/dbus/pid ] || ! kill -0 "$(cat /run/dbus/pid 2>/dev/null)" 2>/dev/null; then
  dbus-daemon --system --fork 2>/dev/null || true
fi

# ── Start VNC server (Xvnc) ────────────────────────────────────────────────

VNC_PORT="${VNC_PORT:-5900}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1280x800}"
VNC_DEPTH="${VNC_DEPTH:-24}"

mkdir -p /tmp/.X11-unix

# Start/restart Xvnc — handles both fresh start and container restart
start_xvnc() {
  # Clean stale Xvnc locks/sockets if process is dead (survives container restart)
  if ! pgrep -x Xvnc > /dev/null 2>&1; then
    rm -f /tmp/.X0-lock /tmp/.X1-lock /tmp/.X11-unix/X0 /tmp/.X11-unix/X1
  else
    echo "  Xvnc already running"
    return 0
  fi

  echo "  Starting Xvnc :0 (${VNC_GEOMETRY}, port ${VNC_PORT})..."
  su -s /bin/bash devshot -c "
    Xvnc :0 \
      -geometry ${VNC_GEOMETRY} \
      -depth ${VNC_DEPTH} \
      -rfbport ${VNC_PORT} \
      -SecurityTypes None \
      -AlwaysShared \
      -AcceptSetDesktopSize \
      -pn \
      -localhost=0 \
      2>/tmp/xvnc.log &
  "

  for i in $(seq 1 12); do
    [ -e /tmp/.X11-unix/X0 ] && break
    sleep 0.5
  done

  if [ ! -e /tmp/.X11-unix/X0 ]; then
    echo "ERROR: Xvnc failed to start. Log:"
    cat /tmp/xvnc.log 2>/dev/null || true
    return 1
  fi
  echo "  Xvnc started"
}

start_xvnc || exit 1

# ── Start desktop environment ───────────────────────────────────────────────

if ! pgrep -x openbox > /dev/null 2>&1; then
  echo "  Starting Openbox + tint2..."
  su -s /bin/bash devshot -c "
    export DISPLAY=:0
    openbox-session &
    sleep 0.5
    tint2 &
  "
  echo "  Desktop ready"
else
  echo "  Desktop already running"
fi

# ── Start websockify + noVNC (browser access) ──────────────────────────────

NOVNC_PORT="${NOVNC_PORT:-6080}"

if ! pgrep -x websockify > /dev/null 2>&1; then
  echo "  Starting noVNC on port ${NOVNC_PORT}..."
  websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" > /tmp/websockify.log 2>&1 &
  echo "  noVNC ready: http://0.0.0.0:${NOVNC_PORT}/vnc.html"
else
  echo "  noVNC already running"
fi
echo ""

# ── Start the Go agent (tunnel mode) or wait (standalone) ──────────────────

if [ "$STANDALONE" = true ]; then
  echo "  Standalone mode — no agent, waiting..."
  echo ""
  wait
else
  echo "  Starting DomU agent..."
  echo ""
  exec /opt/devshot/agent
fi
