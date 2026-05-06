#!/bin/sh
# Recipe: Flowise — visual builder for LLM agents, listens on :3000.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/flowise.sh --name=flowise
#
# Output template: devshot-guest-flowise.qcow2. Post-claim, run
# `start-flowise` (or `start-flowise -d` for detached) to launch.
#
# Spec 050 — declares the workload's TCP listen ports so the bake
# pipeline auto-populates each spawned VM's forward allowlist.
# devshot:exposed_ports=[{"port":3000,"name":"flowise","proto":"http"}]
set -eux

# Same 9p apk-cache + network fallback dance as recipes/hello.sh and
# recipes/n8n.sh. Mac dev nested QEMU slirp DNS is unreliable; the
# host's `apk fetch -R` cache mounts in as `apk_cache` and lets the
# bake install offline.
mkdir -p /tmp/apkcache
if mount -t 9p -o trans=virtio,version=9p2000.L,ro apk_cache /tmp/apkcache 2>/dev/null \
   && ls /tmp/apkcache/nodejs-*.apk >/dev/null 2>&1; then
  echo "Installing system deps from /tmp/apkcache (9p-shared host cache)"
  apk add --no-network --allow-untrusted /tmp/apkcache/*.apk
  umount /tmp/apkcache 2>/dev/null || true
else
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  apk update || echo "apk update warning (continuing with cached index)"
  apk add --no-cache nodejs npm git build-base python3 ca-certificates
fi

# Flowise's tree includes some sqlite/native-bindings packages that
# build via node-gyp during global install — build-base + python3 above
# cover them. npm install over Mac dev's nested slirp NAT is slow
# (~10-15 min on TCG aarch64). CI / Linux dom0 bakes this in seconds.
npm install -g flowise

cat > /usr/local/bin/start-flowise << 'LAUNCHER'
#!/bin/sh
# Start Flowise. Pass -d to run detached.
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi
export PORT=3000
export FLOWISE_PATH="${HOME}/.flowise"
mkdir -p "$FLOWISE_PATH"
if [ "$detached" = "1" ]; then
    nohup npx flowise start > "$FLOWISE_PATH/flowise.log" 2>&1 &
    echo "Flowise started in background — log: $FLOWISE_PATH/flowise.log"
    echo "Listening on :3000 — http://localhost:3000 from the host"
else
    exec npx flowise start
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-flowise

echo "=== Flowise recipe complete ==="
node --version
npx flowise --version || true
sync
