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
# for the editor tarball.
apk add --no-cache nodejs npm gcompat ca-certificates wget tar

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
npm run build || true   # best-effort prebuild of .next cache; dev still recompiles

cat > /usr/local/bin/start-studio <<'LAUNCHER'
#!/bin/sh
# Start the Next.js dev server (hot reload). -d runs detached and returns.
detached=0
[ "${1-}" = "-d" ] && detached=1
cd /var/www/studio
LOG="${LOG:-/tmp/studio-dev.log}"
PORT="${PORT:-3000}"
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

description="DevShot Studio app (next dev, hot reload on :3000)"

depend() {
    need net
    after networking
}

start() {
    ebegin "Starting Studio dev server"
    /usr/local/bin/start-studio -d
    eend $?
}

stop() {
    ebegin "Stopping Studio dev server"
    pkill -f 'next dev' 2>/dev/null || true
    pkill -f 'next-server' 2>/dev/null || true
    eend 0
}

status() {
    if pgrep -f 'next' >/dev/null 2>&1; then
        einfo "running"
        return 0
    fi
    einfo "stopped"
    return 3
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
