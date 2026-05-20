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

PKGS="nginx mariadb mariadb-client composer wget tar gzip unzip ca-certificates openssl"
for ver in 82 83 84; do
  PKGS="$PKGS php${ver}"
  for ext in $PHP_EXTS; do
    PKGS="$PKGS php${ver}-${ext}"
  done
done
apk add --no-cache $PKGS

# composer's apk wrapper depends on php84 and installs /usr/bin/php as
# a symlink there. We want `php` to land on php83 because php83 is what
# each app's FPM pool also uses by default — same engine across CLI
# install and the live web request.
ln -sf /usr/bin/php83 /usr/bin/php
php -m | grep -qi mysqli || { echo "ERROR: mysqli not loaded on /usr/bin/php" >&2; php -m; exit 1; }

# --- Per-version FPM pools + php.ini ---------------------------------
for ver in 82 83 84; do
  mkdir -p /run/php-fpm${ver}
  POOL=/etc/php${ver}/php-fpm.d/www.conf
  sed -i \
    -e "s|^user = .*|user = nginx|" \
    -e "s|^group = .*|group = nginx|" \
    -e "s|^listen = .*|listen = /run/php-fpm${ver}/php-fpm.sock|" \
    -e "s|^;\?listen.owner = .*|listen.owner = nginx|" \
    -e "s|^;\?listen.group = .*|listen.group = nginx|" \
    -e "s|^;\?listen.mode = .*|listen.mode = 0660|" \
    "$POOL"

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
chown nginx:nginx /var/www

# --- phpswitch: one-shot fastcgi_pass swap ---------------------------
# `phpswitch <app> <version>` rewrites the active vhost to point at a
# different FPM pool. All three pools are already running, so this is
# just a config edit + nginx reload — no service restart cascade.
cat > /usr/local/bin/phpswitch <<'SWITCH'
#!/bin/sh
set -eu
usage() { echo "usage: phpswitch <app> <82|83|84>" >&2; exit 2; }
[ $# -eq 2 ] || usage
app=$1; ver=$2
case "$ver" in 82|83|84) ;; *) usage;; esac
conf=/etc/nginx/http.d/$app.conf
[ -f "$conf" ] || { echo "no vhost for app '$app'" >&2; exit 3; }
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
apk add --no-cache nodejs npm

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
id -u devshot >/dev/null 2>&1 || adduser -D -s /bin/bash devshot
mkdir -p /home/devshot/.openvscode-server/data/logs /home/devshot/projects
chown -R devshot:devshot /home/devshot

install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser (openvscode-server) — DevShot Editor"
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
rc-update add mariadb default
rc-update add php-fpm82 default
rc-update add php-fpm83 default
rc-update add php-fpm84 default
rc-update add nginx default
rc-update add openvscode-server default

# --- Launcher --------------------------------------------------------
# Belt-and-suspenders nudge for the very-first-second case (OpenRC
# already brings these up at boot via the runlevel adds above).
cat > /usr/local/bin/start-lamp <<'LAUNCHER'
#!/bin/sh
for svc in mariadb php-fpm82 php-fpm83 php-fpm84 nginx openvscode-server; do
  rc-service "$svc" status >/dev/null 2>&1 || rc-service "$svc" start || true
done
echo "lamp stack ready"
echo "PHP versions available: 8.2, 8.3, 8.4 (default 8.3; switch with phpswitch)"
LAUNCHER
chmod 0755 /usr/local/bin/start-lamp

# --- Cleanup ---------------------------------------------------------
rm -rf /root/.composer /home/*/.composer /tmp/*
rm -rf /var/cache/apk/*

echo "=== LAMP _core recipe complete ==="
df -h /var
for ver in 82 83 84; do echo "php${ver}: $(php${ver} --version | head -1)"; done
sync
