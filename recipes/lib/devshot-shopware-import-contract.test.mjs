import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);

test('installs the Shopware importer in both guest architectures', async () => {
  for (const name of ['Dockerfile.dom0-x86', 'Dockerfile.dom0-arm']) {
    const dockerfile = await readFile(new URL(`docker/${name}`, root), 'utf8');
    assert.match(
      dockerfile,
      /COPY --chmod=0755 recipes\/lib\/devshot-shopware-import\.mjs \/usr\/local\/bin\/devshot-shopware-import/,
      name,
    );
  }
});
