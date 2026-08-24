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

  # Spec 293 — wait until mariadb SERVES, not until it merely exists.
  #
  # The old gate accepted a socket file plus `nc -z 127.0.0.1 3306`. Both are
  # true before the server finishes crash recovery and loads its privilege
  # tables, and both stay true for a moment after the process dies. The bake
  # then ran the app installer against a server that was not answering, and
  # Shopware's system:install failed the whole nightly rebake with
  # "SQLSTATE[HY000] [2002] Connection refused" - taking every OTHER variant
  # down with it, including the wordpress image the public demo needs.
  #
  # Prove three things instead: the process is still alive, the socket answers
  # a ping, and a TCP client completes a real handshake. "Access denied" counts
  # as served - it means the server replied, which is exactly what the
  # installer needs; only connection-level failures keep us waiting.
  mariadb_bake_died() {
    ! kill -0 "${LAMP_MYSQL_PID:-0}" 2>/dev/null
  }
  mariadb_bake_serves() {
    mariadb-admin --socket=/run/mysqld/mysqld.sock -uroot ping >/dev/null 2>&1 || return 1
    tcp_probe=$(mariadb --protocol=TCP -h 127.0.0.1 -P 3306 -uroot -e 'SELECT 1' 2>&1) && return 0
    case "$tcp_probe" in
      *"Access denied"*) return 0 ;;
      *) return 1 ;;
    esac
  }

  mariadb_ready=0
  for _ in $(seq 1 90); do
    if mariadb_bake_died; then
      echo "ERROR: mariadb exited during bake startup" >&2
      cat /var/log/mysql/bake.log >&2
      exit 1
    fi
    if mariadb_bake_serves; then
      mariadb_ready=1
      break
    fi
    sleep 1
  done
  if [ "$mariadb_ready" != "1" ]; then
    echo "ERROR: mariadb never served a query on socket+127.0.0.1:3306" >&2
    cat /var/log/mysql/bake.log >&2
    exit 1
  fi
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

  # Pre-populate the Storefront vendor/ folder so a CUSTOM theme that inherits
  # @Storefront can compile on the FIRST try. @Storefront's own SCSS imports
  # `~vendor/bootstrap`, which only exists after the storefront npm install +
  # copy-to-vendor step — without it the agent's first theme:compile dies on
  # "cannot resolve ~vendor/bootstrap", an opaque wall a small model loops on.
  # Internet is available at bake; strictly best-effort so a transient npm hiccup
  # never aborts the (expensive) Shopware template bake.
  sf_app="vendor/shopware/storefront/Resources/app/storefront"
  if command -v npm >/dev/null 2>&1 && [ -d "$sf_app" ]; then
    ( cd "$sf_app" \
      && { npm ci --no-audit --no-fund || npm install --no-audit --no-fund; } \
      && { [ -f copy-to-vendor.js ] && node copy-to-vendor.js || true; } ) \
      || echo "WARN: storefront vendor bootstrap failed — a custom @Storefront theme may need 'npm ci && node copy-to-vendor.js' in $sf_app before theme:compile"
  else
    echo "WARN: npm or $sf_app missing — skipping storefront vendor bootstrap"
  fi

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

  # Bake a SHORT curated reference of the non-obvious Shopware gotchas that bite
  # real storefront builds — symptom -> cause -> fix KNOWLEDGE the agent greps and
  # then implements in its OWN way. This is deliberately NOT a copy-me plugin
  # skeleton (that would template the one happy path and make the agent narrower);
  # it is the same head-start a strong agent gets from front-loaded domain rules.
  # The agent is pointed here from buildShopwareSystemPrompt.
  cat > /var/www/shopware-patterns.md <<'PATTERNS'
# Shopware 6 — build patterns & gotchas (symptom -> cause -> fix)

This is reference KNOWLEDGE to inform code YOU write — never a template to copy.
Read the entry you need (`grep -n <topic> /var/www/shopware-patterns.md`), then
write the plugin yourself. For deeper API detail consult /var/www/shopware-docs or
one definition file under vendor/shopware/core/<Area>; the storefront theme test
fixtures at vendor/shopware/storefront/Resources (and, on dev checkouts,
tests/unit/Storefront/Theme/fixtures) are good structural references.

## Theme (SCSS-only, no JS build)
- Create every new theme with `bin/console theme:create <UpperCamelCaseName>` and
  edit that canonical scaffold. Its bootstrap MUST extend Plugin AND implement
  `Shopware\Storefront\Framework\ThemeInterface`. A plain active plugin with a
  theme.json is not a registered theme: `theme:change` stays "Invalid theme name".
  Never insert a row into the theme table to compensate.
- On this Shopware 6.7 image, omit `@Plugins` from theme.json views/assets. For a
  SCSS/Twig-only theme, omit `script` entirely; a custom script path requires a real
  compiled `app/storefront/dist/` bundle from `build-storefront.sh`. Use
  `"style": ["app/storefront/src/scss/overrides.scss", "@Storefront", "app/storefront/src/scss/base.scss"]`.
- Put brand variables in `app/storefront/src/scss/overrides.scss` and load it BEFORE
  `@StorefrontBootstrap` so your `$var: ... !default;` overrides actually win; put
  a short import manifest in `base.scss`, with tokens/layout/components/pages in
  separate partials. Compose substantial homepage sections from Twig includes.
  (overrides.scss before the bootstrap import is the difference between your palette
  applying and being ignored.)
- @Storefront's SCSS imports `~vendor/bootstrap`. On a fresh install that folder is
  populated by the storefront npm build; it is PRE-BAKED here, but if a compile ever
  fails on "cannot resolve ~vendor/bootstrap", run `npm ci && node copy-to-vendor.js`
  in vendor/shopware/storefront/Resources/app/storefront.
- Assign a brand-new generated theme with `bin/console theme:change --all <TechnicalName>`;
  the generated plugin name and theme.json "name" are the same technical name. That
  command ALSO compiles — do not add a separate
  theme:compile right after. A standalone `theme:compile` is only for restyling an
  ALREADY-assigned theme. `theme:change` takes the TECHNICAL name (theme.json "name"),
  never a display name — this also avoids shell-quoting issues with `&`/spaces. After any compile run `cache:clear` ONCE and
  RELOAD the preview (a stale `/theme/<hash>/css/all.css` 404 is a CACHE problem,
  not a reason to recompile — recompiling just mints another hash).
- Shopware 6.7's product detail override is
  `Resources/views/storefront/page/content/product-detail.html.twig`. The similarly
  named `page/product-detail/product-detail.html.twig` path is not the page template.
- Shopware 6.7's cart page override is
  `Resources/views/storefront/page/checkout/cart/index.html.twig`, not
  `page/checkout/cart.html.twig`. Category CTAs use
  `seoUrl('frontend.navigation.page', {navigationId: categoryId})` or
  `category.seoUrl`; `frontend.cms.page` expects a real CMS-page id, never a slug.
- For a from-scratch seeded homepage, use deterministic category/product ids directly
  with `seoUrl` instead of querying repositories from a Twig global. If page data is
  genuinely dynamic, subscribe to `NavigationPageLoadedEvent`, attach an `ArrayStruct`
  with `$event->getPage()->addExtension(...)`, and read `page.extensions.<name>` in
  Twig. Never replace `NavigationController` or query DAL inside a Twig extension.
- Preserve Shopware's native offcanvas markup, data attributes, and storefront plugin
  for mobile navigation. Do not inject an inline menu script. A truly custom
  interaction needs a storefront JS entry, `build-storefront.sh`, and a real dist bundle.

## Catalog seeding (idempotent, survives VM churn)
- Seed ALL catalog/CMS data as CODE in the plugin install()/activate() lifecycle
  (where `$this->container->get('product.repository')->upsert(...)` works) — NEVER
  via admin API, raw SQL, or a MigrationStep (a MigrationStep has only a Doctrine
  \Connection, no container). The DB is wiped on every fresh VM; only lifecycle code
  re-seeds. Keep the implementation in `Setup/CatalogSeeder.php`. On FIRST install,
  the plugin's own services.xml is not in the current compiled container yet: never
  call `$this->container->get(CatalogSeeder::class)` there. Instantiate the seeder
  with core repository/FileSaver services from `$this->container`; the exact core
  service id is `Shopware\Core\Content\Media\File\FileSaver::class`. Pass that FQCN
  into the directly-instantiated seeder and do not grep service configs or invent a
  plugin alias. Do not inline or duplicate the payload in the bootstrap.
- Every seeded id is a DETERMINISTIC 32-char hex: `Uuid::fromStringToHex('prod-eth-yirg')`
  (NOT `fromStringToBytes` — that does not exist) or `md5('...')`. Use it on NESTED
  rows too — product_visibility and media have their own BINARY(16) ids; without a
  deterministic id they get a fresh random id on every activate and DUPLICATE.
- For a product to RENDER it needs AT MINIMUM: a `tax`, a gross+net `price` in
  `Defaults::CURRENCY`, `stock`, a `categories` link to an active+visible category, AND
  a `visibilities` entry for the Storefront sales channel — these are the fields whose
  ABSENCE makes it invisible/unbuyable (a product carries many more). Null-check the
  sales channel: `salesChannelRepository->search(...)->first()` can return null —
  guard before `->getId()` and log/return rather than fatal.
- PROVE idempotency: call the Studio `shopware_check` tool with `check:"catalog"`,
  re-run the seeder once, then call the tool again and require both total and
  Storefront-visible counts to stay unchanged. Do not run `dal:count`, mysql/mariadb,
  or temporary PDO/Kernel probes; the tool already handles versioned/binary IDs.

## Media / images
- After any source URL is rejected for subject, bytes, size, or transport, the NEXT
  tool call is `curate_images` for that exact failed slot and subject. Do not walk a
  previously-curated list after a failure. A MIME/suffix mismatch is the one exception:
  retry the same URL once with the suffix named by `download_image`.
- Download the exact topical URLs returned by curate_images into
  `Resources/public/img/products/` before install. Every visible product needs a
  persisted media entity plus both `media` and `cover` assignments; a card/PDP with
  an empty image is a failed catalog. Verify listing and PDP with run_e2e
  `expectImagesLoaded`, then add a real product and assert it in `/checkout/cart`.
- `public/media` is Shopware-managed global state. Never write there and never
  replace Demostore media to fake theme ownership; owned assets stay below the
  plugin's `src/Resources/public/` tree and product files are persisted through
  FileSaver + MediaFile.
- Prefer the core `FileSaver` service for lifecycle seeding; a plugin-owned public alias
  is still unavailable during that plugin's first install. UPSERT the deterministic
  media entity row FIRST, then persist the bundled MediaFile onto it. A silent catch
  here is why product covers come back as 0 — fail loud instead.

## CMS homepage
- The product-slider block template calls `block.slots.getSlot('productSlider')`, so
  that slot MUST be named exactly `productSlider`. Seeding it as `content` (the text
  block's slot name) renders an EMPTY slider with `data-cms-element-id=""` even though
  the resolver has the right product ids. Slot names are a block-template contract.
- The home page loads via `CategoryRoute` using the sales channel's `homeCmsPageId`
  plus a `homeSlotConfig` override (NOT `CmsRoute`). Leave `homeSlotConfig` null — a
  non-null-but-empty override wipes your slots. Store slot config in the translation.

## Debugging an empty render
- If a listing/slider/CMS block is empty but data should exist, do NOT clear-cache-
  and-hope. Call `shopware_check {check:"all"}` directly. Its total vs
  Storefront-visible product counts and category/PDP render status distinguish a
  missing visibility/category relation from a Twig/theme failure. Never read `.env`,
  print DATABASE_URL/APP_SECRET, boot a Kernel in php -r, or query Shopware with a
  database CLI just to diagnose the storefront.
- Never swallow exceptions in a seeder — log/re-throw per item so a broken sub-step
  is visible. Re-read every file you just wrote and fix your own typos / unused
  imports / missed brackets (php -l) before moving on.

## Custom CMS blocks & elements (the bespoke-homepage mechanism)
- A custom CMS ELEMENT needs THREE coordinated parts or it renders nothing: (1) a backend resolver class implementing CmsElementResolverInterface — getType(): string, collect(CmsSlotEntity, ResolverContext): ?CriteriaCollection, enrich(CmsSlotEntity, ResolverContext, ElementDataCollection): void — registered in services.xml with the tag name="shopware.cms.data_resolver" (resolvers are keyed by getType(), matched to slot.type at render); (2) an admin registration: Shopware.Service('cmsService').registerCmsElement({name,label,component,configComponent,previewComponent,defaultConfig}) under Resources/app/administration; (3) a storefront template Resources/views/storefront/element/cms-element-<type>.html.twig. BLOCKS mirror this: registerCmsBlock({name,label,category,component,previewComponent,defaultConfig,slots}) + storefront/block/cms-block-<type>.html.twig.
- DATA FLOW — collect/enrich, never direct queries: collect() reads the slot config (slot.getFieldConfig()), builds a Criteria, and returns a CriteriaCollection so entities batch-fetch ONCE per page; enrich() takes the pre-fetched ElementDataCollection, wraps it in a Struct, and calls slot.setData(struct). NEVER query the repository inside enrich() — it N+1s the page. The storefront template reads element.data / element.fieldConfig.elements / element.config / element.type.
- SLOT CONFIG is a FieldConfig, not a scalar: each key has a SOURCE — SOURCE_STATIC (literal from admin), SOURCE_MAPPED (a path like product.name resolved against the page entity), SOURCE_PRODUCT_STREAM, SOURCE_DEFAULT. In a resolver check config.isStatic()/isMapped() then config.getValue()/getStringValue()/getArrayValue(). A block template renders inner elements with \`{% sw_include '@Storefront/storefront/element/cms-element-' ~ slot.type ~ '.html.twig' ignore missing %}\` (the \`ignore missing\` degrades gracefully).

## Faceted filtering — property group (built-in) vs custom field (needs a handler)
- A storefront FILTER/facet is built in ONLY for property groups: PropertyListingFilterHandler reads the \`properties\` request param (pipe-delimited option UUIDs, \`?properties=<uuid>|<uuid>\`) and aggregates on product.properties.id. So model a facet (roast level, color, size) as a PROPERTY GROUP and attach options via the product payload \`properties => [['id'=>optionId]]\` — faceted filtering then works with ZERO custom code. A value in \`customFields\` is NOT filterable out of the box (you'd need a custom handler extending AbstractListingFilterHandler tagged 'shopware.listing.filter.handler'). RULE: if it should be a FILTER, make it a property group; reserve customFields for display-only detail (origin, tasting notes).

## Clickable product card — the seoUrl + stretched-link contract
- A product card link is \`<a href="{{ seoUrl('frontend.detail.page', {productId: product.id}) }}" class="... stretched-link">\` — Bootstrap's \`stretched-link\` makes the whole card clickable. SYMPTOM: empty href => seoUrl() failed because the product has no id or the route name is wrong (the route is literally 'frontend.detail.page', /detail/{productId}). SYMPTOM: not clickable after a sw_extends override => you dropped the name-link block or the \`stretched-link\` class — keep both. NEVER hard-code hrefs in header/footer/breadcrumb overrides — use seoUrl('frontend.navigation.page', {navigationId: categoryId}) or category.seoUrl (URLs vary per language/sales-channel).

## Bulk seeding performance — disable indexing during the write
- SYMPTOM: seeding many products stalls install/activate. CAUSE: every upsert triggers synchronous indexing. FIX: wrap the seed in try/finally with \`$context->addState(EntityIndexerRegistry::DISABLE_INDEXING)\` at the start + \`removeState()\` in finally, then run \`bin/console dal:refresh:index\` once afterward. Use EntityRepository::upsert() (insert-or-update in one call).

## Env (already configured on this image — for reference only)
- A base `.env` exists, `APP_SECRET` is set, and `APP_ENV=prod` (no dev toolbar).
  These are baked; you should not need to touch them. composer require/update need
  the paid (internet) plan.
PATTERNS

  bake_shopware_base_theme

  set_editor_workspace /var/www/shopware
}

# Spec 170 — bake the parametric flagship-theme skeleton + demo-catalog seeder.
#
# DELIBERATE REVERSAL of the spec-148 "knowledge, not template" stance for the
# THEME SKELETON specifically: authoring ~15 boilerplate files from scratch on a
# slow hosted model is where Shopware builds burned their hours, while the
# skeleton content is exactly the verified spec-148 recipe. This stages FILES
# ONLY under /opt/devshot (no DB mutations, no compile — zero risk to the
# expensive Shopware bake); at build time the agent pulls it into the workspace
# with ONE command (install.sh <BrandName>) and spends its steps on brand,
# content, and imagery instead of plumbing. The knowledge docs above remain the
# reference for everything beyond the skeleton.
bake_shopware_base_theme() {
  base=/opt/devshot/shopware-base-theme
  plugin="$base/plugin/DevshotBase"
  mkdir -p \
    "$plugin/src/Setup" \
    "$plugin/src/Resources/app/storefront/src/scss" \
    "$plugin/src/Resources/public/fonts" \
    "$plugin/src/Resources/public/img/products" \
    "$plugin/src/Resources/views/storefront/layout/header" \
    "$plugin/src/Resources/views/storefront/layout/footer" \
    "$plugin/src/Resources/views/storefront/page/content"

  cat > "$base/install.sh" <<'INSTALL'
#!/bin/sh
# DevShot Studio — install the baked base theme as a brand-named plugin.
# Usage: sh /opt/devshot/shopware-base-theme/install.sh <UpperCamelBrandName>
# Copies the skeleton into custom/plugins/<Name>, renames class/namespace/theme
# to the brand, installs + activates the plugin (which seeds the demo catalog).
# It does NOT compile: edit the brand tokens first, then run
#   bin/console theme:change --all <Name>
# exactly once.
set -eu

NAME="${1:-}"
if ! printf %s "$NAME" | grep -Eq '^[A-Z][A-Za-z0-9]{2,40}$'; then
  echo "usage: install.sh <UpperCamelBrandName> (letters/digits, starts uppercase, 3-41 chars)" >&2
  exit 1
fi
LOWER=$(printf %s "$NAME" | tr 'A-Z' 'a-z')
PROJECT=/var/www/shopware
SRC=/opt/devshot/shopware-base-theme/plugin/DevshotBase
DEST="$PROJECT/custom/plugins/$NAME"

[ -d "$PROJECT" ] || { echo "shopware project not found at $PROJECT" >&2; exit 1; }
[ -e "$DEST" ] && { echo "$DEST already exists — edit it directly instead of re-installing" >&2; exit 1; }

cp -R "$SRC" "$DEST"
# POSIX-safe in-place rename (busybox and BSD sed disagree on -i semantics).
find "$DEST" -type f \( -name '*.php' -o -name '*.json' -o -name '*.twig' -o -name '*.scss' \) | while read -r f; do
  sed "s/DevshotBase/$NAME/g; s/devshotbase/$LOWER/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
mv "$DEST/src/DevshotBase.php" "$DEST/src/$NAME.php"

cd "$PROJECT"
bin/console plugin:refresh
bin/console plugin:install --activate "$NAME"
bin/console assets:install
echo "OK: $NAME installed and activated (demo catalog seeded)."
echo "NEXT: 1) edit brand tokens: custom/plugins/$NAME/src/Resources/app/storefront/src/scss/{overrides.scss,_tokens.scss}"
echo "      2) edit wordmark/footer/hero copy in src/Resources/views/storefront/"
echo "      3) replace the sample catalog in src/Setup/CatalogSeeder.php, re-run plugin:install --activate $NAME"
echo "      4) remove the --devshot-unbranded line from _tokens.scss LAST, then: bin/console theme:change --all $NAME"
INSTALL
  chmod +x "$base/install.sh"

  cat > "$plugin/composer.json" <<'JSON'
{
  "name": "devshot/devshotbase",
  "description": "DevShot Studio base theme - customize tokens, copy, and catalog",
  "version": "1.0.0",
  "type": "shopware-platform-plugin",
  "license": "MIT",
  "extra": {
    "shopware-plugin-class": "DevshotBase\\DevshotBase",
    "label": {
      "en-GB": "DevshotBase Theme"
    }
  },
  "autoload": {
    "psr-4": {
      "DevshotBase\\": "src/"
    }
  }
}
JSON

  cat > "$plugin/src/DevshotBase.php" <<'PHP'
<?php declare(strict_types=1);

namespace DevshotBase;

use DevshotBase\Setup\CatalogSeeder;
use Shopware\Core\Framework\Context;
use Shopware\Core\Framework\Plugin;
use Shopware\Core\Framework\Plugin\Context\ActivateContext;
use Shopware\Core\Framework\Plugin\Context\InstallContext;
use Shopware\Storefront\Framework\ThemeInterface;

class DevshotBase extends Plugin implements ThemeInterface
{
    public function install(InstallContext $installContext): void
    {
        parent::install($installContext);
        $this->seedCatalog($installContext->getContext());
    }

    public function activate(ActivateContext $activateContext): void
    {
        parent::activate($activateContext);
        $this->seedCatalog($activateContext->getContext());
    }

    // First-install rule: this plugin's own services are not in the compiled
    // container yet, so instantiate the seeder with CORE services from the
    // current container, passed as named arguments.
    private function seedCatalog(Context $context): void
    {
        $seeder = new CatalogSeeder(
            productRepository: $this->container->get('product.repository'),
            categoryRepository: $this->container->get('category.repository'),
            taxRepository: $this->container->get('tax.repository'),
            salesChannelRepository: $this->container->get('sales_channel.repository'),
        );
        $seeder->seed($context);
    }
}
PHP

  cat > "$plugin/src/Setup/CatalogSeeder.php" <<'PHP'
<?php declare(strict_types=1);

namespace DevshotBase\Setup;

use Shopware\Core\Defaults;
use Shopware\Core\Framework\Context;
use Shopware\Core\Framework\DataAbstractionLayer\EntityRepository;
use Shopware\Core\Framework\DataAbstractionLayer\Search\Criteria;
use Shopware\Core\Framework\DataAbstractionLayer\Search\Filter\EqualsFilter;

/**
 * Idempotent demo-catalog seeder (baked skeleton).
 *
 * EDIT the payloads below to the brand's REAL categories and products; keep the
 * deterministic md5() ids so re-running install/activate never duplicates.
 * Product imagery: bundle files under src/Resources/public/img/products and
 * attach them via the media repository + FileSaver (see the "media" entries in
 * /var/www/shopware-patterns.md). Failures must throw - never catch-and-continue
 * in a lifecycle seeder.
 */
class CatalogSeeder
{
    public function __construct(
        private readonly EntityRepository $productRepository,
        private readonly EntityRepository $categoryRepository,
        private readonly EntityRepository $taxRepository,
        private readonly EntityRepository $salesChannelRepository,
    ) {
    }

    public function seed(Context $context): void
    {
        $salesChannel = $this->salesChannelRepository->search(
            (new Criteria())->addFilter(new EqualsFilter('typeId', Defaults::SALES_CHANNEL_TYPE_STOREFRONT)),
            $context,
        )->first();
        if ($salesChannel === null) {
            throw new \RuntimeException('CatalogSeeder: no Storefront sales channel found.');
        }

        $rootId = $salesChannel->getNavigationCategoryId();
        $salesChannelId = $salesChannel->getId();
        $taxId = $this->resolveTaxId($context);

        $this->categoryRepository->upsert($this->categories($rootId), $context);
        $this->productRepository->upsert($this->products($taxId, $salesChannelId), $context);
    }

    private function resolveTaxId(Context $context): string
    {
        $tax = $this->taxRepository->search(new Criteria(), $context)->first();
        if ($tax !== null) {
            return $tax->getId();
        }
        $taxId = md5('devshot-tax-standard');
        $this->taxRepository->upsert([[
            'id' => $taxId,
            'name' => 'Standard rate',
            'taxRate' => 19.0,
        ]], $context);
        return $taxId;
    }

    /**
     * EDIT IN PLACE: rename these to the brand's real collections and KEEP the
     * md5() ids — the id is what makes the upsert OVERWRITE this row. Adding new
     * categories alongside these leaves "Collection One/Two/Three" live in the
     * storefront navigation next to the real ones (observed on a real build).
     * afterCategoryId chaining keeps the nav in this exact order.
     */
    private function categories(string $rootId): array
    {
        $one = md5('devshot-cat-one');
        $two = md5('devshot-cat-two');
        $three = md5('devshot-cat-three');
        return [
            ['id' => $one, 'parentId' => $rootId, 'name' => 'Collection One', 'active' => true, 'visible' => true],
            ['id' => $two, 'parentId' => $rootId, 'name' => 'Collection Two', 'active' => true, 'visible' => true, 'afterCategoryId' => $one],
            ['id' => $three, 'parentId' => $rootId, 'name' => 'Collection Three', 'active' => true, 'visible' => true, 'afterCategoryId' => $two],
        ];
    }

    /**
     * EDIT IN PLACE: rewrite these into the brand's real products (names,
     * numbers, prices, descriptions, category slugs) and KEEP the 'slug' values
     * — they seed the md5() ids that make the upsert OVERWRITE these rows.
     * Adding products alongside them leaves "Sample Product …" in the listing.
     * Only a product BEYOND these eight needs a new slug.
     * Every entry already carries the assignments that make it RENDER: a tax, a
     * gross/net price, stock, a category link, and a visibility row for the
     * default Storefront sales channel.
     */
    private function products(string $taxId, string $salesChannelId): array
    {
        $definitions = [
            ['slug' => 'devshot-prod-1', 'name' => 'Sample Product One', 'number' => 'DV-1001', 'gross' => 29.0, 'cat' => 'devshot-cat-one'],
            ['slug' => 'devshot-prod-2', 'name' => 'Sample Product Two', 'number' => 'DV-1002', 'gross' => 39.0, 'cat' => 'devshot-cat-one'],
            ['slug' => 'devshot-prod-3', 'name' => 'Sample Product Three', 'number' => 'DV-1003', 'gross' => 49.0, 'cat' => 'devshot-cat-one'],
            ['slug' => 'devshot-prod-4', 'name' => 'Sample Product Four', 'number' => 'DV-1004', 'gross' => 25.0, 'cat' => 'devshot-cat-two'],
            ['slug' => 'devshot-prod-5', 'name' => 'Sample Product Five', 'number' => 'DV-1005', 'gross' => 59.0, 'cat' => 'devshot-cat-two'],
            ['slug' => 'devshot-prod-6', 'name' => 'Sample Product Six', 'number' => 'DV-1006', 'gross' => 19.0, 'cat' => 'devshot-cat-two'],
            ['slug' => 'devshot-prod-7', 'name' => 'Sample Product Seven', 'number' => 'DV-1007', 'gross' => 79.0, 'cat' => 'devshot-cat-three'],
            ['slug' => 'devshot-prod-8', 'name' => 'Sample Product Eight', 'number' => 'DV-1008', 'gross' => 89.0, 'cat' => 'devshot-cat-three'],
        ];
        $products = [];
        foreach ($definitions as $def) {
            $products[] = [
                'id' => md5($def['slug']),
                'name' => $def['name'],
                'productNumber' => $def['number'],
                'description' => 'EDIT: a real, specific product description.',
                'stock' => 25,
                'active' => true,
                'taxId' => $taxId,
                'price' => [[
                    'currencyId' => Defaults::CURRENCY,
                    'gross' => $def['gross'],
                    'net' => round($def['gross'] / 1.19, 2),
                    'linked' => false,
                ]],
                'visibilities' => [[
                    'id' => md5('vis-' . $def['slug']),
                    'salesChannelId' => $salesChannelId,
                    'visibility' => 30,
                ]],
                'categories' => [['id' => md5($def['cat'])]],
            ];
        }
        return $products;
    }
}
PHP

  cat > "$plugin/src/Resources/theme.json" <<'JSON'
{
  "name": "DevshotBase",
  "author": "DevShot Studio",
  "views": ["@Storefront", "@DevshotBase"],
  "style": [
    "app/storefront/src/scss/overrides.scss",
    "@Storefront",
    "app/storefront/src/scss/base.scss"
  ]
}
JSON

  scss="$plugin/src/Resources/app/storefront/src/scss"
  cat > "$scss/overrides.scss" <<'SCSS'
// Token sheet - EDIT these to the brand. Declared BEFORE @Storefront so the
// framework's !default variables take our values and every stock component
// (buttons, links, breadcrumbs, badges) inherits the brand automatically.
$dv-bone: #f7f5f0;
$dv-ink: #17160f;
$dv-accent: #b4552d;
$dv-hairline: #e5e1d6;

$sw-color-brand-primary: $dv-ink;
$sw-color-brand-secondary: $dv-accent;
$sw-color-buy-button: $dv-ink;
$sw-background-color: $dv-bone;
$sw-border-color: $dv-hairline;

$font-family-base: 'Inter', system-ui, sans-serif;
$headings-font-family: 'Fraunces', Georgia, serif;

$border-radius: 0;
$border-radius-sm: 0;
$border-radius-lg: 0;
$btn-border-radius: 0;
$input-border-radius: 0;
$card-border-radius: 0;
$badge-border-radius: 0;
$modal-content-border-radius: 0;
SCSS

  cat > "$scss/base.scss" <<'SCSS'
// Import manifest ONLY - keep this file tiny; tokens, layout, components, and
// page rules live in their partials.
@import 'fonts';
@import 'tokens';
@import 'layout';
@import 'components';
@import 'pages';
SCSS

  cat > "$scss/_fonts.scss" <<'SCSS'
// Placeholder so theme:compile never fails on a missing import. To self-host
// real webfonts: fetch the Google css2 stylesheet with a browser User-Agent,
// download each woff2 into ../../public/fonts/, rewrite the urls to
// /bundles/devshotbase/fonts/, and replace this file with that css.
SCSS

  cat > "$scss/_tokens.scss" <<'SCSS'
// Brand tokens as custom properties - components build on these. EDIT the
// values together with overrides.scss.
//
// REMOVE the --devshot-unbranded line below as your LAST branding step: it is
// the machine-checked signal that this skeleton has not been branded yet, and
// completion is blocked while it is compiled in.
:root {
  --devshot-unbranded: 1;
  --dv-bone: #f7f5f0;
  --dv-ink: #17160f;
  --dv-accent: #b4552d;
  --dv-hairline: #e5e1d6;
  --dv-font-display: 'Fraunces', Georgia, serif;
  --dv-font-body: 'Inter', system-ui, sans-serif;
}
SCSS

  cat > "$scss/_layout.scss" <<'SCSS'
// Shared layout primitives.
.dv-section {
  max-width: 1320px;
  margin: 0 auto;
  padding: 6rem 1.5rem;
}

.dv-eyebrow {
  text-transform: uppercase;
  font-size: .76rem;
  font-weight: 600;
  letter-spacing: .16em;
  color: var(--dv-accent);
}

.dv-announce {
  background: var(--dv-ink);
  color: var(--dv-bone);
  text-align: center;
  text-transform: uppercase;
  font-size: .72rem;
  font-weight: 600;
  letter-spacing: .16em;
  padding: .55rem 1rem;
}

.dv-wordmark {
  font-family: var(--dv-font-display);
  font-size: 1.35rem;
  font-weight: 600;
  letter-spacing: .04em;
  color: var(--dv-ink);
  text-decoration: none;

  &:hover { color: var(--dv-accent); text-decoration: none; }
}
SCSS

  cat > "$scss/_components.scss" <<'SCSS'
// Gallery product cards - the Storefront hardcodes .product-image-wrapper
// heights (200px card / 332px listing); aspect-ratio alone then derives WIDTH
// from that fixed height and cards collapse to ~160px thumbnails. This is the
// production-verified recipe. Ratios stay DECIMALS (0.8), never 4 / 5.
.product-box {
  border: 0;

  .product-image-wrapper {
    height: auto !important;
    width: 100%;
    aspect-ratio: 0.8;
    overflow: hidden;
    border: 1px solid var(--dv-hairline);
    background: #fff;
  }

  .product-image-link { display: block; width: 100%; height: 100%; }

  .product-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
    transition: transform .7s cubic-bezier(.22, 1, .36, 1);
  }

  &:hover .product-image { transform: scale(1.04); }

  .product-name { font-family: var(--dv-font-display); }

  // gallery-quiet: the card sells with image + name + price.
  .product-description,
  .product-rating { display: none; }
}

// Money chrome sweep - the underlined caps "Prices incl. VAT" is the loudest
// "still a demo" tell after brand blue.
.product-price-tax-link,
.product-price-unit {
  font-size: .72rem;
  text-transform: none;
  text-decoration: none;
  color: rgba(23, 22, 15, .55);
}
SCSS

  cat > "$scss/_pages.scss" <<'SCSS'
// Homepage sections (see views/storefront/page/content/index.html.twig).
.dv-hero {
  background: var(--dv-bone);

  // Editorial default: full-width photo, copy beneath on paper — always legible,
  // no scrim needed. Restyle to a full-bleed overlay or a split layout if the
  // brand calls for it; keep object-fit: cover either way.
  .dv-hero-media {
    display: block;
    width: 100%;
    height: clamp(18rem, 46vh, 34rem);
    object-fit: cover;
  }

  .dv-hero-title {
    font-family: var(--dv-font-display);
    font-size: clamp(2.9rem, 6vw, 5.2rem);
    line-height: 1.05;
    letter-spacing: -0.02em;
    margin: 1rem 0;
  }

  .dv-hero-sub { max-width: 40rem; font-size: 1.1rem; }
  .dv-hero-actions { margin-top: 2rem; display: flex; gap: 1rem; }
}

.dv-tile {
  display: flex;
  align-items: flex-end;
  aspect-ratio: 0.8;
  border: 1px solid var(--dv-hairline);
  background: #fff;
  padding: 1.25rem;
  text-decoration: none;

  span {
    font-family: var(--dv-font-display);
    font-size: 1.3rem;
    color: var(--dv-ink);
  }

  &:hover { border-color: var(--dv-ink); text-decoration: none; }
}

.dv-story .dv-story-title { font-family: var(--dv-font-display); font-size: 2.2rem; }
.dv-story .dv-story-media {
  display: block;
  width: 100%;
  aspect-ratio: 1.25;
  object-fit: cover;
  border: 1px solid var(--dv-hairline);
  background: #fff;
}

.dv-quote {
  background: var(--dv-ink);
  color: var(--dv-bone);

  blockquote {
    font-family: var(--dv-font-display);
    font-style: italic;
    font-size: 1.6rem;
    margin: 0;
    max-width: 46rem;
  }
}

.dv-footer .dv-footer-heading {
  text-transform: uppercase;
  font-size: .74rem;
  font-weight: 600;
  letter-spacing: .14em;
}
.dv-footer .dv-footer-list { list-style: none; padding: 0; }
.dv-footer .dv-footer-list a { color: var(--dv-ink); text-decoration: none; }
.dv-footer .dv-footer-list a:hover { color: var(--dv-accent); }
.dv-footer-bottom {
  text-align: center;
  font-size: .78rem;
  color: rgba(23, 22, 15, .55);
  padding: 1rem 0 2rem;
}
SCSS

  views="$plugin/src/Resources/views/storefront"
  cat > "$views/layout/header/header.html.twig" <<'TWIG'
{% sw_extends '@Storefront/storefront/layout/header/header.html.twig' %}

{# EDIT: announcement copy + wordmark text. Keep the block names and the col-
   classes on the logo wrapper. The announcement bar replaces the default
   currency/language switcher top bar. #}
{% block layout_top_bar %}
    <div class="dv-announce">Complimentary shipping on every order</div>
{% endblock %}

{% block layout_header_logo %}
    <div class="col-4 col-lg-auto header-logo-col">
        <a class="dv-wordmark" href="{{ path('frontend.home.page') }}">DevshotBase</a>
    </div>
{% endblock %}
TWIG

  cat > "$views/layout/footer/footer.html.twig" <<'TWIG'
{% sw_extends '@Storefront/storefront/layout/footer/footer.html.twig' %}

{# EDIT: brand blurb + link columns. This override removes the service-hotline
   column and the "Realised with Shopware" line in one move. The navigationId
   values are the seeded categories (md5 of devshot-cat-one/-two/-three). #}
{% block layout_footer_inner_container %}
    <div class="container dv-footer">
        <div class="row">
            <div class="col-12 col-md-5">
                <p class="dv-wordmark">DevshotBase</p>
                <p class="dv-footer-blurb">EDIT: one-sentence brand statement.</p>
            </div>
            <div class="col-6 col-md-3">
                <p class="dv-footer-heading">Shop</p>
                <ul class="dv-footer-list">
                    <li><a href="{{ seoUrl('frontend.navigation.page', { navigationId: 'fe09f1156a77492e6c7931081b13a1a0' }) }}">Collection One</a></li>
                    <li><a href="{{ seoUrl('frontend.navigation.page', { navigationId: '2f46f4f0a8f7f6ec9ce85ce0e8c659e9' }) }}">Collection Two</a></li>
                    <li><a href="{{ seoUrl('frontend.navigation.page', { navigationId: 'e3ec47f6c13603e65c5977c3c8ebce98' }) }}">Collection Three</a></li>
                </ul>
            </div>
            <div class="col-6 col-md-3">
                <p class="dv-footer-heading">Service</p>
                <ul class="dv-footer-list">
                    <li><a href="{{ path('frontend.home.page') }}">EDIT: Contact</a></li>
                    <li><a href="{{ path('frontend.home.page') }}">EDIT: Shipping &amp; returns</a></li>
                </ul>
            </div>
        </div>
    </div>
{% endblock %}

{% block layout_footer_bottom %}
    <div class="dv-footer-bottom">&copy; {{ "now"|date("Y") }} DevshotBase</div>
{% endblock %}
TWIG

  cat > "$views/page/content/index.html.twig" <<'TWIG'
{% sw_extends '@Storefront/storefront/page/content/index.html.twig' %}

{# GATED bespoke homepage: this template renders EVERY navigation/CMS page, so
   the bespoke sections only render on the shop root - category pages keep
   parent(). EDIT the copy and wire real imagery (curate_images) into the hero
   and story slots; the section structure and the gate are production-verified.
   navigationId values = the seeded categories (md5 of devshot-cat-one/...). #}
{% block base_main_inner %}
    {% if shopware.navigation.id != context.salesChannel.navigationCategoryId %}
        {{ parent() }}
    {% else %}
        <section class="dv-hero">
            {# The asset() call + the bundles/<pluginnamelower>/ prefix is the ONLY
               path that resolves: assets:install publishes src/Resources/public/
               there. A bare "/img/hero.jpg" 404s (observed on a real build — it
               blanked the whole hero). Curate/download into
               src/Resources/public/img/ and swap ONLY the filename below. #}
            <img class="dv-hero-media" src="{{ asset('bundles/devshotbase/img/hero.jpg') }}" alt="EDIT: describe the hero image">
            <div class="dv-section">
                <p class="dv-eyebrow">EDIT: eyebrow line</p>
                <h1 class="dv-hero-title">EDIT: the brand promise in one confident line</h1>
                <p class="dv-hero-sub">EDIT: one supporting sentence about the brand.</p>
                <p class="dv-hero-actions">
                    <a class="btn btn-primary" href="{{ seoUrl('frontend.navigation.page', { navigationId: 'fe09f1156a77492e6c7931081b13a1a0' }) }}">Shop the collection</a>
                    <a class="btn btn-outline-secondary" href="{{ seoUrl('frontend.navigation.page', { navigationId: '2f46f4f0a8f7f6ec9ce85ce0e8c659e9' }) }}">Discover more</a>
                </p>
            </div>
        </section>
        <section class="dv-section">
            <div class="row g-3">
                <div class="col-12 col-md-4"><a class="dv-tile" href="{{ seoUrl('frontend.navigation.page', { navigationId: 'fe09f1156a77492e6c7931081b13a1a0' }) }}"><span>Collection One</span></a></div>
                <div class="col-12 col-md-4"><a class="dv-tile" href="{{ seoUrl('frontend.navigation.page', { navigationId: '2f46f4f0a8f7f6ec9ce85ce0e8c659e9' }) }}"><span>Collection Two</span></a></div>
                <div class="col-12 col-md-4"><a class="dv-tile" href="{{ seoUrl('frontend.navigation.page', { navigationId: 'e3ec47f6c13603e65c5977c3c8ebce98' }) }}"><span>Collection Three</span></a></div>
            </div>
        </section>
        <section class="dv-story dv-section">
            <div class="row align-items-center g-4">
                <div class="col-12 col-md-6">
                    <h2 class="dv-story-title">EDIT: brand story headline</h2>
                    <p>EDIT: two or three sentences of brand story.</p>
                </div>
                <div class="col-12 col-md-6">
                    {# Same asset() contract as the hero — swap the filename only. #}
                    <img class="dv-story-media" src="{{ asset('bundles/devshotbase/img/story.jpg') }}" alt="EDIT: describe the story image">
                </div>
            </div>
        </section>
        <section class="dv-quote">
            <div class="dv-section">
                <blockquote>&ldquo;EDIT: one short customer or founder quote.&rdquo;</blockquote>
            </div>
        </section>
    {% endif %}
{% endblock %}
TWIG

  # The bake runs as root under a restrictive umask, which left the staged
  # skeleton UNREADABLE for the devshot user on the VM ("Permission denied" on
  # the very first synced template, 2026-07-15) — install.sh could never run.
  # The skeleton is public boilerplate: make the tree world-readable and
  # directories traversable, and keep the parent /opt/devshot enterable.
  chmod a+rx /opt/devshot 2>/dev/null || true
  chmod -R a+rX "$base"
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

  # Shopware (Symfony) resolves the request host from HTTP_HOST and matches it
  # against the baked sales-channel domain (http://localhost) — any other Host
  # gets a 400. On a pool VM every reach path carries a non-localhost Host
  # (dom0 vm-app-probe, the claim-gate readiness curl, the public preview
  # proxy), so the storefront 400'd them all and Studio/Shopware never went
  # ready (claim → probe-fail → destroy loop). Force HTTP_HOST=localhost at
  # the fastcgi boundary — same override pattern as the httpoxy HTTP_PROXY
  # line — so the storefront serves for ANY incoming Host. TYPO3's equivalent
  # is trustedHostsPattern='.*' in install_typo3; WordPress is host-agnostic.
  host_override=""
  [ "$app" = "shopware" ] && host_override='fastcgi_param HTTP_HOST "localhost";'

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
    ${host_override}
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
