#!/usr/bin/env node

import { createReadStream, createWriteStream } from 'node:fs';
import {
  access,
  cp,
  lstat,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn, execFile } from 'node:child_process';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import readline from 'node:readline';

const execFileAsync = promisify(execFile);
const PROJECT_ROOT = '/var/www/shopware';
const GROK_ENV = '/tmp/.grok-serve/env';
const IMPORT_ID_FILE = '/tmp/.devshot-shopware-import-id';
const MAX_DOWNLOAD_BYTES = 96 * 1024 * 1024;
const SAFE_TABLE_PATTERNS = [
  /^(?:category|category_translation|category_tag|product|product_(?!review|export)[a-z0-9_]+|property_group|property_group_[a-z0-9_]+)$/,
  /^(?:cms_page|cms_page_translation|cms_section|cms_block|cms_slot|cms_slot_translation)$/,
  /^(?:theme|theme_translation|theme_sales_channel)$/,
  /^(?:sales_channel|sales_channel_translation|sales_channel_type|sales_channel_type_translation|sales_channel_domain)$/,
  /^(?:rule|rule_condition|rule_tag|shipping_method|shipping_method_.*|payment_method|payment_method_translation)$/,
  /^(?:promotion|promotion_translation|promotion_discount|promotion_discount_prices|promotion_sales_channel|promotion_cart_rule|promotion_discount_rule)$/,
  /^(?:tax|tax_rule|tax_rule_type|currency|currency_translation|country|country_.*)$/,
  /^(?:language|locale|snippet|snippet_set|snippet_set_translation|translation_code)$/,
  /^(?:custom_field|custom_field_set|custom_field_set_relation|tag|unit|unit_translation|delivery_time|delivery_time_translation)$/,
  /^(?:seo_url|seo_url_template|seo_url_template_translation)$/,
  /^(?:mail_template|mail_template_translation|mail_template_type|mail_template_type_translation|mail_header_footer|mail_header_footer_translation)$/,
  /^(?:state_machine|state_machine_state|state_machine_state_translation|state_machine_transition)$/,
  /^(?:media_default_folder|media_folder|media_folder_configuration)$/,
  /^plugin$/,
];
const PRESERVED_PATHS = [
  '.env',
  '.git',
  'public/media',
  'public/thumbnail',
  'files/media',
  'var/cache',
  'var/log',
  'vendor',
  'node_modules',
];

function parseEnv(text) {
  const values = {};
  for (const line of String(text || '').split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    values[match[1]] = value;
  }
  return values;
}

export function shopwareImportsEndpoint(baseUrl) {
  const base = String(baseUrl || '').replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) return '';
  return `${base}/shopware/imports`;
}

export function isShopwareContentTable(table) {
  const name = String(table || '');
  return /^[a-z0-9_]+$/.test(name) && SAFE_TABLE_PATTERNS.some((pattern) => pattern.test(name));
}

export function safeZipEntry(name) {
  const value = String(name || '');
  if (!value || value.includes('\0') || value.includes('\\') || value.startsWith('/') || /^[A-Za-z]:/.test(value)) return false;
  const parts = value.replace(/\/$/, '').split('/');
  return parts.length > 0 && parts.every((part) => part && part !== '.' && part !== '..');
}

function binaryValue(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const encoded = typeof value.base64 === 'string' && value.type === 'bytes'
    ? value.base64
    : (typeof value.b === 'string' && value.t === 'bytes' ? value.b : '');
  if (!encoded || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) return null;
  return Buffer.from(encoded, 'base64');
}

export function sqlLiteral(value, columnType = '') {
  if (value === null || value === undefined) return 'NULL';
  const bytes = binaryValue(value);
  if (bytes) return `X'${bytes.toString('hex')}'`;
  if (typeof value === 'boolean') return value ? '1' : '0';
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  if (/^(?:binary|varbinary|tinyblob|blob|mediumblob|longblob)$/i.test(columnType)
    && /^[a-f0-9]{32}$/i.test(text)) {
    return `UNHEX('${text}')`;
  }
  return `X'${Buffer.from(text, 'utf8').toString('hex')}'`;
}

function normalizedRelative(path) {
  return String(path || '').split(sep).join('/').replace(/^\.\//, '').replace(/\/$/, '');
}

function isPreserved(path) {
  const rel = normalizedRelative(path);
  return PRESERVED_PATHS.some((item) => rel === item || rel.startsWith(`${item}/`));
}

function isPreservedAncestor(path) {
  const rel = normalizedRelative(path);
  return PRESERVED_PATHS.some((item) => item.startsWith(`${rel}/`));
}

async function exists(path) {
  try { await access(path); return true; } catch { return false; }
}

async function assertNoLinks(root, current = root) {
  const stat = await lstat(current);
  if (stat.isSymbolicLink()) throw new Error(`archive contains a symbolic link: ${relative(root, current)}`);
  if (!stat.isDirectory()) return;
  for (const entry of await readdir(current)) await assertNoLinks(root, join(current, entry));
}

async function pruneMissing(targetRoot, sourceRoot, current = targetRoot) {
  for (const entry of await readdir(current, { withFileTypes: true })) {
    const target = join(current, entry.name);
    const rel = normalizedRelative(relative(targetRoot, target));
    if (isPreserved(rel)) continue;
    const source = join(sourceRoot, rel);
    if (await exists(source)) {
      const sourceStat = await lstat(source);
      if (entry.isDirectory() && sourceStat.isDirectory()) await pruneMissing(targetRoot, sourceRoot, target);
      else if (entry.isDirectory() !== sourceStat.isDirectory()) await rm(target, { recursive: true, force: true });
      continue;
    }
    if (entry.isDirectory() && isPreservedAncestor(rel)) await pruneMissing(targetRoot, sourceRoot, target);
    else await rm(target, { recursive: true, force: true });
  }
}

async function run(command, args, { cwd = PROJECT_ROOT, env = process.env } = {}) {
  const child = spawn(command, args, { cwd, env, stdio: 'inherit' });
  const [code, signal] = await once(child, 'exit');
  if (code !== 0) throw new Error(`${command} failed (${signal || code})`);
}

async function download(url, destination, maxBytes = MAX_DOWNLOAD_BYTES) {
  const parsed = new URL(url);
  if (parsed.protocol !== 'https:') throw new Error('download URL must use HTTPS');
  const response = await fetch(parsed, { redirect: 'follow' });
  if (!response.ok || !response.body) throw new Error(`download failed with HTTP ${response.status}`);
  if (new URL(response.url).protocol !== 'https:') throw new Error('download redirect must use HTTPS');
  const contentLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(contentLength) && contentLength > maxBytes) throw new Error('download exceeds size limit');
  let received = 0;
  const limiter = new TransformStream({
    transform(chunk, controller) {
      received += chunk.byteLength;
      if (received > maxBytes) throw new Error('download exceeds size limit');
      controller.enqueue(chunk);
    },
  });
  await pipeline(Readable.fromWeb(response.body.pipeThrough(limiter)), createWriteStream(destination, { mode: 0o600 }));
}

async function replaceProjectFiles(archivePath, temporaryRoot) {
  const staging = join(temporaryRoot, 'project');
  await run('unzip', ['-q', archivePath, '-d', staging], { cwd: temporaryRoot });
  await assertNoLinks(staging);
  for (const required of ['composer.json', 'bin/console']) {
    if (!await exists(join(staging, required))) throw new Error(`Shopware archive is missing ${required}`);
  }
  await rm(join(staging, 'devshot-manifest.json'), { force: true });
  await pruneMissing(PROJECT_ROOT, staging);
  for (const entry of await readdir(staging)) {
    await cp(join(staging, entry), join(PROJECT_ROOT, entry), {
      recursive: true,
      force: true,
      errorOnExist: false,
      preserveTimestamps: true,
    });
  }
}

function parseDatabaseUrl(value) {
  const url = new URL(value);
  if (!['mysql:', 'mariadb:'].includes(url.protocol)) throw new Error('DATABASE_URL must use mysql or mariadb');
  const database = decodeURIComponent(url.pathname.replace(/^\//, ''));
  if (!database) throw new Error('DATABASE_URL has no database name');
  return {
    host: url.hostname || '127.0.0.1',
    port: url.port || '3306',
    user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    database,
  };
}

function mariadbArgs(database, extra = []) {
  return [
    '--batch',
    '--raw',
    '--skip-column-names',
    '--default-character-set=utf8mb4',
    '--host', database.host,
    '--port', database.port,
    '--user', database.user,
    ...extra,
    database.database,
  ];
}

async function loadSchema(database) {
  const sql = 'SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION';
  const { stdout } = await execFileAsync('mariadb', mariadbArgs(database, ['-e', sql]), {
    cwd: PROJECT_ROOT,
    env: { ...process.env, MYSQL_PWD: database.password },
    maxBuffer: 32 * 1024 * 1024,
  });
  const schema = new Map();
  for (const line of stdout.split(/\r?\n/)) {
    const [table, column, type] = line.split('\t');
    if (!table || !column || !type || !/^[a-zA-Z0-9_]+$/.test(table) || !/^[a-zA-Z0-9_]+$/.test(column)) continue;
    if (!schema.has(table)) schema.set(table, new Map());
    schema.get(table).set(column, type);
  }
  return schema;
}

async function streamWrite(stream, value) {
  if (!stream.write(value)) await once(stream, 'drain');
}

async function importDatabase(backupPath) {
  const env = parseEnv(await readFile(join(PROJECT_ROOT, '.env'), 'utf8'));
  const database = parseDatabaseUrl(env.DATABASE_URL || '');
  const schema = await loadSchema(database);
  const child = spawn('mariadb', mariadbArgs(database, ['--binary-mode']), {
    cwd: PROJECT_ROOT,
    env: { ...process.env, MYSQL_PWD: database.password },
    stdio: ['pipe', 'inherit', 'inherit'],
  });
  const exited = once(child, 'exit');
  const openedTables = new Set();
  const skippedTables = new Set();
  let importedRows = 0;
  let skippedRows = 0;
  let lineNumber = 0;
  try {
    await streamWrite(child.stdin, 'SET NAMES utf8mb4; SET FOREIGN_KEY_CHECKS=0; START TRANSACTION;\n');
    const lines = readline.createInterface({ input: createReadStream(backupPath), crlfDelay: Infinity });
    for await (const line of lines) {
      lineNumber += 1;
      if (!line.trim()) continue;
      let record;
      try { record = JSON.parse(line); }
      catch { throw new Error(`database backup contains invalid JSON on line ${lineNumber}`); }
      if (lineNumber === 1 && typeof record?.type === 'string') continue;
      const table = typeof record?.table === 'string' ? record.table : '';
      if (!isShopwareContentTable(table) || !schema.has(table) || !record.row || typeof record.row !== 'object' || Array.isArray(record.row)) {
        if (table) skippedTables.add(table);
        skippedRows += 1;
        continue;
      }
      const targetColumns = schema.get(table);
      const columns = Object.keys(record.row).filter((column) => targetColumns.has(column) && /^[a-zA-Z0-9_]+$/.test(column));
      if (!columns.length) { skippedRows += 1; continue; }
      if (!openedTables.has(table)) {
        await streamWrite(child.stdin, `DELETE FROM \`${table}\`;\n`);
        openedTables.add(table);
      }
      const identifiers = columns.map((column) => `\`${column}\``).join(',');
      const values = columns.map((column) => sqlLiteral(record.row[column], targetColumns.get(column))).join(',');
      await streamWrite(child.stdin, `INSERT INTO \`${table}\` (${identifiers}) VALUES (${values});\n`);
      importedRows += 1;
    }
    await streamWrite(child.stdin, 'COMMIT; SET FOREIGN_KEY_CHECKS=1;\n');
    child.stdin.end();
    const [code, signal] = await exited;
    if (code !== 0) throw new Error(`database import failed (${signal || code})`);
  } catch (error) {
    child.stdin.destroy();
    child.kill('SIGTERM');
    await exited.catch(() => null);
    throw error;
  }
  return { importedRows, skippedRows, skippedTables: [...skippedTables].sort() };
}

async function normalizeShopwareDomains() {
  const env = parseEnv(await readFile(join(PROJECT_ROOT, '.env'), 'utf8'));
  const database = parseDatabaseUrl(env.DATABASE_URL || '');
  const sql = [
    'SET @first_domain := (SELECT HEX(id) FROM sales_channel_domain ORDER BY created_at, id LIMIT 1);',
    "UPDATE sales_channel_domain SET url = IF(HEX(id) = @first_domain, 'http://localhost', CONCAT('http://localhost/devshot-', LOWER(HEX(id))));",
  ].join(' ');
  await run('mariadb', mariadbArgs(database, ['-e', sql]), {
    env: { ...process.env, MYSQL_PWD: database.password },
  });
}

async function loadAgentConfig() {
  const values = parseEnv(await readFile(GROK_ENV, 'utf8'));
  const endpoint = shopwareImportsEndpoint(values.DEVSHOT_AI_BASE_URL);
  if (!endpoint || !values.DEVSHOT_AI_KEY) throw new Error('Studio AI session credentials are unavailable');
  return { endpoint, token: values.DEVSHOT_AI_KEY };
}

async function api(action, importId = '') {
  const config = await loadAgentConfig();
  const response = await fetch(config.endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, ...(importId ? { importId } : {}) }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `Shopware import API returned HTTP ${response.status}`);
  return body;
}

async function rememberedImportId(value) {
  const explicit = String(value || '').trim();
  if (explicit) return explicit;
  return (await readFile(IMPORT_ID_FILE, 'utf8')).trim();
}

async function prepare() {
  const prepared = await api('prepare');
  await writeFile(IMPORT_ID_FILE, `${prepared.importId}\n`, { mode: 0o600 });
  process.stdout.write([
    `Shopware import ${prepared.importId} is waiting for the source shop.`,
    prepared.notice,
    '',
    'Run this command from the Shopware project root on the source system:',
    prepared.sourceCommand,
    '',
    `Then run: devshot-shopware-import apply ${prepared.importId}`,
  ].join('\n') + '\n');
}

async function status(importId) {
  const id = await rememberedImportId(importId);
  process.stdout.write(`${JSON.stringify(await api('status', id), null, 2)}\n`);
}

async function applyImport(importId) {
  const id = await rememberedImportId(importId);
  const download = await api('download', id);
  const temporaryRoot = await mkdtemp(join(tmpdir(), 'devshot-shopware-import-'));
  try {
    const archivePath = join(temporaryRoot, 'project.zip');
    const databasePath = join(temporaryRoot, 'database.jsonl');
    process.stdout.write('Downloading the validated Shopware bundle...\n');
    await Promise.all([
      downloadFile(download.projectArchiveUrl, archivePath),
      downloadFile(download.databaseUrl, databasePath),
    ]);
    process.stdout.write('Replacing project files while preserving local secrets, media and generated dependencies...\n');
    await replaceProjectFiles(archivePath, temporaryRoot);
    await run('composer', ['install', '--no-dev', '--prefer-dist', '--no-interaction', '--no-progress']);
    await run('php', ['bin/console', 'database:migrate', '--all', '-n']);
    process.stdout.write('Importing storefront configuration, catalog, CMS and theme data...\n');
    const imported = await importDatabase(databasePath);
    await normalizeShopwareDomains();
    await run('php', ['bin/console', 'plugin:refresh', '-n']);
    await run('php', ['bin/console', 'database:migrate', '--all', '-n']);
    await run('php', ['bin/console', 'theme:refresh', '-n']);
    await run('php', ['bin/console', 'assets:install']);
    await run('php', ['bin/console', 'theme:compile', '-n']);
    await run('php', ['bin/console', 'cache:clear', '-n']);
    await api('complete', id);
    process.stdout.write(`${JSON.stringify({ ok: true, importId: id, ...imported }, null, 2)}\n`);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
}

async function downloadFile(url, path) {
  await access(dirname(path));
  return download(url, path);
}

function usage() {
  return 'usage: devshot-shopware-import <prepare|status|apply> [import-id]';
}

export async function main(argv = process.argv.slice(2)) {
  const [command, importId] = argv;
  if (command === 'prepare') return prepare();
  if (command === 'status') return status(importId);
  if (command === 'apply') return applyImport(importId);
  throw new Error(usage());
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : '';
if (invokedPath && import.meta.url === pathToFileURL(invokedPath).href) {
  main().catch((error) => {
    process.stderr.write(`devshot-shopware-import: ${error.message}\n`);
    process.exitCode = 1;
  });
}

export const __test = { parseEnv, parseDatabaseUrl, isPreserved, isPreservedAncestor, binaryValue };
