#!/usr/bin/env node
// devshot-design — spec 386. The agent's hands on the design catalog that
// build-design-catalog.mjs baked into /opt/devshot-design.
//
//   devshot-design list [query…]      search blocks and components (or a summary)
//   devshot-design show <id>          what it is, what it exports, what it writes
//   devshot-design code <id>          print the main file (read before adapting)
//   devshot-design add <id…>          copy into the project, print the import line
//   devshot-design fonts list/show/add  inspect and install locally baked fonts
//
// 'add' copies the registry item, its dependencies and the
// shadcn primitives it needs are all files under the catalog, every npm
// package they import is already in node_modules, so it works with the
// network gone and needs no dev-server restart — 'next dev' picks new files
// up on its own. CommonJS on purpose: it must run under Alpine's node with no
// package.json of its own. No backticks and no dollar-brace interpolation in
// this file: studio.sh installs it through a quoted heredoc.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { installRegistryItems } = require('./install-design-items.cjs');
const { loadFonts, installFonts } = require('./design-fonts.cjs');

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
    '  fonts list [query] | show <id> | add <id…> [--cwd <project>] — local SIL OFL font assets, no network requests',
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

function unavailableMessage(catalog, ref) {
  const wanted = String(ref).toLowerCase();
  const dropped = (catalog.dropped || []).find((it) => it.id.toLowerCase() === wanted || it.id.split('/').slice(1).join('/').toLowerCase() === wanted);
  const id = dropped ? dropped.id : wanted;
  const source = id.split('/')[0];
  if (!dropped && !((catalog.sources || []).some((it) => it.id === source) && id.includes('/'))) return 'unknown item "' + ref + '" — search with devshot-design list <words>';
  const name = id.slice(source.length + 1);
  const kit = /^(mist|dusk|veil)-/.exec(name);
  const category = name.replace(/^(mist|dusk|veil)-/, '').replace(/-\d+$/, '').replace(/-section$/, '');
  const choices = visible(catalog).filter((it) => it.source === source && (!kit || it.name.startsWith(kit[0])) && (it.category === category || it.name.includes(category))).slice(0, 6);
  const reason = dropped ? dropped.reason : 'not present in this baked catalog; no exclusion reason was recorded';
  return 'unavailable item "' + id + '": ' + reason + (choices.length ? '\nAvailable in the same source' + (kit ? ' and ' + kit[1] + ' kit' : '') + ': ' + choices.map((it) => it.id).join(', ') + '. Inspect one with devshot-design code; no item is substituted automatically.' : '\nNo matching item in the same kit is available in this baked catalog.');
}

function resolveProject(argv, requireShadcn = true) {
  const i = argv.indexOf('--cwd');
  let dir = i !== -1 ? argv[i + 1] : null;
  if (i !== -1) argv.splice(i, 2);
  if (!dir) dir = fs.existsSync(path.join(process.cwd(), 'package.json')) ? process.cwd() : DEFAULT_PROJECT;
  dir = path.resolve(dir);
  if (!fs.existsSync(path.join(dir, 'package.json'))) fail('no package.json in ' + dir + ' — pass --cwd <project>', 2);
  if (requireShadcn && !fs.existsSync(path.join(dir, 'components.json'))) fail(dir + ' has no components.json (not a shadcn project)', 2);
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
    process.stdout.write('Local fonts: devshot-design fonts list; devshot-design fonts add <id>. Missing block ids are explained by devshot-design show <id>.\n');
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
  if (!it) fail(unavailableMessage(catalog, ref), 2);
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
  if (!it) fail(unavailableMessage(catalog, ref), 2);
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
    if (!it) fail(unavailableMessage(catalog, ref), 2);
    return it;
  });
  const paths = items.map((it) => path.join(CATALOG_DIR, it.registryFile));
  const before = new Set();
  for (const it of items) for (const f of it.files) if (fs.existsSync(path.join(project, f))) before.add(f);
  let installed;
  try { installed = installRegistryItems({ catalogDir: CATALOG_DIR, project, registryFiles: paths }); }
  catch (err) { fail(err.message, 3); }
  const missing = [];
  for (const it of items) for (const f of it.files) if (!fs.existsSync(path.join(project, f))) missing.push(f);
  if (missing.length) fail('local installation completed but these files are missing: ' + missing.join(', '), 1);
  const closure = installed.records.map((record) => catalog.items.find((it) => it.id === record.id) || { source: record.id.split('/')[0] });
  const noted = appendLicenseNote(project, catalog, closure);
  const out = [];
  for (const it of items) {
    out.push('added ' + it.id + ':');
    for (const f of it.files) out.push('  ' + (before.has(f) ? 'updated ' : 'created ') + f);
    const imp = importLine(it);
    if (imp) out.push('  ' + imp);
  }
  out.push('installed ' + installed.records.length + ' local registry items including dependencies; no shadcn, npm or network access was used.');
  if (noted) out.push('license notices recorded in ' + LICENSE_NOTE);
  out.push('Now adapt it: replace every demo headline, paragraph, logo, image and price with this project\'s real content and brand — a block is a starting point, not the deliverable. New files hot-reload; no dev-server restart is needed.');
  process.stdout.write(out.join('\n') + '\n');
}

function cmdFonts(argv) {
  const cmd = argv.shift();
  let catalog;
  try { catalog = loadFonts(CATALOG_DIR); } catch (err) { fail('local font catalog unavailable: ' + err.message, 3); }
  if (cmd === 'list') {
    const query = argv.join(' ').toLowerCase();
    for (const font of catalog.items.filter((it) => [it.id, it.family, it.category].join(' ').toLowerCase().includes(query))) {
      process.stdout.write(pad(font.id, 20) + pad(font.family, 20) + font.weight + ' · ' + font.style + ' · ' + Math.round(font.bytes / 1024) + ' KiB · ' + font.license + '\n');
    }
    process.stdout.write('Next: devshot-design fonts show <id> or fonts add <id…>. Assets and licenses are baked locally.\n');
    return;
  }
  if (cmd !== 'show' && cmd !== 'add') usage();
  const project = cmd === 'add' ? resolveProject(argv, false) : null;
  if (!argv.length || (cmd === 'show' && argv.length !== 1)) usage();
  const fonts = argv.map((ref) => {
    const font = catalog.items.find((it) => it.id === ref || it.family.toLowerCase() === ref.toLowerCase());
    if (!font) fail('unknown font "' + ref + '" — run devshot-design fonts list', 2);
    return font;
  });
  if (cmd === 'show') {
    const font = fonts[0];
    process.stdout.write(font.family + ' (' + font.id + ')\n  weight: ' + font.weight + '   style: ' + font.style + '\n  asset: ' + font.file + ' (' + font.bytes + ' bytes)\n  license: ' + font.license + ' — ' + font.licenseFile + '\n  source: ' + font.url + '\n  SHA-256: ' + font.sha256 + '\n  install: devshot-design fonts add ' + font.id + '\n');
    return;
  }
  let files;
  try { files = installFonts({ catalogDir: CATALOG_DIR, project, fonts }); } catch (err) { fail(err.message, 3); }
  process.stdout.write('added local fonts: ' + fonts.map((it) => it.family).join(', ') + '\n' + files.map((file) => '  ' + file).join('\n') + '\nLoad the stylesheet in the document head: <link rel="stylesheet" href="/fonts/devshot-fonts.css" />\nUse font-family: ' + fonts.map((it) => '"' + it.family + '"').join(' or ') + '; and font-optical-sizing: auto. These files also work with next/font/local; do not import next/font/google.\n');
}

function main() {
  const argv = process.argv.slice(2);
  if (!argv.length || argv[0] === '-h' || argv[0] === '--help') usage();
  const cmd = argv.shift();
  if (cmd === 'fonts') return cmdFonts(argv);
  const catalog = loadCatalog();
  if (cmd === 'list' || cmd === 'search' || cmd === 'ls') return cmdList(catalog, argv);
  if (cmd === 'show' || cmd === 'info') { if (argv.length !== 1) usage(); return cmdShow(catalog, argv[0]); }
  if (cmd === 'code' || cmd === 'cat') { if (argv.length !== 1) usage(); return cmdCode(catalog, argv[0]); }
  if (cmd === 'add' || cmd === 'install') return cmdAdd(catalog, argv);
  usage();
}

if (require.main === module) main();

module.exports = { findItem, importLine, visible, unavailableMessage, appendLicenseNote, LICENSE_NOTE };
