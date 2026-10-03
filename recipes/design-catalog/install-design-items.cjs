// Shared by the template type-check gate and devshot-design add. Registry
// payloads are already normalized at bake time; installing them is local IO.
// Never invoke shadcn/npm here: shadcn consults its remote colors registry even
// for a local item, which is unavailable inside a network-locked Studio VM.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function contained(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative));
}

function localPath(root, relative) {
  if (typeof relative !== 'string' || !relative || path.isAbsolute(relative) || relative.includes('\\') || relative.split('/').includes('..')) {
    throw new Error('unsafe local target: ' + relative);
  }
  const rootPath = fs.realpathSync(root);
  const target = path.resolve(rootPath, relative);
  if (!contained(rootPath, target)) throw new Error('target escapes project: ' + relative);
  let existing = target;
  while (!fs.existsSync(existing)) existing = path.dirname(existing);
  if (!contained(rootPath, fs.realpathSync(existing))) throw new Error('target symlink escapes project: ' + relative);
  return target;
}

function packageName(spec) {
  const match = String(spec).match(/^(@[^/\s]+\/[^@\s]+|[^@/\s]+)(?:@.*)?$/);
  if (!match) throw new Error('unsupported npm dependency: ' + spec);
  return match[1];
}

function kebab(key) { return key.replace(/[A-Z]/g, (letter) => '-' + letter.toLowerCase()); }

function cssObject(value, indent) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('registry CSS must be an object');
  const prefix = ' '.repeat(indent || 0);
  return Object.entries(value).map(([key, val]) => {
    if (val !== null && typeof val === 'object' && !Array.isArray(val)) return prefix + key + ' {\n' + cssObject(val, (indent || 0) + 2) + prefix + '}\n';
    if (key.startsWith('@') && val === '') return prefix + key + ';\n';
    if (Array.isArray(val) || val === null || typeof val === 'object') throw new Error('unsupported CSS value for ' + key);
    return prefix + kebab(key) + ': ' + String(val) + ';\n';
  }).join('');
}

const THEME_PREFIXES = {
  colors: 'color', fontFamily: 'font', fontSize: 'text', fontWeight: 'font-weight',
  lineHeight: 'leading', letterSpacing: 'tracking', borderRadius: 'radius',
  spacing: 'spacing', screens: 'breakpoint', boxShadow: 'shadow',
  animation: 'animate', backgroundImage: 'background-image', transitionTimingFunction: 'ease',
};

function themeDeclarations(group, value, names) {
  if (value && typeof value === 'object' && !Array.isArray(value)) return Object.entries(value).map(([key, val]) => themeDeclarations(group, val, names.concat(key === 'DEFAULT' ? [] : [key]))).join('');
  const rendered = Array.isArray(value) && group === 'fontFamily' ? value.join(', ') : value;
  if (typeof rendered !== 'string' && typeof rendered !== 'number') throw new Error('unsupported Tailwind value: ' + group + '.' + names.join('.'));
  return '  --' + THEME_PREFIXES[group] + '-' + names.join('-') + ': ' + rendered + ';\n';
}

function registryStyles(registry) {
  let css = '';
  for (const [mode, vars] of Object.entries(registry.cssVars || {})) {
    const selectors = { theme: '@theme inline', light: ':root', dark: '.dark' };
    if (!selectors[mode]) throw new Error('unsupported cssVars mode: ' + mode);
    const declarations = Object.fromEntries(Object.entries(vars).map(([key, val]) => [key.startsWith('--') ? key : '--' + key, val]));
    css += selectors[mode] + ' {\n' + cssObject(declarations, 2) + '}\n';
  }
  if (registry.css) css += cssObject(registry.css, 0);
  const config = registry.tailwind && registry.tailwind.config;
  if (config) {
    const unsupported = Object.keys(config).filter((key) => key !== 'theme');
    const extraTheme = Object.keys(config.theme || {}).filter((key) => key !== 'extend');
    if (unsupported.length || extraTheme.length) throw new Error('unsupported Tailwind v3 configuration: ' + unsupported.concat(extraTheme).join(', '));
    let theme = '';
    for (const [group, value] of Object.entries((config.theme || {}).extend || {})) {
      if (group === 'keyframes') {
        for (const [name, frames] of Object.entries(value)) css += '@keyframes ' + name + ' {\n' + cssObject(frames, 2) + '}\n';
      } else if (THEME_PREFIXES[group]) theme += themeDeclarations(group, value, []);
      else throw new Error('unsupported Tailwind v3 theme group: ' + group);
    }
    if (theme) css += '@theme inline {\n' + theme + '}\n';
  }
  return css;
}

function writeLocal(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.devshot-' + crypto.randomUUID();
  const descriptor = fs.openSync(tmp, 'wx', 0o644);
  try { fs.writeFileSync(descriptor, content); fs.renameSync(tmp, file); }
  finally { fs.closeSync(descriptor); if (fs.existsSync(tmp)) fs.unlinkSync(tmp); }
}

function installRegistryItems({ catalogDir, project, registryFiles, checkPackages = true }) {
  const root = fs.realpathSync(catalogDir);
  const records = new Map();
  const visiting = new Set();
  function read(file) {
    const absolute = fs.realpathSync(path.resolve(root, file));
    if (!contained(root, absolute)) throw new Error('registry dependency is not local to the catalog: ' + file);
    if (records.has(absolute) || visiting.has(absolute)) return;
    visiting.add(absolute);
    const registry = JSON.parse(fs.readFileSync(absolute, 'utf8'));
    for (const dependency of registry.registryDependencies || []) {
      if (typeof dependency !== 'string' || /^https?:|^@/.test(dependency)) throw new Error('registry dependency is not a baked local path: ' + dependency);
      read(dependency);
    }
    visiting.delete(absolute);
    records.set(absolute, { registry, id: path.relative(path.join(root, 'r'), absolute).replace(/\\/g, '/').replace(/\.json$/, '') });
  }
  registryFiles.forEach(read);
  const writes = new Map();
  const packages = new Set();
  const styles = [];
  for (const { registry, id } of records.values()) {
    for (const dependency of (registry.dependencies || []).concat(registry.devDependencies || [])) packages.add(packageName(dependency));
    for (const file of registry.files || []) {
      if (typeof file.content !== 'string') throw new Error('missing baked source content: ' + id + '/' + file.target);
      const target = localPath(project, file.target);
      if (writes.has(target) && writes.get(target) !== file.content) throw new Error('conflicting registry sources for ' + file.target);
      writes.set(target, file.content);
    }
    const css = registryStyles(registry);
    if (css) styles.push({ id, css });
  }
  if (checkPackages) {
    const missing = [...packages].filter((name) => !fs.existsSync(path.join(project, 'node_modules', name, 'package.json')));
    if (missing.length) throw new Error('required npm packages are not installed: ' + missing.join(', ') + '. Restore the baked node_modules or install these packages explicitly, then retry; no project files were changed.');
  }
  if (styles.length) {
    const config = JSON.parse(fs.readFileSync(path.join(project, 'components.json'), 'utf8'));
    const cssFile = localPath(project, config.tailwind && config.tailwind.css);
    let content = fs.readFileSync(cssFile, 'utf8');
    for (const { id, css } of styles) {
      const start = '/* devshot-design:' + id + ':start */';
      const end = '/* devshot-design:' + id + ':end */';
      const block = start + '\n' + css + end + '\n';
      const begin = content.indexOf(start);
      const finish = content.indexOf(end, begin);
      if (begin !== -1 && finish === -1) throw new Error('incomplete CSS marker for ' + id);
      content = begin === -1 ? content + '\n' + block : content.slice(0, begin) + block + content.slice(finish + end.length).replace(/^\n/, '');
    }
    writes.set(cssFile, content);
  }
  for (const [file, content] of writes) writeLocal(file, content);
  return { records: [...records.values()], files: [...writes.keys()].map((file) => path.relative(fs.realpathSync(project), file)), packages: [...packages] };
}

module.exports = { contained, localPath, packageName, registryStyles, writeLocal, installRegistryItems };
