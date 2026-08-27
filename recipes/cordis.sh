#!/bin/sh
# Recipe: Cordis — the official Cordis application boilerplate with its WebUI
# on :3140 and openvscode-server on :8080, both opened to /var/www/cordis.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/cordis.sh --name=cordis
# Output template: devshot-guest-cordis.qcow2 (claimed as template "cordis").
#
# Cordis is pre-release software. Pin the exact boilerplate archive and digest
# so a rebuild cannot silently change the scaffold contract without a reviewed
# diff. create-cordis only accepts mutable dist-tags in --ref, not versions.
# devshot:exposed_ports=[{"port":3140,"name":"cordis","proto":"http"},{"port":8080,"name":"editor","proto":"http"},{"port":24678,"name":"vite-hmr","proto":"http"}]
# devshot:memory_mb=2048
# devshot:disk_gb=4
set -eux

apk update
apk add --no-cache \
  git nodejs npm gcompat libstdc++ libc6-compat ca-certificates wget tar e2fsprogs-extra \
  chromium chromium-swiftshader ttf-freefont

# Runtime tools and the supervised services run as the unprivileged devshot user.
install -d -m 0750 /etc/sudoers.d
printf 'devshot ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/devshot
chmod 0440 /etc/sudoers.d/devshot
visudo -cf /etc/sudoers

# Bake recipes are executed through QGA with a minimal PATH. The shared
# installer writes Grok and Specify to /usr/local/bin and Python's venv module
# needs an absolute interpreter path during this non-interactive boot phase.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
/usr/local/libexec/devshot/install-grok-speckit.sh
# Keep Cordis bakes compatible with base images whose shared installer predates
# the restrictive-QGA-umask fix. The Studio agent runs this CLI as devshot.
chmod -R a+rX /opt/grok
chmod -R a+rX /opt/specify-cli
su devshot -c 'test -x /opt/grok/grok'
su devshot -c 'test -x /opt/specify-cli/bin/specify'

# Browser-backed verification is available offline inside the claimed VM.
install -d /opt/devshot-e2e
( cd /opt/devshot-e2e && npm init -y >/dev/null 2>&1 && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --omit=dev puppeteer-core )
# QGA runs recipes with a restrictive umask. The browser witness is executed by
# the unprivileged Studio agent, so every parent directory and installed module
# must be traversable/readable after the bake.
chmod -R a+rX /opt/devshot-e2e
su devshot -c "node -e \"require('/opt/devshot-e2e/node_modules/puppeteer-core')\""

# A loopback-only Cordis plugin gives the Studio agent a typed view of the live
# runtime graph. It is platform-managed and restored into every workspace at
# boot, so project restores cannot silently remove the agent contract.
install -d -m 0755 /opt/devshot-cordis-agent-bridge
cat > /opt/devshot-cordis-agent-bridge/package.json <<'BRIDGEPACKAGE'
{
  "name": "devshot-agent-bridge",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "src/index.ts"
}
BRIDGEPACKAGE
cat > /opt/devshot-cordis-agent-bridge/index.ts <<'BRIDGESOURCE'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'

export const name = 'devshot-agent-bridge'

const HOST = '127.0.0.1'
const PORT = 3141
const MAX_BODY_BYTES = 64 * 1024
const STATE_NAMES = ['pending', 'loading', 'active', 'failed', 'disposed', 'unloading'] as const
const SECRET_KEY = /(?:pass(?:word)?|token|secret|credential|api[_-]?key|authorization|cookie)/i
const PROTECTED_PLUGIN = /devshot-agent-bridge/i

type RuntimeRow = { runtime: any, fiber: any }
type JsonRecord = Record<string, unknown>

class BridgeError extends Error {
  constructor(public status: number, message: string, public details?: unknown) {
    super(message)
  }
}

function isPlainObject(value: unknown): value is JsonRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function safeValue(value: unknown, key = '', depth = 0, seen = new WeakSet<object>()): unknown {
  if (SECRET_KEY.test(key)) return '[redacted]'
  if (value == null || typeof value === 'boolean' || typeof value === 'number') return value
  if (typeof value === 'string') return value.length > 2_000 ? `${value.slice(0, 2_000)}…` : value
  if (typeof value === 'bigint') return String(value)
  if (typeof value === 'function' || typeof value === 'symbol') return undefined
  if (depth >= 7) return '[max-depth]'
  if (typeof value !== 'object') return String(value)
  if (seen.has(value)) return '[circular]'
  seen.add(value)
  if (value instanceof Date) return value.toISOString()
  if (Array.isArray(value)) {
    return value.slice(0, 100).map((item) => safeValue(item, key, depth + 1, seen))
  }
  const output: JsonRecord = {}
  for (const [childKey, childValue] of Object.entries(value).slice(0, 100)) {
    const safe = safeValue(childValue, childKey, depth + 1, seen)
    if (safe !== undefined) output[childKey] = safe
  }
  return output
}

function schemaSummary(schema: any, depth = 0, seen = new WeakSet<object>()): unknown {
  if (schema == null) return null
  if ((typeof schema !== 'object' && typeof schema !== 'function') || depth >= 8) return safeValue(schema)
  if (seen.has(schema)) return '[circular-schema]'
  seen.add(schema)
  const output: JsonRecord = {}
  if (typeof schema.type === 'string') output.type = schema.type
  if (schema.meta && typeof schema.meta === 'object') output.meta = safeValue(schema.meta, 'meta')
  if (schema.dict && typeof schema.dict === 'object') {
    output.properties = Object.fromEntries(
      Object.entries(schema.dict).slice(0, 100).map(([key, child]) => [key, schemaSummary(child, depth + 1, seen)]),
    )
  }
  if (schema.inner) output.inner = schemaSummary(schema.inner, depth + 1, seen)
  if (schema.list) output.items = schemaSummary(schema.list, depth + 1, seen)
  for (const key of ['union', 'intersect', 'variants', 'options']) {
    if (!Array.isArray(schema[key])) continue
    output[key] = schema[key].slice(0, 50).map((child: unknown) => schemaSummary(child, depth + 1, seen))
  }
  if (!Object.keys(output).length) return { available: true }
  return output
}

function runtimeRows(root: any): RuntimeRow[] {
  const rows: RuntimeRow[] = []
  for (const runtime of root.registry.values()) {
    for (const fiber of runtime.fibers) rows.push({ runtime, fiber })
  }
  return rows
}

function pluginName(row: RuntimeRow): string {
  return String(row.runtime.name || row.fiber.name || 'anonymous')
}

function fiberSummary(row: RuntimeRow, detail: 'summary' | 'full'): JsonRecord {
  const state = STATE_NAMES[row.fiber.state] || `unknown:${row.fiber.state}`
  return {
    uid: row.fiber.uid,
    plugin: pluginName(row),
    state,
    inject: Object.entries(row.fiber.inject || {}).map(([service, required]) => ({ service, required: Boolean(required) })),
    ...(detail === 'full' ? {
      config: safeValue(row.fiber.config, 'config'),
      effects: safeValue(row.fiber.getEffects(), 'effects'),
    } : {}),
  }
}

function serviceSummaries(root: any): JsonRecord[] {
  return Reflect.ownKeys(root.reflect.store)
    .sort((left, right) => String(left).localeCompare(String(right)))
    .slice(0, 500)
    .map((key) => {
      const impl = root.reflect.store[key]
      const service = impl?.name || (typeof key === 'symbol' ? key.description : key) || String(key)
      return {
        service,
        providerUid: impl?.fiber?.uid ?? null,
        providerPlugin: impl?.fiber?.name || null,
        active: Boolean(impl?.value !== undefined || impl?.check?.()),
      }
    })
}

function eventHookSummaries(root: any): JsonRecord[] {
  return Reflect.ownKeys(root.events._hooks)
    .map((event) => ({ event: typeof event === 'symbol' ? String(event) : event, listeners: root.events._hooks[event]?.length || 0 }))
    .filter((item) => item.listeners > 0)
    .sort((left, right) => String(left.event).localeCompare(String(right.event)))
    .slice(0, 500)
}

function mergePatch(current: unknown, patch: JsonRecord): JsonRecord {
  const output: JsonRecord = isPlainObject(current) ? { ...current } : {}
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) {
      delete output[key]
    } else if (isPlainObject(value)) {
      output[key] = mergePatch(output[key], value)
    } else {
      output[key] = value
    }
  }
  return output
}

function boundedNumber(value: unknown, fallback: number, minimum: number, maximum: number): number {
  const number = Number(value)
  return Number.isFinite(number) ? Math.max(minimum, Math.min(maximum, Math.round(number))) : fallback
}

function exactPluginRows(root: any, plugin: string): RuntimeRow[] {
  return runtimeRows(root).filter((row) => pluginName(row) === plugin || row.fiber.name === plugin)
}

function selectFiber(root: any, body: JsonRecord): RuntimeRow {
  const hasUid = Number.isInteger(Number(body.uid))
  const plugin = String(body.plugin || '').trim()
  if (!hasUid && !plugin) throw new BridgeError(400, 'uid or plugin is required')
  let matches = runtimeRows(root)
  if (hasUid) matches = matches.filter((row) => row.fiber.uid === Number(body.uid))
  if (plugin) matches = matches.filter((row) => pluginName(row) === plugin || row.fiber.name === plugin)
  if (matches.length !== 1) {
    throw new BridgeError(matches.length ? 409 : 404, matches.length ? 'plugin selector is ambiguous; use uid' : 'plugin fiber not found', {
      matches: matches.map((row) => ({ uid: row.fiber.uid, plugin: pluginName(row), state: STATE_NAMES[row.fiber.state] })),
    })
  }
  if (PROTECTED_PLUGIN.test(pluginName(matches[0]))) throw new BridgeError(403, 'the DevShot agent bridge is platform-managed')
  return matches[0]
}

function readJson(request: IncomingMessage): Promise<JsonRecord> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    request.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new BridgeError(413, 'request body is too large'))
        request.destroy()
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => {
      if (!chunks.length) return resolve({})
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (!isPlainObject(value)) throw new Error('JSON object required')
        resolve(value)
      } catch (error) {
        reject(new BridgeError(400, error instanceof Error ? error.message : 'invalid JSON'))
      }
    })
    request.on('error', reject)
  })
}

function sendJson(response: ServerResponse, status: number, payload: JsonRecord) {
  const body = JSON.stringify(payload, null, 2)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    connection: 'close',
  })
  response.end(body)
}

function isLoopback(address: string | undefined): boolean {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
}

export function apply(ctx: any) {
  const root = ctx.root
  let eventSequence = 0
  let lastActivityAt = Date.now()
  const recentEvents: JsonRecord[] = []
  const record = (event: string, details: JsonRecord = {}) => {
    eventSequence += 1
    lastActivityAt = Date.now()
    recentEvents.push({ sequence: eventSequence, at: new Date().toISOString(), event, ...details })
    if (recentEvents.length > 50) recentEvents.shift()
  }

  ctx.on('internal/plugin', (fiber) => record('plugin', { uid: fiber.uid, plugin: fiber.name }), { global: true })
  ctx.on('internal/status', (fiber, previous) => record('status', {
    uid: fiber.uid,
    plugin: fiber.name,
    from: STATE_NAMES[previous] || previous,
    to: STATE_NAMES[fiber.state] || fiber.state,
  }), { global: true })
  ctx.on('internal/service', function (service, value) {
    record('service', { service, action: value === undefined ? 'removed' : 'provided' })
  }, { global: true })
  ctx.on('internal/update', function (config, noSave, next) {
    record('update', { uid: this.uid, plugin: this.name, persisted: !noSave })
    return next()
  }, { global: true })

  const snapshot = (body: JsonRecord) => {
    const detail = body.detail === 'full' ? 'full' : 'summary'
    const filter = String(body.plugin || '').trim()
    const allRows = runtimeRows(root)
    const selectedRows = filter ? allRows.filter((row) => pluginName(row) === filter || row.fiber.name === filter) : allRows
    const failed = allRows.filter((row) => row.fiber.state === 3)
    return {
      ok: failed.length === 0,
      bridge: { version: 1, host: HOST, port: PORT },
      runtime: {
        registryCounter: root.registry.counter,
        runtimes: root.registry.size,
        fibers: allRows.length,
        selectedFibers: selectedRows.length,
        failedFibers: failed.length,
      },
      process: {
        pid: process.pid,
        uptimeSeconds: Math.round(process.uptime() * 10) / 10,
        memoryBytes: process.memoryUsage(),
        cpuMicroseconds: process.cpuUsage(),
      },
      plugins: selectedRows.map((row) => fiberSummary(row, detail)),
      services: serviceSummaries(root),
      eventHooks: detail === 'full' ? eventHookSummaries(root) : undefined,
      recentEvents: recentEvents.slice(-20),
    }
  }

  const waitForStable = async (body: JsonRecord) => {
    const timeoutMs = boundedNumber(body.timeout_ms, 10_000, 250, 30_000)
    const quietMs = boundedNumber(body.quiet_ms, 300, 50, 5_000)
    const startedAt = Date.now()
    let observedSequence = eventSequence
    let quietSince = Date.now()
    while (Date.now() - startedAt <= timeoutMs) {
      const rows = runtimeRows(root)
      const failed = rows.filter((row) => row.fiber.state === 3)
      if (failed.length) {
        throw new BridgeError(409, 'Cordis has failed plugin fibers', {
          failed: failed.map((row) => ({ uid: row.fiber.uid, plugin: pluginName(row) })),
        })
      }
      if (eventSequence !== observedSequence) {
        observedSequence = eventSequence
        quietSince = Date.now()
      }
      // PENDING can be a durable, healthy state while an optional dependency is
      // absent. Only an actual load/unload cycle means the graph is in motion.
      const transitioning = rows.filter((row) => [1, 5].includes(row.fiber.state))
      const quietFor = Math.min(Date.now() - quietSince, Date.now() - lastActivityAt)
      if (!transitioning.length && quietFor >= quietMs) {
        return { ok: true, stable: true, waitedMs: Date.now() - startedAt, sequence: eventSequence }
      }
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    throw new BridgeError(408, 'Cordis did not become stable before timeout')
  }

  ctx.effect(async () => {
    const server = createServer(async (request, response) => {
      try {
        if (!isLoopback(request.socket.remoteAddress)) throw new BridgeError(403, 'loopback requests only')
        const url = new URL(request.url || '/', `http://${HOST}:${PORT}`)
        if (request.method === 'GET' && url.pathname === '/v1/health') {
          return sendJson(response, 200, { ok: true, bridge: 'devshot-agent-bridge', version: 1 })
        }
        if (request.method !== 'POST') throw new BridgeError(405, 'POST required')
        const body = await readJson(request)
        if (url.pathname === '/v1/snapshot') return sendJson(response, 200, snapshot(body))
        if (url.pathname === '/v1/schema') {
          const plugin = String(body.plugin || '').trim()
          if (!plugin) throw new BridgeError(400, 'plugin is required')
          const matches = exactPluginRows(root, plugin)
          const runtimes = [...new Set(matches.map((row) => row.runtime))]
          if (!runtimes.length) throw new BridgeError(404, 'plugin not found')
          if (runtimes.length > 1) throw new BridgeError(409, 'plugin name resolves to multiple runtimes')
          return sendJson(response, 200, {
            ok: true,
            plugin,
            fiberUids: matches.map((row) => row.fiber.uid),
            schema: schemaSummary(runtimes[0].Config),
          })
        }
        if (url.pathname === '/v1/config') {
          if (!isPlainObject(body.patch)) throw new BridgeError(400, 'patch must be an object')
          const row = selectFiber(root, body)
          const standard = (row.runtime.Config as any)?.['~standard']
          if (typeof standard?.validate !== 'function') throw new BridgeError(422, 'plugin has no live configuration schema')
          const entry = row.fiber.entry
          if (!entry?.parent?.tree) throw new BridgeError(422, 'plugin is not managed by the Cordis loader')
          const current = isPlainObject(entry.options?.config) ? entry.options.config : row.fiber.config
          const proposed = body.replace === true ? body.patch : mergePatch(current, body.patch)
          const validation = await standard.validate(proposed)
          if (validation?.issues?.length) throw new BridgeError(422, 'configuration validation failed', { issues: safeValue(validation.issues) })
          // Entry.update() is the same lifecycle path used by the Cordis WebUI.
          // It validates again, applies with noSave=true, and keeps loader state
          // coherent. Write only after the new fiber has become active.
          await entry.update({ config: proposed }, false, true)
          await row.fiber.await()
          entry.parent.tree.write()
          const stable = await waitForStable({ timeout_ms: body.timeout_ms, quiet_ms: 200 })
          return sendJson(response, 200, {
            ok: true,
            updated: { uid: row.fiber.uid, plugin: pluginName(row), config: safeValue(row.fiber.config, 'config') },
            stable,
          })
        }
        if (url.pathname === '/v1/wait') return sendJson(response, 200, await waitForStable(body))
        if (url.pathname === '/v1/verify') {
          const stable = await waitForStable({ timeout_ms: body.timeout_ms, quiet_ms: body.quiet_ms })
          const rows = runtimeRows(root)
          const activePlugins = new Set(rows.filter((row) => row.fiber.state === 2).map(pluginName))
          const services = new Set(serviceSummaries(root).filter((item) => item.active).map((item) => String(item.service)))
          const expectedPlugins = Array.isArray(body.plugins) ? body.plugins.map(String).slice(0, 100) : []
          const expectedServices = Array.isArray(body.services) ? body.services.map(String).slice(0, 100) : []
          const missingPlugins = expectedPlugins.filter((plugin) => !activePlugins.has(plugin))
          const missingServices = expectedServices.filter((service) => !services.has(service))
          if (missingPlugins.length || missingServices.length) {
            throw new BridgeError(409, 'Cordis verification failed', { missingPlugins, missingServices })
          }
          return sendJson(response, 200, {
            ok: true,
            stable,
            checks: {
              noFailedFibers: true,
              expectedPlugins: expectedPlugins.length,
              expectedServices: expectedServices.length,
            },
          })
        }
        throw new BridgeError(404, 'unknown bridge route')
      } catch (error) {
        const status = error instanceof BridgeError ? error.status : 500
        const message = error instanceof Error ? error.message : 'internal bridge error'
        sendJson(response, status, {
          ok: false,
          error: message,
          ...(error instanceof BridgeError && error.details !== undefined ? { details: safeValue(error.details) } : {}),
        })
      }
    })
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(PORT, HOST, resolve)
    })
    record('bridge-ready', { host: HOST, port: PORT })
    return () => new Promise<void>((resolve) => server.close(() => resolve()))
  }, 'devshot-agent-bridge')
}
BRIDGESOURCE
chmod 0644 /opt/devshot-cordis-agent-bridge/package.json /opt/devshot-cordis-agent-bridge/index.ts

# Every Cordis project gets one stable, project-owned result surface. The
# Cordis dashboard remains available to the runtime, while Studio and its agent
# render /result/ and edit this file instead of patching framework node_modules.
# Keep an immutable seed outside the workspace so an older project restore can
# recover the contract without overwriting user changes that are still present.
install -d -m 0755 /opt/devshot-cordis-output/src /opt/devshot-cordis-output/public
cat > /opt/devshot-cordis-output/package.json <<'OUTPUTPACKAGE'
{
  "name": "devshot-cordis-output",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "src/index.ts"
}
OUTPUTPACKAGE
cat > /opt/devshot-cordis-output/src/index.ts <<'OUTPUTSOURCE'
import { readFile } from 'node:fs/promises'

export const name = 'devshot-cordis-output'
export const inject = ['server']

const outputFile = new URL('../public/index.html', import.meta.url)

export function apply(ctx: any) {
  ctx.server.get(/^\/result(?:\/.*)?$/, async (_request: any, response: any) => {
    response.headers.set('content-type', 'text/html; charset=utf-8')
    response.headers.set('cache-control', 'no-store')
    response.text(await readFile(outputFile, 'utf8'))
  })
}
OUTPUTSOURCE
cat > /opt/devshot-cordis-output/public/index.html <<'OUTPUTHTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Cordis result</title>
    <style>
      * { box-sizing: border-box; }
      html, body { min-height: 100%; margin: 0; }
      body { background: #ffffff; color: #111827; font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    </style>
  </head>
  <body>
    <main id="app" data-cordis-output="ready"></main>
  </body>
</html>
OUTPUTHTML
chmod 0644 \
  /opt/devshot-cordis-output/package.json \
  /opt/devshot-cordis-output/src/index.ts \
  /opt/devshot-cordis-output/public/index.html

cat > /usr/local/libexec/devshot/ensure-cordis-output <<'ENSUREOUTPUT'
#!/bin/sh
set -eu
cd /var/www/cordis
install -d packages/devshot-output/src packages/devshot-output/public
[ -f packages/devshot-output/package.json ] || cp /opt/devshot-cordis-output/package.json packages/devshot-output/package.json
[ -f packages/devshot-output/src/index.ts ] || cp /opt/devshot-cordis-output/src/index.ts packages/devshot-output/src/index.ts
[ -f packages/devshot-output/public/index.html ] || cp /opt/devshot-cordis-output/public/index.html packages/devshot-output/public/index.html
if ! grep -Fq 'name: ./packages/devshot-output/src/index.ts' app.yml; then
  printf '\n- id: d3570a12\n  name: ./packages/devshot-output/src/index.ts\n' >> app.yml
fi
ENSUREOUTPUT
chmod 0755 /usr/local/libexec/devshot/ensure-cordis-output

# Build the official Cordis scaffold as the same user that later edits and runs it.
install -d -o devshot -g devshot /var/www
cat > /tmp/devshot-build-cordis.sh <<'BUILDCORDIS'
#!/bin/sh
set -eux
export HOME=/home/devshot
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

cd /var/www
CORDIS_BOILERPLATE_URL='https://registry.npmjs.org/@cordisjs/boilerplate/-/boilerplate-0.6.1.tgz'
CORDIS_BOILERPLATE_SHA256='27269f1848fa099b7a028b4977841d43f7b3e4bd8236e833027b590125497830'
wget -q -O /home/devshot/cordis-boilerplate.tgz "$CORDIS_BOILERPLATE_URL"
echo "$CORDIS_BOILERPLATE_SHA256  /home/devshot/cordis-boilerplate.tgz" | sha256sum -c -
install -d cordis
tar -xzf /home/devshot/cordis-boilerplate.tgz -C cordis --strip-components=1
rm /home/devshot/cordis-boilerplate.tgz
cd /var/www/cordis
node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));p.name='cordis';fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\\n')"

install -d external/devshot-agent-bridge/src
cp /opt/devshot-cordis-agent-bridge/package.json external/devshot-agent-bridge/package.json
cp /opt/devshot-cordis-agent-bridge/index.ts external/devshot-agent-bridge/src/index.ts
if ! grep -Fq 'name: ./external/devshot-agent-bridge/src/index.ts' app.yml; then
  printf '\n- id: d3570a11\n  name: ./external/devshot-agent-bridge/src/index.ts\n' >> app.yml
fi
/usr/local/libexec/devshot/ensure-cordis-output

# Upstream intentionally defaults to loopback. The DevShot host proxy reaches
# the guest over its VM interface, so the server must listen on every interface.
if ! grep -q '^[[:space:]]*host:[[:space:]]*0\.0\.0\.0[[:space:]]*$' app.yml; then
  sed -i '/^[[:space:]]*port:[[:space:]]*3140[[:space:]]*$/a\    host: 0.0.0.0' app.yml
fi

printf '\n# DevShot platform files (regenerated at boot)\n.devshot/\nexternal/devshot-agent-bridge/\n' >> .gitignore
npm install --no-audit --no-fund
npm run build

test -x node_modules/.bin/cordis || {
  echo 'FATAL: Cordis CLI missing after bake' >&2
  exit 1
}
npm ls --depth=0 >/dev/null 2>&1 || {
  echo 'FATAL: npm reports unsatisfied Cordis dependencies' >&2
  npm ls --depth=0 >&2
  exit 1
}
BUILDCORDIS
chmod 0755 /tmp/devshot-build-cordis.sh
# Bake VMs mount /tmp noexec; invoke the reviewed script through /bin/sh while
# retaining the unprivileged build user boundary.
su devshot -c 'sh /tmp/devshot-build-cordis.sh'
rm -f /tmp/devshot-build-cordis.sh

cat > /usr/local/bin/start-cordis <<'LAUNCHER'
#!/bin/sh
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME=/home/devshot
cd /var/www/cordis
LOG="${LOG:-/var/log/cordis.log}"

# Restore the platform bridge before dependency recovery or Cordis startup.
install -d external/devshot-agent-bridge/src
cp /opt/devshot-cordis-agent-bridge/package.json external/devshot-agent-bridge/package.json
cp /opt/devshot-cordis-agent-bridge/index.ts external/devshot-agent-bridge/src/index.ts
if ! grep -Fq 'name: ./external/devshot-agent-bridge/src/index.ts' app.yml; then
  printf '\n- id: d3570a11\n  name: ./external/devshot-agent-bridge/src/index.ts\n' >> app.yml
fi
/usr/local/libexec/devshot/ensure-cordis-output

# A healthy baked image never installs at boot. This recovery path only handles
# a workspace restore or explicit cleanup that removed node_modules.
if [ ! -x node_modules/.bin/cordis ]; then
  echo '[boot] Cordis dependencies missing; restoring them' >> "$LOG"
  if [ -f package-lock.json ]; then
    npm ci --prefer-offline --no-audit --no-fund >> "$LOG" 2>&1
  else
    npm install --prefer-offline --no-audit --no-fund >> "$LOG" 2>&1
  fi
fi

echo '[boot] starting Cordis development runtime on :3140' >> "$LOG"
exec npm run dev
LAUNCHER
chmod 0755 /usr/local/bin/start-cordis
install -o devshot -g devshot -m 0644 /dev/null /var/log/cordis.log

# QEMU user-mode DHCP can configure eth0 and its default route while leaving
# Alpine's resolver empty. The Studio agent then accepts a prompt but Grok can
# never resolve the AI gateway. Repair the resolver as root after networking:
# slirp exposes DNS on 10.0.2.3; bridged guests use their gateway's dnsmasq.
cat > /etc/init.d/devshot-dns <<'DNSINIT'
#!/sbin/openrc-run
name="devshot-dns"
description="Ensure Cordis Studio has a working DNS resolver"

depend() {
  need net
  after networking xennet
  before devshot-cordis openvscode-server
}

start() {
  if grep -Eq '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null; then
    return 0
  fi
  gateway="$(ip route show default 2>/dev/null | awk 'NR == 1 { print $3 }')"
  [ -n "$gateway" ] || { eerror "No default gateway available for DNS"; return 1; }
  dns="$gateway"
  [ "$gateway" != '10.0.2.2' ] || dns='10.0.2.3'
  printf 'nameserver %s\n' "$dns" > /etc/resolv.conf
}
DNSINIT
chmod +x /etc/init.d/devshot-dns
rc-update add devshot-dns default

cat > /etc/init.d/devshot-cordis <<'INITD'
#!/sbin/openrc-run

name="devshot-cordis"
description="DevShot Cordis application (development runtime on :3140)"
supervisor=supervise-daemon
command="/usr/local/bin/start-cordis"
command_user="devshot:devshot"
pidfile="/run/devshot-cordis.pid"
output_log="/var/log/cordis.log"
error_log="/var/log/cordis.log"
respawn_delay=3
respawn_max=0

depend() {
  need net devshot-dns
  after networking firewall
}
INITD
chmod +x /etc/init.d/devshot-cordis
rc-update add devshot-cordis default

# Restored project files must remain writable by the app, editor, and VM agent.
cat > /etc/init.d/devshot-perms <<'PERMS'
#!/sbin/openrc-run
name="devshot-perms"
description="Make /var/www owned by and writable to devshot before Cordis starts"
depend() {
  after localmount
  before devshot-cordis openvscode-server
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

# The Cordis SDK, browser verifier and editor exceed the 2 GB base filesystem.
# The bake pipeline grows this template's sparse qcow2 to disk_gb above; consume
# that capacity online before any workspace service starts. resize2fs is
# idempotent, so every clone can safely run the same one-shot service.
cat > /etc/init.d/devshot-grow-root <<'GROWROOT'
#!/sbin/openrc-run
name="devshot-grow-root"
description="Grow the Cordis root filesystem to the template disk size"
depend() {
  need localmount
  before devshot-perms devshot-cordis openvscode-server
}
start() {
  ebegin "Growing Cordis root filesystem"
  /usr/sbin/resize2fs /dev/vda
  eend $?
}
GROWROOT
chmod +x /etc/init.d/devshot-grow-root
rc-update add devshot-grow-root default

# Browser editor, matching the other Studio application templates.
OPENVSCODE_VERSION="${OPENVSCODE_VERSION:-1.95.2}"
case "$(uname -m)" in
  x86_64) OV_ARCH=x64 ;;
  aarch64) OV_ARCH=arm64 ;;
  *) echo "ERROR: unsupported architecture for openvscode-server" >&2; exit 1 ;;
esac
install -d /opt/openvscode-server
wget -q -O /tmp/openvscode.tar.gz \
  "https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OPENVSCODE_VERSION}/openvscode-server-v${OPENVSCODE_VERSION}-linux-${OV_ARCH}.tar.gz"
tar -xzf /tmp/openvscode.tar.gz -C /opt/openvscode-server --strip-components=1
rm /tmp/openvscode.tar.gz
node /opt/openvscode-server/out/server-main.js --version | head -1

install -d -o devshot -g devshot /home/devshot/.openvscode-server/data/User
install -d -o devshot -g devshot /home/devshot/.openvscode-server/data/Machine
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
  "terminal.integrated.defaultProfile.linux": "sh",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 800,
  "workbench.welcomePageOnStartup": false,
  "workbench.tips.enabled": false
}
SETTINGS
chown devshot:devshot /home/devshot/.openvscode-server/data/User/settings.json

echo /var/www/cordis > /etc/openvscode-default-folder
install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log
cat > /etc/init.d/openvscode-server <<'SVC'
#!/sbin/openrc-run

name="openvscode-server"
description="VSCode in the browser — DevShot Cordis editor"
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder 2>/dev/null || echo /var/www/cordis)"
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

# /tmp/xenstore is a live QGA mount during image baking; never sweep /tmp as a
# glob. Every recipe-owned temporary file was removed at its point of use.
rm -rf /home/devshot/.npm /home/devshot/.cache /root/.npm /var/cache/apk/*

echo "=== Cordis recipe complete ==="
node --version
npm --version
du -sh /var/www/cordis
sync
