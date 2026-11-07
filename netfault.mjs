#!/usr/bin/env node
// bridge/netfault.mjs - TCP proxy with deterministic fault injection (simulate a dead/silent link).
//
// Purpose: test the client's "passive timeout + /tip probe" reconnect detection WITHOUT touching
// real matchmaking and WITHOUT patching the client. Point the guest client at this proxy
// (`-p 7912` instead of `-p 7911`); then toggle link faults from another shell.
//
// TOPOLOGY
//   guest client ── TCP 127.0.0.1:7912 ──► [netfault] ── TCP 127.0.0.1:7911 ──► host client (LAN server)
//                                            ▲
//                     HTTP control 127.0.0.1:7913 (status / mode / log)
//
// MODES (POST /mode?m=...)
//   normal  forward bytes both ways (default)
//   freeze  do NOT forward anything, but keep every socket open -> the client gets neither data
//           nor EOF: that is the "silent dead link" case. Bytes arriving while frozen are
//           DROPPED and counted as droppedBytes (we intentionally do not buffer them: a real
//           dead link does not replay stale data after recovery).
//   drop    one-shot: destroy every live connection immediately (both ends see the close), then
//           go back to `normal` so the client's reconnect can actually succeed. (The task calls it
//           a mode; behaviour-wise it is a one-shot action, so /status reports `normal` again.)
//   reject  every NEW connection is closed immediately (connection refused-ish); existing ones
//           stay. Use it to test "cannot connect at all" vs "connected but silent".
//
// HTTP (127.0.0.1:7913)
//   GET  /status                          -> {listen, upstream, ctrl, mode, connections, ..., bytesUp, bytesDown, droppedBytes}
//   POST /mode?m=normal|freeze|drop|reject
//   POST /thaw                            -> same as /mode?m=normal
//   GET  /log?tail=N                      -> {"lines":[...]} most recent N event lines
//   GET  /help                            -> short plain-text usage
//
// CLI
//   node bridge/netfault.mjs [--listen 7912] [--upstream 127.0.0.1:7911] [--ctrl 7913]
//                            [--log-size 500] [--verbose]
//
// Pure Node (18+), no dependencies. Logs go to stderr AND to an in-memory ring buffer (/log).
// SIGINT / SIGTERM shut everything down gracefully.

import net from 'node:net';
import http from 'node:http';
import process from 'node:process';

// ------------------------------------------------------------------ CLI
const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
};
const parseHostPort = (s, dfltHost, dfltPort) => {
  const str = String(s || '');
  if (!str.includes(':')) return { host: dfltHost, port: Number(str) || dfltPort };
  const i = str.lastIndexOf(':');
  return { host: str.slice(0, i), port: Number(str.slice(i + 1)) || dfltPort };
};

const listenAddr = parseHostPort(opt('listen', 7912), '127.0.0.1', 7912);
const upstreamAddr = parseHostPort(opt('upstream', '127.0.0.1:7911'), '127.0.0.1', 7911);
const ctrlAddr = parseHostPort(opt('ctrl', 7913), '127.0.0.1', 7913);
const LOG_SIZE = Math.max(20, Number(opt('log-size', 500)) || 500);
const VERBOSE = !!opt('verbose', false);

// ------------------------------------------------------------------ state
const T0 = Date.now();
const st = {
  mode: 'normal',            // normal | freeze | reject   (drop is one-shot)
  connections: 0,
  totalConnections: 0,
  bytesUp: 0,                // client -> upstream
  bytesDown: 0,              // upstream -> client
  droppedBytes: 0,           // arrived while frozen, deliberately discarded
  droppedUp: 0,
  droppedDown: 0,
  droppedConnections: 0,     // destroyed by mode=drop
  rejectedConnections: 0,    // closed by mode=reject
  upstreamErrors: 0,
  clientErrors: 0,
  lastModeChangeAt: new Date().toISOString(),
};

const logRing = [];
function stamp() {
  const d = new Date();
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  const ms = String(d.getMilliseconds()).padStart(3, '0');
  return `${hh}:${mm}:${ss}.${ms}`;
}
function log(msg) {
  const line = `[${stamp()}] ${msg}`;
  logRing.push(line);
  while (logRing.length > LOG_SIZE) logRing.shift();
  process.stderr.write(line + '\n');
}
const dbg = (msg) => { if (VERBOSE) log(msg); };

// ------------------------------------------------------------------ live connections
let nextConnId = 1;
const live = new Map();   // id -> { id, client, upstream, openedAt, upBytes, downBytes }

function attach(conn) {
  const { client, upstream } = conn;

  client.on('data', (chunk) => {
    if (st.mode === 'freeze') {
      st.droppedBytes += chunk.length;
      st.droppedUp += chunk.length;
      dbg(`conn#${conn.id} freeze: dropped ${chunk.length}B upstream-ward`);
      return;
    }
    st.bytesUp += chunk.length;
    conn.upBytes += chunk.length;
    if (!upstream.destroyed) upstream.write(chunk);
  });

  upstream.on('data', (chunk) => {
    if (st.mode === 'freeze') {
      st.droppedBytes += chunk.length;
      st.droppedDown += chunk.length;
      dbg(`conn#${conn.id} freeze: dropped ${chunk.length}B downstream-ward`);
      return;
    }
    st.bytesDown += chunk.length;
    conn.downBytes += chunk.length;
    if (!client.destroyed) client.write(chunk);
  });

  const close = (who) => {
    if (!live.has(conn.id)) return;      // already cleaned up
    live.delete(conn.id);
    st.connections = live.size;
    log(`conn#${conn.id} closed by ${who} after ${Date.now() - conn.openedAt}ms ` +
      `(up=${conn.upBytes}B down=${conn.downBytes}B, live=${live.size})`);
  };

  client.on('error', (e) => {
    st.clientErrors++;
    dbg(`conn#${conn.id} client error: ${e.code || e.message}`);
  });
  client.on('close', () => {
    if (!upstream.destroyed) upstream.destroy();
    close('client');
  });
  upstream.on('close', () => {
    if (!client.destroyed) client.destroy();
    close('upstream');
  });
}

function destroyAll(reason) {
  const n = live.size;
  for (const conn of [...live.values()]) {
    try { conn.client.destroy(); } catch { /* ignore */ }
    try { conn.upstream.destroy(); } catch { /* ignore */ }
  }
  live.clear();
  st.connections = 0;
  return n;
}

// ------------------------------------------------------------------ TCP proxy
const server = net.createServer({ allowHalfOpen: false }, (client) => {
  const id = nextConnId++;
  const peer = `${client.remoteAddress}:${client.remotePort}`;

  if (st.mode === 'reject') {
    st.rejectedConnections++;
    log(`conn#${id} REJECTED (mode=reject) peer=${peer}`);
    client.destroy();
    return;
  }

  const upstream = net.connect({ host: upstreamAddr.host, port: upstreamAddr.port });
  const conn = { id, client, upstream, openedAt: Date.now(), upBytes: 0, downBytes: 0 };
  live.set(id, conn);
  st.connections = live.size;
  st.totalConnections++;
  log(`conn#${id} open peer=${peer} -> upstream ${upstreamAddr.host}:${upstreamAddr.port} ` +
    `(live=${live.size}, mode=${st.mode})`);

  upstream.on('connect', () => dbg(`conn#${id} upstream connected`));
  upstream.on('error', (e) => {
    log(`conn#${id} upstream error ${e.code || e.message} -> closing client`);
    try { client.destroy(); } catch { /* ignore */ }
  });
  attach(conn);
});

server.on('error', (e) => {
  log(`FATAL tcp server error: ${e.code || e.message}`);
  process.exit(1);
});

server.listen(listenAddr.port, listenAddr.host, () => {
  log(`netfault listening tcp ${listenAddr.host}:${listenAddr.port} -> ${upstreamAddr.host}:${upstreamAddr.port}`);
  log(`netfault ctrl http ${ctrlAddr.host}:${ctrlAddr.port}  (mode=${st.mode})`);
});

// ------------------------------------------------------------------ HTTP control
function json(res, code, obj) {
  const body = JSON.stringify(obj, null, 2);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

const VALID_MODES = new Set(['normal', 'freeze', 'drop', 'reject']);
function setMode(m) {
  if (m === 'drop') {
    const n = destroyAll('mode=drop');
    st.droppedConnections += n;
    st.mode = 'normal';                       // one-shot; a reconnect must be able to succeed
    st.lastModeChangeAt = new Date().toISOString();
    log(`MODE drop -> destroyed ${n} live connection(s); mode back to normal`);
    return { ok: true, mode: st.mode, dropped: n, note: 'drop is one-shot; mode is back to normal' };
  }
  if (m === 'freeze' && st.mode !== 'freeze') {
    log(`MODE freeze -> keep ${live.size} connection(s) open but stop forwarding ` +
      `(data will be dropped, not buffered)`);
  }
  if (m === 'reject' && st.mode !== 'reject') log('MODE reject -> new connections will be closed immediately');
  if (m === 'normal' && st.mode !== 'normal') log(`MODE normal -> forwarding resumed (live=${live.size})`);
  st.mode = m;
  st.lastModeChangeAt = new Date().toISOString();
  return { ok: true, mode: st.mode };
}

const ctrl = http.createServer((req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);
  const path = url.pathname.replace(/\/+$/, '') || '/';
  const q = url.searchParams;
  const allowAny = req.method === 'POST' || req.method === 'GET';

  if (path === '/status' && allowAny) {
    return json(res, 200, {
      listen: `${listenAddr.host}:${listenAddr.port}`,
      upstream: `${upstreamAddr.host}:${upstreamAddr.port}`,
      ctrl: `${ctrlAddr.host}:${ctrlAddr.port}`,
      mode: st.mode,
      connections: live.size,
      totalConnections: st.totalConnections,
      bytesUp: st.bytesUp,
      bytesDown: st.bytesDown,
      droppedBytes: st.droppedBytes,
      droppedUp: st.droppedUp,
      droppedDown: st.droppedDown,
      droppedConnections: st.droppedConnections,
      rejectedConnections: st.rejectedConnections,
      upstreamErrors: st.upstreamErrors,
      clientErrors: st.clientErrors,
      lastModeChangeAt: st.lastModeChangeAt,
      uptimeMs: Date.now() - T0,
      connectionsDetail: [...live.values()].map((c) => ({
        id: c.id, openedAt: c.openedAt, ageMs: Date.now() - c.openedAt, upBytes: c.upBytes, downBytes: c.downBytes,
      })),
    });
  }

  if ((path === '/mode' || path === '/thaw') && allowAny) {
    const m = path === '/thaw' ? 'normal' : String(q.get('m') || '').toLowerCase();
    if (!VALID_MODES.has(m)) {
      return json(res, 400, { ok: false, error: `bad mode: ${q.get('m')}`, validModes: [...VALID_MODES] });
    }
    return json(res, 200, setMode(m));
  }

  if (path === '/log' && allowAny) {
    const n = Math.max(1, Math.min(LOG_SIZE, Number(q.get('tail') || 50) || 50));
    return json(res, 200, { lines: logRing.slice(-n), count: Math.min(n, logRing.length) });
  }

  if (path === '/help' && allowAny) {
    const text = [
      'netfault control:',
      '  GET  /status',
      '  POST /mode?m=normal|freeze|drop|reject   (GET also accepted)',
      '  POST /thaw                               (= /mode?m=normal)',
      '  GET  /log?tail=N',
      'mode=freeze keeps sockets open but drops all bytes; mode=drop is one-shot (destroys live connections);',
      'mode=reject closes NEW connections immediately.',
    ].join('\n');
    res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
    return res.end(text + '\n');
  }

  json(res, 404, { ok: false, error: `unknown path ${path}`, help: 'GET /help' });
});

ctrl.on('error', (e) => {
  log(`FATAL ctrl http error: ${e.code || e.message}`);
  process.exit(1);
});
ctrl.listen(ctrlAddr.port, ctrlAddr.host, () => {
  log(`netfault ctrl ready: http://${ctrlAddr.host}:${ctrlAddr.port}/status`);
});

// ------------------------------------------------------------------ shutdown
let shuttingDown = false;
function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`shutdown (${sig}): destroying ${live.size} connection(s), ` +
    `total=${st.totalConnections} up=${st.bytesUp}B down=${st.bytesDown}B dropped=${st.droppedBytes}B`);
  try { server.close(); } catch { /* ignore */ }
  try { ctrl.close(); } catch { /* ignore */ }
  destroyAll('shutdown');
  setTimeout(() => process.exit(0), 50).unref?.();
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => shutdown(sig));
process.on('uncaughtException', (e) => { log(`uncaughtException: ${e && e.stack || e}`); });
process.on('unhandledRejection', (e) => { log(`unhandledRejection: ${e}`); });

console.log(`netfault: tcp ${listenAddr.host}:${listenAddr.port} -> ${upstreamAddr.host}:${upstreamAddr.port}`);
console.log(`netfault: ctrl http://${ctrlAddr.host}:${ctrlAddr.port}/status  (GET /help for usage)`);
