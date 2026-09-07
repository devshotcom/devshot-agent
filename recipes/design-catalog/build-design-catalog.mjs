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
