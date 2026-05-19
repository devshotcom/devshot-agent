#!/bin/sh
# LAMP recipe library — sourced by per-(app, version) variant wrappers.
# Provides parametrized install helpers + nginx vhost writer + mariadb
# bake-time lifecycle. Not a recipe itself; build-templates.sh skips
# files matching _*.sh during the variant-pass scan.

set -eu

LAMP_ADMIN_USER="${LAMP_ADMIN_USER:-admin}"
LAMP_ADMIN_PASSWORD="${LAMP_ADMIN_PASSWORD:-Admin12345!}"
LAMP_ADMIN_EMAIL="${LAMP_ADMIN_EMAIL:-admin@example.com}"

# Start mariadb in the background for the bake step. Required because
# every app's installer either runs SQL directly (wp install, typo3
# setup) or connects via DATABASE_URL (shopware system:install).
start_mariadb_for_bake() {
  mariadbd --user=mysql \
    --datadir=/var/lib/mysql \
    --socket=/run/mysqld/mysqld.sock \
    --bind-address=127.0.0.1 \
    --port=3306 \
    --pid-file=/run/mysqld/mysqld.pid \
    >/var/log/mysql/bake.log 2>&1 &
  LAMP_MYSQL_PID=$!

  for _ in $(seq 1 30); do
    [ -S /run/mysqld/mysqld.sock ] && break
    sleep 1
  done
  [ -S /run/mysqld/mysqld.sock ] || { echo "ERROR: mariadb socket missing" >&2; cat /var/log/mysql/bake.log >&2; exit 1; }

  for _ in $(seq 1 10); do
    nc -z 127.0.0.1 3306 && break
    sleep 1
  done
  nc -z 127.0.0.1 3306 || { echo "ERROR: mariadb not listening on 127.0.0.1:3306" >&2; cat /var/log/mysql/bake.log >&2; exit 1; }
}

stop_mariadb_after_bake() {
  mariadb-admin -uroot --socket=/run/mysqld/mysqld.sock shutdown || true
  wait "${LAMP_MYSQL_PID:-0}" 2>/dev/null || true
}

# Create one DB + matching user. Grants cover both 'localhost' (socket)
# and '127.0.0.1' (TCP), since different apps connect via different
# mysqli driver paths.
create_app_db() {
  db_name="$1"
  db_user="$2"
  db_pass="$3"
  mariadb -uroot --socket=/run/mysqld/mysqld.sock <<SQL
CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL ON ${db_name}.* TO '${db_user}'@'localhost';
GRANT ALL ON ${db_name}.* TO '${db_user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

# install_wordpress <version>
#   version: "6.7", "6.6", "5.9", … (matches WP's release-archive naming)
install_wordpress() {
  version="$1"
  create_app_db wordpress wordpress wordpress

  url="https://wordpress.org/wordpress-${version}.tar.gz"
  wget -q -O /tmp/wp.tar.gz "$url" \
    || { echo "ERROR: wp ${version} download failed from ${url}" >&2; exit 1; }
  tar -xzf /tmp/wp.tar.gz -C /var/www
  rm /tmp/wp.tar.gz

  cd /var/www/wordpress
  wp --allow-root config create \
    --dbname=wordpress --dbuser=wordpress --dbpass=wordpress \
    --dbhost=127.0.0.1 --skip-check
  wp --allow-root core install \
    --url=http://localhost \
    --title="DevShot WordPress ${version}" \
    --admin_user="${LAMP_ADMIN_USER}" \
    --admin_password="${LAMP_ADMIN_PASSWORD}" \
    --admin_email="${LAMP_ADMIN_EMAIL}" \
    --skip-email
}

# install_shopware <version>
#   version: any of
#     "6.6"                  → resolves to ^6.6 (latest 6.6.x.y)
#     "6.6.10.17"            → exact pin (Shopware uses 4-part SemVer)
#     "^6.7"                 → passed through as-is
#   Discovery emits the exact resolved version (4 segments). Operator-
#   typed loose forms (2 segments) also work.
install_shopware() {
  version="$1"
  case "$version" in
    \^*|~*|*\|*) constraint="$version" ;;             # already a composer expr
    *.*.*)       constraint="$version" ;;             # 3+ segments → exact pin
    *.*)         constraint="${version}.*" ;;         # "6.6" → "6.6.*" wildcard
    *)           constraint="^${version}" ;;           # bare major → caret
  esac
  create_app_db shopware shopware shopware

  cd /var/www
  export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
  composer create-project --no-dev --prefer-dist \
    "shopware/production:${constraint}" shopware

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
  # Shopware 6.7's system:install dropped admin-* flags — basic-setup
  # creates `admin/shopware`; we override right after to keep creds
  # consistent across variants. For ≤6.6 the flags still work, but
  # the override below is also a no-op-equivalent.
  ./bin/console system:install \
    --basic-setup \
    --force \
    --shop-locale=en-GB \
    --shop-currency=EUR \
    --shop-name="DevShot Shop (${version})" \
    --shop-email="${LAMP_ADMIN_EMAIL}" \
    -n
  ./bin/console user:change-password admin --password="${LAMP_ADMIN_PASSWORD}" -n
  ./bin/console assets:install
}

# install_typo3 <version>
#   version: any of
#     "13"          → ^13 (latest 13.x)
#     "13.4"        → ^13.4
#     "13.4.1"      → exact pin
#     "^14" / "~12" → passed through
#   Discovery emits the exact 3-segment version; manual invocation may
#   use any of the looser forms.
install_typo3() {
  version="$1"
  case "$version" in
    \^*|~*|*\|*) constraint="$version" ;;             # already a composer expr
    *.*.*)       constraint="$version" ;;             # exact (13.4.1)
    *.*)         constraint="^${version}" ;;          # 13.4 → ^13.4
    *)           constraint="^${version}" ;;          # bare major → caret
  esac
  create_app_db typo3 typo3 typo3

  cd /var/www
  export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
  composer create-project --no-dev --prefer-dist \
    "typo3/cms-base-distribution:${constraint}" typo3

  cd /var/www/typo3
  ./vendor/bin/typo3 setup \
    --driver=mysqli \
    --host=127.0.0.1 \
    --port=3306 \
    --dbname=typo3 \
    --username=typo3 \
    --password=typo3 \
    --admin-username="${LAMP_ADMIN_USER}" \
    --admin-user-password="${LAMP_ADMIN_PASSWORD}" \
    --admin-email="${LAMP_ADMIN_EMAIL}" \
    --project-name="DevShot TYPO3 v${version}" \
    --server-type=other \
    --create-site=http://localhost \
    --force \
    -n

  # Open SYS.trustedHostsPattern to '.*'. TYPO3 defaults to SERVER_NAME
  # match, which 503s any request whose Host doesn't equal the baked
  # site URL — incl. proxy reach paths in production. See spec 058
  # discussion + the lamp.sh original fix.
  php -r '$f="/var/www/typo3/config/system/settings.php";
$c=require $f;
if(!isset($c["SYS"])) $c["SYS"]=[];
$c["SYS"]["trustedHostsPattern"]=".*";
file_put_contents($f, "<?php\nreturn ".var_export($c, true).";\n");'
}

# write_nginx_vhost <app> <port> <doc_root> <client_max_body_size>
# IPv4 only — pool VM kernel has no AF_INET6 (see spec 058 / lamp.sh
# original fix). `listen [::]:NN` would EAFNOSUPPORT-abort nginx on
# boot.
write_nginx_vhost() {
  app="$1"; port="$2"; doc_root="$3"; max_body="$4"
  default_marker=""
  # WordPress vhost gets default_server so any unrouted request lands
  # somewhere sane; the other apps live on dedicated ports.
  [ "$app" = "wordpress" ] && default_marker=" default_server"

  cat > /etc/nginx/http.d/${app}.conf <<NGINX
server {
  listen ${port}${default_marker};
  server_name _;
  root ${doc_root};
  index index.php;
  client_max_body_size ${max_body};
  location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
  location ~ \\.php\$ {
    fastcgi_pass unix:/run/php-fpm83/php-fpm.sock;
    include /etc/nginx/fastcgi.conf;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY "";
  }
  location ~ /\\.ht { deny all; }
}
NGINX
}

# finalize_app_bake <app>
# Common post-install steps: fix ownership, remove vendor test suites,
# clear composer caches. Idempotent per call so a multi-app wrapper
# can run it once at end.
finalize_app_bake() {
  chown -R nginx:nginx /var/www
  chmod -R u+w \
    /var/www/wordpress/wp-content 2>/dev/null \
    || true
  chmod -R u+w \
    /var/www/typo3/var \
    /var/www/typo3/public/typo3temp \
    /var/www/typo3/public/typo3conf 2>/dev/null || true
  chmod -R u+w \
    /var/www/shopware/var \
    /var/www/shopware/public 2>/dev/null || true

  # Vendor test suites + .git mirrors ship with composer create-project.
  # None are needed at runtime.
  find /var/www -type d \( -name '.git' -o -name 'Tests' -o -name 'tests' \) \
    -prune -exec rm -rf {} + 2>/dev/null || true

  rm -rf /root/.composer /home/*/.composer /tmp/*
  rm -rf /var/cache/apk/*
}
