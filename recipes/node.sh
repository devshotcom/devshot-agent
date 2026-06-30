#!/bin/sh
# Recipe: Node — Node.js + npm + a baked Next.js starter listening on
# :3000. Generic enough that other node frameworks can ride the same
# template by adding an APP_PRESETS entry with workload='node' and
# dropping a matching /usr/local/bin/start-<name> launcher.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/node.sh --name=node
#
# Output template: devshot-guest-node.qcow2. Every VM spawned from it
# boots straight into the Next.js app via OpenRC.
#
# Spec 050 — declared listen ports auto-populate the per-VM forward
# allowlist:
# devshot:exposed_ports=[{"port":3000,"name":"nextjs","proto":"http"}]
# devshot:memory_mb=512
set -eux

apk update
apk add --no-cache git nodejs npm ca-certificates

# Latest Next.js starter. npx pulls create-next-app@latest from npm at
# bake time, so every rebuild picks up whatever's current. --yes accepts
# defaults (TypeScript + ESLint + Tailwind + App Router) and --use-npm
# pins the package manager so a later yarn/pnpm sneak-in won't confuse
# the start script.
mkdir -p /var/www
cd /var/www
npx --yes create-next-app@latest nextjs --yes --use-npm

cd /var/www/nextjs
npm run build
# Drop dev-only deps now that .next/ is on disk. `next` itself lives in
# dependencies, so the runtime stays intact — strips ~150 MB of TS /
# ESLint / Tailwind tooling we don't need at request time.
npm prune --omit=dev

cat > /usr/local/bin/start-node <<'LAUNCHER'
#!/bin/sh
# Start the baked Next.js app. -d runs detached and returns.
detached=0
[ "${1-}" = "-d" ] && detached=1
cd /var/www/nextjs
LOG="${LOG:-/tmp/nextjs.log}"
export PORT="${PORT:-3000}"
export HOSTNAME="${HOSTNAME:-0.0.0.0}"
if [ "$detached" = "1" ]; then
    nohup npm run start > "$LOG" 2>&1 &
    echo "Next.js started in background — log: $LOG"
    echo "Listening on :$PORT"
else
    exec npm run start
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-node

# OpenRC auto-start so the iframe finds :3000 alive the moment the VM
# reaches "ready" — same pattern as the hello / lamp recipes.
cat > /etc/init.d/devshot-node <<'INITD'
#!/sbin/openrc-run

description="DevShot Next.js (next start on :3000)"

depend() {
    need net
    after networking
}

start() {
    ebegin "Starting Next.js"
    /usr/local/bin/start-node -d
    eend $?
}

stop() {
    ebegin "Stopping Next.js"
    pkill -f 'next-server' 2>/dev/null || true
    eend 0
}

status() {
    if pgrep -f 'next-server' >/dev/null 2>&1; then
        einfo "running"
        return 0
    fi
    einfo "stopped"
    return 3
}
INITD
chmod +x /etc/init.d/devshot-node
rc-update add devshot-node default

# Cleanup — npm cache + tmp dirs from create-next-app's archive extract.
rm -rf /root/.npm /tmp/* /var/cache/apk/*

echo "=== Node recipe complete ==="
node --version
npm --version
du -sh /var/www/nextjs
sync
