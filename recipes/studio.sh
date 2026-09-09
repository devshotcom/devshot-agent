#!/bin/sh
# Recipe: Studio — the fresh per-session app VM behind studio.devshot.com.
# A Next.js (App Router, TS, Tailwind v4, shadcn/ui) starter served in DEV mode with hot
# reload on :3000, plus openvscode-server on :8080 opened to the project.
# The DevShot Studio agent edits files in /var/www/studio via vm-exec; the
# running dev server reflects the change in the visitor's live preview.
#
# Why dev mode (not `next start` like node.sh): Studio is interactive — the
# AI rewrites files mid-session and the user must see the result instantly.
# `next dev` watches the filesystem and hot-reloads; a prod build would
# need a rebuild per change. So we keep the dev toolchain (no npm prune).
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/studio.sh --name=studio
# Output template: devshot-guest-studio.qcow2 (claimed as template "studio").
#
# Spec 050 — declared listen ports auto-populate the per-VM forward allowlist:
# devshot:exposed_ports=[{"port":3000,"name":"app","proto":"http"},{"port":8080,"name":"editor","proto":"http"}]
# devshot:memory_mb=2048
set -eux

apk update
# nodejs/npm for Next.js; gcompat so openvscode-server's optional glibc
# .node modules (watcher/spdlog/vsda) dlopen cleanly under musl; wget/tar
# for the editor tarball. chromium (+swiftshader for GPU-less headless +
# ttf-freefont) powers inspect_preview's real screenshot for the multimodal agent.
apk add --no-cache git nodejs npm gcompat ca-certificates wget tar chromium chromium-swiftshader ttf-freefont

# Runtime tools and start-studio use sudo as the unprivileged devshot user.
# Make that contract explicit in the flavored image instead of relying on the
# base template to carry the drop-in forever.
install -d -m 0750 /etc/sudoers.d
printf 'devshot ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/devshot
chmod 0440 /etc/sudoers.d/devshot
visudo -cf /etc/sudoers

# --- Grok Build + official GitHub Spec Kit -------------------------------
# The base image supplies one reviewed installer shared by every Studio flavor.
# It pins Grok by binary digest and Spec Kit by release commit, then leaves an
# offline project provisioner for .grok/skills at runtime.
/usr/local/libexec/devshot/install-grok-speckit.sh

# E2E browser-testing harness deps: puppeteer-core drives the chromium above so the
# agent's run_e2e tool can PROVE functionality (clicks/inputs/assertions), not just
# that a page renders. Installed into a fixed /opt path at BAKE time (network is
# available here) so it works OFFLINE on the network-locked runtime VM. puppeteer-core
# ships NO browser of its own (PUPPETEER_SKIP_DOWNLOAD=1; it uses the apk chromium),
# so this stays small. The runner (.devshot/e2e-runner.cjs) requires it by absolute path.
install -d /opt/devshot-e2e
( cd /opt/devshot-e2e && npm init -y >/dev/null 2>&1 && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --omit=dev puppeteer-core )

# --- Next.js starter at /var/www/studio ------------------------------
# create-next-app@latest at bake time → always the current starter.
# --yes accepts defaults (TypeScript + ESLint + Tailwind + App Router);
# --use-npm pins the package manager. NOTE: we deliberately do NOT build
# or prune — the VM runs `next dev`.
# Build the starter AS the devshot user — the dev server, editor, and (at
# runtime) the agent's vm-exec all run as devshot, so building as devshot makes
# the WHOLE project tree devshot-owned from the start. No build-as-root +
# chown-the-result: a fresh `npm install` mid-session can't leave root-owned
# node_modules the dev server can't read. /var/www is created devshot-owned so
# the app user can populate its own project dir; the build runs from a script
# file so the nested next.config heredoc needs no `su` quoting.
# NOTE: at BAKE the recipe runs as root (the bakery uses QGA ExecSimple
# directly), so this `su` is what drops to devshot here.
install -d -o devshot -g devshot /var/www

# --- Design catalog (spec 386) — root side ------------------------------
# /opt/devshot-design is where the bake leaves ~600 MIT-licensed marketing
# sections and UI components as LOCAL shadcn registry items, so the agent can
# `devshot-design add tailark/veil-hero-section-1` on the network-locked runtime
# VM. The builder below runs as devshot inside the build script (it installs the
# blocks' npm packages into the template and type-checks every block there);
# the directory is created here so the unprivileged user can write it. The
# builder's source of truth is apps/agent/recipes/design-catalog/
# build-design-catalog.mjs — the recipe is the only file that reaches the
# chroot, so it is embedded VERBATIM here and a console test asserts the two
# copies are identical (design-catalog-recipe.spec386.test.js).
install -d -o devshot -g devshot /opt/devshot-design
# A writable TMPDIR for the unprivileged build below. `/tmp` in the BAKE chroot
# is root-owned, and nothing needed it before: npm and npx cache under HOME, and
# create-next-app writes into its target. The shadcn CLI does not — it
# `mkdtemp()`s in TMPDIR, so the first bake with a catalog died on
# `EACCES: permission denied, mkdtemp '/tmp/shadcn-XXXXXX'` and took the whole
# template publish down with it (measured 2026-09-08, rebake 34205262837).
# Pointing TMPDIR at a directory devshot owns fixes every tool at once and
# leaves the image's own /tmp semantics alone.
install -d -o devshot -g devshot /home/devshot/.tmp
# >>> design-catalog: build-design-catalog.mjs (verbatim copy — do not edit here)
cat > /tmp/devshot-build-design-catalog.mjs <<'DEVSHOT_DESIGN_BUILDER_EOF'
#!/usr/bin/env node
// build-design-catalog.mjs — spec 386. Runs INSIDE the studio template bake
// (apps/agent/recipes/studio.sh embeds this file verbatim; the recipe is the
// only thing that reaches the chroot, so this script has no siblings there).
//
// What it produces, at --out (the image ships it at /opt/devshot-design):
//   r/<source>/<name>.json   one shadcn registry item per catalog entry, with
//                            every registryDependency rewritten to a LOCAL
//                            absolute path, every file given an explicit target,
//                            and import specifiers rewritten where a file was
//                            relocated — so `shadcn add <path>` works with the
//                            network gone (the runtime VM only reaches npm).
//   catalog.json             the index the devshot-design CLI and the agent read.
//   CATALOG.md               the same index for humans, grouped by category.
//   LICENSES/<source>.md     the upstream license text, fetched — a source whose
//                            license does not read MIT fails the bake.
//   dropped.json             every excluded item with its reason (audit trail).
//
// Why the bake and not the turn: the VM is network-locked except npm, and a
// block pulled at runtime would need a dev-server restart for its new packages
// anyway (studio-agent.js, "NEW DEPENDENCIES"). Here the network is open, so
// the union of npm dependencies is installed into the template once and a
// runtime `devshot-design add` is a pure file copy.
//
// Why a type-check gate: eight registries, eight conventions. Some declare
// hooks as components, some import packages they never declare, some ship
// three kits that all want to be components/ui/button.tsx. Nothing enters the
// catalog that does not compile INSIDE this template — the same `tsc` that
// `next build` runs — so an agent that adds a block never inherits a red build.
//
// Only Node built-ins. No npm dependency of its own; runs on Alpine's node.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

// ── sources ─────────────────────────────────────────────────────────────────
// Verified 2026-09-07 (license file, registry index, one item each): every
// source below is MIT with no Commons Clause. Shadcnblocks, Shadcn Studio,
// Aceternity and ReactBits are deliberately absent — their terms forbid
// exactly what DevShot is (a website generator / an AI tool that builds sites
// for end users), or carry no OSS license at all. Do not add a source here
// without re-reading its LICENSE.
//
// Namespacing: every source's ui files live under components/ui/<ns>/ and its
// block-level files under components/blocks/<ns>/, imports rewritten to match,
// so eight registries that each want components/ui/marquee.tsx or
// components/header.tsx coexist. <ns> is the source id, or the kit for Tailark
// (mist / dusk / veil, three complete kits that each ship their own button).
// Only the shadcn/ui primitives keep the bare components/ui/<name> path.
//
// `primitives` names which shadcn/ui flavour a source composes with: Radix
// (`asChild`) or Base UI (`render=`). Both flavours ship; the Base UI set is
// namespaced under components/ui/base/ and only Blocks.so imports it.
//
// `fixups` patch known upstream registry defects in file content before
// anything else looks at it (Tailark serves `SVGProps` and `ComponentProps`
// with their type arguments stripped — every file fails tsc as served).
//
// `importRewrites` map monorepo-internal specifiers (`@repo/shadcn`,
// `@repo/shadcn-ui/...`) to the project paths the shadcn CLI would have used.
export const SHADCN_STYLE = 'radix-nova';

export const SOURCES = [
  {
    id: 'tailark', title: 'Tailark (Mist / Dusk / Veil kits)', homepage: 'https://tailark.com',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/tailark/blocks/main/LICENCE.md',
    index: 'https://oss.tailark.com/r/radix/registry.json', item: 'https://oss.tailark.com/r/radix/{name}.json',
    namespaces: ['@tailark-oss', '@tailark'], hosts: ['oss.tailark.com'],
    select: (it) => it.type === 'registry:block', kind: 'block',
    uiNamespace: 'kit', blocksNamespace: 'kit', kits: ['mist', 'dusk', 'veil'], nameDerivedTargets: true,
    // Only in type positions (after `:`, `<`, `,`, `=`, `(`, `&`, `|`) — never in
    // an import list, where `{ SVGProps }` must stay a bare identifier.
    fixups: [
      [/(?<=[:<,=(&|]\s*)\bSVGProps(?![<\w])/g, 'SVGProps<SVGSVGElement>'],
      [/(?<=[:<,=(&|]\s*)\b(React\.)?ComponentProps(?![<\w])/g, '$1ComponentProps<any>'],
      [/(?<=[:<,=(&|]\s*)\b(React\.)?ComponentType(?![<\w])/g, '$1ComponentType<any>'],
    ],
  },
  {
    id: 'uilayouts', title: 'UI-Layouts blocks', homepage: 'https://www.ui-layouts.com',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/ui-layouts/uilayouts/main/LICENSE',
    index: 'https://www.ui-layouts.com/r/registry.json', item: 'https://www.ui-layouts.com/r/{name}.json',
    namespaces: ['@ui-layouts'], hosts: ['www.ui-layouts.com', 'ui-layouts.com'],
    select: (it) => it.type === 'registry:block', kind: 'block',
    uiNamespace: 'uilayouts', blocksNamespace: 'uilayouts',
    importRewrites: [{ barrel: /^@repo\/(ui\/)?shadcn$/ }],
  },
  {
    id: 'blocksso', title: 'Blocks.so', homepage: 'https://blocks.so',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/ephraimduncan/blocks/main/LICENSE.md',
    index: 'https://blocks.so/r/registry.json', item: 'https://blocks.so/r/{name}.json',
    namespaces: ['@blocks-so'], hosts: ['blocks.so'],
    select: (it) => it.type === 'registry:block', kind: 'block',
    uiNamespace: 'blocksso', blocksNamespace: 'blocksso', primitives: 'shadcn-base',
  },
  {
    id: 'smoothui', title: 'Smooth UI blocks', homepage: 'https://smoothui.dev',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/educlopez/smoothui/main/LICENSE',
    index: 'https://smoothui.dev/r/registry.json', item: 'https://smoothui.dev/r/{name}.json',
    namespaces: ['@smoothui'], hosts: ['smoothui.dev', 'www.smoothui.dev'],
    select: (it) => it.type === 'registry:block', kind: 'block',
    uiNamespace: 'smoothui', blocksNamespace: null, // already ships under components/smoothui/
  },
  {
    id: 'magicui', title: 'Magic UI', homepage: 'https://magicui.design',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/magicuidesign/magicui/main/LICENSE.md',
    index: 'https://magicui.design/r/registry.json', item: 'https://magicui.design/r/{name}.json',
    namespaces: ['@magicui'], hosts: ['magicui.design', 'www.magicui.design'],
    select: (it) => it.type === 'registry:ui', kind: 'component',
    uiNamespace: 'magicui', blocksNamespace: 'magicui',
  },
  {
    id: 'motionprim', title: 'Motion Primitives', homepage: 'https://motion-primitives.com',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/ibelick/motion-primitives/main/LICENCE.md',
    // The site answers bots with a Vercel checkpoint; the registry is committed.
    index: 'https://raw.githubusercontent.com/ibelick/motion-primitives/main/public/c/registry.json',
    item: 'https://raw.githubusercontent.com/ibelick/motion-primitives/main/public/c/{name}.json',
    namespaces: ['@motion-primitives'], hosts: ['motion-primitives.com', 'www.motion-primitives.com'],
    select: (it) => it.type === 'registry:ui', kind: 'component',
    uiNamespace: 'motionprim', blocksNamespace: 'motionprim',
  },
  {
    id: 'fancy', title: 'Fancy Components', homepage: 'https://www.fancycomponents.dev',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/danielpetho/fancy/main/LICENSE',
    index: 'https://www.fancycomponents.dev/r/registry.json', item: 'https://www.fancycomponents.dev/r/{name}.json',
    namespaces: ['@fancy'], hosts: ['fancycomponents.dev', 'www.fancycomponents.dev'],
    select: (it) => (it.type === 'registry:ui' || it.type === 'registry:block') && !/-demo(-|$)/.test(it.name),
    kind: 'component', uiNamespace: 'fancy', blocksNamespace: 'fancy',
  },
  {
    id: 'kibo', title: 'Kibo UI', homepage: 'https://www.kibo-ui.com',
    license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/shadcnblocks/kibo/main/license.md',
    index: 'https://www.kibo-ui.com/r/registry.json', item: 'https://www.kibo-ui.com/r/{name}.json',
    namespaces: ['@kibo-ui'], hosts: ['www.kibo-ui.com', 'kibo-ui.com'],
    select: (it) => it.type === 'registry:ui', kind: 'component',
    uiNamespace: 'kibo', blocksNamespace: null, // already ships under components/kibo-ui/
    importRewrites: [{ prefix: '@repo/shadcn-ui/components/ui/', to: '@/components/ui/' }, { prefix: '@repo/shadcn-ui/lib/utils', to: '@/lib/utils' }],
  },
];

// shadcn/ui itself, in both flavours. Bare registryDependencies ("button",
// "card") resolve to the owner source's `primitives` (Radix by default).
export const SHADCN_SOURCE = {
  id: 'shadcn', title: 'shadcn/ui (Radix)', homepage: 'https://ui.shadcn.com',
  license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/shadcn-ui/ui/main/LICENSE.md',
  item: `https://ui.shadcn.com/r/styles/${SHADCN_STYLE}/{name}.json`,
  namespaces: [], hosts: ['ui.shadcn.com'], kind: 'primitive', uiNamespace: null, blocksNamespace: null,
};
export const SHADCN_BASE_SOURCE = {
  id: 'shadcn-base', title: 'shadcn/ui (Base UI)', homepage: 'https://ui.shadcn.com',
  license: 'MIT', licenseUrl: 'https://raw.githubusercontent.com/shadcn-ui/ui/main/LICENSE.md',
  item: 'https://ui.shadcn.com/r/styles/base-nova/{name}.json',
  namespaces: [], hosts: [], kind: 'primitive', uiNamespace: 'base', blocksNamespace: 'base', primitives: 'shadcn-base',
  // base-nova items import @base-ui/react but do not declare it (init -b base adds it).
  extraDependencies: ['@base-ui/react'],
};
export const PRIMITIVE_SOURCES = [SHADCN_SOURCE, SHADCN_BASE_SOURCE];

// Items pulling any of these in are excluded up front: editors, sandboxes,
// media players, 3D and LLM SDKs are app frameworks, not design blocks, and
// each would add tens of megabytes to a template that boots in a 2 GB VM.
export const HEAVY_DEPENDENCIES = [
  /^@tiptap\//, /^@codesandbox\//, /^media-chrome$/, /^ai$/, /^shiki$/, /^@shikijs\//,
  /^three$/, /^@react-three\//, /^@shadergradient\//, /^ogl$/, /^gsap$/, /^lowlight$/,
  /^@clack\//, /^picocolors$/, /^tsup$/, /^tsx$/, /^vitest$/, /^ultracite$/,
];

// ── pure helpers (unit-tested from apps/console) ────────────────────────────

export function depName(spec) {
  // "cobe@^0.6.4" → "cobe"; "@dnd-kit/core@1" → "@dnd-kit/core"
  const s = String(spec || '').trim();
  if (!s) return '';
  const at = s.indexOf('@', s.startsWith('@') ? 1 : 0);
  return at === -1 ? s : s.slice(0, at);
}

export function isHeavyDependency(spec) {
  const name = depName(spec);
  return HEAVY_DEPENDENCIES.some((re) => re.test(name));
}

export function cleanSegments(p) {
  return String(p || '').replace(/\\/g, '/').split('/').filter((s) => s && s !== '.' && s !== '..');
}

// naturalTarget — where the file's OWN imports expect it to live, relative to
// the project root. Mirrors the shadcn CLI's resolution (explicit target wins;
// otherwise the path's well-known segment, otherwise the file type) but is
// computed here so the catalog knows every path before the CLI runs, and so a
// hook that a registry mislabels as a component still lands in hooks/.
const TARGET_ALIASES = [['@ui/', 'components/ui/'], ['@components/', 'components/'], ['@lib/', 'lib/'], ['@hooks/', 'hooks/'], ['~/', '']];
const TYPE_DIRS = { 'registry:ui': 'components/ui', 'registry:component': 'components', 'registry:block': 'components', 'registry:hook': 'hooks', 'registry:lib': 'lib' };

export function naturalTarget(file) {
  if (!file || typeof file !== 'object') return null;
  const explicit = String(file.target || '').replace(/\\/g, '/');
  if (explicit) {
    for (const [alias, dir] of TARGET_ALIASES) if (explicit.startsWith(alias)) return dir + explicit.slice(alias.length);
    const segs = cleanSegments(explicit);
    return segs.length ? segs.join('/') : null;
  }
  const segs = cleanSegments(file.path);
  if (!segs.length) return null;
  const base = segs[segs.length - 1];
  const idx = (name) => segs.lastIndexOf(name);
  const ui = idx('ui');
  if (ui !== -1 && segs[ui - 1] === 'components' && ui < segs.length - 1) return 'components/ui/' + segs.slice(ui + 1).join('/');
  const hooks = idx('hooks');
  if (hooks !== -1 && hooks < segs.length - 1) return 'hooks/' + segs.slice(hooks + 1).join('/');
  const lib = idx('lib');
  if (lib !== -1 && lib < segs.length - 1) return 'lib/' + segs.slice(lib + 1).join('/');
  const comps = idx('components');
  if (comps !== -1 && comps < segs.length - 1) return 'components/' + segs.slice(comps + 1).join('/');
  const dir = TYPE_DIRS[file.type];
  if (!dir) return null;
  return `${dir}/${base}`;
}

// kitOf — Tailark names are `<kit>-<thing>`; `core-*` is shared by all kits.
export function kitOf(source, itemName) {
  if (!source || !Array.isArray(source.kits)) return null;
  const head = String(itemName || '').split('-')[0];
  return source.kits.includes(head) ? head : null;
}

// namespaceOf — the folder a source's ui or block files live under, or null
// for "leave the path alone" (shadcn Radix primitives, sources that already
// ship namespaced paths).
export function namespaceOf(source, itemName, which) {
  const rule = source ? source[which === 'ui' ? 'uiNamespace' : 'blocksNamespace'] : null;
  if (!rule) return null;
  if (rule === 'kit') return kitOf(source, itemName); // core-*: shared, null
  return String(rule);
}

// relocate — the final project path for a file, given its natural path.
export function relocate(source, itemName, natural) {
  if (!natural) return natural;
  if (natural.startsWith('components/ui/')) {
    const ns = namespaceOf(source, itemName, 'ui');
    const rest = natural.slice('components/ui/'.length);
    if (!ns || rest.startsWith(`${ns}/`)) return natural;
    return `components/ui/${ns}/${rest}`;
  }
  if (natural.startsWith('components/') && !natural.startsWith('components/blocks/')) {
    const ns = namespaceOf(source, itemName, 'blocks');
    const rest = natural.slice('components/'.length);
    if (!ns || rest.startsWith(`${ns}/`) || rest.startsWith(`${source?.id}/`)) return natural;
    return `components/blocks/${ns}/${rest}`;
  }
  return natural;
}

// applyFixups — patch known upstream defects before anything reads the file.
export function applyFixups(content, source) {
  let out = String(content || '');
  for (const [re, to] of source?.fixups || []) out = out.replace(re, to);
  return out;
}

// Component → shadcn/ui module, for barrel imports like
// `import { Button, Switch } from '@repo/shadcn'`. Only what the registries
// actually use; an unknown name is left alone and fails the type gate.
export const SHADCN_MODULE_OF = {
  Button: 'button', Switch: 'switch', Card: 'card', CardContent: 'card', CardHeader: 'card', CardTitle: 'card', CardDescription: 'card', CardFooter: 'card',
  Badge: 'badge', Input: 'input', Label: 'label', Separator: 'separator', Textarea: 'textarea', Checkbox: 'checkbox', Avatar: 'avatar', AvatarImage: 'avatar', AvatarFallback: 'avatar',
  Tabs: 'tabs', TabsList: 'tabs', TabsTrigger: 'tabs', TabsContent: 'tabs', Slider: 'slider', Progress: 'progress', Skeleton: 'skeleton', Tooltip: 'tooltip', TooltipTrigger: 'tooltip', TooltipContent: 'tooltip', TooltipProvider: 'tooltip',
  Accordion: 'accordion', AccordionItem: 'accordion', AccordionTrigger: 'accordion', AccordionContent: 'accordion', Dialog: 'dialog', DialogTrigger: 'dialog', DialogContent: 'dialog', DialogHeader: 'dialog', DialogTitle: 'dialog', DialogDescription: 'dialog', DialogFooter: 'dialog',
  Popover: 'popover', PopoverTrigger: 'popover', PopoverContent: 'popover', Select: 'select', SelectTrigger: 'select', SelectContent: 'select', SelectItem: 'select', SelectValue: 'select', ScrollArea: 'scroll-area', Spinner: 'spinner', RadioGroup: 'radio-group', RadioGroupItem: 'radio-group',
};

// rewriteSourceImports — monorepo specifiers → project paths. Returns the new
// content plus the shadcn module names it now imports, so the caller can add
// them as primitive dependencies the upstream registry forgot to declare.
export function rewriteSourceImports(content, source) {
  let out = String(content || '');
  const modules = new Set();
  for (const rule of source?.importRewrites || []) {
    if (rule.prefix) {
      const re = new RegExp(`(from\\s*['"])${rule.prefix.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')}([^'"]*)`, 'g');
      out = out.replace(re, (m, lead, rest) => {
        if (rule.to.startsWith('@/components/ui/') && /^[a-z0-9-]+$/.test(rest)) modules.add(rest);
        return `${lead}${rule.to}${rest}`;
      });
    }
    if (rule.barrel) {
      out = out.replace(/^([ \t]*)import\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\3\s*;?[ \t]*$/gm, (m, indent, names, q, spec) => {
        if (!rule.barrel.test(spec)) return m;
        const lines = [];
        for (const part of names.split(',')) {
          const raw = part.trim();
          if (!raw) continue;
          const base = raw.split(/\s+as\s+/)[0].trim();
          const mod = SHADCN_MODULE_OF[base];
          if (!mod) return m; // unknown component: leave the line, let tsc judge
          modules.add(mod);
          lines.push(`${indent}import { ${raw} } from ${q}@/components/ui/${mod}${q};`);
        }
        return lines.join('\n');
      });
    }
  }
  return { content: out, modules: [...modules] };
}

// primitiveImports — the shadcn/ui modules a file imports by bare path
// (`@/components/ui/<name>`), for inferring primitives a registry forgot to
// declare. Nested paths (svgs/…) are never primitives.
export function primitiveImports(content) {
  const out = new Set();
  for (const m of String(content || '').matchAll(/from\s*['"]@\/components\/ui\/([a-z0-9-]+)['"]/g)) out.add(m[1]);
  return [...out];
}

export function stripExt(p) {
  return String(p || '').replace(/\.(tsx|ts|jsx|js|mjs|cjs|css|json)$/, '');
}

// rewriteImports — every `from '@/x'`, `import('@/x')` and `require('@/x')`
// whose module id is in the relocation map is rewritten. `map` keys and values
// are extension-less project-relative paths ("components/header" →
// "components/blocks/veil/header"); a directory import resolves via "/index".
export function rewriteImports(content, map) {
  if (!content || !map || !map.size) return content;
  const re = /((?:from|import|require)\s*\(?\s*)(['"])@\/([^'"]+)\2/g;
  return String(content).replace(re, (m, lead, q, spec) => {
    const target = map.get(spec) || map.get(`${spec}/index`) || (spec.endsWith('/index') ? map.get(spec.slice(0, -6)) : undefined);
    return target ? `${lead}${q}@/${target}${q}` : m;
  });
}

// resolveDepRef — turn one registryDependency string into {source, name}.
export function resolveDepRef(dep, ownerSource, sources = SOURCES) {
  const s = String(dep || '').trim();
  if (!s) return null;
  if (/^https?:\/\//.test(s)) {
    let url;
    try { url = new URL(s); } catch { return null; }
    const src = [...sources, ...PRIMITIVE_SOURCES].find((x) => (x.hosts || []).includes(url.hostname));
    const m = url.pathname.match(/\/([^/]+)\.json$/);
    if (!src || !m) return null;
    return { source: src.id, name: m[1] };
  }
  if (s.startsWith('@')) {
    const slash = s.indexOf('/');
    if (slash === -1) return null;
    const ns = s.slice(0, slash); const name = s.slice(slash + 1);
    const src = sources.find((x) => (x.namespaces || []).includes(ns));
    return src && name ? { source: src.id, name } : null;
  }
  if (/^[a-z0-9][a-z0-9-]*$/i.test(s)) return { source: ownerSource?.primitives || SHADCN_SOURCE.id, name: s };
  return null;
}

const CATEGORY_RULES = [
  ['hero', /hero/], ['header', /header|navbar|nav-|navigation|menu/], ['footer', /footer/],
  ['pricing', /pricing|price|plans?\b/], ['features', /feature|bento|benefit|service/], ['testimonials', /testimonial|review|quote/],
  ['faq', /faq|question/], ['cta', /\bcta\b|call-to-action|newsletter|waitlist|signup-cta/], ['logos', /logo-?cloud|logos|brands|partners|integrations?/],
  ['stats', /stats?\b|metric|kpi|number|chart|analytics/], ['team', /team|member|about-us|about/], ['contact', /contact|form/],
  ['auth', /login|signin|sign-in|signup|sign-up|register|auth|password|otp/], ['content', /blog|article|post|content|gallery|timeline|experience|comparison/],
  ['dashboard', /dashboard|sidebar|table|onboarding|dialog|file-upload|settings|billing|notification|chat|ai\b|command|calendar|kanban|gantt|list/],
  ['text', /text|typography|letter|word|heading|title|number|counter|type-?writer|underline|highlight/],
  ['background', /background|grid|dot|particle|beam|meteor|aurora|gradient|shader|noise|pattern|warp|globe|orbit|ripple|retro|spotlight|border/],
  ['motion', /marquee|reveal|scroll|carousel|slider|cursor|hover|magnetic|morph|transition|animated|animation|progress|shimmer|sparkle|confetti|dock|tilt|parallax|float/],
  ['button', /button/], ['card', /card/], ['media', /image|video|avatar|icon|player|zoom|crop/],
];

export function categorize(item, sourceKind) {
  const declared = Array.isArray(item?.categories) ? item.categories.filter(Boolean) : [];
  if (declared.length) return String(declared[0]).toLowerCase();
  const hay = `${item?.name || ''} ${item?.title || ''}`.toLowerCase();
  for (const [cat, re] of CATEGORY_RULES) if (re.test(hay)) return cat;
  return sourceKind === 'block' ? 'section' : 'component';
}

export function extractExports(content) {
  const out = new Set();
  const s = String(content || '');
  for (const m of s.matchAll(/export\s+default\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) out.add(`default:${m[1]}`);
  for (const m of s.matchAll(/export\s+default\s+([A-Za-z_$][\w$]*)\s*;?/g)) if (!/^(function|async|class)$/.test(m[1])) out.add(`default:${m[1]}`);
  for (const m of s.matchAll(/export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) out.add(m[1]);
  for (const m of s.matchAll(/export\s+(?:const|let|var|class)\s+([A-Za-z_$][\w$]*)/g)) out.add(m[1]);
  for (const m of s.matchAll(/export\s*\{([^}]*)\}/g)) {
    for (const part of m[1].split(',')) {
      const name = part.trim().split(/\s+as\s+/).pop();
      if (name && /^[A-Za-z_$][\w$]*$/.test(name)) out.add(name);
    }
  }
  return [...out];
}

// mainFile — the file the agent imports: the one named like the item, else
// the first block/component file outside components/ui, else the first file.
export function mainFile(item, files) {
  if (!files?.length) return null;
  const name = String(item?.name || '');
  const short = name.replace(/^(mist|dusk|veil)-/, '');
  const byName = files.find((f) => stripExt(path.posix.basename(f.target)) === short || stripExt(path.posix.basename(f.target)) === name);
  if (byName) return byName;
  const block = files.find((f) => !f.target.startsWith('components/ui/') && !f.target.startsWith('hooks/') && !f.target.startsWith('lib/') && /\.(tsx|jsx)$/.test(f.target));
  return block || files.find((f) => /\.(tsx|jsx|ts)$/.test(f.target)) || files[0];
}

// summarizeShape — what a block actually renders, from its own source, so ONE
// `devshot-design list` is enough to shortlist. Spec 390: measured live, the
// agent ran `list` four times, never `show`, never `code`, and adopted nothing.
// From "Hero Video Dialog — A hero video dialog component." you cannot tell
// whether a block fits your page; judging it meant a round trip per candidate,
// which costs more than writing the section yourself. So the judgement material
// moves into the listing.
export function summarizeShape(content) {
  const s = String(content || '');
  const count = (re) => (s.match(re) || []).length;
  const parts = [];
  const h = count(/<h[1-6][\s/>]/g);
  const p = count(/<p[\s/>]/g);
  if (h || p) parts.push(`${h}h${p ? `+${p}p` : ''}`);
  // A button is a <Button>, a <button>, or a link styled as a call to action.
  const btn = count(/<Button[\s/>]/g) + count(/<button[\s/>]/g);
  if (btn) parts.push(`${btn}btn`);
  const img = count(/<Image[\s/>]/g) + count(/<img[\s/>]/g);
  if (img) parts.push(`${img}img`);
  const svg = count(/<svg[\s/>]/g);
  if (svg && !img) parts.push(`${svg}svg`);
  // Repeated data is what makes a section a grid: an array literal of objects,
  // or a .map() over one.
  const maps = count(/\.map\(/g);
  if (maps) parts.push(`${maps}map`);
  if (/from ['"]motion\/react['"]|from ['"]framer-motion['"]/.test(s)) parts.push('motion');
  if (/'use client'|"use client"/.test(s)) parts.push('client');
  const lines = s.split('\n').length;
  parts.push(`${lines}L`);
  return parts.join('\u00b7');
}

export function hashContent(s) {
  return crypto.createHash('sha256').update(String(s || '')).digest('hex').slice(0, 16);
}

// resolveCollisions — two items writing different bytes to the same project
// path cannot both be installed. Keep the item from the earlier (higher
// priority) source; within a source keep the alphabetically first; drop the
// rest, then drop everything that depended on a dropped item, to a fixpoint.
export function resolveCollisions(items, sourceOrder) {
  const dropped = new Map();
  const rank = (id) => { const i = sourceOrder.indexOf(id.split('/')[0]); return i === -1 ? 999 : i; };
  const alive = () => [...items.values()].filter((it) => !dropped.has(it.id));
  let changed = true;
  while (changed) {
    changed = false;
    const owners = new Map(); // target → {id, hash}
    for (const it of alive().sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id))) {
      for (const f of it.files) {
        const prev = owners.get(f.target);
        if (!prev) { owners.set(f.target, { id: it.id, hash: f.hash }); continue; }
        if (prev.hash !== f.hash && prev.id !== it.id) {
          dropped.set(it.id, `collides with ${prev.id} on ${f.target}`);
          changed = true;
          break;
        }
      }
    }
    for (const it of alive()) {
      const dead = it.registryDependencies.find((d) => dropped.has(d) || !items.has(d));
      if (dead) { dropped.set(it.id, `depends on ${dead}${items.has(dead) ? '' : ' (unresolved)'}`); changed = true; }
    }
  }
  return dropped;
}

// ── fetching ────────────────────────────────────────────────────────────────

function log(...a) { process.stderr.write(a.join(' ') + '\n'); }

async function fetchText(url, { cacheDir, retries = 3 } = {}) {
  const key = cacheDir ? path.join(cacheDir, crypto.createHash('sha1').update(url).digest('hex')) : null;
  if (key && fs.existsSync(key)) return fs.readFileSync(key, 'utf8');
  let lastErr;
  for (let i = 0; i < retries; i += 1) {
    try {
      const res = await fetch(url, { redirect: 'follow', headers: { 'user-agent': 'Mozilla/5.0 (DevShot design-catalog bake)', accept: 'application/json,text/plain,*/*' } });
      if (res.status === 404) throw Object.assign(new Error(`404 ${url}`), { notFound: true });
      if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
      const text = await res.text();
      if (key) { fs.mkdirSync(cacheDir, { recursive: true }); fs.writeFileSync(key, text); }
      return text;
    } catch (err) {
      lastErr = err;
      if (err.notFound) throw err;
      await new Promise((r) => setTimeout(r, 800 * (i + 1)));
    }
  }
  throw lastErr;
}

async function fetchJson(url, opts) {
  const text = await fetchText(url, opts);
  try { return JSON.parse(text); } catch { throw new Error(`not JSON: ${url}`); }
}

async function mapLimit(list, limit, fn) {
  const out = new Array(list.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, list.length) }, async () => {
    while (next < list.length) { const i = next; next += 1; out[i] = await fn(list[i], i); }
  });
  await Promise.all(workers);
  return out;
}

// ── build ───────────────────────────────────────────────────────────────────

export async function buildCatalog({ out, project, cacheDir, concurrency = 8, validate = true, minItems = 0, sources = SOURCES } = {}) {
  if (!out) throw new Error('--out is required');
  const outAbs = path.resolve(out);
  const rDir = path.join(outAbs, 'r');
  fs.rmSync(rDir, { recursive: true, force: true });
  fs.mkdirSync(rDir, { recursive: true });
  fs.mkdirSync(path.join(outAbs, 'LICENSES'), { recursive: true });

  const allSources = [...PRIMITIVE_SOURCES, ...sources]; // primitives first = highest priority
  const byId = new Map(allSources.map((s) => [s.id, s]));
  const priority = allSources.map((s) => s.id);
  const dropped = new Map(); // id → reason
  const raw = new Map(); // id → upstream item json (content already fixed up + import-rewritten)
  const wanted = []; // ids selected from indexes (roots)
  const missing404 = new Set();

  // 1. licenses — fail loud, this is the whole point.
  for (const s of allSources) {
    const text = await fetchText(s.licenseUrl, { cacheDir });
    if (!/permission is hereby granted, free of charge/i.test(text)) throw new Error(`license for ${s.id} does not read as MIT: ${s.licenseUrl}`);
    if (/commons clause/i.test(text)) throw new Error(`license for ${s.id} carries a Commons Clause: ${s.licenseUrl}`);
    fs.writeFileSync(path.join(outAbs, 'LICENSES', `${s.id}.md`), `# ${s.title}\n\nSource: ${s.homepage}\nLicense file: ${s.licenseUrl}\n\n${text.trim()}\n`);
  }

  // 2. indexes → roots
  for (const s of sources) {
    const index = await fetchJson(s.index, { cacheDir });
    const items = Array.isArray(index?.items) ? index.items : [];
    let picked = 0;
    for (const it of items) {
      if (!it?.name || !s.select(it)) continue;
      wanted.push(`${s.id}/${it.name}`); picked += 1;
    }
    log(`[catalog] ${s.id}: ${picked} of ${items.length} index items selected`);
    if (!picked) throw new Error(`no items selected from ${s.id} — index format changed?`);
  }

  // fetchItem — one registry item: fetched, fixed up, monorepo imports rewritten,
  // its declared + import-derived dependencies queued.
  const seen = new Set();
  const pending = [];
  const enqueue = (id) => { if (!seen.has(id)) { seen.add(id); pending.push(id); } };
  async function fetchItem(id) {
    const sid = id.split('/')[0]; const name = id.slice(id.indexOf('/') + 1);
    const s = byId.get(sid);
    if (!s) { dropped.set(id, `unknown source ${sid}`); return; }
    let item;
    try {
      item = await fetchJson(s.item.replace('{name}', name), { cacheDir });
    } catch (err) {
      if (err.notFound) missing404.add(id);
      dropped.set(id, `fetch failed: ${err.message}`);
      return;
    }
    const deps = new Set();
    for (const dep of item.registryDependencies || []) {
      const ref = resolveDepRef(dep, s, sources);
      if (!ref) { dropped.set(id, `unresolvable registryDependency "${dep}"`); continue; }
      deps.add(`${ref.source}/${ref.name}`);
    }
    for (const f of item.files || []) {
      if (typeof f.content !== 'string') continue;
      const fixed = applyFixups(f.content, s);
      const { content, modules } = rewriteSourceImports(fixed, s);
      f.content = content;
      for (const mod of modules) deps.add(`${s.primitives || SHADCN_SOURCE.id}/${mod}`);
    }
    item.registryDependencies = [...deps];
    raw.set(id, item);
    for (const d of deps) enqueue(d);
  }

  // 3. fetch closure
  for (const id of wanted) enqueue(id);
  while (pending.length) {
    const batch = pending.splice(0, pending.length);
    await mapLimit(batch, concurrency, fetchItem);
  }
  log(`[catalog] fetched ${raw.size} items (${dropped.size} failed)`);

  // 4. normalize: natural targets, relocation, hashes
  const items = new Map();
  const relocMap = new Map(); // `${source}:${kit}:${naturalNoExt}` → newNoExt
  const scopeOf = (s, name) => `${s.id}:${kitOf(s, name) || ''}`;
  function normalize(id) {
    const item = raw.get(id);
    if (!item || dropped.has(id) || items.has(id)) return;
    const s = byId.get(id.split('/')[0]);
    const kit = kitOf(s, item.name);
    const files = [];
    let bad = null;
    const nonUi = (item.files || []).filter((f) => !['registry:ui', 'registry:hook', 'registry:lib'].includes(f.type));
    for (const f of item.files || []) {
      if (f.type === 'registry:page' || f.type === 'registry:file') { bad = `ships a ${f.type} (would add routes)`; break; }
      let natural = naturalTarget(f);
      // Tailark declares `@components/header.tsx` for every kit header while its
      // blocks import `@/components/hero-section-1-header`: the name is the truth.
      if (s.nameDerivedTargets && kit && nonUi.length === 1 && nonUi[0] === f && natural && natural.startsWith('components/') && !natural.startsWith('components/ui/')) {
        natural = `components/${item.name.slice(kit.length + 1)}${path.posix.extname(natural) || '.tsx'}`;
      }
      if (!natural) { bad = `file without a resolvable target: ${f.path || '?'}`; break; }
      if (typeof f.content !== 'string' || !f.content) { bad = `file without content: ${f.path || natural}`; break; }
      const target = relocate(s, item.name, natural);
      if (target !== natural) relocMap.set(`${scopeOf(s, item.name)}:${stripExt(natural)}`, stripExt(target));
      files.push({ type: f.type, natural, target, content: f.content });
    }
    if (!bad && !files.length && !(item.cssVars || item.css)) bad = 'no files';
    if (!bad) {
      const heavy = [...(item.dependencies || []), ...(item.devDependencies || [])].find(isHeavyDependency);
      if (heavy) bad = `heavy dependency ${heavy}`;
    }
    if (bad) { dropped.set(id, bad); return; }
    items.set(id, { id, source: s.id, kit, name: item.name, upstream: item, files, registryDependencies: [...item.registryDependencies] });
  }
  for (const id of raw.keys()) normalize(id);

  // 4b. infer primitives a registry forgot to declare: an import of
  //     `@/components/ui/<x>` that nothing in the item's closure provides is a
  //     shadcn/ui primitive of the source's flavour. Fetch it, to a fixpoint.
  const provides = (id, x, visited = new Set()) => {
    if (visited.has(id)) return false; visited.add(id);
    const it = items.get(id);
    if (!it) return false;
    if (it.files.some((f) => stripExt(f.natural) === `components/ui/${x}`)) return true;
    return it.registryDependencies.some((d) => provides(d, x, visited));
  };
  // siblingProvider — a same-source (same-kit) item whose files ship
  //     components/ui/<x>: UI-Layouts blocks import `@/components/ui/timeline-animation`
  //     that only a sibling block carries. Prefer the smallest provider (a
  //     dedicated ui item over a whole block that happens to bundle it).
  const siblingProvider = (it, x) => {
    let best = null;
    for (const other of items.values()) {
      if (other.id === it.id || other.source !== it.source || other.kit !== it.kit) continue;
      if (!other.files.some((f) => stripExt(f.natural) === `components/ui/${x}`)) continue;
      if (!best || other.files.length < best.files.length || (other.files.length === best.files.length && other.id < best.id)) best = other;
    }
    return best ? best.id : null;
  };
  for (let pass = 0; pass < 5; pass += 1) {
    const inferred = new Map(); // itemId → dep ids
    for (const it of items.values()) {
      const s = byId.get(it.source);
      if (s.kind === 'primitive') continue;
      for (const f of it.files) {
        for (const x of primitiveImports(f.content)) {
          if (provides(it.id, x)) continue;
          const sibling = siblingProvider(it, x);
          const depId = sibling || `${s.primitives || SHADCN_SOURCE.id}/${x}`;
          if (!sibling && dropped.has(depId)) continue; // asked before, nothing there
          if (!inferred.has(it.id)) inferred.set(it.id, new Set());
          inferred.get(it.id).add(depId);
        }
      }
    }
    if (!inferred.size) break;
    for (const deps of inferred.values()) for (const d of deps) if (!raw.has(d) && !dropped.has(d)) enqueue(d);
    while (pending.length) { const batch = pending.splice(0, pending.length); await mapLimit(batch, concurrency, fetchItem); }
    for (const id of raw.keys()) normalize(id);
    let added = 0;
    for (const [itemId, deps] of inferred) {
      const it = items.get(itemId);
      if (!it) continue;
      for (const d of deps) {
        if (!items.has(d)) continue; // not a primitive after all (a sibling nobody ships, a 404): tsc will say
        if (!it.registryDependencies.includes(d)) { it.registryDependencies.push(d); it.upstream.registryDependencies.push(d); added += 1; }
      }
    }
    log(`[catalog] inferred ${added} undeclared dependencies from imports (pass ${pass + 1})`);
    if (!added) break;
  }

  // 4c. rewrite imports: a file sees its own source+kit relocations, the shared
  //     (kit-less) ones of its source, and those of the primitive flavour it uses.
  for (const it of items.values()) {
    const s = byId.get(it.source);
    const scopes = [`${s.id}:${it.kit || ''}`, `${s.id}:`];
    const prim = byId.get(s.primitives || SHADCN_SOURCE.id);
    if (prim && prim.id !== s.id) scopes.push(`${prim.id}:`);
    const map = new Map();
    for (const [k, v] of relocMap) for (const sc of scopes) if (k.startsWith(`${sc}:`)) map.set(k.slice(sc.length + 1), v);
    for (const f of it.files) { f.content = rewriteImports(f.content, map); f.hash = hashContent(f.content); }
  }

  // 5. collisions + dependency closure
  for (const [id, why] of resolveCollisions(items, priority)) { dropped.set(id, why); items.delete(id); }
  log(`[catalog] ${items.size} items after collision/dependency pruning`);

  // 6. write registry items
  const itemPath = (id) => path.join(rDir, `${id}.json`);
  const writeAll = () => {
    fs.rmSync(rDir, { recursive: true, force: true });
    for (const it of items.values()) {
      const u = it.upstream;
      const json = {
        $schema: 'https://ui.shadcn.com/schema/registry-item.json',
        name: u.name, type: u.type, title: u.title, description: u.description,
        author: u.author, categories: u.categories, meta: u.meta, docs: u.docs,
        dependencies: [...(u.dependencies || []).filter((d) => !isHeavyDependency(d)), ...(byId.get(it.source)?.extraDependencies || [])],
        devDependencies: (u.devDependencies || []).filter((d) => !isHeavyDependency(d)),
        registryDependencies: it.registryDependencies.map((d) => itemPath(d)),
        files: it.files.map((f) => ({ path: `registry/${it.source}/${path.posix.basename(f.target)}`, type: f.type, target: f.target, content: f.content })),
        cssVars: u.cssVars, css: u.css, tailwind: u.tailwind,
      };
      for (const k of Object.keys(json)) if (json[k] === undefined) delete json[k];
      fs.mkdirSync(path.dirname(itemPath(it.id)), { recursive: true });
      fs.writeFileSync(itemPath(it.id), JSON.stringify(json, null, 1));
    }
  };
  writeAll();

  // 7. npm dependencies into the template (once, at bake)
  if (project) {
    const pkg = JSON.parse(fs.readFileSync(path.join(project, 'package.json'), 'utf8'));
    const have = new Set([...Object.keys(pkg.dependencies || {}), ...Object.keys(pkg.devDependencies || {})]);
    const deps = new Set(); const dev = new Set();
    for (const it of items.values()) {
      for (const d of it.upstream.dependencies || []) if (!isHeavyDependency(d) && !have.has(depName(d))) deps.add(d);
      for (const d of it.upstream.devDependencies || []) if (!isHeavyDependency(d) && !have.has(depName(d))) dev.add(d);
      for (const d of byId.get(it.source)?.extraDependencies || []) if (!have.has(depName(d))) deps.add(d);
    }
    for (const list of [deps, dev]) for (const d of list) if (dev.has(d) && deps.has(d)) dev.delete(d);
    log(`[catalog] installing ${deps.size} dependencies + ${dev.size} devDependencies into ${project}`);
    const npm = (args) => execFileSync('npm', ['install', '--no-audit', '--no-fund', '--no-progress', ...args], { cwd: project, stdio: 'inherit', env: { ...process.env, HOME: process.env.HOME || '/tmp' } });
    if (deps.size) npm(['--save', ...deps]);
    if (dev.size) npm(['--save-dev', ...dev]);
  }

  // 8. type-check gate: install EVERYTHING into a staging copy of the template
  //    and drop whatever does not compile there, to a fixpoint (≤ 3 rounds).
  if (validate && project) {
    for (let round = 1; round <= 3; round += 1) {
      const staging = path.join(outAbs, '.staging');
      fs.rmSync(staging, { recursive: true, force: true });
      fs.mkdirSync(staging, { recursive: true });
      for (const entry of fs.readdirSync(project)) {
        if (entry === 'node_modules' || entry === '.next' || entry === '.git') continue;
        fs.cpSync(path.join(project, entry), path.join(staging, entry), { recursive: true });
      }
      fs.symlinkSync(path.join(project, 'node_modules'), path.join(staging, 'node_modules'));
      const shadcn = path.join(project, 'node_modules', '.bin', 'shadcn');
      const ids = [...items.keys()].sort();
      for (let i = 0; i < ids.length; i += 40) {
        const chunk = ids.slice(i, i + 40).map(itemPath);
        const r = spawnSync(shadcn, ['add', '-y', '-o', '-s', '-c', staging, ...chunk], { cwd: staging, encoding: 'utf8', env: { ...process.env, HOME: process.env.HOME || '/tmp', CI: '1' } });
        if (r.status !== 0) throw new Error(`shadcn add failed in staging (round ${round}):\n${r.stdout}\n${r.stderr}`);
      }
      // every target the catalog claims must exist where it claims
      let missing = 0;
      for (const it of items.values()) for (const f of it.files) if (!fs.existsSync(path.join(staging, f.target))) { dropped.set(it.id, `CLI did not write ${f.target}`); items.delete(it.id); missing += 1; break; }
      // Next 16 declares its route helper types (LayoutProps, PageProps) in
      // .next/types, which only exist after a build or `next typegen`; the
      // staging copy has no .next, so generate them first (best effort — a
      // failure here shows up as an error OUTSIDE the catalog, reported below).
      const next = path.join(project, 'node_modules', '.bin', 'next');
      if (fs.existsSync(next)) spawnSync(next, ['typegen'], { cwd: staging, encoding: 'utf8', env: { ...process.env, HOME: process.env.HOME || '/tmp', CI: '1' } });
      const tsc = path.join(project, 'node_modules', '.bin', 'tsc');
      const t = spawnSync(tsc, ['--noEmit', '--pretty', 'false', '-p', staging], { cwd: staging, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
      const errs = String(t.stdout || '').split('\n').filter((l) => /error TS\d+/.test(l));
      const owners = new Map();
      for (const it of items.values()) for (const f of it.files) owners.set(f.target, it.id);
      const culprits = new Map();
      for (const line of errs) {
        const m = line.match(/^([^(]+)\(\d+,\d+\): error (TS\d+): (.*)$/);
        if (!m) continue;
        const file = m[1].replace(/\\/g, '/').replace(/^\.\//, '');
        const owner = owners.get(file);
        if (owner) culprits.set(owner, `${m[2]} in ${file}: ${m[3].slice(0, 160)}`);
      }
      log(`[catalog] round ${round}: ${errs.length} type errors → ${culprits.size} items dropped, ${missing} missing targets`);
      for (const [id, why] of culprits) { dropped.set(id, `type error: ${why}`); items.delete(id); }
      for (const [id, why] of resolveCollisions(items, priority)) { dropped.set(id, why); items.delete(id); }
      writeAll();
      // audit trail per round, so a bake that dies later still explains its drops
      fs.writeFileSync(path.join(outAbs, 'dropped.json'), JSON.stringify([...dropped].map(([id, reason]) => ({ id, reason })), null, 1));
      if (!culprits.size && !missing) {
        // Errors in files nobody in the catalog owns are the template's own
        // (or a typegen that could not run) — not this gate's verdict. Say so.
        if (errs.length) log(`[catalog] WARN ${errs.length} type error(s) outside the catalog (template-level, not gated):\n${errs.slice(0, 10).join('\n')}`);
        fs.rmSync(staging, { recursive: true, force: true });
        break;
      }
      if (round === 3) throw new Error('catalog did not converge to a clean type-check in 3 rounds');
    }
  }

  // 9. index
  const catalog = {
    version: 1, generatedAt: new Date().toISOString(), style: SHADCN_STYLE, root: outAbs,
    sources: allSources.map((s) => ({ id: s.id, title: s.title, homepage: s.homepage, license: s.license, licenseFile: `LICENSES/${s.id}.md`, kind: s.kind })),
    primitives: PRIMITIVE_SOURCES.map((s) => ({ id: s.id, style: (s.item.match(/styles\/([^/]+)\//) || [])[1] || null, namespace: s.uiNamespace })),
    items: [...items.values()].filter((it) => wanted.includes(it.id) || byId.get(it.source)?.kind !== 'primitive').sort((a, b) => a.id.localeCompare(b.id)).map((it) => {
      const s = byId.get(it.source);
      const main = mainFile(it.upstream, it.files);
      return {
        id: it.id, source: it.source, name: it.name, type: it.upstream.type,
        kind: wanted.includes(it.id) ? s.kind : 'support',
        category: categorize(it.upstream, s.kind),
        title: it.upstream.title || it.name, description: it.upstream.description || '',
        files: it.files.map((f) => f.target),
        main: main ? main.target : null,
        shape: main ? summarizeShape(main.content) : '',
        exports: main ? extractExports(main.content) : [],
        dependencies: [...(it.upstream.dependencies || []).filter((d) => !isHeavyDependency(d)), ...(byId.get(it.source)?.extraDependencies || [])],
        registryDependencies: it.registryDependencies,
        registryFile: path.relative(outAbs, itemPath(it.id)),
      };
    }),
    dropped: [...dropped].map(([id, reason]) => ({ id, reason })).sort((a, b) => a.id.localeCompare(b.id)),
  };
  const visible = catalog.items.filter((it) => it.kind !== 'support');
  if (visible.length < minItems) throw new Error(`only ${visible.length} catalog items survived (minimum ${minItems})`);
  fs.writeFileSync(path.join(outAbs, 'catalog.json'), JSON.stringify(catalog, null, 1));
  fs.writeFileSync(path.join(outAbs, 'dropped.json'), JSON.stringify(catalog.dropped, null, 1));
  fs.writeFileSync(path.join(outAbs, 'CATALOG.md'), renderCatalogMarkdown(catalog));
  log(`[catalog] done: ${visible.length} items (${catalog.items.length} incl. support), ${catalog.dropped.length} dropped → ${outAbs}`);
  return catalog;
}

export function renderCatalogMarkdown(catalog) {
  const lines = ['# DevShot design catalog', '', `Generated ${catalog.generatedAt} · shadcn style ${catalog.style}`, '',
    'Use `devshot-design list <query>` to search, `devshot-design show <id>` for details and',
    '`devshot-design add <id>` to copy a block into the project. Every item is MIT; see LICENSES/.', ''];
  const groups = new Map();
  for (const it of catalog.items) {
    if (it.kind === 'support') continue;
    const key = `${it.kind}/${it.category}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(it);
  }
  for (const key of [...groups.keys()].sort()) {
    lines.push(`## ${key} (${groups.get(key).length})`, '');
    for (const it of groups.get(key)) lines.push(`- \`${it.id}\` — ${it.title}${it.description ? `: ${it.description}` : ''} → ${it.main || it.files[0]}`);
    lines.push('');
  }
  lines.push('## Sources', '');
  for (const s of catalog.sources) lines.push(`- ${s.title} — ${s.homepage} — ${s.license} (${s.licenseFile})`);
  lines.push('');
  return lines.join('\n');
}

// ── cli ─────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const o = { concurrency: 8, validate: true, minItems: 0 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--out') o.out = argv[++i];
    else if (a === '--project') o.project = argv[++i];
    else if (a === '--cache') o.cacheDir = argv[++i];
    else if (a === '--concurrency') o.concurrency = Number(argv[++i]) || 8;
    else if (a === '--min-items') o.minItems = Number(argv[++i]) || 0;
    else if (a === '--no-validate') o.validate = false;
    else throw new Error(`unknown argument ${a}`);
  }
  return o;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) {
  buildCatalog(parseArgs(process.argv.slice(2))).catch((err) => {
    log(`FATAL: design catalog build failed: ${err.stack || err.message}`);
    process.exit(1);
  });
}

export const __filename_for_tests = fileURLToPath(import.meta.url);
DEVSHOT_DESIGN_BUILDER_EOF
# <<< design-catalog: build-design-catalog.mjs
chmod 0644 /tmp/devshot-build-design-catalog.mjs
cat > /tmp/devshot-build-studio.sh <<'BUILDSTUDIO'
#!/bin/sh
set -eux
export HOME=/home/devshot
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# /tmp is root-owned in the bake chroot; the shadcn CLI mkdtemp()s in TMPDIR.
# Created devshot-owned by the root half above.
export TMPDIR=/home/devshot/.tmp

# create-next-app@latest at bake time → always the current starter. --yes accepts
# defaults (TypeScript + ESLint + Tailwind + App Router); --use-npm pins the
# package manager. We deliberately do NOT prune — the VM runs `next dev`.
cd /var/www
npx --yes create-next-app@latest studio --yes --use-npm
cd /var/www/studio

# --- Clean the create-next-app default cruft -------------------------
# The default starter ships a branded welcome page.tsx that references
# /next.svg + /vercel.svg, plus public/{next,vercel,file,globe,window}.svg.
# Once a real app is built those are orphaned and the dev server 404s them —
# noise weaker models fixate on every turn ("/next.svg is a 404 but that's
# fine…"). Ship a clean, neutral starting page and drop the branding SVGs so a
# fresh Studio app has ZERO create-next-app default cruft for the agent to chase.
rm -f public/next.svg public/vercel.svg public/file.svg public/globe.svg public/window.svg
# The run_e2e harness writes .devshot/e2e-runner.cjs into the project each run;
# git-ignore it so it never lands in the user's commits (auto-commit, spec 080).
printf '\n# DevShot run_e2e harness (regenerated each run)\n.devshot/\n' >> .gitignore
cat > app/page.tsx <<'STARTPAGE'
export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-3 p-8 text-center">
      <h1 className="text-2xl font-semibold tracking-tight">Your app is ready</h1>
      <p className="text-sm text-gray-500">Describe a change in the chat to start building.</p>
    </main>
  );
}
STARTPAGE

# --- Asset prefix for the path-based public proxy --------------------
# The preview is served behind /api/public/p/<vm>/<port>/, but Next.js loads its
# runtime chunks/fonts/CSS from the ORIGIN ROOT (/_next/...) by default — which,
# inside the proxied iframe, resolves to the console origin and 404s every asset
# (blank/unstyled preview). Point Next's assetPrefix at the per-VM proxy path so
# every emitted /_next/... URL routes back through the proxy to this VM. The value
# can't be baked (it depends on the VM name) — start-studio exports
# DEVSHOT_ASSET_PREFIX per-VM and `next dev` reads it at launch. Replace any
# starter config so there's a single next.config Next will read.
rm -f next.config.js next.config.mjs next.config.ts
cat > next.config.mjs <<'NEXTCONFIG'
// Managed by the DevShot Studio recipe — serves build assets under the per-VM
// public-proxy path. DEVSHOT_ASSET_PREFIX is exported by start-studio from this
// VM's xenstore vm-name; unset in a plain `next build`, so config stays default.
const assetPrefix = process.env.DEVSHOT_ASSET_PREFIX || undefined;

/** @type {import('next').NextConfig} */
const nextConfig = assetPrefix
  ? { assetPrefix, images: { path: `${assetPrefix}/_next/image` } }
  : {};

export default nextConfig;
NEXTCONFIG

# Pre-install the libraries a "make it beautiful" build almost always reaches for
# so the agent NEVER has to `npm install` them at runtime (a freshly-installed dep
# isn't hot-resolved by Turbopack, and weaker models import without installing it
# → "Module not found" white screens). NO `|| true`: these are a hard requirement
# (the agent system prompt promises they are pre-installed), network is available
# at bake time, and a half-installed tree must never publish — `set -eux` aborts
# the bake on failure.
npm install --save lucide-react framer-motion clsx tailwind-merge class-variance-authority

# --- shadcn/ui base + design catalog (spec 386) ---------------------------
# The catalog's blocks import `@/components/ui/button`, `cn()` from lib/utils and
# the shadcn theme tokens, so the template becomes a shadcn/ui project here:
# Radix base, "nova" preset, Tailwind v4 — non-interactive (`-y -b radix -p nova`
# is the exact flag set the CLI accepts without a prompt; measured 2026-09-07).
# `motion` is what every catalog source imports (`motion/react`); framer-motion
# stays because the agent prompt has promised it since spec 358.
npx --yes shadcn@latest init -y -b radix -p nova
npm install --save motion
# Fetch, namespace, dependency-close and TYPE-CHECK the catalog inside this very
# project. Fails the bake when a source's license stops reading MIT, when an
# index changes shape, or when fewer than 300 items survive the tsc gate — a
# thin or wrong catalog must never publish silently.
node /tmp/devshot-build-design-catalog.mjs --project /var/www/studio --out /opt/devshot-design --min-items 300
test -f /opt/devshot-design/catalog.json || { echo "FATAL: design catalog missing after build" >&2; exit 1; }

# Warm .next so the first request after boot compiles fast; dev still recompiles.
# Best-effort (|| true): a build miss is a COMPILE concern, not a dependency one
# (dev recompiles on demand), so it must not gate the dep-completeness check below.
npm run build || true

# --- Validate complete deps so the runtime install branch is DEAD (spec 090) ---
# start-studio runs a BLOCKING `npm install` at boot iff node_modules/.bin/next is
# absent — a 30-120s cold-boot tax. Baking node_modules is what makes that branch
# unreachable; assert it HERE so an incomplete bake fails LOUD at build time
# instead of silently shipping a template that reinstalls on every boot. Same
# checks start-studio (.bin/next) and spec 082's restore (`npm ls`) gate on, so
# "satisfied" means the same thing everywhere. Runs as devshot (this script's
# user) — the perms the dev server sees.
test -x node_modules/.bin/next || { echo "FATAL: node_modules/.bin/next missing after bake — template would reinstall on every boot" >&2; exit 1; }
npm ls --depth=0 >/dev/null 2>&1 || { echo "FATAL: npm ls reports unsatisfied deps after bake:" >&2; npm ls --depth=0 >&2; exit 1; }
echo "Studio template deps validated: node_modules/.bin/next present, npm ls clean"
BUILDSTUDIO
chmod +x /tmp/devshot-build-studio.sh
su devshot -c /tmp/devshot-build-studio.sh
rm -f /tmp/devshot-build-studio.sh

# --- devshot-design CLI (spec 386) -----------------------------------------
# The agent's hands on the catalog: list / show / code / add. Source of truth is
# apps/agent/recipes/design-catalog/devshot-design.cjs, embedded verbatim (same
# test as the builder). `add` is a local `shadcn add` through the project's own
# node_modules/.bin/shadcn, so it works offline and needs no restart.
# >>> design-catalog: devshot-design.cjs (verbatim copy — do not edit here)
cat > /usr/local/bin/devshot-design <<'DEVSHOT_DESIGN_CLI_EOF'
#!/usr/bin/env node
// devshot-design — spec 386. The agent's hands on the design catalog that
// build-design-catalog.mjs baked into /opt/devshot-design.
//
//   devshot-design list [query…]      search blocks and components (or a summary)
//   devshot-design show <id>          what it is, what it exports, what it writes
//   devshot-design code <id>          print the main file (read before adapting)
//   devshot-design add <id…>          copy into the project, print the import line
//
// 'add' is a local 'shadcn add': the registry item, its dependencies and the
// shadcn primitives it needs are all files under the catalog, every npm
// package they import is already in node_modules, so it works with the
// network gone and needs no dev-server restart — 'next dev' picks new files
// up on its own. CommonJS on purpose: it must run under Alpine's node with no
// package.json of its own. No backticks and no dollar-brace interpolation in
// this file: studio.sh installs it through a quoted heredoc.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const CATALOG_DIR = process.env.DEVSHOT_DESIGN_DIR || '/opt/devshot-design';
const DEFAULT_PROJECT = process.env.DEVSHOT_PROJECT_DIR || '/var/www/studio';
const LICENSE_NOTE = 'THIRD_PARTY_LICENSES.md';

function fail(msg, code) {
  process.stderr.write('devshot-design: ' + msg + '\n');
  process.exit(code || 1);
}

function usage() {
  process.stderr.write([
    'usage: devshot-design list [query…] | show <id> | code <id> | add <id…> [--cwd <project>]',
    '  list   search the catalog by category, name or words in the description; no query prints a summary',
    '  show   details for one item: exports, files it will create, npm packages, license',
    '  code   print the item\'s main source file',
    '  add    install one or more items into the project (default ' + DEFAULT_PROJECT + ') and print the import lines',
  ].join('\n') + '\n');
  process.exit(2);
}

function loadCatalog() {
  const file = path.join(CATALOG_DIR, 'catalog.json');
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { fail('no catalog at ' + file + ' (' + err.message + ')', 3); }
  if (!data || !Array.isArray(data.items)) fail('catalog.json is malformed', 3);
  return data;
}

function visible(catalog) {
  return catalog.items.filter((it) => it.kind !== 'support');
}

function findItem(catalog, ref) {
  const want = String(ref || '').trim().toLowerCase();
  if (!want) return null;
  const exact = catalog.items.find((it) => it.id.toLowerCase() === want);
  if (exact) return exact;
  const byName = catalog.items.filter((it) => it.name.toLowerCase() === want && it.kind !== 'support');
  if (byName.length === 1) return byName[0];
  if (byName.length > 1) fail('"' + ref + '" is ambiguous: ' + byName.map((it) => it.id).join(', ') + ' — use the full id', 2);
  return null;
}

function resolveProject(argv) {
  const i = argv.indexOf('--cwd');
  let dir = i !== -1 ? argv[i + 1] : null;
  if (i !== -1) argv.splice(i, 2);
  if (!dir) dir = fs.existsSync(path.join(process.cwd(), 'package.json')) ? process.cwd() : DEFAULT_PROJECT;
  dir = path.resolve(dir);
  if (!fs.existsSync(path.join(dir, 'package.json'))) fail('no package.json in ' + dir + ' — pass --cwd <project>', 2);
  if (!fs.existsSync(path.join(dir, 'components.json'))) fail(dir + ' has no components.json (not a shadcn project)', 2);
  return dir;
}

function pad(s, n) { s = String(s == null ? '' : s); return s.length >= n ? s : s + ' '.repeat(n - s.length); }

function cmdList(catalog, words) {
  const items = visible(catalog);
  if (!words.length) {
    const groups = new Map();
    for (const it of items) {
      const key = it.kind + '/' + it.category;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(it);
    }
    process.stdout.write(items.length + ' items in ' + CATALOG_DIR + ' (all MIT). Categories:\n');
    for (const key of [...groups.keys()].sort()) {
      const g = groups.get(key);
      process.stdout.write('  ' + pad(key, 28) + pad(g.length, 5) + 'e.g. ' + g.slice(0, 3).map((it) => it.id).join(', ') + '\n');
    }
    process.stdout.write('\nSearch: devshot-design list <category or words>   e.g. "devshot-design list hero", "devshot-design list pricing dark"\n');
    process.stdout.write('Each hit prints its structure (headings, buttons, images, repeated lists, motion, length), so one listing is enough to shortlist.\n');
    return;
  }
  const terms = words.map((w) => w.toLowerCase());
  const scored = [];
  for (const it of items) {
    const hay = [it.id, it.title, it.description, it.category, it.source, it.kind].join(' ').toLowerCase();
    let score = 0;
    for (const t of terms) {
      if (it.category === t) score += 5;
      else if (it.id.toLowerCase().includes(t)) score += 3;
      else if (hay.includes(t)) score += 1;
      else { score = 0; break; }
    }
    if (score > 0) scored.push([score, it]);
  }
  scored.sort((a, b) => b[0] - a[0] || a[1].id.localeCompare(b[1].id));
  if (!scored.length) { process.stdout.write('no items match "' + words.join(' ') + '"; try a category from "devshot-design list"\n'); return; }
  const shown = scored.slice(0, 60);
  // Spec 390 — the shape column is what makes one listing enough to choose from:
  // 2h+3p, 2btn, 1img, 4map, motion, 118L says more about whether a section fits
  // than its marketing sentence does. Titles are truncated before it is dropped.
  for (const [, it] of shown) {
    const desc = (it.description || it.title || '').replace(/\s+/g, ' ').slice(0, 44);
    process.stdout.write(pad(it.id, 40) + pad(it.category, 12) + pad(String(it.shape || '').slice(0, 30), 32) + desc + '\n');
  }
  if (scored.length > shown.length) process.stdout.write('… ' + (scored.length - shown.length) + ' more; narrow the query\n');
  process.stdout.write('\nShape: h=headings p=paragraphs btn=buttons img=images map=repeated lists L=lines.\n');
  process.stdout.write('Next: devshot-design code <id> to read one, then devshot-design add <id>.\n');
}

function importLine(it) {
  if (!it.main) return null;
  const mod = '@/' + it.main.replace(/\.(tsx|ts|jsx|js)$/, '').replace(/\/index$/, '');
  const def = (it.exports || []).find((e) => e.indexOf('default:') === 0);
  const named = (it.exports || []).filter((e) => e.indexOf('default:') !== 0);
  if (def) return 'import ' + def.slice(8) + ' from \'' + mod + '\';';
  if (named.length) return 'import { ' + named.slice(0, 4).join(', ') + ' } from \'' + mod + '\';';
  return 'import … from \'' + mod + '\';';
}

function cmdShow(catalog, ref) {
  const it = findItem(catalog, ref);
  if (!it) fail('unknown item "' + ref + '" — search with devshot-design list <words>', 2);
  const src = (catalog.sources || []).find((s) => s.id === it.source) || {};
  const lines = [
    it.id + ' — ' + (it.title || it.name),
    it.description ? '  ' + it.description : null,
    '  kind: ' + it.kind + '   category: ' + it.category + '   source: ' + (src.title || it.source) + ' (' + (src.license || '?') + ')',
    '  files it writes into the project:',
  ].filter(Boolean);
  for (const f of it.files) lines.push('    ' + f + (f === it.main ? '   ← main' : ''));
  const deps = (it.registryDependencies || []).filter((d) => d.indexOf('shadcn/') !== 0);
  const prims = (it.registryDependencies || []).filter((d) => d.indexOf('shadcn/') === 0).map((d) => d.slice(7));
  if (deps.length) lines.push('  also installs: ' + deps.join(', '));
  if (prims.length) lines.push('  shadcn primitives: ' + prims.join(', '));
  if ((it.dependencies || []).length) lines.push('  npm packages (already installed): ' + it.dependencies.join(', '));
  if ((it.exports || []).length) lines.push('  exports: ' + it.exports.map((e) => e.replace(/^default:/, 'default ')).join(', '));
  const imp = importLine(it);
  if (imp) lines.push('  after add: ' + imp);
  lines.push('  read the source first: devshot-design code ' + it.id);
  process.stdout.write(lines.join('\n') + '\n');
}

function readRegistryItem(it) {
  const file = path.join(CATALOG_DIR, it.registryFile);
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { fail('cannot read ' + file + ': ' + err.message, 3); }
  return null;
}

function cmdCode(catalog, ref) {
  const it = findItem(catalog, ref);
  if (!it) fail('unknown item "' + ref + '"', 2);
  const reg = readRegistryItem(it);
  const main = (reg.files || []).find((f) => f.target === it.main) || (reg.files || [])[0];
  if (!main) fail(it.id + ' has no source file', 3);
  process.stdout.write('// ' + main.target + '\n' + main.content + (main.content.endsWith('\n') ? '' : '\n'));
}

function appendLicenseNote(project, catalog, items) {
  const sourcesUsed = new Set(items.map((it) => it.source));
  for (const it of items) for (const d of it.registryDependencies || []) sourcesUsed.add(String(d).split('/')[0]);
  const file = path.join(project, LICENSE_NOTE);
  let existing = '';
  try { existing = fs.readFileSync(file, 'utf8'); } catch (err) { existing = ''; }
  let text = existing || '# Third-party UI components\n\nThis project includes UI components from the following MIT-licensed libraries. Each notice below is the upstream license.\n';
  let changed = !existing;
  for (const sid of [...sourcesUsed].sort()) {
    const src = (catalog.sources || []).find((s) => s.id === sid);
    if (!src) continue;
    const marker = '## ' + src.title;
    if (text.indexOf(marker) !== -1) continue;
    let body = '';
    try { body = fs.readFileSync(path.join(CATALOG_DIR, src.licenseFile), 'utf8').replace(/^# .*\n/, '').trim(); } catch (err) { body = src.license + ' — ' + src.homepage; }
    text += '\n' + marker + '\n\n' + body + '\n';
    changed = true;
  }
  if (changed) fs.writeFileSync(file, text);
  return changed;
}

function cmdAdd(catalog, argv) {
  const project = resolveProject(argv);
  if (!argv.length) usage();
  const items = argv.map((ref) => {
    const it = findItem(catalog, ref);
    if (!it) fail('unknown item "' + ref + '" — search with devshot-design list <words>', 2);
    return it;
  });
  const shadcn = path.join(project, 'node_modules', '.bin', 'shadcn');
  if (!fs.existsSync(shadcn)) fail('shadcn CLI missing at ' + shadcn + ' — this project was not baked with the design catalog', 3);
  const paths = items.map((it) => path.join(CATALOG_DIR, it.registryFile));
  const before = new Set();
  for (const it of items) for (const f of it.files) if (fs.existsSync(path.join(project, f))) before.add(f);
  const r = spawnSync(shadcn, ['add', '-y', '-o', '-s', '-c', project].concat(paths), { cwd: project, encoding: 'utf8', env: Object.assign({}, process.env, { CI: '1', HOME: process.env.HOME || '/tmp' }) });
  if (r.status !== 0) {
    process.stderr.write((r.stdout || '') + (r.stderr || ''));
    fail('shadcn add failed (exit ' + r.status + ')', 1);
  }
  const missing = [];
  for (const it of items) for (const f of it.files) if (!fs.existsSync(path.join(project, f))) missing.push(f);
  if (missing.length) fail('shadcn add returned 0 but these files are missing: ' + missing.join(', '), 1);
  const noted = appendLicenseNote(project, catalog, items);
  const out = [];
  for (const it of items) {
    out.push('added ' + it.id + ':');
    for (const f of it.files) out.push('  ' + (before.has(f) ? 'updated ' : 'created ') + f);
    const imp = importLine(it);
    if (imp) out.push('  ' + imp);
  }
  if (noted) out.push('license notices recorded in ' + LICENSE_NOTE);
  out.push('Now adapt it: replace every demo headline, paragraph, logo, image and price with this project\'s real content and brand — a block is a starting point, not the deliverable. New files hot-reload; no dev-server restart is needed.');
  process.stdout.write(out.join('\n') + '\n');
}

function main() {
  const argv = process.argv.slice(2);
  if (!argv.length || argv[0] === '-h' || argv[0] === '--help') usage();
  const cmd = argv.shift();
  const catalog = loadCatalog();
  if (cmd === 'list' || cmd === 'search' || cmd === 'ls') return cmdList(catalog, argv);
  if (cmd === 'show' || cmd === 'info') { if (argv.length !== 1) usage(); return cmdShow(catalog, argv[0]); }
  if (cmd === 'code' || cmd === 'cat') { if (argv.length !== 1) usage(); return cmdCode(catalog, argv[0]); }
  if (cmd === 'add' || cmd === 'install') return cmdAdd(catalog, argv);
  usage();
}

if (require.main === module) main();

module.exports = { findItem, importLine, visible, appendLicenseNote, LICENSE_NOTE };
DEVSHOT_DESIGN_CLI_EOF
# <<< design-catalog: devshot-design.cjs
chmod 0755 /usr/local/bin/devshot-design
# Smoke-test the baked catalog exactly the way a turn will use it, as devshot.
su devshot -c 'cd /var/www/studio && devshot-design list >/dev/null && devshot-design list hero | head -n 3' \
  || { echo "FATAL: devshot-design cannot read the baked catalog" >&2; exit 1; }
cd /var/www/studio

cat > /usr/local/bin/start-studio <<'LAUNCHER'
#!/bin/sh
# Start the Next.js dev server (hot reload). -d runs detached and returns.
# A sane PATH so this works under supervise-daemon's minimal environment too.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
detached=0
[ "${1-}" = "-d" ] && detached=1
cd /var/www/studio
LOG="${LOG:-/tmp/studio-dev.log}"
PORT="${PORT:-3000}"

# Boot-phase timing (spec 089). /proc/uptime is seconds since KERNEL boot, so
# these markers also expose how long OpenRC took to reach this service — the gap
# the console's claim→ready timing can't see from outside the VM. They append to
# $LOG, which the boot screen tails and the console boot-probe harvests, so a
# slow stage (xenstore settle, a cold `npm install`, dev-server launch) shows up
# as a real timestamp instead of the boot screen's synthetic ones.
boot_ts() { awk '{printf "%.1f", $1}' /proc/uptime 2>/dev/null || printf '?'; }
boot_phase() { echo "[boot +$(boot_ts)s] $*" >> "$LOG"; }
boot_phase "start-studio: launching (port $PORT)"

# Derive the public-proxy asset prefix from this VM's name so Next.js emits its
# runtime /_next/... chunk/font/CSS URLs under /api/public/p/<vm>/<PORT>/...
# instead of the iframe-origin root (which 404s behind the path proxy). The VM
# name lives in xenstore: real xenstored under Xen, the 9p FileXenstore file
# tree (mounted at $XS_ROOT by start-agent.sh) under QEMU. Both are root-owned
# 0600 (the 9p files carry the orchestrator's uid), and this launcher runs as
# the unprivileged `devshot` user — so read through the sandbox's passwordless
# sudo rather than fail the perms check.
read_xs_value() {
    if [ -e /proc/xen/xenbus ]; then
        # Relative "domid" read works where the absolute self alias returns
        # ENOENT (cxenstored). See docker/start-agent.sh for the full why.
        _domid="$(sudo -n xenstore-read domid 2>/dev/null \
            || xenstore-read domid 2>/dev/null \
            || sudo -n xenstore-read /local/domain/self/domid 2>/dev/null \
            || xenstore-read /local/domain/self/domid 2>/dev/null || echo 0)"
        sudo -n xenstore-read "/local/domain/${_domid}/data/$1" 2>/dev/null \
            || xenstore-read "/local/domain/${_domid}/data/$1" 2>/dev/null || true
    else
        _xf="${XS_ROOT:-/tmp/xenstore}/local__domain__1__data__$1"
        sudo -n cat "$_xf" 2>/dev/null || cat "$_xf" 2>/dev/null || true
    fi
}
# The 9p share / xenstored may settle just after this service starts, so poll
# briefly; fall back to no prefix (degraded, not hung) rather than block boot.
VM_NAME=""
i=0
while [ "$i" -lt 15 ]; do
    VM_NAME="$(read_xs_value vm-name)"
    [ -n "$VM_NAME" ] && break
    i=$((i + 1))
    sleep 1
done
if [ -n "$VM_NAME" ]; then
    export DEVSHOT_ASSET_PREFIX="/api/public/p/${VM_NAME}/${PORT}"
    echo "Studio asset prefix: $DEVSHOT_ASSET_PREFIX"
    # Spec 240 — a per-VM value that lives only in one process is lost on the
    # first restart. The export above reaches the dev server this script execs,
    # and nothing else: the agent restarting `npm run dev` while fixing
    # something, a crash restart, a workspace reset — all of those come up with
    # assetPrefix undefined and every /_next chunk 500s behind the proxy. The
    # session cannot recompute it (sudo is removed at claim time and the
    # xenstore node is root-only 0600), so write it where Next itself reads it
    # on EVERY start. .env.local is loaded before next.config.mjs is evaluated.
    # Console rewrites this file per turn as well, which is what corrects a
    # workspace restored from a different VM.
    if [ -d /var/www/studio ]; then
        _envf=/var/www/studio/.env.local
        _want="DEVSHOT_ASSET_PREFIX=${DEVSHOT_ASSET_PREFIX}"
        if ! grep -qxF "$_want" "$_envf" 2>/dev/null; then
            { grep -v '^DEVSHOT_ASSET_PREFIX=' "$_envf" 2>/dev/null || true; echo "$_want"; } > "$_envf.devshot-tmp" \
                && mv "$_envf.devshot-tmp" "$_envf" \
                && chown devshot:devshot "$_envf" 2>/dev/null || true
        fi
    fi
else
    echo "WARN: vm-name not found in xenstore — assets may 404 behind the proxy" >&2
fi
boot_phase "xenstore vm-name resolved after ${i}s: ${VM_NAME:-<none>}"

# Dependency preflight — a last-resort RUNTIME net, NOT a boot-path expectation.
# The bake guarantees a complete node_modules (spec 090 fails the build if
# node_modules/.bin/next is missing or `npm ls` is unsatisfied), so on a
# correctly-baked template this branch is DEAD at boot. It survives only for a
# LIVE VM that loses node_modules mid-session — a `git clean -fxd`, a
# connect-a-repo project switch — where `next dev` genuinely cannot serve and,
# without this, the supervisor would respawn "sh: next: not found" every 3s
# forever (respawn_max=0) and hang the preview. Install when the dev binary is
# missing — npm ci with a lockfile (fast, deterministic), else npm install.
# Output streams to $LOG and is announced via boot_phase (spec 089) so a cold
# install is loudly visible, never a silent stall.
if [ ! -x node_modules/.bin/next ]; then
    boot_phase "deps MISSING (node_modules/.bin/next absent) — npm install starting (cold boot will be slow)"
    echo "Studio deps missing (node_modules/.bin/next absent) — installing before dev server…"
    if [ -f package-lock.json ]; then
        npm ci --prefer-offline --no-audit --no-fund 2>&1 | tee -a "$LOG" \
            || npm install --prefer-offline --no-audit --no-fund 2>&1 | tee -a "$LOG"
    else
        npm install --prefer-offline --no-audit --no-fund 2>&1 | tee -a "$LOG"
    fi
    boot_phase "npm install finished"
else
    boot_phase "deps present — skipping install"
fi

# Bind 0.0.0.0 so the console public proxy can reach it; pass through the
# project's dev script (Turbopack/webpack) with host+port.
boot_phase "launching next dev on :$PORT (first compile follows)"
if [ "$detached" = "1" ]; then
    nohup npm run dev -- -H 0.0.0.0 -p "$PORT" > "$LOG" 2>&1 &
    echo "Studio dev server started — log: $LOG (listening on :$PORT)"
else
    exec npm run dev -- -H 0.0.0.0 -p "$PORT"
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-studio

cat > /etc/init.d/devshot-studio <<'INITD'
#!/sbin/openrc-run

name="devshot-studio"
description="DevShot Studio app (next dev, hot reload on :3000)"

# Supervised (not a hand-rolled `nohup … &`): supervise-daemon keeps the dev
# server alive and AUTO-RESTARTS it on crash. The public readiness probe hits
# :3000 — an unsupervised server that died at boot would otherwise leave the
# visitor stuck on "booting" forever with no recovery. `rc-service
# devshot-studio status` then reports the real state, which the boot screen
# surfaces. Runs in the foreground (start-studio without -d) so the supervisor
# tracks the actual process; stdout/stderr go to the log the boot screen tails.
supervisor=supervise-daemon
command="/usr/local/bin/start-studio"
command_user="devshot:devshot"
pidfile="/run/devshot-studio.pid"
output_log="/tmp/studio-dev.log"
error_log="/tmp/studio-dev.log"
respawn_delay=3
respawn_max=0

depend() {
    need net
    after networking firewall
}
INITD
chmod +x /etc/init.d/devshot-studio
rc-update add devshot-studio default

# --- devshot-perms: webroot writable to devshot ON EVERY BOOT (spec 110) ----
# The dev server, editor, and the agent's vm-exec all run as devshot. If any
# project file drifts to another owner — a root-context step, a churned-VM
# restore — devshot can't write .next/node_modules and the dev server fails. This
# boots BEFORE the dev server + editor and re-asserts devshot ownership + write
# bits at the OS level, so it needs neither a console deploy nor an agent turn.
# Drift-targeted (find ! -user) so a clean tree is a stat-walk, not a rewrite;
# -xdev so it never crosses into another mount. (Restore-time drift is handled
# separately in the restore command itself — this covers boot/bake drift.)
cat > /etc/init.d/devshot-perms <<'PERMS'
#!/sbin/openrc-run
name="devshot-perms"
description="Make /var/www owned by and writable to devshot before the app starts"
depend() {
    after localmount
    before devshot-studio openvscode-server
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

# --- openvscode-server (in-browser editor on :8080) ------------------
# Same Gitpod fork + system-Node approach the LAMP recipe uses (see
# recipes/lamp/_core.sh for the gcompat rationale). Opened to the studio
# project so claim → editor lands on the app files.
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

# Editor profile: Dark Modern, no welcome, trust off (it's a throwaway VM).
# Written AS devshot (it's devshot's home) so the editor's user-data dir is
# devshot-owned and openvscode (which runs as devshot) can write runtime state
# into it — no chown needed.
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

# The editor opens the studio project; the agent and editor share these files.
echo /var/www/studio > /etc/openvscode-default-folder
# No chown: the project tree (built above) and the editor's user-data dir are
# already devshot-owned, and vm-exec runs as devshot at runtime (see
# handleVMExec) — so devshot (editor + agent) owns everything it touches.
install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser (openvscode-server) — DevShot Studio editor"
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder 2>/dev/null || echo /var/www/studio)"
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
# npm/npx ran as devshot, so the package cache is under devshot's home now.
rm -rf /home/devshot/.npm /home/devshot/.cache /home/devshot/.tmp/* /root/.npm /tmp/* /var/cache/apk/*

echo "=== Studio recipe complete ==="
node --version
npm --version
du -sh /var/www/studio
sync
