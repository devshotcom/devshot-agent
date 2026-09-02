import assert from 'node:assert/strict';
import test from 'node:test';
import {
  __test,
  isShopwareContentTable,
  safeZipEntry,
  shopwareImportsEndpoint,
  sqlLiteral,
} from './devshot-shopware-import.mjs';

test('builds the agent API endpoint from the injected Studio gateway base', () => {
  assert.equal(
    shopwareImportsEndpoint('https://console.devshot.com/api/ai/v1/'),
    'https://console.devshot.com/api/ai/v1/shopware/imports',
  );
  assert.equal(shopwareImportsEndpoint('not-a-url'), '');
});

test('imports storefront content but refuses personal, transactional, secret, and media tables', () => {
  for (const table of ['product', 'product_translation', 'category', 'cms_page', 'theme', 'sales_channel', 'plugin']) {
    assert.equal(isShopwareContentTable(table), true, table);
  }
  for (const table of ['customer', 'customer_address', 'order', 'order_customer', 'user', 'integration', 'system_config', 'media', 'log_entry', 'product_review', 'promotion_individual_code']) {
    assert.equal(isShopwareContentTable(table), false, table);
  }
});

test('rejects archive traversal and platform-specific paths', () => {
  assert.equal(safeZipEntry('custom/plugins/Theme/composer.json'), true);
  assert.equal(safeZipEntry('../escape.php'), false);
  assert.equal(safeZipEntry('/etc/passwd'), false);
  assert.equal(safeZipEntry('C:\\secret.txt'), false);
});

test('encodes values without SQL interpolation and understands typed binary values', () => {
  assert.equal(sqlLiteral(null), 'NULL');
  assert.equal(sqlLiteral(true), '1');
  assert.equal(sqlLiteral(12.5), '12.5');
  assert.equal(sqlLiteral("x'); DROP TABLE product; --"), "X'7827293b2044524f50205441424c452070726f647563743b202d2d'");
  assert.equal(sqlLiteral('00112233445566778899aabbccddeeff', 'binary'), "UNHEX('00112233445566778899aabbccddeeff')");
  assert.equal(sqlLiteral({ type: 'bytes', base64: 'AAEC' }, 'binary'), "X'000102'");
});

test('parses the local Shopware and Grok environment formats', () => {
  assert.deepEqual(__test.parseEnv('DATABASE_URL="mysql://shopware:p%40ss@127.0.0.1:3306/shopware"\nDEVSHOT_AI_KEY=dsst_x.y\n'), {
    DATABASE_URL: 'mysql://shopware:p%40ss@127.0.0.1:3306/shopware',
    DEVSHOT_AI_KEY: 'dsst_x.y',
  });
  assert.deepEqual(__test.parseDatabaseUrl('mysql://shopware:p%40ss@127.0.0.1:3306/shopware'), {
    host: '127.0.0.1',
    port: '3306',
    user: 'shopware',
    password: 'p@ss',
    database: 'shopware',
  });
});
