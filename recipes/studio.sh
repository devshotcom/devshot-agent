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
apk add --no-cache git nodejs npm gcompat ca-certificates wget tar chromium chromium-swiftshader ttf-freefont

# Runtime tools and start-studio use sudo as the unprivileged devshot user.
# Make that contract explicit in the flavored image instead of relying on the
# base template to carry the drop-in forever.
install -d -m 0750 /etc/sudoers.d
printf 'devshot ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/devshot
chmod 0440 /etc/sudoers.d/devshot
visudo -cf /etc/sudoers

# --- Grok Build ACP agent -------------------------------------------------
# Studio chat is an ACP window onto the agent inside this VM. Pin both native
# Linux artifacts by version + digest so Mac/ARM64 development and x86_64
# production run the same reviewed Grok release without a runtime download.
GROK_VERSION=1.0.0
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    GROK_ARCH=x86_64
    GROK_SHA256=28dbc967a5843dae2374b6834dadbab95354e685c7e5c8dc750b92a4e5fc7c3e
    ;;
  aarch64|arm64)
    GROK_ARCH=aarch64
    GROK_SHA256=bb7c51116564a2219f6a49850815060f416918ac407f1f2ba82c53c0b0d4383f
    ;;
  *)
    echo "ERROR: unsupported architecture $ARCH for Grok Build" >&2
    exit 1
    ;;
esac
mkdir -p /opt/grok
wget -q -O /tmp/grok "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${GROK_VERSION}-linux-${GROK_ARCH}"
echo "${GROK_SHA256}  /tmp/grok" | sha256sum -c -
install -m 0755 /tmp/grok /opt/grok/grok
ln -sfn /opt/grok/grok /usr/local/bin/grok
rm -f /tmp/grok
grok --version | head -1

# E2E browser-testing harness deps: puppeteer-core drives the chromium above so the
# agent's run_e2e tool can PROVE functionality (clicks/inputs/assertions), not just
# that a page renders. Installed into a fixed /opt path at BAKE time (network is
# available here) so it works OFFLINE on the network-locked runtime VM. puppeteer-core
# ships NO browser of its own (PUPPETEER_SKIP_DOWNLOAD=1; it uses the apk chromium),
# so this stays small. The runner (.devshot/e2e-runner.cjs) requires it by absolute path.
install -d /opt/devshot-e2e
( cd /opt/devshot-e2e && npm init -y >/dev/null 2>&1 && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --omit=dev puppeteer-core )

# --- Next.js starter at /var/www/studio ------------------------------
# create-next-app@latest at bake time → always the current starter.
# --yes accepts defaults (TypeScript + ESLint + Tailwind + App Router);
# --use-npm pins the package manager. NOTE: we deliberately do NOT build
# or prune — the VM runs `next dev`.
# Build the starter AS the devshot user — the dev server, editor, and (at
# runtime) the agent's vm-exec all run as devshot, so building as devshot makes
# the WHOLE project tree devshot-owned from the start. No build-as-root +
# chown-the-result: a fresh `npm install` mid-session can't leave root-owned
# node_modules the dev server can't read. /var/www is created devshot-owned so
# the app user can populate its own project dir; the build runs from a script
# file so the nested next.config heredoc needs no `su` quoting.
# NOTE: at BAKE the recipe runs as root (the bakery uses QGA ExecSimple
# directly), so this `su` is what drops to devshot here.
install -d -o devshot -g devshot /var/www
cat > /tmp/devshot-build-studio.sh <<'BUILDSTUDIO'
#!/bin/sh
set -eux
export HOME=/home/devshot
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# create-next-app@latest at bake time → always the current starter. --yes accepts
# defaults (TypeScript + ESLint + Tailwind + App Router); --use-npm pins the
# package manager. We deliberately do NOT prune — the VM runs `next dev`.
cd /var/www
npx --yes create-next-app@latest studio --yes --use-npm
cd /var/www/studio

# --- Clean the create-next-app default cruft -------------------------
# The default starter ships a branded welcome page.tsx that references
# /next.svg + /vercel.svg, plus public/{next,vercel,file,globe,window}.svg.
# Once a real app is built those are orphaned and the dev server 404s them —
# noise weaker models fixate on every turn ("/next.svg is a 404 but that's
# fine…"). Ship a clean, neutral starting page and drop the branding SVGs so a
# fresh Studio app has ZERO create-next-app default cruft for the agent to chase.
rm -f public/next.svg public/vercel.svg public/file.svg public/globe.svg public/window.svg
# The run_e2e harness writes .devshot/e2e-runner.cjs into the project each run;
# git-ignore it so it never lands in the user's commits (auto-commit, spec 080).
printf '\n# DevShot run_e2e harness (regenerated each run)\n.devshot/\n' >> .gitignore
cat > app/page.tsx <<'STARTPAGE'
export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-3 p-8 text-center">
      <h1 className="text-2xl font-semibold tracking-tight">Your app is ready</h1>
      <p className="text-sm text-gray-500">Describe a change in the chat to start building.</p>
    </main>
  );
}
STARTPAGE

# --- Asset prefix for the path-based public proxy --------------------
# The preview is served behind /api/public/p/<vm>/<port>/, but Next.js loads its
# runtime chunks/fonts/CSS from the ORIGIN ROOT (/_next/...) by default — which,
# inside the proxied iframe, resolves to the console origin and 404s every asset
# (blank/unstyled preview). Point Next's assetPrefix at the per-VM proxy path so
# every emitted /_next/... URL routes back through the proxy to this VM. The value
# can't be baked (it depends on the VM name) — start-studio exports
# DEVSHOT_ASSET_PREFIX per-VM and `next dev` reads it at launch. Replace any
# starter config so there's a single next.config Next will read.
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

# Pre-install the libraries a "make it beautiful" build almost always reaches for
# so the agent NEVER has to `npm install` them at runtime (a freshly-installed dep
# isn't hot-resolved by Turbopack, and weaker models import without installing it
# → "Module not found" white screens). NO `|| true`: these are a hard requirement
# (the agent system prompt promises they are pre-installed), network is available
# at bake time, and a half-installed tree must never publish — `set -eux` aborts
# the bake on failure.
npm install --save lucide-react framer-motion clsx tailwind-merge class-variance-authority

# Warm .next so the first request after boot compiles fast; dev still recompiles.
# Best-effort (|| true): a build miss is a COMPILE concern, not a dependency one
# (dev recompiles on demand), so it must not gate the dep-completeness check below.
npm run build || true

# --- Validate complete deps so the runtime install branch is DEAD (spec 090) ---
# start-studio runs a BLOCKING `npm install` at boot iff node_modules/.bin/next is
# absent — a 30-120s cold-boot tax. Baking node_modules is what makes that branch
# unreachable; assert it HERE so an incomplete bake fails LOUD at build time
# instead of silently shipping a template that reinstalls on every boot. Same
# checks start-studio (.bin/next) and spec 082's restore (`npm ls`) gate on, so
# "satisfied" means the same thing everywhere. Runs as devshot (this script's
# user) — the perms the dev server sees.
test -x node_modules/.bin/next || { echo "FATAL: node_modules/.bin/next missing after bake — template would reinstall on every boot" >&2; exit 1; }
npm ls --depth=0 >/dev/null 2>&1 || { echo "FATAL: npm ls reports unsatisfied deps after bake:" >&2; npm ls --depth=0 >&2; exit 1; }
echo "Studio template deps validated: node_modules/.bin/next present, npm ls clean"
BUILDSTUDIO
chmod +x /tmp/devshot-build-studio.sh
su devshot -c /tmp/devshot-build-studio.sh
rm -f /tmp/devshot-build-studio.sh
cd /var/www/studio

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

# Boot-phase timing (spec 089). /proc/uptime is seconds since KERNEL boot, so
# these markers also expose how long OpenRC took to reach this service — the gap
# the console's claim→ready timing can't see from outside the VM. They append to
# $LOG, which the boot screen tails and the console boot-probe harvests, so a
# slow stage (xenstore settle, a cold `npm install`, dev-server launch) shows up
# as a real timestamp instead of the boot screen's synthetic ones.
boot_ts() { awk '{printf "%.1f", $1}' /proc/uptime 2>/dev/null || printf '?'; }
boot_phase() { echo "[boot +$(boot_ts)s] $*" >> "$LOG"; }
boot_phase "start-studio: launching (port $PORT)"

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
        # Relative "domid" read works where the absolute self alias returns
        # ENOENT (cxenstored). See docker/start-agent.sh for the full why.
        _domid="$(sudo -n xenstore-read domid 2>/dev/null \
            || xenstore-read domid 2>/dev/null \
            || sudo -n xenstore-read /local/domain/self/domid 2>/dev/null \
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
boot_phase "xenstore vm-name resolved after ${i}s: ${VM_NAME:-<none>}"

# Dependency preflight — a last-resort RUNTIME net, NOT a boot-path expectation.
# The bake guarantees a complete node_modules (spec 090 fails the build if
# node_modules/.bin/next is missing or `npm ls` is unsatisfied), so on a
# correctly-baked template this branch is DEAD at boot. It survives only for a
# LIVE VM that loses node_modules mid-session — a `git clean -fxd`, a
# connect-a-repo project switch — where `next dev` genuinely cannot serve and,
# without this, the supervisor would respawn "sh: next: not found" every 3s
# forever (respawn_max=0) and hang the preview. Install when the dev binary is
# missing — npm ci with a lockfile (fast, deterministic), else npm install.
# Output streams to $LOG and is announced via boot_phase (spec 089) so a cold
# install is loudly visible, never a silent stall.
if [ ! -x node_modules/.bin/next ]; then
    boot_phase "deps MISSING (node_modules/.bin/next absent) — npm install starting (cold boot will be slow)"
    echo "Studio deps missing (node_modules/.bin/next absent) — installing before dev server…"
    if [ -f package-lock.json ]; then
        npm ci --prefer-offline --no-audit --no-fund 2>&1 | tee -a "$LOG" \
            || npm install --prefer-offline --no-audit --no-fund 2>&1 | tee -a "$LOG"
    else
        npm install --prefer-offline --no-audit --no-fund 2>&1 | tee -a "$LOG"
    fi
    boot_phase "npm install finished"
else
    boot_phase "deps present — skipping install"
fi

# Bind 0.0.0.0 so the console public proxy can reach it; pass through the
# project's dev script (Turbopack/webpack) with host+port.
boot_phase "launching next dev on :$PORT (first compile follows)"
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

# --- devshot-perms: webroot writable to devshot ON EVERY BOOT (spec 110) ----
# The dev server, editor, and the agent's vm-exec all run as devshot. If any
# project file drifts to another owner — a root-context step, a churned-VM
# restore — devshot can't write .next/node_modules and the dev server fails. This
# boots BEFORE the dev server + editor and re-asserts devshot ownership + write
# bits at the OS level, so it needs neither a console deploy nor an agent turn.
# Drift-targeted (find ! -user) so a clean tree is a stat-walk, not a rewrite;
# -xdev so it never crosses into another mount. (Restore-time drift is handled
# separately in the restore command itself — this covers boot/bake drift.)
cat > /etc/init.d/devshot-perms <<'PERMS'
#!/sbin/openrc-run
name="devshot-perms"
description="Make /var/www owned by and writable to devshot before the app starts"
depend() {
    after localmount
    before devshot-studio openvscode-server
}
start() {
    ebegin "Normalizing /var/www ownership for devshot"
    find /var/www -xdev \! -user devshot -exec chown devshot:devshot {} + 2>/dev/null
    find /var/www -xdev \! -group devshot -exec chgrp devshot {} + 2>/dev/null
    find /var/www -xdev -type d \! -perm -u+w -exec chmod u+rwX {} + 2>/dev/null
    find /var/www -xdev -type f \! -perm -u+w -exec chmod u+rw {} + 2>/dev/null
    eend 0
}
PERMS
chmod +x /etc/init.d/devshot-perms
rc-update add devshot-perms default

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
# Written AS devshot (it's devshot's home) so the editor's user-data dir is
# devshot-owned and openvscode (which runs as devshot) can write runtime state
# into it — no chown needed.
cat > /tmp/devshot-oc-settings.sh <<'OCSETTINGS'
#!/bin/sh
set -eux
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
OCSETTINGS
chmod +x /tmp/devshot-oc-settings.sh
su devshot -c /tmp/devshot-oc-settings.sh
rm -f /tmp/devshot-oc-settings.sh

# The editor opens the studio project; the agent and editor share these files.
echo /var/www/studio > /etc/openvscode-default-folder
# No chown: the project tree (built above) and the editor's user-data dir are
# already devshot-owned, and vm-exec runs as devshot at runtime (see
# handleVMExec) — so devshot (editor + agent) owns everything it touches.
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
# npm/npx ran as devshot, so the package cache is under devshot's home now.
rm -rf /home/devshot/.npm /home/devshot/.cache /root/.npm /tmp/* /var/cache/apk/*

echo "=== Studio recipe complete ==="
node --version
npm --version
du -sh /var/www/studio
sync
