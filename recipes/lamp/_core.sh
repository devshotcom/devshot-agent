#!/bin/sh
# Recipe: LAMP _core (intermediate) — nginx + multi-PHP (8.2/8.3/8.4) +
# mariadb, NO app installed.
#
# This is Stage 1 of the spec-058 backing chain: produces lamp-shared.qcow2
# that the per-(app,version) variant overlays back onto. Variants
# (lamp/wp-6.7.sh, lamp/sw-6.6.sh, lamp/t3-v13.sh, …) only add their app
# files + DB rows on top of this image — saves ~250 MB per variant vs.
# flat-baking the entire stack each time.
#
# Header keys consumed by build-templates.sh:
#   intermediate=true   → marks this template as a backing-only image,
#                          excluded from the templates picker in the UI.
# devshot:intermediate=true
# devshot:memory_mb=1024
set -eux

# shellcheck disable=SC1091
. /tmp/recipe.d/_app_lib.sh

# --- Pin Alpine to v3.22 ---------------------------------------------
# Alpine 3.23's community repo dropped php82 (it ships php83/84/85). We
# want all three of 8.2/8.3/8.4 side-by-side, and v3.22 is the most
# recent branch that still ships every one of them.
sed -i 's|/alpine/v3\.[0-9]\+|/alpine/v3.22|g' /etc/apk/repositories
apk update
apk upgrade --no-cache

# --- Packages --------------------------------------------------------
# Same extension set for each PHP version so any app can run on any
# version. Covers what WP, Shopware 6.x and TYPO3 v11–v13 all
# collectively require.
PHP_EXTS="cli fpm opcache openssl pdo pdo_mysql mysqli curl gd mbstring \
xml dom simplexml xmlreader xmlwriter iconv zip intl fileinfo phar \
tokenizer session ctype bcmath exif sodium sockets"

PKGS="nginx mariadb mariadb-client composer git wget tar gzip unzip ca-certificates openssl openrc util-linux"
for ver in 82 83 84; do
  PKGS="$PKGS php${ver}"
  for ext in $PHP_EXTS; do
    PKGS="$PKGS php${ver}-${ext}"
  done
done
apk add --no-cache $PKGS

# --- Guest memory pressure safety -----------------------------------
# LAMP matrix images are built by build-lamp-matrix.sh, outside the Go Baker
# path that adds swap to ordinary recipe images. That left every published
# Shopware VM with 0 bytes of swap. Cache maintenance was measured successfully
# at 1536 MiB without swap, but an unbounded vendor scan could still create a
# sharp memory-pressure event and take the VM's control channel down with it.
#
# Keep one bounded GiB inside the guest: pressure becomes slower I/O instead of
# killing the agent/VM. The OpenRC boot service is load-bearing — enabling swap
# only during the bake would produce another runtime image with SwapTotal=0.
SWAP_MB=1024
SWAP_FILE=/var/swap/devshot.swap
# Spec 356 — the bake chroots into this image, so /proc/swaps belongs to the
# BUILDER's kernel. An earlier fix's best-effort swapon activated the guest's
# file on the builder; after the workspace was cleaned the kernel still listed
# the path with its file gone, and mkswap refuses a listed path outright --
# --force does not override that check, and no swapoff can clear a stale entry.
# So the swap area is built under a private path the builder cannot be holding
# and moved into place afterwards: the header lives in the file's contents, so
# a rename carries it. Nothing is ever activated here; SwapTotal>0 at runtime
# comes from the fstab line plus the OpenRC service, and those are verified.
SWAP_BUILD="${SWAP_FILE}.build.$$"
install -d -m 0700 "$(dirname "$SWAP_FILE")"
rm -f "$SWAP_BUILD"
fallocate -l "${SWAP_MB}M" "$SWAP_BUILD"
chmod 0600 "$SWAP_BUILD"
mkswap "$SWAP_BUILD" >/dev/null
swapoff "$SWAP_FILE" 2>/dev/null || true
rm -f "$SWAP_FILE"
mv "$SWAP_BUILD" "$SWAP_FILE"
grep -q "^$SWAP_FILE " /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
[ -x /etc/init.d/swap ] || { echo "ERROR: OpenRC swap service is unavailable" >&2; exit 1; }
rc-update add swap boot
rc-update show boot | grep -q '\bswap\b' || {
  echo "ERROR: LAMP guest swap service is not enabled at boot" >&2
  exit 1
}
echo "guest swap prepared at $SWAP_FILE; it activates at boot via fstab + OpenRC"
mkdir -p /etc/sysctl.d
printf 'vm.swappiness=10\n' > /etc/sysctl.d/60-devshot-swap.conf

# The editor and PHP-FPM intentionally share one workload user. These
# VMs are disposable dev environments, and keeping generated app files
# under the same UID prevents VS Code save failures in /var/www.
id -u devshot >/dev/null 2>&1 || adduser -D -s /bin/bash devshot

# composer's apk wrapper depends on php84 and installs /usr/bin/php as
# a symlink there. We want `php` to land on php83 because php83 is what
# each app's FPM pool also uses by default — same engine across CLI
# install and the live web request.
ln -sf /usr/bin/php83 /usr/bin/php
php -m | grep -qi mysqli || { echo "ERROR: mysqli not loaded on /usr/bin/php" >&2; php -m; exit 1; }

# Keep Shopware maintenance inside the 1536 MiB guest contract. Every ordinary
# CLI call still runs as the workload user, but commands that rebuild the
# container/theme are serialized while FPM is quiesced. This removes the only
# meaningful PHP concurrency spike: a 512 MiB CLI process no longer overlaps a
# cold Storefront worker compiling the same container. The PATH wrapper catches
# both `bin/console ...` (#!/usr/bin/env php) and `php bin/console ...` without
# modifying Shopware's own executable.
# Alpine's base image ships no /usr/local/sbin (and not always /usr/local/bin),
# so the helpers below had nowhere to land: the bake died with
# "can't create /usr/local/sbin/devshot-shopware-lowmem: nonexistent
# directory" (agent run 33793176950).
install -d -m 0755 /usr/local/sbin /usr/local/bin
cat > /usr/local/sbin/devshot-shopware-lowmem <<'LOWMEM'
#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo "devshot-shopware-lowmem must run through sudo" >&2; exit 77; }
[ "$#" -gt 0 ] || { echo "devshot-shopware-lowmem: missing PHP arguments" >&2; exit 64; }

exec 9>/run/devshot-shopware-maintenance.lock
flock -x 9
active_fpm=""
restore_fpm() {
  trap - 0 1 2 15
  for svc in $active_fpm; do rc-service "$svc" start >/dev/null 2>&1 || true; done
}
trap restore_fpm 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

for svc in php-fpm82 php-fpm83 php-fpm84; do
  if rc-service "$svc" status >/dev/null 2>&1; then
    active_fpm="$active_fpm $svc"
    rc-service "$svc" stop >/dev/null
  fi
done

set +e
su -s /bin/sh -- devshot -c 'exec /usr/bin/php83 "$@"' devshot-shopware-lowmem "$@"
rc=$?
set -e
exit "$rc"
LOWMEM
chmod 0755 /usr/local/sbin/devshot-shopware-lowmem

cat > /usr/local/bin/php <<'PHPWRAP'
#!/bin/sh
set -eu
real_php=/usr/bin/php83
console_path=""
console_command=""
seen_console=0
for arg in "$@"; do
  if [ "$seen_console" = "1" ]; then
    case "$arg" in
      cache:clear|theme:compile|theme:change|theme:refresh|plugin:install|plugin:update|plugin:activate|plugin:deactivate|dal:refresh:index|database:migrate|database:migrate-destructive)
        console_command=$arg
        break
        ;;
    esac
  fi
  case "$arg" in
    bin/console|./bin/console|*/bin/console) console_path=$arg; seen_console=1 ;;
  esac
done

case "$console_command" in
  cache:clear|theme:compile|theme:change|theme:refresh|plugin:install|plugin:update|plugin:activate|plugin:deactivate|dal:refresh:index|database:migrate|database:migrate-destructive)
    # During the image bake bin/console is still root-owned. Runtime projects
    # are devshot-owned; only those enter the maintenance scheduler.
    owner=$(stat -c %U "$console_path" 2>/dev/null || true)
    if [ "$owner" = "devshot" ]; then
      for arg in "$@"; do
        case "$arg" in
          memory_limit=*[Gg]|-dmemory_limit=*[Gg]|memory_limit=-1|-dmemory_limit=-1)
            echo "Shopware low-memory contract: unlimited/GiB PHP heaps are forbidden; maximum is 512M" >&2
            exit 64
            ;;
          memory_limit=*[Mm]|-dmemory_limit=*[Mm])
            value=${arg##*=}; value=${value%M}; value=${value%m}
            case "$value" in
              ''|*[!0-9]*) ;;
              *) [ "$value" -le 512 ] || {
                echo "Shopware low-memory contract: PHP memory_limit=${value}M exceeds 512M" >&2
                exit 64
              } ;;
            esac
            ;;
        esac
      done
      exec sudo -n /usr/local/sbin/devshot-shopware-lowmem "$@"
    fi
    ;;
esac

exec "$real_php" "$@"
PHPWRAP
chmod 0755 /usr/local/bin/php

# --- Per-version FPM pools + php.ini ---------------------------------
for ver in 82 83 84; do
  mkdir -p /run/php-fpm${ver}
  POOL=/etc/php${ver}/php-fpm.d/www.conf
  sed -i \
    -e "s|^user = .*|user = devshot|" \
    -e "s|^group = .*|group = devshot|" \
    -e "s|^listen = .*|listen = /run/php-fpm${ver}/php-fpm.sock|" \
    -e "s|^;\?listen.owner = .*|listen.owner = nginx|" \
    -e "s|^;\?listen.group = .*|listen.group = nginx|" \
    -e "s|^;\?listen.mode = .*|listen.mode = 0660|" \
    -e 's|^pm = .*|pm = ondemand|' \
    -e 's|^pm.max_children = .*|pm.max_children = 1|' \
    -e 's|^;*pm.process_idle_timeout = .*|pm.process_idle_timeout = 10s|' \
    -e 's|^;*pm.max_requests = .*|pm.max_requests = 100|' \
    -e 's|^;*php_admin_value\[memory_limit\] = .*|php_admin_value[memory_limit] = 256M|' \
    "$POOL"
  grep -q '^php_admin_value\[memory_limit\] = ' "$POOL" \
    || printf '\nphp_admin_value[memory_limit] = 256M\n' >> "$POOL"

  # Shopware migrations and TYPO3 setup both want >256 MB.
  PHPINI=/etc/php${ver}/php.ini
  sed -i \
    -e 's|^;*memory_limit = .*|memory_limit = 512M|' \
    -e 's|^;*upload_max_filesize = .*|upload_max_filesize = 64M|' \
    -e 's|^;*post_max_size = .*|post_max_size = 64M|' \
    -e 's|^;*max_execution_time = .*|max_execution_time = 300|' \
    "$PHPINI"
done

# --- MariaDB: enable TCP on loopback ---------------------------------
# Alpine ships skip-networking=ON for hardening; Shopware's mysqli
# connect needs TCP. Sed the source line out, then drop our override
# in zz-prefixed cnf so it loads last.
sed -i 's|^[[:space:]]*skip-networking[[:space:]]*$|#skip-networking (disabled by devshot lamp _core recipe)|' \
  /etc/my.cnf.d/mariadb-server.cnf

cat > /etc/my.cnf.d/zz-devshot.cnf <<'CFG'
[mariadbd]
skip-networking = 0
bind-address = 127.0.0.1
skip-name-resolve
performance_schema = OFF
innodb_buffer_pool_size = 128M
innodb_log_buffer_size = 8M
max_connections = 20
table_open_cache = 256
thread_cache_size = 4
tmp_table_size = 16M
max_heap_table_size = 16M
CFG

mkdir -p /run/mysqld /var/log/mysql
chown -R mysql:mysql /run/mysqld /var/lib/mysql /var/log/mysql

# Initialize the data dir but do NOT start mariadb here. Variants will
# start it inside their own overlay (so the per-variant DB rows land in
# their overlay, not in lamp-shared) and shut down at end.
mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null

# --- wp-cli ----------------------------------------------------------
# WP variants use this; harmless if Shopware/TYPO3 variants never call it.
wget -q -O /usr/local/bin/wp \
  https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod 0755 /usr/local/bin/wp

# --- /var/www stage --------------------------------------------------
mkdir -p /var/www
chown devshot:devshot /var/www

# --- Shared desktop surface -----------------------------------------
# The public homepage maps Desktop, Web App, Code Editor, and Terminal
# to the same WordPress VM. Reuse the canonical desktop recipe so the
# LAMP template exposes Xvnc on :5900 without maintaining a second copy
# of the Openbox/tint2/launcher setup.
[ -f /tmp/recipe.d/desktop.sh ] || {
  echo "ERROR: /tmp/recipe.d/desktop.sh missing — build-lamp-matrix must stage the shared desktop recipe" >&2
  exit 1
}
/bin/sh /tmp/recipe.d/desktop.sh

# --- phpswitch: start-on-demand + fastcgi_pass swap -----------------
# `phpswitch <app> <version>` rewrites the active vhost to point at a
# different FPM pool. Only the DEFAULT pool (8.3) auto-starts at boot —
# booting all three is slow and RAM-heavy on a small VM — so phpswitch
# starts the requested pool on demand first, then swaps the socket and
# reloads nginx.
cat > /usr/local/bin/phpswitch <<'SWITCH'
#!/bin/sh
set -eu
usage() { echo "usage: phpswitch <app> <82|83|84>" >&2; exit 2; }
[ $# -eq 2 ] || usage
app=$1; ver=$2
case "$ver" in 82|83|84) ;; *) usage;; esac
conf=/etc/nginx/http.d/$app.conf
[ -f "$conf" ] || { echo "no vhost for app '$app'" >&2; exit 3; }
rc-service "php-fpm$ver" status >/dev/null 2>&1 || rc-service "php-fpm$ver" start
sed -i "s|/run/php-fpm[0-9]*/php-fpm.sock|/run/php-fpm$ver/php-fpm.sock|" "$conf"
nginx -t && rc-service nginx reload >/dev/null 2>&1 || nginx -s reload
echo "$app -> php8.${ver#8}"
SWITCH
chmod 0755 /usr/local/bin/phpswitch

# --- Strip stub default nginx vhost ---------------------------------
# Variants drop their own vhost into /etc/nginx/http.d/. lamp-shared
# has no apps so it has no vhost — but Alpine ships a stub default
# that would 404 every request if no variant overrode it.
rm -f /etc/nginx/http.d/default.conf

# --- openvscode-server (the in-browser editor for this stack) --------
# Every LAMP variant inherits this layer, so the dev experience is:
# claim "WordPress 6.9" → land in VSCode workbench at :8080 with
# /var/www/wordpress as the open folder, live site on :80 visible
# via the editor's port-forward panel or a sibling browser tab.
#
# Why openvscode-server (Gitpod fork) + system Node 22 instead of
# Coder's code-server: the latter ships a glibc-bundled node and a
# pinned argon2@0.28.4 native module that don't run on Alpine musl
# even with gcompat (fcntl64 missing) and don't build with Node 24.
# openvscode-server's tarball is plain JS we exec under apk's musl
# Node 22 (Alpine 3.22 pin above; 3.23 ships Node 24 which the
# editor warns against).
#
# gcompat: openvscode-server ships a handful of OPTIONAL .node native
# modules (spdlog for logging, @parcel/watcher for file change events,
# vsda for license verification) built against glibc. Without gcompat
# they fail to load with `Error: Error loading shared library
# ld-linux-aarch64.so.1: No such file or directory`. The workbench
# falls back to a JS path for each but the failure cascades — log
# messages get swallowed, file watching misses changes, and (we
# discovered the hard way) webview commands like simpleBrowser.api.open
# silently no-op because the extension host's IPC layer chokes on the
# missing watcher. gcompat ships the glibc-compat dynamic linker
# stubs Alpine needs to dlopen those modules cleanly.
apk add --no-cache nodejs npm gcompat

# E2E browser-testing harness — parity with the studio recipe so EVERY LAMP-matrix
# flavor (Shopware/WordPress/TYPO3/plain LAMP) can run the agent's run_e2e tool.
# Without it, run_e2e fails on every Shopware build with "puppeteer-core not
# installed — rebake the studio image" and the self-driving agent burns its whole
# continuation budget retrying a tool it cannot fix from the workspace. chromium +
# swiftshader give a GPU-less headless browser; puppeteer-core ships NO browser of
# its own (PUPPETEER_SKIP_DOWNLOAD=1 → it drives the apk chromium) so it works
# OFFLINE on the network-locked runtime VM. The runner (.devshot/e2e-runner.cjs)
# requires it by absolute path at /opt/devshot-e2e/node_modules/puppeteer-core.
apk add --no-cache chromium chromium-swiftshader ttf-freefont
install -d /opt/devshot-e2e
( cd /opt/devshot-e2e && npm init -y >/dev/null 2>&1 && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --omit=dev puppeteer-core )

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
# Smoke test — system Node must be able to load the JS entry; the
# bundled /opt/openvscode-server/node is glibc-only and stays unused.
node /opt/openvscode-server/out/server-main.js --version | head -1

# devshot user owns the editor state dir; variants will lay down
# the per-app workspace settings on top of this.
mkdir -p /home/devshot/.openvscode-server/data/logs /home/devshot/projects
mkdir -p /home/devshot/.openvscode-server/data/User
mkdir -p /home/devshot/.openvscode-server/data/Machine

# DX: Dark Modern, no Welcome, terminal opens on boot, no popups.
# These land in the user profile so they apply to whatever folder the
# variant ends up opening (set_editor_workspace in _app_lib.sh).
cat > /home/devshot/.openvscode-server/data/User/settings.json <<'SETTINGS'
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.startupEditor": "none",
  "workbench.activityBar.location": "default",
  "workbench.statusBar.visible": true,
  "window.menuBarVisibility": "compact",
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.banner": "never",
  "security.workspace.trust.startupPrompt": "never",
  "security.workspace.trust.untrustedFiles": "open",
  "terminal.integrated.defaultProfile.linux": "bash",
  "terminal.integrated.profiles.linux": {
    "bash": { "path": "/bin/bash", "args": ["-l"] }
  },
  "terminal.integrated.cwd": "${workspaceFolder}",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 800,
  "editor.fontSize": 13,
  "editor.minimap.enabled": true,
  "editor.bracketPairColorization.enabled": true,
  "explorer.compactFolders": false,
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

mkdir -p /home/devshot/.openvscode-server/data/User/globalStorage
cat > /home/devshot/.openvscode-server/data/User/globalStorage/storage.json <<'STORAGE'
{
  "workbench.welcomePage.walkthroughs.openOnInstall": false,
  "workbench.welcomePageOnStartup": false
}
STORAGE

# ─── DevShot Side Panel auto-open extension ─────────────────────────
# A trivial built-in extension that fires on workspace open, resolves
# the workload-local app URL through VS Code's external URI service,
# and opens that browser-reachable URL in Simple Browser. Lands the
# user in VSCode with the editor on the left and the live site rendered
# in a webview tab on the right — one claim, code + preview, no further
# clicks.
EXT_DIR=/opt/openvscode-server/extensions/devshot-side-panel
mkdir -p "$EXT_DIR"
cat > "$EXT_DIR/package.json" <<'PKG'
{
  "name": "devshot-side-panel",
  "displayName": "DevShot Side Panel",
  "description": "Auto-opens the live app preview alongside the editor.",
  "version": "0.0.1",
  "publisher": "devshot",
  "engines": { "vscode": "^1.60.0" },
  "main": "./extension.js",
  "browser": "./extension.js",
  "extensionKind": ["ui"],
  "activationEvents": ["onStartupFinished"]
}
PKG
cat > "$EXT_DIR/package.nls.json" <<'NLS'
{}
NLS
cat > "$EXT_DIR/extension.js" <<'EXT'
// Web extension - runs in the workbench's web worker host. No fs, no
// Node modules; URL is derived from the workspace folder name so we
// don't need a side-channel file. Matches set_editor_workspace's
// /var/www/<app> convention.
const vscode = require('vscode');

const URLS = {
  wordpress: 'http://localhost:80/',
  shopware:  'http://localhost:81/',
  typo3:     'http://localhost:82/',
};

async function openPreview(url) {
  const localUri = vscode.Uri.parse(url);
  const externalUri = await vscode.env.asExternalUri(localUri);
  const externalUrl = externalUri.toString(true);

  try {
    await vscode.commands.executeCommand(
      'simpleBrowser.api.open',
      externalUri,
      { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true }
    );
  } catch {
    // Older simple-browser builds only expose the user-facing show
    // command (with the URL prompt suppressed when an arg is given).
    await vscode.commands.executeCommand('simpleBrowser.show', externalUrl);
  }
}

async function activate(context) {
  // The proxy reaches the live site at the workload-side port the
  // bake exposed. workspace folder name = /var/www/<app>, basename is
  // the lookup key.
  const folder = vscode.workspace.workspaceFolders?.[0];
  const app = folder ? folder.name : 'wordpress';
  const url = URLS[app] || URLS.wordpress;
  // Fire after the workbench has settled — Simple Browser's command
  // is registered the first time it activates, and the workbench's
  // editor service needs to be ready to accept the Beside split.
  setTimeout(() => {
    openPreview(url).catch((error) => {
      console.error('[DevShot Side Panel] failed to open preview', error);
    });
  }, 1800);
}
function deactivate() {}
module.exports = { activate, deactivate };
EXT

chown -R devshot:devshot /home/devshot

install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser (openvscode-server) — DevShot Editor"
# Stop a single editor process from expanding until the kernel has no room for
# Shopware maintenance. 256 MiB old-space is ample for the web editor; file and
# terminal operations keep working, while the 1536 MiB VM retains a hard budget.
export NODE_OPTIONS="--max-old-space-size=256"
# OPENVSCODE_DEFAULT_FOLDER is populated per-variant by _app_lib's
# install_<app> step; falls back to /home/devshot/projects when
# no app has claimed the editor (lamp-shared boot only — variants
# always set it).
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder 2>/dev/null || echo /home/devshot/projects)"
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

# --- OpenRC services auto-start on boot ------------------------------
# Only the DEFAULT php-fpm (8.3) boots — running all three pools spins up
# 3× the FPM masters/workers, which on a small VM both slows the boot (more
# services to start before the app answers HTTP) and burns RAM that the app
# itself needs. 8.2/8.4 are installed and start on demand via `phpswitch`.
rc-update add mariadb default
rc-update add php-fpm83 default
rc-update add nginx default
rc-update add openvscode-server default

# --- devshot-perms: webroot writable to devshot ON EVERY BOOT (spec 110) ----
# The app kernel (Shopware) AND the agent both run as devshot. If any project
# file drifts to another owner — a root-context step, a churned-VM restore — the
# kernel can't write var/cache and EVERY bin/console dies at container compile
# (the live "Application.php line 759" dead-kernel incident). This boots BEFORE
# php-fpm/nginx/the editor and re-asserts devshot ownership + write bits at the
# OS level, so it needs neither a console deploy nor an agent turn — the only
# layer that recovers a VM whose kernel is already dead. Drift-targeted
# (find ! -user) so a clean tree is a stat-walk, not a rewrite; -xdev so it never
# crosses into another mount. (Restore-time drift is handled separately, in the
# restore command itself — this covers boot/bake drift before the first turn.)
cat > /etc/init.d/devshot-perms <<'PERMS'
#!/sbin/openrc-run
name="devshot-perms"
description="Make /var/www owned by and writable to devshot before the app starts"
depend() {
    after localmount
    before php-fpm83 nginx openvscode-server
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

# --- Launcher --------------------------------------------------------
# Belt-and-suspenders nudge for the very-first-second case (OpenRC
# already brings these up at boot via the runlevel adds above).
install_lamp_launcher

# --- Cleanup ---------------------------------------------------------
rm -rf /root/.composer /home/*/.composer /tmp/*
rm -rf /var/cache/apk/*

echo "=== LAMP _core recipe complete ==="
df -h /var
for ver in 82 83 84; do echo "php${ver}: $(php${ver} --version | head -1)"; done
sync
