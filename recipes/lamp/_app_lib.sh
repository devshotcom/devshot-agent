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
