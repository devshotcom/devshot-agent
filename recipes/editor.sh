#!/bin/sh
# Recipe: Editor — openvscode-server (Gitpod's VSCode-in-browser fork)
# running on Alpine + system Node 22.
#
# Why openvscode-server + system Node, not code-server's bundled tarball:
#   - code-server 4.x ships a glibc-linked node binary. Alpine is
#     musl; even gcompat doesn't carry the full glibc surface
#     (fcntl64 etc. missing).
#   - code-server pinned argon2@0.28.4 which won't build on Node
#     24 (Alpine 3.23's nodejs) and even with --ignore-scripts it's
#     required at runtime.
#   - npm install -g code-server on Alpine consistently fails with
#     EBADENGINE + ENOENT race during the vscode/node_modules
#     extraction.
#
# openvscode-server bypasses ALL of this:
#   - Plain JS entry point at out/server-main.js — runs under any
#     compatible Node, including Alpine's musl Node.
#   - We ignore the bundled glibc node entirely and launch via the
#     system Node 22 from Alpine 3.22's community repo.
#   - No native module compile during install: the only native bits
#     (node-pty for the integrated terminal) are skipped at runtime
#     with a non-fatal ERR_DLOPEN_FAILED — the editor + file
#     navigation still work, and a built-in terminal panel falls
#     back to a different IPC mechanism.
#
# devshot:exposed_ports=[{"port":8080,"name":"editor","proto":"http"}]
# devshot:memory_mb=1024
set -eux

# ── Pin Alpine to v3.22 so we get Node 22 (3.23 ships Node 24 which
# openvscode-server engine warns against). Same pin pattern the LAMP
# recipe uses for php82 availability. v3.22 packages run fine on
# the v3.23 base rootfs because Alpine maintains ABI compatibility
# across adjacent branches.
sed -i 's|/alpine/v3\.[0-9]\+|/alpine/v3.22|g' /etc/apk/repositories
apk update
apk upgrade --no-cache

# ── Dev toolbox + Node 22 ─────────────────────────────────────────────────
# Cloud-shell-flavoured baseline: bash + git + curl + jq + vim/nano
# for terminal-panel work; nodejs/npm/python3 because most tutorials
# assume they're there.
apk add --no-cache \
  bash \
  ca-certificates \
  curl \
  wget \
  git \
  openssh-client \
  vim \
  nano \
  python3 \
  py3-pip \
  nodejs \
  npm \
  jq \
  tar \
  gzip \
  unzip \
  htop \
  procps \
  shadow \
  sudo \
  tzdata

# ── openvscode-server install ─────────────────────────────────────────────
# Gitpod's tarball ships JS source + a bundled glibc node we ignore.
# Pin a known-good 1.x version; patch updates ride along on next bake.
OPENVSCODE_VERSION="${OPENVSCODE_VERSION:-1.95.2}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  OV_ARCH=x64 ;;
  aarch64) OV_ARCH=arm64 ;;
  *)       echo "ERROR: unsupported arch $ARCH" >&2; exit 1 ;;
esac

mkdir -p /opt/openvscode-server
wget -q -O /tmp/openvscode.tar.gz \
  "https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OPENVSCODE_VERSION}/openvscode-server-v${OPENVSCODE_VERSION}-linux-${OV_ARCH}.tar.gz"
tar -xzf /tmp/openvscode.tar.gz -C /opt/openvscode-server --strip-components=1
rm /tmp/openvscode.tar.gz

# Smoke test: system Node loads the entry, prints version. Bundled
# node in /opt/openvscode-server/node is glibc-linked and skipped.
node /opt/openvscode-server/out/server-main.js --version

# ── User account ──────────────────────────────────────────────────────────
id -u devshot >/dev/null 2>&1 || adduser -D -s /bin/bash devshot
mkdir -p /home/devshot/projects /home/devshot/.openvscode-server/data/logs
chown -R devshot:devshot /home/devshot

cat > /home/devshot/projects/README.md <<'README'
# DevShot Editor

You're in an Alpine VM with openvscode-server (a Gitpod-maintained
fork of VSCode-in-browser) pre-installed.

## What's here

- **openvscode-server 1.95.x** (VSCode UI in the browser, you're using it now)
- **git, curl, wget, jq, vim, nano, htop**
- **node + npm** (run `node --version` in the terminal panel)
- **python3 + pip** (run `python3 --version`)

## Quick starts

Open the integrated terminal (`Ctrl+\``) and try:

```sh
git clone https://github.com/your/repo .
npm install
```

Or just start a new project:

```sh
mkdir my-app && cd my-app
npm init -y
```

`/home/devshot` survives across container restarts inside this VM.
The VM itself is ephemeral — claim a persistent storage volume in
the console to keep work across VM teardowns.
README
chown devshot:devshot /home/devshot/projects/README.md

# ── OpenRC service ────────────────────────────────────────────────────────
# Launch via system node, NOT the bundled openvscode-server wrapper
# script — that script tries to exec /opt/openvscode-server/node
# (the glibc one we can't run on musl).
#
# Pre-create the log file with devshot ownership: start-stop-daemon
# opens it BEFORE setuid'ing to command_user, so root needs to have
# stamped it with the right perms.
install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser (openvscode-server)"
command="/usr/bin/node"
command_args="/opt/openvscode-server/out/server-main.js \
  --host 0.0.0.0 --port 8080 \
  --without-connection-token \
  --disable-telemetry \
  --server-data-dir /home/devshot/.openvscode-server \
  --default-folder /home/devshot/projects"
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

# ── Launcher script (start-editor) ────────────────────────────────────────
# Matches the start-<name> contract that AppsTab.startWorkloadInVM
# uses to kick off the app right after claim.
cat > /usr/local/bin/start-editor <<'LAUNCHER'
#!/bin/sh
rc-service openvscode-server status >/dev/null 2>&1 \
  || rc-service openvscode-server start || true
echo "editor ready — openvscode-server on :8080"
echo "Workbench loads at /?folder=/home/devshot/projects"
LAUNCHER
chmod 0755 /usr/local/bin/start-editor

# ── Cleanup ────────────────────────────────────────────────────────────────
rm -rf /root/.npm /home/devshot/.npm /tmp/* /var/cache/apk/*

echo "=== editor recipe complete ==="
du -sh /opt/openvscode-server /home/devshot 2>/dev/null || true
node /opt/openvscode-server/out/server-main.js --version 2>&1 | head -3
df -h /var
sync
