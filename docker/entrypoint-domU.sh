#!/bin/bash
set -eu

# ── Validate required env vars ──────────────────────────────────────────────

: "${DEVSHOT_SERVER_ID:?ERROR: DEVSHOT_SERVER_ID is required. Create a server in the DevShot console.}"
: "${DEVSHOT_HMAC_SECRET:?ERROR: DEVSHOT_HMAC_SECRET is required. Copy the key from the console.}"
: "${DEVSHOT_TUNNEL_URL:?ERROR: DEVSHOT_TUNNEL_URL is required. Example: wss://console.devshot.com}"

# ── Derive VM identity ──────────────────────────────────────────────────────

VM_NAME="${DEVSHOT_VM_NAME:-domu-${DEVSHOT_SERVER_ID:0:8}}"
DOMID="${DOMID:-1}"
XS_ROOT="${XS_ROOT:-/tmp/xenstore}"

# Compute time-bound VM token: HMAC-SHA256(hmac_secret, "vm:{name}:{timestamp}")
VM_TOKEN_TS=$(date +%s)
VM_TOKEN=$(printf "vm:%s:%s" "$VM_NAME" "$VM_TOKEN_TS" | openssl dgst -sha256 -hmac "$DEVSHOT_HMAC_SECRET" -hex 2>/dev/null | awk '{print $NF}')

echo "════════════════════════════════════════════════════════"
echo "  DevShot DomU (standalone)"
echo "════════════════════════════════════════════════════════"
echo "  Server ID: ${DEVSHOT_SERVER_ID}"
echo "  VM Name:   ${VM_NAME}"
echo "  Tunnel:    ${DEVSHOT_TUNNEL_URL}"
echo ""

# ── Seed file-backed xenstore ───────────────────────────────────────────────
# The Go agent reads tunnel config from xenstore paths.
# File-backed xenstore maps /local/domain/1/data/X to $XS_ROOT/local__domain__1__data__X

mkdir -p "$XS_ROOT"

xs_write() {
  local path="$1" value="$2"
  # Convert xenstore path to filename: strip leading /, replace / with __
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

# ── Start the Go agent ──────────────────────────────────────────────────────

echo "  Starting DomU agent..."
echo ""
exec /opt/devshot/agent
