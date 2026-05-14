#!/bin/sh
# Recipe: Hello — minimal node http server on :8080. Boots in ~50 ms,
# uses node stdlib only (no npm install), echoes request method / URL /
# headers + auto-refreshing timestamp. Built for end-to-end testing of
# the spec-051 proxy pipeline (SW → /forward channel → guest port).
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/hello.sh --name=hello
#
# Output template: devshot-guest-hello.qcow2. Post-claim, run
# `start-hello` (or `start-hello -d` for detached) to launch.
#
# Spec 050 — declares the workload's TCP listen ports so the bake
# pipeline auto-populates each spawned VM's forward allowlist.
# devshot:exposed_ports=[{"port":8080,"name":"hello","proto":"http"}]
set -eux

# Bake VMs run nested under the Mac orchestrator; their slirp DNS
# forwards to the orch's slirp, which forwards to Mac DNS. That double
# hop is reliably broken — apk's index fetch fails with "DNS: transient
# error" and `apk add nodejs` then fails with "no such package". Even
# pinning /etc/resolv.conf to 1.1.1.1 doesn't help (the same UDP NAT
# carries it).
#
# Workaround: the orch runs a tiny socat-based HTTP server on
# 0.0.0.0:8765 (apk-httpd init script) serving its `apk fetch -R`
# cache out of /xen/boot/apk-cache. The bake VM's gateway is the
# orch (10.0.2.2 from the bake's POV), so curl/wget against
# http://10.0.2.2:8765/apk-cache/<file>.apk reaches it without
# needing any external DNS. To refresh the cache, run inside the
# orch:
#   apk update
#   apk fetch -R --output /xen/boot/apk-cache nodejs ca-certificates
# Network-free apk install via 9p. vmm_qemu honors BAKE_APK_CACHE_DIR
# at VM creation and 9p-shares that host dir into the bake VM as the
# `apk_cache` mount tag. Mount it, install, done — no slirp NAT, no
# DNS, no transient transfer failures on large packages.
#
# Dockerfile prebakes run during CI image builds, not inside a bake VM, so
# no apk_cache 9p mount exists there. In that one controlled path we use
# Docker's normal networked apk install and keep the rest of the recipe
# identical to live bakes.
if [ "${DEVSHOT_RECIPE_DOCKER_BUILD:-0}" = "1" ]; then
    apk add --no-cache nodejs ca-certificates
else
    # Try the 9p apk-cache fast path; fall back to network apk if the
    # orchestrator hasn't set BAKE_APK_CACHE_DIR (= no apk_cache 9p
    # share). Linux orchestrators (sharp-ada, etc.) typically have
    # working slirp DNS so the network fallback Just Works; the 9p path
    # is the Mac-orchestrator optimization to skip DNS double-hops.
    mkdir -p /tmp/apkcache
    if mount -t 9p -o trans=virtio,version=9p2000.L,ro apk_cache /tmp/apkcache 2>/dev/null && \
       ls /tmp/apkcache/*.apk >/dev/null 2>&1; then
        ls /tmp/apkcache/*.apk 2>&1 | head -5
        apk add --no-network --allow-untrusted /tmp/apkcache/*.apk
        umount /tmp/apkcache 2>/dev/null || true
    else
        echo "9p apk_cache unavailable — falling back to networked apk add"
        umount /tmp/apkcache 2>/dev/null || true
        apk update && apk add --no-cache nodejs ca-certificates
    fi
fi

# Single-file server. node-stdlib only so install is just `apk add
# nodejs`. The same script also runs as a one-liner on any VM that
# already has node:
#   curl -fsSL <repo>/apps/agent/recipes/hello-server.js | node
mkdir -p /opt/devshot
# /opt/devshot is mode 0700 in the base image (it holds the agent
# binary in production). The recipe's payload needs to be readable
# by the unprivileged user that qemu-ga's guest-exec runs as
# (devshot:1000 in the spawned pool VM), otherwise `start-hello`
# fails with "Cannot find module '/opt/devshot/hello-server.js'"
# even though the file is right there.
chmod 0755 /opt/devshot
cat > /opt/devshot/hello-server.js << 'SERVER'
'use strict';
const http = require('http');
const os = require('os');

const PORT = Number(process.env.PORT) || 8080;
const HOST = process.env.HOST || '0.0.0.0';
const STARTED_AT = new Date().toISOString();

const PAGE = (req) => `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>DevShot Hello — ${os.hostname()}</title>
  <style>
    :root { color-scheme: light dark; }
    body { font: 14px/1.5 system-ui, sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; }
    h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
    .sub { color: #666; margin: 0 0 1.5rem; }
    .card { border: 1px solid rgba(127,127,127,.3); border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
    .card h2 { font-size: .9rem; text-transform: uppercase; letter-spacing: .05em; color: #888; margin: 0 0 .5rem; }
    pre { font: 12px/1.4 ui-monospace, monospace; background: rgba(127,127,127,.08); padding: .5rem; border-radius: 4px; overflow-x: auto; margin: 0; }
    .live { color: #0a0; }
    button { font: inherit; padding: .4rem .8rem; border-radius: 4px; border: 1px solid rgba(127,127,127,.4); background: rgba(127,127,127,.08); cursor: pointer; }
    button:hover { background: rgba(127,127,127,.18); }
    .row { display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; }
    input { font: inherit; padding: .4rem .5rem; border-radius: 4px; border: 1px solid rgba(127,127,127,.4); flex: 1; min-width: 200px; }
    .ok { color: #0a0; }
    .err { color: #a00; }
  </style>
</head>
<body>
  <h1>👋 Hello from <code>${os.hostname()}</code></h1>
  <p class="sub">DevShot proxy debug page · started ${STARTED_AT} · ${process.platform}/${process.arch} · node ${process.versions.node}</p>

  <div class="card">
    <h2>Live clock <span class="live">● streaming</span></h2>
    <p>Server time: <code id="now">…</code></p>
    <p style="font-size:12px;color:#888">Updates every second via Server-Sent Events on <code>/api/sse</code>. If the value moves, SSE through the proxy works.</p>
  </div>

  <div class="card">
    <h2>Request that loaded this page</h2>
    <pre>${escapeHtml(req.method)} ${escapeHtml(req.url)}
${Object.entries(req.headers).map(([k,v]) => `${k}: ${v}`).join('\n')}</pre>
  </div>

  <div class="card">
    <h2>POST echo test</h2>
    <div class="row">
      <input id="echo-in" placeholder="Type something and Send" value="hello world">
      <button id="echo-btn">Send POST</button>
    </div>
    <pre id="echo-out" style="margin-top:.5rem">(no response yet)</pre>
  </div>

  <div class="card">
    <h2>Useful endpoints</h2>
    <ul>
      <li><a href="/api/json">/api/json</a> — JSON dump of request / hostname / time</li>
      <li><code>/api/sse</code> — Server-Sent Events stream (1 Hz)</li>
      <li><code>POST /api/echo</code> — echoes back the request body</li>
      <li><code>/api/headers</code> — dumps the request headers as plain text</li>
    </ul>
  </div>

<script>
const evtSource = new EventSource('/api/sse');
evtSource.onmessage = (e) => { document.getElementById('now').textContent = e.data; };
evtSource.onerror = () => { document.getElementById('now').textContent = '(SSE disconnected)'; };

document.getElementById('echo-btn').addEventListener('click', async () => {
  const out = document.getElementById('echo-out');
  out.textContent = '(sending…)';
  try {
    const body = document.getElementById('echo-in').value;
    const r = await fetch('/api/echo', { method: 'POST', headers: { 'content-type': 'text/plain' }, body });
    const text = await r.text();
    out.textContent = 'HTTP ' + r.status + '\\n' + text;
    out.className = r.ok ? 'ok' : 'err';
  } catch (e) {
    out.textContent = 'ERROR: ' + e.message;
    out.className = 'err';
  }
});
</script>
</body>
</html>`;

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
}

const server = http.createServer((req, res) => {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${req.method} ${req.url}`);

  if (req.url === '/api/json') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      hostname: os.hostname(),
      method: req.method,
      url: req.url,
      headers: req.headers,
      time: ts,
      pid: process.pid,
      uptime_s: Math.round(process.uptime()),
      node: process.versions.node,
    }, null, 2));
    return;
  }

  if (req.url === '/api/headers') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\n') + '\n');
    return;
  }

  if (req.url === '/api/echo' && req.method === 'POST') {
    let body = Buffer.alloc(0);
    req.on('data', (c) => { body = Buffer.concat([body, c]); });
    req.on('end', () => {
      res.writeHead(200, { 'content-type': req.headers['content-type'] || 'text/plain' });
      res.end(body);
    });
    return;
  }

  if (req.url === '/api/sse') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache, no-transform',
      'connection': 'keep-alive',
      'x-accel-buffering': 'no',
    });
    const tick = () => {
      res.write(`data: ${new Date().toISOString()}\n\n`);
    };
    tick();
    const iv = setInterval(tick, 1000);
    req.on('close', () => clearInterval(iv));
    return;
  }

  // Calculator demo page — driven by Playwright uptime tests. Minimal
  // arithmetic-only expression evaluator: matches the same /calc endpoint
  // exposed by the local hello-server.js mirror so a single workload covers
  // both Hello and Calculator app launches without baking a second template.
  if (req.url === '/calc' || req.url.startsWith('/calc?')) {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>DevShot Calculator</title>
<style>body{font:14px/1.5 system-ui;max-width:360px;margin:2rem auto;padding:0 1rem}h1{font-size:1.2rem;margin:0 0 1rem}input,button{font:inherit;padding:.5rem;border-radius:4px;border:1px solid #888;background:#fff;color:#000}input{width:100%;margin-bottom:.5rem}button{cursor:pointer;background:#0a0;color:#fff;border:0;padding:.5rem 1rem}.result{font-size:1.5rem;font-family:ui-monospace,monospace;margin-top:1rem;padding:.75rem;border:1px solid #888;border-radius:4px;min-height:1.5em}</style>
</head><body>
  <h1>🧮 Calculator</h1>
  <input id="expr" data-testid="calc-expr" placeholder="3+5" autocomplete="off" />
  <button id="eq" data-testid="calc-equals" type="button">=</button>
  <div class="result" id="result" data-testid="calc-result"></div>
<script>
// Arithmetic-only eval: digits, ops, parens, decimal points, whitespace.
// Matches the same allowlist used by the recipe so server and embedded
// tests agree.
function calc(expr){
  if (!/^[\\d+\\-*/().\\s]+$/.test(expr)) return 'invalid';
  try { return String(Function('return (' + expr + ')')()); } catch { return 'invalid'; }
}
const $ = (id) => document.getElementById(id);
function run() { $('result').textContent = calc($('expr').value.trim()); }
$('eq').addEventListener('click', run);
$('expr').addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
</script>
</body></html>`);
    return;
  }

  // Default: HTML hello page.
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(PAGE(req));
});

server.listen(PORT, HOST, () => {
  console.log(`hello-server listening on ${HOST}:${PORT}`);
});

process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
process.on('SIGINT',  () => { server.close(() => process.exit(0)); });
SERVER
chmod 0644 /opt/devshot/hello-server.js

# Launcher matches the start-n8n / start-flowise convention.
cat > /usr/local/bin/start-hello << 'LAUNCHER'
#!/bin/sh
# Start the DevShot hello-world debug server. Pass -d to run detached.
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi
export HOST=0.0.0.0
export PORT="${PORT:-8080}"
LOG="${LOG:-/tmp/hello.log}"
if [ "$detached" = "1" ]; then
    nohup node /opt/devshot/hello-server.js > "$LOG" 2>&1 &
    echo "hello-server started in background — log: $LOG"
    echo "Listening on :$PORT"
else
    exec node /opt/devshot/hello-server.js
fi
LAUNCHER
chmod 0755 /usr/local/bin/start-hello

# ── OpenRC service: auto-start hello-server on boot ────────────────────
# Why: the AppsTab "Launch Hello" flow previously relied on a post-claim
# /api/vms/<vm>/exec call to kick `start-hello -d`. That exec rides the
# QGA virtio-serial channel — which is single-threaded, can wedge under
# contention, and has no observable retry path. When the exec timed out
# (or the channel was busy), the iframe loaded against a port nothing
# was listening on and the user saw the SW upstream-timeout page.
#
# Same fix as the desktop recipe: bring the workload up via OpenRC at
# boot, so the moment the VM reaches "ready" the forward chain finds a
# live :8080. The console-side `startWorkloadInVM` exec is kept as a
# best-effort kick for the very-first-second-after-claim case but is
# no longer load-bearing.
cat > /etc/init.d/devshot-hello <<'INITD'
#!/sbin/openrc-run

description="DevShot hello-server (node http on :8080)"

depend() {
    need net
    after networking
}

start() {
    ebegin "Starting DevShot hello-server"
    /usr/local/bin/start-hello -d
    eend $?
}

stop() {
    ebegin "Stopping DevShot hello-server"
    pkill -f 'node .*hello-server.js' 2>/dev/null || true
    eend 0
}

status() {
    if pgrep -f 'node .*hello-server.js' >/dev/null 2>&1; then
        einfo "running (hello-server :8080 alive)"
        return 0
    fi
    einfo "stopped"
    return 3
}
INITD
chmod +x /etc/init.d/devshot-hello
rc-update add devshot-hello default

echo "=== Hello recipe complete ==="
node --version
ls -la /opt/devshot/hello-server.js /usr/local/bin/start-hello
# Force the kernel to flush dirty pages before the bake VM is shut
# down. Without this, the bakery sometimes records a successful recipe
# but the resulting qcow2 has none of the recipe's writes — the VM is
# force-destroyed during the QGA-shutdown fallback before fsync runs,
# so the in-flight blocks never reach disk. With sync the bake commit
# always sees the fully-installed image.
sync
