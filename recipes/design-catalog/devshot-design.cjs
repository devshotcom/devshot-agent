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
  for (const [, it] of shown) {
    const desc = (it.description || '').replace(/\s+/g, ' ').slice(0, 90);
    process.stdout.write(pad(it.id, 42) + pad(it.category, 13) + (it.title || '') + (desc ? ' — ' + desc : '') + '\n');
  }
  if (scored.length > shown.length) process.stdout.write('… ' + (scored.length - shown.length) + ' more; narrow the query\n');
  process.stdout.write('\nNext: devshot-design show <id>, then devshot-design add <id>\n');
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
