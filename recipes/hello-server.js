'use strict';
// DevShot hello-world debug server. Pure node stdlib (no npm), suitable
// for end-to-end testing the spec-051 proxy pipeline (browser SW →
// /forward channel → guest port).
//
// One-liner from any VM that has node:
//   curl -fsSL <repo-url>/apps/agent/recipes/hello-server.js | node
//
// Or, if the file is already on disk:
//   PORT=8080 node hello-server.js
//
// Endpoints:
//   GET  /              → HTML hello page (live clock via SSE,
//                         POST-echo button, request dump)
//   GET  /api/json      → JSON: hostname, request, headers, time
//   GET  /api/headers   → request headers as plain text
//   GET  /api/sse       → 1 Hz Server-Sent Events stream
//   POST /api/echo      → echoes the request body back

const http = require('http');
const os = require('os');

const PORT = Number(process.env.PORT) || 8080;
const HOST = process.env.HOST || '0.0.0.0';
const STARTED_AT = new Date().toISOString();

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
}

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
${Object.entries(req.headers).map(([k,v]) => `${escapeHtml(k)}: ${escapeHtml(v)}`).join('\n')}</pre>
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
    const tick = () => { res.write(`data: ${new Date().toISOString()}\n\n`); };
    tick();
    const iv = setInterval(tick, 1000);
    req.on('close', () => clearInterval(iv));
    return;
  }

  // Calculator demo (mirrors the recipe path) — Playwright uptime tests
  // open /calc, type into [data-testid="calc-expr"], click [data-testid=
  // "calc-equals"], and assert the [data-testid="calc-result"] text.
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

  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(PAGE(req));
});

server.listen(PORT, HOST, () => {
  console.log(`hello-server listening on ${HOST}:${PORT}`);
});

process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
process.on('SIGINT',  () => { server.close(() => process.exit(0)); });
