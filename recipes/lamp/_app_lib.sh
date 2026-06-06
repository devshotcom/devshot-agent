#!/bin/sh
# LAMP recipe library — sourced by per-(app, version) variant wrappers.
# Provides parametrized install helpers + nginx vhost writer + mariadb
# bake-time lifecycle. Not a recipe itself; build-templates.sh skips
# files matching _*.sh during the variant-pass scan.

set -eu

LAMP_ADMIN_USER="${LAMP_ADMIN_USER:-admin}"
LAMP_ADMIN_PASSWORD="${LAMP_ADMIN_PASSWORD:-Admin12345!}"
LAMP_ADMIN_EMAIL="${LAMP_ADMIN_EMAIL:-admin@example.com}"

install_lamp_launcher() {
  cat > /usr/local/bin/start-lamp <<'LAUNCHER'
#!/bin/sh
# Belt-and-suspenders nudge for the services OpenRC already boots. Only the
# DEFAULT php-fpm (8.3) is touched — 8.2/8.4 start on demand via phpswitch, so
# we don't pay 3x FPM startup + RAM here. Each start is retried once.
for svc in mariadb php-fpm83 nginx openvscode-server; do
  rc-service "$svc" status >/dev/null 2>&1 && continue
  rc-service "$svc" start >/dev/null 2>&1 || rc-service "$svc" start >/dev/null 2>&1 || true
done
# Wait for MariaDB's socket so a cold first HTTP hit doesn't 500 on a DB query
# (it settles on its own after; this just smooths the first request).
i=0
while [ "$i" -lt 20 ]; do
  [ -S /run/mysqld/mysqld.sock ] && break
  i=$((i + 1)); sleep 0.5
done
echo "lamp stack ready"
echo "PHP versions available: 8.2, 8.3, 8.4 (default 8.3; switch with phpswitch)"
LAUNCHER
  chmod 0755 /usr/local/bin/start-lamp
}

# set_editor_workspace <doc_root>
# Tells the openvscode-server OpenRC service to open <doc_root> as
# its default folder on boot. Called by install_<app> right after
# the app filesystem lands, so claim → editor opens the variant's
# own /var/www/<app> tree. The service start script reads from
# /etc/openvscode-default-folder (a one-line plain text file) —
# see _core.sh.
#
# Also bakes a workspace .vscode/settings.json with the DX defaults
# (Dark Modern, no Welcome, auto-save, no trust prompt) — VS Code Web
# ignores the server-side User profile, so workspace settings are the
# only way to ship a stunning out-of-the-box experience.
set_editor_workspace() {
  echo "$1" > /etc/openvscode-default-folder
  mkdir -p "$1/.vscode"
  cat > "$1/.vscode/settings.json" <<JSON
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.iconTheme": "vs-seti",
  "workbench.startupEditor": "none",
  "workbench.tips.enabled": false,
  "workbench.welcomePage.walkthroughs.openOnInstall": false,
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
  "task.allowAutomaticTasks": "on",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 800,
  "editor.fontSize": 13,
  "editor.minimap.enabled": true,
  "editor.bracketPairColorization.enabled": true,
  "explorer.compactFolders": false,
  "explorer.confirmDelete": false,
  "explorer.confirmDragAndDrop": false
}
JSON
  # Auto-run task on folder open — VS Code's `runOn: folderOpen` is the
  # only built-in hook that opens a terminal panel without a user
  # gesture. The task does nothing useful (`true`), but its presence
  # forces VS Code to spawn the integrated terminal at startup so the
  # operator lands on a ready bash prompt without hunting for Ctrl-`.
  cat > "$1/.vscode/tasks.json" <<JSON
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "DevShot: open terminal",
      "type": "shell",
      "command": "echo 'Welcome — you are in $1. PHP versions: 8.2 / 8.3 (default) / 8.4. Switch with phpswitch.'",
      "presentation": {
        "reveal": "always",
        "panel": "shared",
        "focus": false,
        "echo": false,
        "showReuseMessage": false,
        "clear": false
      },
      "runOptions": { "runOn": "folderOpen" },
      "problemMatcher": []
    }
  ]
}
JSON
}

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
  # WP canonical_redirect kicks in any time the request Host doesn't
  # match the configured siteurl — that's exactly what happens when
  # the DevShot proxy forwards `Host: <vm>.local:80` and WP tries to
  # send the browser back to `http://localhost/`. The redirect goes
  # to a host the browser can't reach, surfacing as a blank iframe
  # (the parent's CSP refuses to follow the cross-origin navigation).
  #
  # Install a must-use plugin that:
  #   (1) removes WP's redirect_canonical filter outright, and
  #   (2) rewrites HOME_URL / SITE_URL to the incoming request's
  #       scheme+host so subdir asset URLs (wp-content/...) resolve
  #       relative to whatever Host the proxy is sending today.
  # Must-use plugins live in /wp-content/mu-plugins/ and auto-load
  # without admin activation — perfect for opinionated baked-in
  # fixes.
  mkdir -p /var/www/wordpress/wp-content/mu-plugins
  cat > /var/www/wordpress/wp-content/mu-plugins/devshot-proxy.php <<'PHP'
<?php
// Devshot proxy compatibility — drop canonical redirects and let
// siteurl/home follow whatever Host the proxy is forwarding.
remove_filter('template_redirect', 'redirect_canonical');
add_filter('redirect_canonical', '__return_false');
$dynamic_url = function () {
  $scheme = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off' ? 'https' : 'http';
  $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
  return $scheme . '://' . $host;
};
add_filter('option_siteurl', $dynamic_url);
add_filter('option_home',    $dynamic_url);
PHP
  set_editor_workspace /var/www/wordpress
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

  # Bake the official Shopware 6 developer docs into the image so the Studio
  # agent can ground its plugin/theme/bugfix work in the real guidance — it is
  # instructed to consult these plus the core under vendor/shopware before
  # coding. A sibling of the project (not under /var/www/shopware) so it never
  # pollutes the agent's in-project file searches; the agent greps it by
  # absolute path. --depth 1 keeps the bake lean and finalize_app_bake strips
  # the .git mirror. Best-effort: a transient clone failure must not abort the
  # (expensive) Shopware template bake — the agent then falls back to the core.
  git clone --depth 1 https://github.com/shopware/docs.git /var/www/shopware-docs \
    || echo "WARN: shopware/docs clone failed — Studio agent will rely on core code only"

  set_editor_workspace /var/www/shopware
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
  set_editor_workspace /var/www/typo3
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
  install_lamp_launcher

  chown -R devshot:devshot /var/www
  chmod -R u+rwX,go+rX /var/www

  # Vendor test suites + .git mirrors ship with composer create-project.
  # None are needed at runtime.
  find /var/www -type d \( -name '.git' -o -name 'Tests' -o -name 'tests' \) \
    -prune -exec rm -rf {} + 2>/dev/null || true

  rm -rf /root/.composer /home/*/.composer /tmp/*
  rm -rf /var/cache/apk/*
}
