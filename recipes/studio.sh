#!/bin/sh
# Recipe: Studio — the fresh per-session app VM behind studio.devshot.com.
# A Next.js (App Router, TS, Tailwind) starter served in DEV mode with hot
# reload on :3000, plus openvscode-server on :8080 opened to the project.
# The DevShot Studio agent edits files in /var/www/studio via vm-exec; the
# running dev server reflects the change in the visitor's live preview.
#
# Why dev mode (not `next start` like node.sh): Studio is interactive — the
# AI rewrites files mid-session and the user must see the result instantly.
# `next dev` watches the filesystem and hot-reloads; a prod build would
# need a rebuild per change. So we keep the dev toolchain (no npm prune).
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/studio.sh --name=studio
# Output template: devshot-guest-studio.qcow2 (claimed as template "studio").
#
# Spec 050 — declared listen ports auto-populate the per-VM forward allowlist:
# devshot:exposed_ports=[{"port":3000,"name":"app","proto":"http"},{"port":8080,"name":"editor","proto":"http"}]
# devshot:memory_mb=2048
set -eux

apk update
# nodejs/npm for Next.js; gcompat so openvscode-server's optional glibc
# .node modules (watcher/spdlog/vsda) dlopen cleanly under musl; wget/tar
# for the editor tarball. chromium (+swiftshader for GPU-less headless +
# ttf-freefont) powers inspect_preview's real screenshot for the multimodal agent.
apk add --no-cache nodejs npm gcompat ca-certificates wget tar chromium chromium-swiftshader ttf-freefont

# --- Next.js starter at /var/www/studio ------------------------------
# create-next-app@latest at bake time → always the current starter.
# --yes accepts defaults (TypeScript + ESLint + Tailwind + App Router);
# --use-npm pins the package manager. NOTE: we deliberately do NOT build
# or prune — the VM runs `next dev`.
mkdir -p /var/www
cd /var/www
npx --yes create-next-app@latest studio --yes --use-npm

# Warm the dependency tree / Next binary so the first request after boot
# compiles fast rather than also resolving modules.
cd /var/www/studio

# --- Asset prefix for the path-based public proxy --------------------
# The preview is served behind /api/public/p/<vm>/<port>/, but Next.js loads
# its runtime chunks/fonts/CSS from the ORIGIN ROOT (/_next/...) by default —
# which, inside the proxied iframe, resolves to the console origin and 404s
# every asset (blank/unstyled preview). Point Next's assetPrefix at the per-VM
# proxy path so every emitted /_next/... URL routes back through the proxy to
# this VM. The value can't be baked (it depends on the VM name) — start-studio
# exports DEVSHOT_ASSET_PREFIX per-VM and `next dev` reads it at launch. Replace
# any starter config so there's a single next.config Next will read.
rm -f next.config.js next.config.mjs next.config.ts
cat > next.config.mjs <<'NEXTCONFIG'
// Managed by the DevShot Studio recipe — serves build assets under the per-VM
// public-proxy path. DEVSHOT_ASSET_PREFIX is exported by start-studio from this
// VM's xenstore vm-name; unset in a plain `next build`, so config stays default.
const assetPrefix = process.env.DEVSHOT_ASSET_PREFIX || undefined;

/** @type {import('next').NextConfig} */
const nextConfig = assetPrefix
  ? { assetPrefix, images: { path: `${assetPrefix}/_next/image` } }
  : {};

export default nextConfig;
NEXTCONFIG

npm run build || true   # best-effort prebuild of .next cache; dev still recompiles

cat > /usr/local/bin/start-studio <<'LAUNCHER'
#!/bin/sh
# Start the Next.js dev server (hot reload). -d runs detached and returns.
# A sane PATH so this works under supervise-daemon's minimal environment too.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
detached=0
[ "${1-}" = "-d" ] && detached=1
cd /var/www/studio
LOG="${LOG:-/tmp/studio-dev.log}"
PORT="${PORT:-3000}"

# Derive the public-proxy asset prefix from this VM's name so Next.js emits its
# runtime /_next/... chunk/font/CSS URLs under /api/public/p/<vm>/<PORT>/...
# instead of the iframe-origin root (which 404s behind the path proxy). The VM
# name lives in xenstore: real xenstored under Xen, the 9p FileXenstore file
# tree (mounted at $XS_ROOT by start-agent.sh) under QEMU. Both are root-owned
# 0600 (the 9p files carry the orchestrator's uid), and this launcher runs as
# the unprivileged `devshot` user — so read through the sandbox's passwordless
# sudo rather than fail the perms check.
read_xs_value() {
    if [ -e /proc/xen/xenbus ]; then
        _domid="$(sudo -n xenstore-read /local/domain/self/domid 2>/dev/null \
            || xenstore-read /local/domain/self/domid 2>/dev/null || echo 0)"
        sudo -n xenstore-read "/local/domain/${_domid}/data/$1" 2>/dev/null \
            || xenstore-read "/local/domain/${_domid}/data/$1" 2>/dev/null || true
    else
        _xf="${XS_ROOT:-/tmp/xenstore}/local__domain__1__data__$1"
        sudo -n cat "$_xf" 2>/dev/null || cat "$_xf" 2>/dev/null || true
    fi
}
# The 9p share / xenstored may settle just after this service starts, so poll
# briefly; fall back to no prefix (degraded, not hung) rather than block boot.
VM_NAME=""
i=0
while [ "$i" -lt 15 ]; do
    VM_NAME="$(read_xs_value vm-name)"
    [ -n "$VM_NAME" ] && break
    i=$((i + 1))
    sleep 1
done
if [ -n "$VM_NAME" ]; then
    export DEVSHOT_ASSET_PREFIX="/api/public/p/${VM_NAME}/${PORT}"
    echo "Studio asset prefix: $DEVSHOT_ASSET_PREFIX"
else
    echo "WARN: vm-name not found in xenstore — assets may 404 behind the proxy" >&2
fi

# Bind 0.0.0.0 so the console public proxy can reach it; pass through the
# project's dev script (Turbopack/webpack) with host+port.
if [ "$detached" = "1" ]; then
    nohup npm run dev -- -H 0.0.0.0 -p "$PORT" > "$LOG" 2>&1 &
    echo "Studio dev server started — log: $LOG (listening on :$PORT)"
else
    exec npm run dev -- -H 0.0.0.0 -p "$PORT"
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-studio

cat > /etc/init.d/devshot-studio <<'INITD'
#!/sbin/openrc-run

name="devshot-studio"
description="DevShot Studio app (next dev, hot reload on :3000)"

# Supervised (not a hand-rolled `nohup … &`): supervise-daemon keeps the dev
# server alive and AUTO-RESTARTS it on crash. The public readiness probe hits
# :3000 — an unsupervised server that died at boot would otherwise leave the
# visitor stuck on "booting" forever with no recovery. `rc-service
# devshot-studio status` then reports the real state, which the boot screen
# surfaces. Runs in the foreground (start-studio without -d) so the supervisor
# tracks the actual process; stdout/stderr go to the log the boot screen tails.
supervisor=supervise-daemon
command="/usr/local/bin/start-studio"
command_user="devshot:devshot"
pidfile="/run/devshot-studio.pid"
output_log="/tmp/studio-dev.log"
error_log="/tmp/studio-dev.log"
respawn_delay=3
respawn_max=0

depend() {
    need net
    after networking firewall
}
INITD
chmod +x /etc/init.d/devshot-studio
rc-update add devshot-studio default

# --- openvscode-server (in-browser editor on :8080) ------------------
# Same Gitpod fork + system-Node approach the LAMP recipe uses (see
# recipes/lamp/_core.sh for the gcompat rationale). Opened to the studio
# project so claim → editor lands on the app files.
OPENVSCODE_VERSION="${OPENVSCODE_VERSION:-1.95.2}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  OV_ARCH=x64 ;;
  aarch64) OV_ARCH=arm64 ;;
  *)       echo "ERROR: unsupported arch $ARCH for openvscode-server" >&2; exit 1 ;;
esac
mkdir -p /opt/openvscode-server
wget -q -O /tmp/openvscode.tar.gz \
  "https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OPENVSCODE_VERSION}/openvscode-server-v${OPENVSCODE_VERSION}-linux-${OV_ARCH}.tar.gz"
tar -xzf /tmp/openvscode.tar.gz -C /opt/openvscode-server --strip-components=1
rm /tmp/openvscode.tar.gz
node /opt/openvscode-server/out/server-main.js --version | head -1

# Editor profile: Dark Modern, no welcome, trust off (it's a throwaway VM).
mkdir -p /home/devshot/.openvscode-server/data/User /home/devshot/.openvscode-server/data/Machine
cat > /home/devshot/.openvscode-server/data/User/settings.json <<'SETTINGS'
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.startupEditor": "none",
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.startupPrompt": "never",
  "security.workspace.trust.untrustedFiles": "open",
  "terminal.integrated.defaultProfile.linux": "bash",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 800,
  "editor.fontSize": 13,
  "explorer.confirmDelete": false,
  "explorer.confirmDragAndDrop": false,
  "workbench.welcomePage.walkthroughs.openOnInstall": false,
  "workbench.welcomePageOnStartup": false,
  "workbench.tips.enabled": false,
  "workbench.colorCustomizations": {
    "editor.background": "#0d0e13",
    "editor.foreground": "#e8e9eb",
    "editorCursor.foreground": "#22c55e",
    "editor.selectionBackground": "#22c55e33",
    "sideBar.background": "#0b0d11",
    "sideBar.foreground": "#c9cdd3",
    "sideBarSectionHeader.background": "#11131a",
    "activityBar.background": "#0b0d11",
    "activityBar.foreground": "#e8e9eb",
    "activityBar.inactiveForeground": "#777e89",
    "activityBar.activeBorder": "#22c55e",
    "activityBarBadge.background": "#22c55e",
    "activityBarBadge.foreground": "#0d0e13",
    "titleBar.activeBackground": "#0b0d11",
    "titleBar.activeForeground": "#e8e9eb",
    "menubar.selectionBackground": "#1f2228",
    "statusBar.background": "#22c55e",
    "statusBar.foreground": "#0d0e13",
    "statusBar.noFolderBackground": "#22c55e",
    "statusBarItem.remoteBackground": "#1a7f37",
    "editorGroupHeader.tabsBackground": "#0b0d11",
    "tab.activeBackground": "#0d0e13",
    "tab.activeForeground": "#ffffff",
    "tab.inactiveBackground": "#0b0d11",
    "tab.inactiveForeground": "#777e89",
    "tab.activeBorderTop": "#22c55e",
    "tab.hoverBackground": "#11131a",
    "panel.background": "#0b0d11",
    "panel.border": "#232831",
    "panelTitle.activeBorder": "#22c55e",
    "terminal.background": "#0b0d11",
    "terminal.foreground": "#c9cdd3",
    "input.background": "#11131a",
    "input.border": "#232831",
    "dropdown.background": "#11131a",
    "focusBorder": "#22c55e",
    "inputOption.activeBorder": "#22c55e",
    "button.background": "#22c55e",
    "button.foreground": "#0d0e13",
    "button.hoverBackground": "#2ee06a",
    "button.secondaryBackground": "#1f2228",
    "button.secondaryForeground": "#e8e9eb",
    "list.activeSelectionBackground": "#1f2228",
    "list.activeSelectionForeground": "#6ee79f",
    "list.hoverBackground": "#11131a",
    "list.highlightForeground": "#22c55e",
    "quickInput.background": "#0d0e13",
    "quickInputList.focusBackground": "#1f2228",
    "quickInputList.focusForeground": "#6ee79f",
    "pickerGroup.foreground": "#22c55e",
    "progressBar.background": "#22c55e",
    "textLink.foreground": "#6ee79f",
    "textLink.activeForeground": "#22c55e",
    "editorWidget.background": "#11131a",
    "editorWidget.border": "#232831",
    "badge.background": "#22c55e",
    "badge.foreground": "#0d0e13"
  }
}
SETTINGS

# The editor opens the studio project; the agent and editor share these files.
echo /var/www/studio > /etc/openvscode-default-folder
# Let the devshot user (editor) and root (agent vm-exec) both work the tree.
chown -R devshot:devshot /home/devshot /var/www/studio
install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser (openvscode-server) — DevShot Studio editor"
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder 2>/dev/null || echo /var/www/studio)"
command="/usr/bin/node"
command_args="/opt/openvscode-server/out/server-main.js \
  --host 0.0.0.0 --port 8080 \
  --without-connection-token \
  --disable-telemetry \
  --disable-workspace-trust \
  --user-data-dir /home/devshot/.openvscode-server/data \
  --server-data-dir /home/devshot/.openvscode-server \
  --default-folder $DEFAULT_FOLDER"
command_user="devshot:devshot"
command_background=true
pidfile="/run/openvscode-server.pid"
output_log="/var/log/openvscode-server.log"
error_log="/var/log/openvscode-server.log"

depend() {
    need net
    after firewall
}
SVC
chmod +x /etc/init.d/openvscode-server
rc-update add openvscode-server default

# --- Cleanup ---------------------------------------------------------
rm -rf /root/.npm /tmp/* /var/cache/apk/*

echo "=== Studio recipe complete ==="
node --version
npm --version
du -sh /var/www/studio
sync
