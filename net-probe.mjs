#!/usr/bin/env node
// bridge/net-probe.mjs - poll the client's read-only GET /net and print a timeline CSV.
//
// Purpose: quantify "how long does the client take to notice the link is dead?" without touching
// the client, the duel, or any other process. Read-only: it only GETs /net (and never POSTs).
//
// OUTPUT
//   stdout : CSV rows (header first), plus `EVENT DEAD ...` / `EVENT ALIVE ...` marker lines and a
//            final `SUMMARY {...}` line. So stdout is a log, not a pure CSV file.
//   --csv  : the pure CSV file (header + rows only; safe to open in Excel / feed to scripts).
//
// CSV COLUMNS (fixed order)
//   ts,elapsed_ms,alive,sinceLastStoc,rttMs,fails,connected,closeReason,inDuel,turn,probeState
//   ts              ISO-8601 UTC timestamp of the sample
//   elapsed_ms      ms since the probe started
//   alive           true|false (empty when the client does not expose it)
//   sinceLastStoc   ms since the last server->client packet (empty when unknown)
//   rttMs           probe round-trip time reported by the client (empty when unknown)
//   fails           consecutive probe failures reported by the client
//   connected       true|false (client's own socket state)
//   closeReason     last socket close reason text (quoted, commas escaped)
//   inDuel          true|false
//   turn            duel turn
//   probeState      client detection state: healthy|idle|probing|probe_failed|confirmed_dead,
//                   or net-unavailable / http-error when /net could not be read
//
// EVENTS
//   EVENT DEAD at t=<ms> (sinceLastStoc=<v>, fails=<v>, state=<probeState>)
//   EVENT ALIVE at t=<ms> (after <ms>ms)
//
// USAGE
//   node bridge/net-probe.mjs --port 7789 --interval 500 --duration 60000 --csv ranked/logs/net.csv
//   node bridge/net-probe.mjs --port 7789 --duration 0        # run until Ctrl+C
//
// FLAGS
//   --port N        client control port (default 7789)
//   --host          base URL (default http://127.0.0.1)
//   --interval MS   sample interval (default 500)
//   --duration MS   stop after MS (default 60000; 0 = until SIGINT)
//   --csv PATH      also write a pure CSV file (overwrites; use --append to append without header)
//   --append        append to --csv instead of truncating
//   --summary PATH  also write the final summary JSON to PATH
//   --timeout MS    per-request timeout (default 1500)
//   --quiet         do not echo CSV rows to stdout (EVENT/SUMMARY lines still printed)
//   --no-header     omit the CSV header on stdout
//
// Field shapes: tolerates both the design-contract shape (RECONNECT-DESIGN.md §2.1:
// sinceLastStocMs / probe.failStreak / state) and the short shape used by supervisor.mjs
// (sinceLastStoc / probe.fails / alive), so it works with either client build.
//
// Pure Node (18+), no dependencies. SIGINT prints the summary and exits 0.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

// ------------------------------------------------------------------ args
const argv = process.argv.slice(2);
function has(name) { return argv.includes('--' + name); }
function opt(name, dflt) {
  const i = argv.indexOf('--' + name);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}
const CFG = {
  port: Number(opt('port', 7789)),
  host: String(opt('host', 'http://127.0.0.1')).replace(/\/+$/, ''),
  intervalMs: Math.max(50, Number(opt('interval', 500))),
  durationMs: Number(opt('duration', 60000)),
  csvPath: opt('csv', null) ? path.resolve(String(opt('csv'))) : null,
  append: has('append'),
  summaryPath: opt('summary', null) ? path.resolve(String(opt('summary'))) : null,
  timeoutMs: Math.max(100, Number(opt('timeout', 1500))),
  quiet: has('quiet'),
  noHeader: has('no-header'),
};
if (!Number.isFinite(CFG.port) || CFG.port <= 0) { console.error('bad --port'); process.exit(2); }
if (!Number.isFinite(CFG.durationMs) || CFG.durationMs < 0) { console.error('bad --duration'); process.exit(2); }

const BASE = `${CFG.host}:${CFG.port}`;
const T0 = Date.now();
const COLS = ['ts', 'elapsed_ms', 'alive', 'sinceLastStoc', 'rttMs', 'fails', 'connected', 'closeReason', 'inDuel', 'turn', 'probeState'];

// ------------------------------------------------------------------ helpers
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = () => new Date().toISOString();
function cell(v) {
  if (v === undefined || v === null) return '';
  const s = String(v);
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
function rowLine(o) { return COLS.map((c) => cell(o[c])).join(','); }

function out(line) {
  try { process.stdout.write(line + '\n'); } catch { /* ignore EPIPE */ }
}

let csvFd = null;
function openCsv() {
  if (!CFG.csvPath) return;
  try {
    fs.mkdirSync(path.dirname(CFG.csvPath), { recursive: true });
    csvFd = fs.openSync(CFG.csvPath, CFG.append ? 'a' : 'w');
    if (!CFG.append) fs.writeSync(csvFd, COLS.join(',') + '\n');
  } catch (e) {
    console.error(`[net-probe] cannot open ${CFG.csvPath}: ${e.message} (CSV file disabled)`);
    csvFd = null;
  }
}
function writeCsv(line) {
  if (csvFd === null) return;
  try { fs.writeSync(csvFd, line + '\n'); } catch { /* ignore */ }
}

async function getNet() {
  const t = Date.now();
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), CFG.timeoutMs);
  try {
    const res = await fetch(`${BASE}/net`, { method: 'GET', signal: ac.signal });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* not json */ }
    return { ok: res.ok, status: res.status, json, ms: Date.now() - t, error: null };
  } catch (e) {
    return { ok: false, status: 0, json: null, ms: Date.now() - t, error: e.name === 'AbortError' ? 'timeout' : String(e.message || e) };
  } finally {
    clearTimeout(timer);
  }
}

/** tolerant field extraction: supports both documented shapes */
function extract(net, res) {
  const n = net || {};
  const probe = n.probe || {};
  const pick = (...vals) => vals.find((v) => v !== undefined && v !== null && v !== '');
  const state = pick(n.state, probe.state, null);
  let alive = n.alive;
  if (alive === undefined || alive === null) {
    if (state === 'confirmed_dead') alive = false;
    else if (state === 'healthy' || state === 'idle' || state === 'probing' || state === 'probe_failed') alive = true;
  }
  const ts = n.sinceLastStoc !== undefined ? n.sinceLastStoc : n.sinceLastStocMs;
  return {
    alive: alive === undefined || alive === null ? '' : (alive ? 'true' : 'false'),
    sinceLastStoc: ts === undefined || ts === null ? '' : ts,
    rttMs: pick(probe.rttMs, n.rttMs, ''),
    fails: pick(probe.fails, probe.failStreak, ''),
    connected: n.connected === undefined || n.connected === null ? '' : (n.connected ? 'true' : 'false'),
    closeReason: pick(n.closeReason, n.lastError, probe.lastError, ''),
    inDuel: n.inDuel === undefined || n.inDuel === null ? '' : (n.inDuel ? 'true' : 'false'),
    turn: n.turn === undefined || n.turn === null ? '' : n.turn,
    probeState: res.ok ? (state || '') : (res.status === 404 ? 'net-unavailable' : 'http-error'),
  };
}

// ------------------------------------------------------------------ state
const stats = {
  samples: 0,
  httpErrors: 0,
  netUnavailable: 0,
  firstSampleAt: null,
  deadCount: 0,
  aliveCount: 0,
  firstDeadAt: null,
  lastAliveAt: null,
  maxSinceLastStoc: 0,
  maxFails: 0,
  lastState: null,
  lastAlive: null,
  stopped: false,
};

function onSample(rec, elapsed) {
  // transition detection: deadNow is true when alive=false or the client says confirmed_dead
  const deadNow = rec.alive === 'false' || rec.probeState === 'confirmed_dead';
  if (stats.lastAlive === null) {
    stats.lastAlive = !deadNow;
    if (deadNow) stats.deadCount++;
  } else if (deadNow && stats.lastAlive === true) {
    stats.lastAlive = false;
    stats.deadCount++;
    if (stats.firstDeadAt === null) stats.firstDeadAt = elapsed;
    out(`EVENT DEAD at t=${elapsed}ms (sinceLastStoc=${rec.sinceLastStoc || '?'}, fails=${rec.fails || '?'}, state=${rec.probeState || '?'})`);
  } else if (!deadNow && stats.lastAlive === false) {
    stats.lastAlive = true;
    stats.aliveCount++;
    stats.lastAliveAt = elapsed;
    out(`EVENT ALIVE at t=${elapsed}ms (after ${stats.firstDeadAt === null ? '?' : elapsed - stats.firstDeadAt}ms)`);
  }
  if (rec.probeState !== stats.lastState) {
    if (rec.probeState) out(`# state ${stats.lastState === null ? '(start)' : stats.lastState} -> ${rec.probeState} at t=${elapsed}ms`);
    stats.lastState = rec.probeState;
  }
  const stall = Number(rec.sinceLastStoc);
  if (Number.isFinite(stall) && stall > stats.maxSinceLastStoc) stats.maxSinceLastStoc = stall;
  const fails = Number(rec.fails);
  if (Number.isFinite(fails) && fails > stats.maxFails) stats.maxFails = fails;
}

// ------------------------------------------------------------------ main loop
function summaryObject() {
  return {
    base: BASE,
    samples: stats.samples,
    durationMs: Date.now() - T0,
    intervalMs: CFG.intervalMs,
    httpErrors: stats.httpErrors,
    netUnavailable: stats.netUnavailable,
    deadCount: stats.deadCount,
    aliveRecoveries: stats.aliveCount,
    firstDeadAtMs: stats.firstDeadAt,
    lastAliveAtMs: stats.lastAliveAt,
    maxSinceLastStoc: stats.maxSinceLastStoc,
    maxFails: stats.maxFails,
    lastState: stats.lastState,
    csv: CFG.csvPath,
  };
}

function finish(reason) {
  if (stats.stopped) return;
  stats.stopped = true;
  const s = summaryObject();
  out(`SUMMARY ${JSON.stringify(s)}`);
  if (CFG.summaryPath) {
    try {
      fs.mkdirSync(path.dirname(CFG.summaryPath), { recursive: true });
      fs.writeFileSync(CFG.summaryPath, JSON.stringify(s, null, 2) + '\n');
    } catch (e) { console.error(`[net-probe] cannot write summary: ${e.message}`); }
  }
  if (csvFd !== null) { try { fs.closeSync(csvFd); } catch { /* ignore */ } csvFd = null; }
  console.error(`[net-probe] stop (${reason}) samples=${s.samples} dead=${s.deadCount} firstDeadAt=${s.firstDeadAtMs === null ? '-' : s.firstDeadAtMs + 'ms'} httpErrors=${s.httpErrors}`);
}

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => { finish(sig); process.exit(0); });
}

openCsv();
if (!CFG.noHeader) out(COLS.join(','));
console.error(`[net-probe] polling ${BASE}/net every ${CFG.intervalMs}ms` +
  (CFG.durationMs > 0 ? ` for ${CFG.durationMs}ms` : ' until SIGINT') +
  (CFG.csvPath ? `; csv=${CFG.csvPath}` : ''));

const stopAt = CFG.durationMs > 0 ? T0 + CFG.durationMs : Infinity;
while (!stats.stopped && Date.now() < stopAt) {
  const startedAt = Date.now();
  const res = await getNet();
  const elapsed = startedAt - T0;
  stats.samples++;
  if (stats.firstSampleAt === null) stats.firstSampleAt = elapsed;
  if (!res.ok) {
    stats.httpErrors++;
    if (res.status === 404) stats.netUnavailable++;
  }
  const rec = { ts: iso(), elapsed_ms: elapsed, ...extract(res.json, res) };
  onSample(rec, elapsed);
  const line = rowLine(rec);
  writeCsv(line);
  if (!CFG.quiet) out(line);
  const spent = Date.now() - startedAt;
  const wait = Math.max(0, CFG.intervalMs - spent);
  if (Date.now() + wait >= stopAt) { await sleep(Math.max(0, stopAt - Date.now())); break; }
  await sleep(wait);
}

finish('duration-reached');
process.exit(0);
