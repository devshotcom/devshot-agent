#!/bin/sh
# Recipe: n8n — workflow automation, listens on :5678 by default.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/n8n.sh --name=n8n
#
# The output template is devshot-guest-n8n.qcow2 — every VM spawned from
# it has n8n already installed. The user post-claim runs `start-n8n` to
# launch the daemon (foreground) or `start-n8n -d` for a detached run.
#
# Spec 050 — declares the workload's TCP listen ports so the bake
# pipeline auto-populates each spawned VM's forward allowlist. Operators
# can punch additional holes per-VM via vm-forward-add at runtime.
# devshot:exposed_ports=[{"port":5678,"name":"n8n","proto":"http"}]
set -eux

apk update
apk add --no-cache \
    nodejs npm git \
    build-base python3 \
    ca-certificates

# Global install — n8n's own postinstall hook handles compile of native
# deps via node-gyp (build-base + python3 above are required for that).
npm install -g n8n

# Launcher dropped in /usr/local/bin so the user doesn't have to remember
# the binary name + port. Runs as the devshot user with N8N_USER_FOLDER
# pointing at the user's workspace so installs persist across boots only
# if the disk is persistent — bake VMs are ephemeral by default.
cat > /usr/local/bin/start-n8n << 'LAUNCHER'
#!/bin/sh
# Start n8n. Pass -d to run detached.
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi
export N8N_HOST=0.0.0.0
export N8N_PORT=5678
export N8N_USER_FOLDER="${HOME}/.n8n"
mkdir -p "$N8N_USER_FOLDER"
if [ "$detached" = "1" ]; then
    nohup n8n > "$N8N_USER_FOLDER/n8n.log" 2>&1 &
    echo "n8n started in background — log: $N8N_USER_FOLDER/n8n.log"
    echo "Listening on :5678 — http://localhost:5678 from the host"
else
    exec n8n
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-n8n

echo "=== n8n recipe complete ==="
node --version
n8n --version
