// A deliberately small, reproducible font pack. Downloads happen once while
// baking the template; fonts list/show/add never fetch anything at runtime.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { localPath, writeLocal } = require('./install-design-items.cjs');

const GOOGLE_FONTS_REVISION = '9710da1eacb3be272583c3224dcb70f9da6eadbb';
const FONT_BASE = 'https://raw.githubusercontent.com/google/fonts/' + GOOGLE_FONTS_REVISION + '/ofl/';
const FONT_PACK = [
  {
    id: 'bodoni-moda', family: 'Bodoni Moda', category: 'serif', weight: '400 900', style: 'normal', format: 'truetype',
    homepage: 'https://fonts.google.com/specimen/Bodoni+Moda',
    url: FONT_BASE + 'bodonimoda/BodoniModa%5Bopsz%2Cwght%5D.ttf',
    sha256: '550f5e34ee0a828d7941b1fe9bc58b34e5260d3f33a61532e6d0a0114e79a5cf',
    bytes: 162104, licenseUrl: FONT_BASE + 'bodonimoda/OFL.txt',
    licenseSha256: '931dfe2e0cd3c9443295f5c1d754b8a8403bf060df50c1d5900267ade83d0046',
  },
  {
    id: 'dm-sans', family: 'DM Sans', category: 'sans-serif', weight: '100 1000', style: 'normal', format: 'truetype',
    homepage: 'https://fonts.google.com/specimen/DM+Sans',
    url: FONT_BASE + 'dmsans/DMSans%5Bopsz%2Cwght%5D.ttf',
    sha256: '8cd08d97e89c24d0aa92edd2f0f4c8ee6195eee9b7c9f154865a58b02f0c1c0d',
    bytes: 240164, licenseUrl: FONT_BASE + 'dmsans/OFL.txt',
    licenseSha256: '9af36190332437f5ecd09974de43c1f7c77a310a996cdd8ceb25628b458840e1',
  },
];

function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

async function bakeFontCatalog({ out, cacheDir, fonts = FONT_PACK, fetchAsset = fetch }) {
  const items = [];
  async function download(url, expected) {
    const cache = cacheDir && path.join(cacheDir, 'font-' + expected);
    let bytes;
    if (cache && fs.existsSync(cache)) bytes = fs.readFileSync(cache);
    else {
      const response = await fetchAsset(url, { redirect: 'error', signal: AbortSignal.timeout(30000) });
      if (!response.ok) throw new Error('font asset HTTP ' + response.status + ': ' + url);
      bytes = Buffer.from(await response.arrayBuffer());
    }
    if (digest(bytes) !== expected) throw new Error('font asset checksum mismatch: ' + url);
    if (cache) { fs.mkdirSync(cacheDir, { recursive: true }); writeLocal(cache, bytes); }
    return bytes;
  }
  for (const font of fonts) {
    const file = 'fonts/' + font.id + '.ttf';
    const licenseFile = 'fonts/LICENSES/' + font.id + '.txt';
    const [bytes, license] = await Promise.all([download(font.url, font.sha256), download(font.licenseUrl, font.licenseSha256)]);
    if (bytes.length !== font.bytes) throw new Error('unexpected font asset size: ' + font.id);
    if (!/SIL OPEN FONT LICENSE Version 1\.1/.test(license.toString('utf8'))) throw new Error('font license is not SIL OFL 1.1: ' + font.id);
    writeLocal(path.join(out, file), bytes);
    writeLocal(path.join(out, licenseFile), license);
    items.push({ ...font, license: 'SIL OFL 1.1', file, licenseFile });
  }
  const catalog = { version: 1, revision: GOOGLE_FONTS_REVISION, items };
  writeLocal(path.join(out, 'fonts.json'), JSON.stringify(catalog, null, 1) + '\n');
  return catalog;
}

function loadFonts(catalogDir) {
  const catalog = JSON.parse(fs.readFileSync(path.join(catalogDir, 'fonts.json'), 'utf8'));
  if (!Array.isArray(catalog.items)) throw new Error('fonts.json is malformed');
  return catalog;
}

function fontCss(font) {
  return '@font-face {\n  font-family: "' + font.family + '";\n  src: url("/fonts/' + font.id + '.ttf") format("' + font.format + '");\n  font-style: ' + font.style + ';\n  font-weight: ' + font.weight + ';\n  font-display: swap;\n}\n';
}

function installFonts({ catalogDir, project, fonts }) {
  const writes = [];
  for (const font of fonts) {
    const source = fs.readFileSync(localPath(catalogDir, font.file));
    const license = fs.readFileSync(localPath(catalogDir, font.licenseFile));
    if (digest(source) !== font.sha256 || digest(license) !== font.licenseSha256) throw new Error('baked font checksum mismatch: ' + font.id);
    writes.push([localPath(project, 'public/fonts/' + font.id + '.ttf'), source]);
    writes.push([localPath(project, 'public/fonts/LICENSES/' + font.id + '.txt'), license]);
  }
  const stylesheet = localPath(project, 'public/fonts/devshot-fonts.css');
  let css = fs.existsSync(stylesheet) ? fs.readFileSync(stylesheet, 'utf8') : '';
  const notice = localPath(project, 'THIRD_PARTY_LICENSES.md');
  let text = fs.existsSync(notice) ? fs.readFileSync(notice, 'utf8') : '# Third-party licenses\n';
  for (const font of fonts) {
    const start = '/* devshot-font:' + font.id + ':start */';
    const end = '/* devshot-font:' + font.id + ':end */';
    const begin = css.indexOf(start);
    const finish = css.indexOf(end, begin);
    if (begin !== -1 && finish === -1) throw new Error('incomplete font CSS marker: ' + font.id);
    const block = start + '\n' + fontCss(font) + end + '\n';
    css = begin === -1 ? css + '\n' + block : css.slice(0, begin) + block + css.slice(finish + end.length).replace(/^\n/, '');
    const marker = '## Font — ' + font.family;
    if (!text.includes(marker)) text += '\n' + marker + '\n\nSource: ' + font.url + '\n\n' + fs.readFileSync(localPath(catalogDir, font.licenseFile), 'utf8') + '\n';
  }
  writes.push([stylesheet, css], [notice, text]);
  for (const [file, content] of writes) writeLocal(file, content);
  return writes.map(([file]) => path.relative(fs.realpathSync(project), file));
}

module.exports = { FONT_PACK, GOOGLE_FONTS_REVISION, bakeFontCatalog, loadFonts, fontCss, installFonts };
