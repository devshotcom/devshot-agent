# Local design resources

`build-design-catalog.mjs` runs during the Studio template bake, when upstream registries and npm are reachable. It resolves registry dependencies, namespaces each kit, installs npm dependencies into the template and type-checks the catalog. Unsupported styles and excluded blocks are recorded in `catalog.json` and `dropped.json` with their reasons.

The bake and the runtime share `install-design-items.cjs`. Installation traverses only baked local registry files, checks every required npm package and destination before writing, and copies source files plus CSS variables, rules and supported Tailwind theme extensions. It does not invoke shadcn, npm or a network client. This avoids shadcn's implicit `ui.shadcn.com/r/colors/...` request even for local registry items. Missing dependencies require an explicit package installation or restoration of the baked `node_modules`; no sources are written before that check succeeds.

```sh
devshot-design list hero
devshot-design code tailark/dusk-hero-section-4
devshot-design add tailark/dusk-hero-section-4
devshot-design show tailark/dusk-hero-section-5
```

`show`, `code` and `add` explain excluded IDs and list matching available items from the same source and kit. They never choose a replacement automatically. If an ID was not indexed and has no recorded exclusion, the tool states that limitation rather than inventing a reason.

## Fonts

The initial font pack contains two unmodified variable TrueType fonts: Bodoni Moda (normal, 400–900, 162,104 bytes) and DM Sans (normal, 100–1000, 240,164 bytes). Both include optical sizing and the upstream glyph coverage. Fonts and full SIL OFL 1.1 notices come from Google's official font repository at the immutable revision in `design-fonts.cjs`. The bake verifies the SHA-256 of every font and license before writing the manifest. Downloads happen only at bake time; runtime installation verifies the local checksums again.

```sh
devshot-design fonts list
devshot-design fonts show bodoni-moda
devshot-design fonts add bodoni-moda dm-sans --cwd /var/www/studio
```

`fonts add` writes assets, license files and `public/fonts/devshot-fonts.css`, and appends full notices to `THIRD_PARTY_LICENSES.md`. Load this stylesheet from the document head:

```html
<link rel="stylesheet" href="/fonts/devshot-fonts.css" />
```

Use `font-family: "Bodoni Moda", serif` or `font-family: "DM Sans", sans-serif` and `font-optical-sizing: auto`. Next.js projects can also import the same files through `next/font/local`; `next/font/google` would initiate an unnecessary compile-time network request. Installing fonts does not rewrite the site's typography choices.

## Recipe and verification

The Studio recipe embeds all four scripts under `/usr/local/lib/devshot-design`, and `/usr/local/bin/devshot-design` points to the CLI. Update the source files and run `node apps/agent/recipes/design-catalog/sync-into-recipe.mjs`; `--check` detects drift. Changing these files takes effect in new templates after a normal template bake/release, not in already running VMs.

The offline regression suite forbids network clients and subprocesses during runtime installation, covers registry dependency closure and CSS resources, checks package/path preflight and verifies font checksums, notices and repeat installation. Run from `apps/console`:

```sh
npx vitest run lib/studio/design-catalog.offline.test.js lib/studio/design-catalog.spec386.test.js lib/studio/design-catalog.spec389.test.js lib/studio/design-catalog.spec390.test.js
```
