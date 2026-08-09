#!/bin/sh
# Recipe: Blank — a bare Linux workspace for Studio's "blank" stack with
# Docker + Compose + DDEV preinstalled, plus openvscode-server on :8080
# opened to /workspace. There is NO app baked and NO dev server running:
# the DevShot Studio agent (or the user) builds and runs its OWN app —
# either a plain container (`docker run -p 3000:<port>`) or a PHP/CMS/Laravel
# project via DDEV — and binds it to :3000 so the Studio preview shows it.
#
# Containers run in the Xen DomU WITHOUT nested virt (namespaces + cgroups,
# not VMs) — /dev/kvm is irrelevant. The Alpine 3.23 virt kernel (~6.6, PVH)
# ships cgroup v2 + overlayfs + namespaces + netfilter, which is everything
# dockerd needs.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/blank.sh --name=blank
# Output template: devshot-guest-blank.qcow2 (claimed as template "blank").
#
# STATIC CHECKS PASS; RUNTIME UNVERIFIED — dockerd-up-at-boot, devshot-in-
# docker-group, and a real `ddev start` answering a Host-less :3000 GET have
# NOT been exercised on a booted image. Validate with one live bake+boot
# (see the recipe footer) before this rides the nightly prod rebake.
#
# Spec 050 — declared listen ports auto-populate the per-VM forward allowlist:
# devshot:exposed_ports=[{"port":3000,"name":"app","proto":"http"},{"port":8080,"name":"editor","proto":"http"}]
# devshot:memory_mb=3072
set -eux

# --- Repos -----------------------------------------------------------
# The base rootfs already writes both main + community and build-templates.sh
# re-pins everything to v3.23, so community is normally present. Re-enable
# defensively (public-session-desktop idiom) in case a future base drops it,
# then refresh — docker/docker-cli-compose live in community.
if ! grep -q '^http.*community' /etc/apk/repositories; then
    main_line=$(grep -m1 '^http.*main$' /etc/apk/repositories || true)
    if [ -n "$main_line" ]; then
        community_line=$(echo "$main_line" | sed 's|/main$|/community|')
        echo "$community_line" >> /etc/apk/repositories
    fi
fi
apk update || (sleep 5 && apk update)

# --- Packages --------------------------------------------------------
# nodejs/npm + gcompat for OPENVSCODE-SERVER only — its optional glibc .node
# modules (watcher/spdlog/vsda) dlopen under musl via gcompat (see lamp/_core.sh).
# NOTE: ddev and mkcert do NOT need gcompat — both are STATICALLY-LINKED Go
# ELF binaries (verified with `file` on the real v1.25.2 release tarball), so
# they run on bare musl. gcompat is here purely for openvscode.
# wget/tar for the editor + ddev tarballs; curl is in the base, kept explicit.
# docker + docker-cli + docker-cli-compose = the v2 engine + CLI + `docker
# compose` plugin (all Alpine v3.23 community).
apk add --no-cache \
  nodejs npm gcompat libstdc++ libc6-compat ca-certificates wget tar curl \
  docker docker-cli docker-cli-compose

# --- Docker: group + cgroup-parent + boot wiring ---------------------
# devshot runs the editor, the agent's vm-exec, and every docker/ddev call,
# so put it in the docker group → plain `docker` works without sudo (it also
# has NOPASSWD sudo as a fallback). The Alpine docker apk ships its own
# /etc/init.d/docker (depend: need sysfs cgroups; after net) and an
# /etc/init.d/cgroups that mounts the cgroup v2 hierarchy. cgroups belongs to
# the BOOT runlevel (mounted before the DEFAULT runlevel where dockerd lives)
# so the hierarchy exists when dockerd starts.
addgroup devshot docker

# cgroup-v2 collision pre-empt (aports #15570 / OpenRC #680): OpenRC's cgroups
# service OWNS /sys/fs/cgroup/docker, and dockerd's DEFAULT --cgroup-parent is
# also "docker" → the two collide and CONTAINERS THAT SET RESOURCE LIMITS fail
# to start. `ddev start` sets limits on its web/db containers, so this is the
# single most likely reason a started ddev project dies at runtime. Point
# dockerd at a non-colliding parent so it manages its own subtree.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DAEMONJSON'
{
  "cgroup-parent": "dockerd.slice"
}
DAEMONJSON

rc-update add cgroups boot
rc-update add docker default

# --- DDEV (statically-linked Go binary; NO gcompat needed) -----------
# DDEV ships per-arch tarballs on GitHub releases. Pin a version for
# reproducible bakes. The release uses amd64/arm64 naming — a SEPARATE arch
# map from openvscode's x64/arm64 below (do NOT share it). The tarball bundles
# `ddev`, `ddev-hostname`, `mkcert`, a LICENSE and shell completions (verified
# against the real v1.25.2 asset); we install `ddev` + the bundled `mkcert`
# (so there is NO second download from dl.filippo.io). `ddev --version` is a
# HARD bake gate: Cobra handles that flag before DDEV probes the Docker socket,
# which is intentionally absent in the offline build chroot. The `ddev version`
# subcommand is NOT equivalent: it queries Docker and made the nightly bake
# silently omit this production template. v1.25.2 is well past the
# host_webserver_port bug fixed in v1.22.3 (issue #5341), which goal C relies on.
case "$(uname -m)" in
  aarch64) DDEV_ARCH=arm64 ;;
  x86_64)  DDEV_ARCH=amd64 ;;
  *)       echo "ERROR: unsupported arch $(uname -m) for ddev" >&2; exit 1 ;;
esac
DDEV_VERSION="${DDEV_VERSION:-v1.25.2}"
wget -q -O /tmp/ddev.tar.gz \
  "https://github.com/ddev/ddev/releases/download/${DDEV_VERSION}/ddev_linux-${DDEV_ARCH}.${DDEV_VERSION}.tar.gz"
mkdir -p /tmp/ddev-extract
tar -xzf /tmp/ddev.tar.gz -C /tmp/ddev-extract
install -m 0755 /tmp/ddev-extract/ddev /usr/local/bin/ddev
# mkcert is BUNDLED in the same tarball (a static Go ELF) — install it from
# here instead of a second network fetch. DDEV uses it for *.ddev.site TLS;
# the preview path (goal C) is plain HTTP on :3000, so it is non-load-bearing,
# but having it lets `ddev start` skip TLS warnings and lets a human use HTTPS.
if [ -f /tmp/ddev-extract/mkcert ]; then
    install -m 0755 /tmp/ddev-extract/mkcert /usr/local/bin/mkcert
fi
# ddev-hostname is the helper ddev shells out to for /etc/hosts edits; install
# it too so ddev never tries to self-download it at runtime (offline-safe).
if [ -f /tmp/ddev-extract/ddev-hostname ]; then
    install -m 0755 /tmp/ddev-extract/ddev-hostname /usr/local/bin/ddev-hostname
fi
rm -rf /tmp/ddev.tar.gz /tmp/ddev-extract
validate_ddev() {
    su devshot -c 'HOME=/home/devshot /usr/local/bin/ddev --version'
}
# Fail-fast gate: prove the static binary execs without Docker as its runtime user.
validate_ddev

# mkcert local CA (best-effort, headless-safe; non-fatal — preview is plain HTTP)
mkcert -install 2>/dev/null || true

# --- Bare workspace, owned by devshot from the start -----------------
# install -d -o devshot (NOT plain `mkdir -p`, which leaves it root-owned and
# the devshot-run editor/agent/docker-compose-in-cwd can't write — the exact
# root-owned-tree bug documented in project memory). The base only pre-creates
# /home/devshot/workspace; /workspace at root must be created here.
install -d -o devshot -g devshot /workspace

# --- DDEV global config (lean; the per-project :3000 binding is NOT here) ---
# THE preview mechanism (goal C) is PER-PROJECT: `host_webserver_port: "3000"`
# in /workspace/.ddev/config.yaml, written by the agent's `ddev config
# --host-webserver-port=3000` (mandated in the system prompt). It CANNOT be
# baked — the project does not exist yet. Here we only trim the ssh-agent
# container globally for lean-ness (the router is kept for normal *.ddev.site
# use). NOTE: `ddev config global` may NO-OP in the bake chroot because there
# is no running dockerd (DDEV issue #3910) — this is a best-effort lean-ness
# tweak, NOT part of the reachability path, so a no-op is harmless.
cat > /tmp/devshot-ddev-global.sh <<'DDEVGLOBAL'
#!/bin/sh
set -eux
export HOME=/home/devshot
ddev config global --omit-containers=ddev-ssh-agent --instrumentation-opt-in=false || true
DDEVGLOBAL
chmod +x /tmp/devshot-ddev-global.sh
su devshot -c /tmp/devshot-ddev-global.sh || true
rm -f /tmp/devshot-ddev-global.sh

# --- openvscode-server (in-browser editor on :8080) ------------------
# Same Gitpod fork + system-Node approach as the studio/lamp recipes (see
# lamp/_core.sh for the gcompat rationale). NOTE the arch map here is
# x64/arm64 — DIFFERENT from ddev's amd64/arm64 above; do not conflate them.
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

# --- grok-build agent (spec 212) ------------------------------------------
# The static-pie official grok binary runs on Alpine x86_64 as-is (no
# cross-build, no gcompat — verified 2026-08-08). Baked here so a blank VM boots
# WITH grok present; the console bridge (STUDIO_GROK_BRIDGE) launches
# `grok agent serve` and drives it over ACP. Pinned by version + sha256; never
# "latest" — a silent grok update must not change agent behaviour unreviewed.
GROK_VERSION=1.0.0
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

# Editor profile: Dark Modern, no welcome, trust off (throwaway VM). Written
# AS devshot (it's devshot's home) so the user-data dir is devshot-owned and
# the editor (which runs as devshot) can write runtime state into it.
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

# The editor opens the bare workspace; the agent and editor share these files.
echo /workspace > /etc/openvscode-default-folder
install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser (openvscode-server) — DevShot Studio editor"
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder 2>/dev/null || echo /workspace)"
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
# Drop npm/apk/tmp caches. PRESERVE /var/lib/docker (image/layer store) — it
# is empty at bake (no daemon ran) but never blow it away on principle.
rm -rf /root/.npm /home/devshot/.npm /home/devshot/.cache /tmp/* /var/cache/apk/*

echo "=== Blank recipe complete ==="
docker --version
docker compose version || true
validate_ddev
mkcert -version 2>/dev/null || true
node --version
sync

# --- VALIDATE-AFTER-REBAKE (run ONCE on a booted devshot-guest-blank.qcow2) ---
#   rc-service docker status                  # dockerd up at boot
#   docker info | grep -i cgroup              # cgroup driver/parent sane, no error
#   su devshot -c 'docker run --rm --memory=256m alpine echo ok'   # limits work (cgroup collision check)
#   su devshot -c 'docker ps'                 # devshot in docker group, no sudo
#   su devshot -c 'cd /workspace && ddev config --project-type=php --docroot=. --host-webserver-port=3000 && ddev start'
#   curl -fsS http://127.0.0.1:3000/          # Host-less GET reaches the ddev web container
