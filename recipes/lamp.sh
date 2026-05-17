#!/bin/sh
# Recipe: LAMP — nginx + multi-PHP (8.2/8.3/8.4) + mariadb. Three apps
# pre-installed, each on its own port:
#
#   - WordPress  on :80
#   - Shopware 6 on :81
#   - TYPO3 v13  on :82
#
# All three apps default to php-fpm 8.3. The 8.2 + 8.4 FPM pools also
# run (sockets at /run/php-fpm82/ + /run/php-fpm84/), and the CLI
# binaries `php82` / `php83` / `php84` are on PATH for testing version
# compatibility from a shell. Use `phpswitch <app> <version>` to point
# a vhost at a different FPM pool, e.g. `phpswitch shopware 84`.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/lamp.sh --name=lamp
#
# Output template: devshot-guest-lamp.qcow2. Default admin creds for
# every app:  admin / Admin12345!  (rotate before exposing anywhere real).
#
# Spec 050 — declared listen ports auto-populate the per-VM forward
# allowlist (and surface as Open buttons in the Servers tab):
# devshot:exposed_ports=[{"port":80,"name":"wordpress","proto":"http"},{"port":81,"name":"shopware","proto":"http"},{"port":82,"name":"typo3","proto":"http"}]
# devshot:memory_mb=1024
set -eux

# --- Pin Alpine to v3.22 ---------------------------------------------
# Alpine 3.23's community repo dropped php82 (it ships php83/84/85). We
# want all three of 8.2/8.3/8.4 side-by-side, and v3.22 is the most
# recent branch that still ships every one of them. build-templates.sh
# pre-pins to v3.23; override that here. v3.22 packages run fine on the
# v3.23 base rootfs because Alpine maintains ABI compatibility across
# adjacent branches for the libraries we touch.
sed -i 's|/alpine/v3\.[0-9]\+|/alpine/v3.22|g' /etc/apk/repositories
apk update
apk upgrade --no-cache

# --- Packages --------------------------------------------------------
# Same extension set for each PHP version so any app can run on any
# version. The 28 names below cover what WP, Shopware 6.6 and TYPO3 v13
# all collectively require.
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
# a symlink there. We want `php` (the binary wp-cli's PHAR shebang,
# composer's own shebang, and TYPO3's setup CLI all hit via `#!/usr/bin/env php`)
# to land on php83 because php83 is what each app's FPM pool also uses
# by default — same engine and extension set across CLI install and
# the live web request.
ln -sf /usr/bin/php83 /usr/bin/php
php -m | grep -qi mysqli || { echo "ERROR: mysqli not loaded on /usr/bin/php" >&2; php -m; exit 1; }

# --- Per-version FPM pools + php.ini ---------------------------------
# Each pool gets its own unix socket under /run/php-fpmXX/ so nginx can
# route an individual vhost (or even a single location block) to a
# specific PHP major.minor. All three pools run as nginx:nginx so
# /var/www file ownership stays uniform.
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

  # Shopware migrations and TYPO3 setup both want >256 MB. Same knobs
  # per ini so version doesn't change behavior.
  PHPINI=/etc/php${ver}/php.ini
  sed -i \
    -e 's|^;*memory_limit = .*|memory_limit = 512M|' \
    -e 's|^;*upload_max_filesize = .*|upload_max_filesize = 64M|' \
    -e 's|^;*post_max_size = .*|post_max_size = 64M|' \
    -e 's|^;*max_execution_time = .*|max_execution_time = 300|' \
    "$PHPINI"
done

# --- MariaDB: enable TCP on loopback ---------------------------------
# Alpine ships /etc/my.cnf.d/mariadb-server.cnf with `skip-networking`
# turned ON for hardening. Shopware's installer reads DATABASE_URL and
# connects via mysqli over TCP, so we have to flip it off. Two steps:
#
#  1. Comment the bare `skip-networking` line out of mariadb-server.cnf.
#     Setting `skip-networking = 0` in an override file alone is *not*
#     enough because /etc/my.cnf.d/ files load in lexicographic order
#     and `mariadb-server.cnf` always wins against anything alphabetically
#     before it.
#  2. Drop our settings in `zz-devshot.cnf` so it loads last and the
#     bind-address ends up at 127.0.0.1 (not whatever default the
#     base config picks).
sed -i 's|^[[:space:]]*skip-networking[[:space:]]*$|#skip-networking (disabled by devshot lamp recipe)|' \
  /etc/my.cnf.d/mariadb-server.cnf

cat > /etc/my.cnf.d/zz-devshot.cnf <<'CFG'
[mariadbd]
skip-networking = 0
bind-address = 127.0.0.1
skip-name-resolve
CFG

mkdir -p /run/mysqld /var/log/mysql
chown -R mysql:mysql /run/mysqld /var/lib/mysql /var/log/mysql
mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null

mariadbd --user=mysql \
  --datadir=/var/lib/mysql \
  --socket=/run/mysqld/mysqld.sock \
  --bind-address=127.0.0.1 \
  --port=3306 \
  --pid-file=/run/mysqld/mysqld.pid \
  >/var/log/mysql/bake.log 2>&1 &
MYSQL_PID=$!

for _ in $(seq 1 30); do
  [ -S /run/mysqld/mysqld.sock ] && break
  sleep 1
done
[ -S /run/mysqld/mysqld.sock ] || { echo "ERROR: mariadb socket missing" >&2; cat /var/log/mysql/bake.log >&2; exit 1; }

# Confirm TCP is actually listening — that's the failure mode we just
# hit when skip-networking was on. busybox's nc supports -z.
for _ in $(seq 1 10); do
  nc -z 127.0.0.1 3306 && break
  sleep 1
done
nc -z 127.0.0.1 3306 || { echo "ERROR: mariadb not listening on 127.0.0.1:3306" >&2; cat /var/log/mysql/bake.log >&2; exit 1; }

# One DB + user per app. Grants cover both 'localhost' (mysqli socket
# path) and '127.0.0.1' (Shopware DATABASE_URL).
mariadb -uroot --socket=/run/mysqld/mysqld.sock <<SQL
CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wordpress'@'localhost' IDENTIFIED BY 'wordpress';
CREATE USER 'wordpress'@'127.0.0.1' IDENTIFIED BY 'wordpress';
GRANT ALL ON wordpress.* TO 'wordpress'@'localhost';
GRANT ALL ON wordpress.* TO 'wordpress'@'127.0.0.1';

CREATE DATABASE shopware CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'shopware'@'localhost' IDENTIFIED BY 'shopware';
CREATE USER 'shopware'@'127.0.0.1' IDENTIFIED BY 'shopware';
GRANT ALL ON shopware.* TO 'shopware'@'localhost';
GRANT ALL ON shopware.* TO 'shopware'@'127.0.0.1';

CREATE DATABASE typo3 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'typo3'@'localhost' IDENTIFIED BY 'typo3';
CREATE USER 'typo3'@'127.0.0.1' IDENTIFIED BY 'typo3';
GRANT ALL ON typo3.* TO 'typo3'@'localhost';
GRANT ALL ON typo3.* TO 'typo3'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

mkdir -p /var/www
cd /var/www

# --- WordPress (latest) ----------------------------------------------
wget -q -O /tmp/wp.tar.gz https://wordpress.org/latest.tar.gz
tar -xzf /tmp/wp.tar.gz -C /var/www
rm /tmp/wp.tar.gz

wget -q -O /usr/local/bin/wp \
  https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod 0755 /usr/local/bin/wp

cd /var/www/wordpress
wp --allow-root config create \
  --dbname=wordpress --dbuser=wordpress --dbpass=wordpress \
  --dbhost=127.0.0.1 --skip-check
wp --allow-root core install \
  --url=http://localhost \
  --title="DevShot WordPress" \
  --admin_user=admin \
  --admin_password=Admin12345! \
  --admin_email=admin@example.com \
  --skip-email

# --- TYPO3 (v13 LTS) -------------------------------------------------
cd /var/www
export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
composer create-project --no-dev --prefer-dist \
  "typo3/cms-base-distribution:^13" typo3

cd /var/www/typo3
./vendor/bin/typo3 setup \
  --driver=mysqli \
  --host=127.0.0.1 \
  --port=3306 \
  --dbname=typo3 \
  --username=typo3 \
  --password=typo3 \
  --admin-username=admin \
  --admin-user-password=Admin12345! \
  --admin-email=admin@example.com \
  --project-name="DevShot TYPO3" \
  --server-type=other \
  --create-site=http://localhost \
  --force \
  -n

# --- Shopware 6 (latest) ---------------------------------------------
cd /var/www
composer create-project --no-dev --prefer-dist \
  shopware/production shopware

cd /var/www/shopware
cat > .env <<ENV
APP_ENV=prod
APP_SECRET=$(openssl rand -hex 32)
APP_URL=http://localhost
DATABASE_URL=mysql://shopware:shopware@127.0.0.1:3306/shopware
INSTANCE_ID=$(openssl rand -hex 16)
LOCK_DSN=flock
MAILER_DSN=null://null
ENV
# Shopware 6.7's system:install dropped the admin-* flags — basic-setup
# now always creates `admin/shopware`. We override the password right
# after to keep creds consistent across the three apps.
./bin/console system:install \
  --basic-setup \
  --force \
  --shop-locale=en-GB \
  --shop-currency=EUR \
  --shop-name="DevShot Shop" \
  --shop-email=admin@example.com \
  -n
./bin/console user:change-password admin --password='Admin12345!' -n
./bin/console assets:install
# theme:compile + admin webpack build are NOT run — they pull node_modules
# (~500 MB) and we want the template small. Vendor ships pre-built
# Resources/public/dist that's good enough for a vanilla install; the
# user can run `./bin/build-*.sh` post-claim if they need to recompile.

# --- Ownership + writable dirs ---------------------------------------
chown -R nginx:nginx /var/www
chmod -R u+w \
  /var/www/wordpress/wp-content \
  /var/www/typo3/var /var/www/typo3/public/typo3temp /var/www/typo3/public/typo3conf \
  /var/www/shopware/var /var/www/shopware/public 2>/dev/null || true

# --- nginx vhosts (each app on its own port, all routed to fpm83) ----
rm -f /etc/nginx/http.d/default.conf

cat > /etc/nginx/http.d/wordpress.conf <<'NGINX'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root /var/www/wordpress;
  index index.php;
  client_max_body_size 64M;
  location / { try_files $uri $uri/ /index.php?$args; }
  location ~ \.php$ {
    fastcgi_pass unix:/run/php-fpm83/php-fpm.sock;
    include /etc/nginx/fastcgi.conf;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
  }
  location ~ /\.ht { deny all; }
}
NGINX

cat > /etc/nginx/http.d/shopware.conf <<'NGINX'
server {
  listen 81;
  listen [::]:81;
  server_name _;
  root /var/www/shopware/public;
  index index.php;
  client_max_body_size 128M;
  location / { try_files $uri /index.php$is_args$args; }
  location ~ \.php$ {
    fastcgi_pass unix:/run/php-fpm83/php-fpm.sock;
    include /etc/nginx/fastcgi.conf;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_param HTTP_PROXY "";
  }
}
NGINX

cat > /etc/nginx/http.d/typo3.conf <<'NGINX'
server {
  listen 82;
  listen [::]:82;
  server_name _;
  root /var/www/typo3/public;
  index index.php;
  client_max_body_size 64M;
  location / { try_files $uri $uri/ /index.php$is_args$args; }
  location ~ \.php$ {
    fastcgi_pass unix:/run/php-fpm83/php-fpm.sock;
    include /etc/nginx/fastcgi.conf;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
  }
}
NGINX

# --- phpswitch: one-shot fastcgi_pass swap ---------------------------
# `phpswitch <app> <version>` rewrites the active vhost to point at a
# different FPM pool. All three pools are already running, so this is
# just a config edit + nginx reload — no service restart cascade.
cat > /usr/local/bin/phpswitch <<'SWITCH'
#!/bin/sh
set -eu
usage() { echo "usage: phpswitch <wordpress|shopware|typo3> <82|83|84>" >&2; exit 2; }
[ $# -eq 2 ] || usage
app=$1; ver=$2
case "$app" in wordpress|shopware|typo3) ;; *) usage;; esac
case "$ver" in 82|83|84) ;; *) usage;; esac
sed -i "s|/run/php-fpm[0-9]*/php-fpm.sock|/run/php-fpm$ver/php-fpm.sock|" /etc/nginx/http.d/$app.conf
nginx -t && rc-service nginx reload >/dev/null 2>&1 || nginx -s reload
echo "$app -> php8.${ver#8}"
SWITCH
chmod 0755 /usr/local/bin/phpswitch

# --- Stop bake mariadb (data persists in /var/lib/mysql) -------------
mariadb-admin -uroot --socket=/run/mysqld/mysqld.sock shutdown || true
wait $MYSQL_PID 2>/dev/null || true

# --- OpenRC services auto-start on boot ------------------------------
rc-update add mariadb default
rc-update add php-fpm82 default
rc-update add php-fpm83 default
rc-update add php-fpm84 default
rc-update add nginx default

# --- Launcher --------------------------------------------------------
# AppsTab's startWorkloadInVM calls `/usr/local/bin/start-<name> -d`.
# All three presets (wordpress/shopware/typo3) share workload=lamp, so
# this one script covers them — services come up via OpenRC at boot and
# this is a best-effort idempotent nudge for the very-first-second case.
cat > /usr/local/bin/start-lamp <<'LAUNCHER'
#!/bin/sh
for svc in mariadb php-fpm82 php-fpm83 php-fpm84 nginx; do
  rc-service "$svc" status >/dev/null 2>&1 || rc-service "$svc" start || true
done
echo "lamp stack ready — WordPress :80, Shopware :81, TYPO3 :82"
echo "PHP versions available: 8.2, 8.3, 8.4 (default 8.3; switch with phpswitch)"
LAUNCHER
chmod 0755 /usr/local/bin/start-lamp

# --- Cleanup (claw back ~200 MB) -------------------------------------
rm -rf /root/.composer /home/*/.composer /tmp/*
rm -rf /var/cache/apk/*
# Composer is install-time only; ditch it.
apk del composer 2>/dev/null || true
# Vendor test suites + .git mirrors ship with composer create-project.
# None are needed at runtime.
find /var/www -type d \( -name '.git' -o -name 'Tests' -o -name 'tests' \) \
  -prune -exec rm -rf {} + 2>/dev/null || true

echo "=== LAMP recipe complete ==="
du -sh /var/www/wordpress /var/www/shopware /var/www/typo3 2>/dev/null || true
df -h /var
for ver in 82 83 84; do echo "php${ver}: $(php${ver} --version | head -1)"; done
sync
