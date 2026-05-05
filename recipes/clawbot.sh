#!/bin/sh
# Recipe: OpenClaw (Clawbot) — local AI assistant Gateway. Source:
# https://github.com/openclaw/openclaw
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/clawbot.sh --name=clawbot
#
# Output template: devshot-guest-clawbot.qcow2. The Gateway daemon is
# NOT auto-started or onboarded inside the bake — `openclaw onboard`
# wants interactive input + provider keys, both of which belong to the
# end user, not the template. Post-claim, the user runs
# `openclaw onboard --install-daemon` themselves with their own creds.
#
# Spec 050 — Clawbot's Gateway port is decided at onboard time (per-user
# provider config), so this template ships an empty allowlist. Operators
# add the actual port via vm-forward-add after the user picks one.
# devshot:exposed_ports=[]
set -eux

apk update
apk add --no-cache \
    nodejs npm git \
    build-base python3 \
    ca-certificates

# OpenClaw requires Node 22.14+ or 24. Alpine 3.23 ships Node 24.x, so
# the apk-installed nodejs already meets the floor — no extra version
# pinning needed.
node_major=$(node -p 'process.versions.node.split(".")[0]')
if [ "$node_major" -lt 22 ]; then
    echo "ERROR: openclaw needs Node 22.14+ or 24, got $(node --version)" >&2
    exit 1
fi

# Global install of the published package.
npm install -g openclaw@latest

# pnpm is the project's recommended package manager and the onboarding
# hook may invoke it for sub-package installs. Drop it in too so the
# user doesn't hit a "pnpm: not found" on first run.
npm install -g pnpm

# Launcher: thin wrapper that reminds the user about the onboarding
# step. Onboarding writes config under $HOME/.openclaw and registers
# the daemon — both must be done with the user's own credentials.
cat > /usr/local/bin/start-clawbot << 'LAUNCHER'
#!/bin/sh
# First run? Onboard. Subsequent runs? Just start the gateway.
if [ ! -f "$HOME/.openclaw/config.json" ]; then
    echo "First run — running 'openclaw onboard --install-daemon'."
    echo "You'll be asked for an AI model provider (e.g. OpenAI/Anthropic) key."
    openclaw onboard --install-daemon
else
    openclaw start
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-clawbot

echo "=== OpenClaw / Clawbot recipe complete ==="
node --version
openclaw --version || true
