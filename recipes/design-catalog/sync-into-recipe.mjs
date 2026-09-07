#!/usr/bin/env node
// sync-into-recipe.mjs — spec 386. The studio recipe is the only file that
// reaches the template chroot, so build-design-catalog.mjs and
// devshot-design.cjs are embedded in apps/agent/recipes/studio.sh between
// marker lines. Edit the source files, run this, commit both; the console test
// design-catalog-recipe.spec386.test.js fails when the copies drift.
//
//   node apps/agent/recipes/design-catalog/sync-into-recipe.mjs          # rewrite
//   node apps/agent/recipes/design-catalog/sync-into-recipe.mjs --check  # exit 1 on drift
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const RECIPE = path.join(here, '..', 'studio.sh');
export const EMBEDS = [
  { file: 'build-design-catalog.mjs', start: '# >>> design-catalog: build-design-catalog.mjs', end: '# <<< design-catalog: build-design-catalog.mjs', heredoc: 'DEVSHOT_DESIGN_BUILDER_EOF', target: '/tmp/devshot-build-design-catalog.mjs' },
  { file: 'devshot-design.cjs', start: '# >>> design-catalog: devshot-design.cjs', end: '# <<< design-catalog: devshot-design.cjs', heredoc: 'DEVSHOT_DESIGN_CLI_EOF', target: '/usr/local/bin/devshot-design' },
];

export function renderEmbed(embed, source) {
  if (source.includes(embed.heredoc)) throw new Error(`${embed.file} contains its own heredoc delimiter ${embed.heredoc}`);
  const body = source.endsWith('\n') ? source : `${source}\n`;
  return `${embed.start} (verbatim copy — do not edit here)\ncat > ${embed.target} <<'${embed.heredoc}'\n${body}${embed.heredoc}\n${embed.end}\n`;
}

export function syncRecipe(recipeText, sources) {
  let out = recipeText;
  for (const embed of EMBEDS) {
    const startIdx = out.indexOf(embed.start);
    const endMarker = `${embed.end}\n`;
    const endIdx = out.indexOf(endMarker, startIdx);
    if (startIdx === -1 || endIdx === -1) throw new Error(`markers for ${embed.file} not found in recipe`);
    out = out.slice(0, startIdx) + renderEmbed(embed, sources[embed.file]) + out.slice(endIdx + endMarker.length);
  }
  return out;
}

// extractEmbedded — the source text the recipe currently carries for one embed.
export function extractEmbedded(recipeText, embed) {
  const open = `<<'${embed.heredoc}'\n`;
  const startIdx = recipeText.indexOf(embed.start);
  const bodyStart = recipeText.indexOf(open, startIdx);
  const bodyEnd = recipeText.indexOf(`\n${embed.heredoc}\n`, bodyStart);
  if (startIdx === -1 || bodyStart === -1 || bodyEnd === -1) return null;
  return recipeText.slice(bodyStart + open.length, bodyEnd + 1);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const sources = Object.fromEntries(EMBEDS.map((e) => [e.file, fs.readFileSync(path.join(here, e.file), 'utf8')]));
  const current = fs.readFileSync(RECIPE, 'utf8');
  const next = syncRecipe(current, sources);
  if (process.argv.includes('--check')) {
    if (next !== current) { process.stderr.write('studio.sh is out of sync with design-catalog/*.{mjs,cjs}; run sync-into-recipe.mjs\n'); process.exit(1); }
    process.stdout.write('studio.sh embeds are in sync\n');
  } else if (next !== current) {
    fs.writeFileSync(RECIPE, next);
    process.stdout.write('studio.sh updated\n');
  } else {
    process.stdout.write('studio.sh already in sync\n');
  }
}
