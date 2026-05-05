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

apk update
apk add --no-cache \
    nodejs npm git \
    build-base python3 \
    ca-certificates

# Flowise's tree includes some sqlite/native-bindings packages that
# build via node-gyp during global install — build-base + python3 above
# cover them.
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
