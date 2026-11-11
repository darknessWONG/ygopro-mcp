#!/usr/bin/env node
// bridge/doctor.mjs - self-check for the YGOPro control-layer bridge.
//
// It only READS the client's control API (GET /health, /state, /net, /ui). It never starts a client,
// never sends an action, and never writes anything.
//
// Usage:
//   node doctor.mjs                      # probe http://127.0.0.1:7788 (host position)
//   node doctor.mjs --port 7789          # guest position
//   node doctor.mjs --client "C:\path\YGOPro.exe"   # also fingerprint the client binary
//   node doctor.mjs --json               # machine-readable output only
//
// Output: human-readable [GREEN]/[YELLOW]/[RED]/[INFO] lines + a JSON block; exit 0 only when the
// bridge is fully usable (client reachable + /health + /state + /net), otherwise exit 1 with hints.

import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);

const argv = process.argv.slice(2);
function opt(name, dflt) {
  const i = argv.indexOf('--' + name);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}
const envBase = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const cliPort = opt('port', null);
const HOST = String(opt('host', envBase.replace(/:\d+\/?$/, ''))).replace(/\/+$/, '');
const PORT = Number(cliPort || (envBase.match(/:(\d+)/) || [])[1] || 7788);
const BASE = `${HOST}:${PORT}`;
const CLIENT_EXE = opt('client', null);
const JSON_ONLY = argv.includes('--json');
// --strict-build: compare size AND sha256 (release self-check). Default compares size only, which is
// portable across machines/timezones/copies; sha256 is the stable way to tell two builds of the same
// size apart (a real case: 22:51:31 and 00:07:02 are both 6,295,040 B).
const STRICT_BUILD = argv.includes('--strict-build');
const TIMEOUT = Math.max(200, Number(opt('timeout', 1500)) || 1500);

// Fingerprint of the client build this bridge is developed/tested against (see README).
const EXPECTED = {
  size: 6312448,
  mtime: '2026-11-11 13:14:33',
  sha256: '60D07673F3D968CC28ADC2B89BB9C77278A0E10CC8A8C2862E12C8D0F359141E',
};

const C = { green: (s) => `[GREEN]  ${s}`, yellow: (s) => `[YELLOW] ${s}`, red: (s) => `[RED]    ${s}`, info: (s) => `[INFO]   ${s}` };

async function getJson(path) {
  const t = Date.now();
  try {
    const res = await fetch(BASE + path, { signal: AbortSignal.timeout(TIMEOUT) });
    let data = null;
    const text = await res.text();
    try { data = JSON.parse(text); } catch { data = { raw: String(text).slice(0, 200) }; }
    return { ok: res.ok, status: res.status, data, ms: Date.now() - t, error: null };
  } catch (e) {
    return { ok: false, status: 0, data: null, ms: Date.now() - t, error: e?.name === 'TimeoutError' ? `timeout(${TIMEOUT}ms)` : String(e?.message || e) };
  }
}

function fingerprintClient() {
  if (!CLIENT_EXE) return { version: 'unknown', source: 'not provided', matchesExpected: null, strictOk: null };
  try {
    const fs = require('node:fs');
    const crypto = require('node:crypto');
    const st = fs.statSync(String(CLIENT_EXE));
    const pad = (n) => String(n).padStart(2, '0');
    const d = st.mtime;
    const mtime = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    const sha256 = crypto.createHash('sha256').update(fs.readFileSync(String(CLIENT_EXE))).digest('hex').toUpperCase();
    const sizeOk = st.size === EXPECTED.size;
    const shaOk = sha256 === EXPECTED.sha256;
    const version = `${st.size} B / ${mtime} / sha256 ${sha256.slice(0, 12)}…`;
    // default: size only (portable). --strict-build: size AND sha256 (release self-check).
    const matchesExpected = STRICT_BUILD ? (sizeOk && shaOk) : sizeOk;
    return { version, source: String(CLIENT_EXE), matchesExpected, sizeOk, shaOk, strictOk: sizeOk && shaOk, size: st.size, mtime, sha256 };
  } catch (e) {
    return { version: 'unknown', source: String(CLIENT_EXE), error: String(e.message || e), matchesExpected: null, strictOk: null };
  }
}
// `require` is available via createRequire (declared at the top of this module)

const report = {
  base: BASE,
  port: PORT,
  clientReachable: false,
  healthOk: false,
  stateOk: false,
  netOk: false,
  uiOk: false,
  started: null,
  inDuel: null,
  turn: null,
  lp: null,
  lpOrder: null,
  mySeat: null,
  curMsg: null,
  chainDepth: null,
  netAlive: null,
  netState: null,
  netConnected: null,
  sinceLastStoc: null,
  closeReason: null,
  probe: null,
  uiActions: null,
  chainMode: null,
  chainModeName: null,
  winPlayer: null,
  winPlayerLocal: null,
  isWin: null,
  isLoss: null,
  isDraw: null,
  version: 'unknown',
  netVersion: null,
  overall: 'RED',
  hints: [],
  checks: [],
  raw: {},
};

const addCheck = (name, level, detail) => { report.checks.push({ name, level, detail }); };
const hint = (s) => { if (!report.hints.includes(s)) report.hints.push(s); };

// ---------------------------------------------------------------- /health
const health = await getJson('/health');
if (health.ok) {
  report.healthOk = true;
  report.clientReachable = true;
  addCheck('/health', 'GREEN', `ok (${health.ms}ms) started=${health.data?.started === true}`);
} else {
  addCheck('/health', 'RED', health.error || `status ${health.status}`);
}

// ---------------------------------------------------------------- /state
const state = await getJson('/state');
if (state.ok && state.data) {
  report.stateOk = true;
  report.clientReachable = true;
  const s = state.data;
  report.started = s.started === true;
  report.inDuel = s.inDuel === true;
  report.turn = s.turn ?? null;
  report.lp = s.lp ?? null;
  report.lpOrder = s.lpOrder ?? null;
  report.mySeat = s.mySeat ?? null;
  report.curMsg = s.curMsg ?? null;
  report.chainDepth = s.chainDepth ?? null;
  report.winPlayer = s.winPlayer ?? null;
  report.winPlayerLocal = s.winPlayerLocal ?? null;
  report.isWin = typeof s.isWin === 'boolean' ? s.isWin : null;
  report.isLoss = typeof s.isLoss === 'boolean' ? s.isLoss : null;
  report.isDraw = typeof s.isDraw === 'boolean' ? s.isDraw : null;
  report.raw.state = { started: s.started, inDuel: s.inDuel, turn: s.turn, lp: s.lp, lpOrder: s.lpOrder, curMsg: s.curMsg };
  addCheck('/state', 'GREEN', `turn=${report.turn} started=${report.started} inDuel=${report.inDuel} mySeat=${report.mySeat} chainDepth=${report.chainDepth}`);
  if (!report.started) hint('客户端控制层已连上，但还没进对局：先在大厅 → 准备 → 开始，之后 /state.started 应为 true');
} else {
  addCheck('/state', report.healthOk ? 'YELLOW' : 'RED', state.error || `status ${state.status}`);
}

// ---------------------------------------------------------------- /net (needs the patched client)
const net = await getJson('/net');
if (net.ok && net.data) {
  report.netOk = true;
  const n = net.data;
  report.netAlive = n.alive === true;
  report.netState = n.state ?? null;
  report.netConnected = n.connected ?? null;
  report.sinceLastStoc = n.sinceLastStoc ?? null;
  report.closeReason = n.closeReason ?? null;
  report.probe = n.probe ?? null;
  report.netVersion = n.version ?? null;
  report.raw.net = { alive: n.alive, state: n.state, connected: n.connected, sinceLastStoc: n.sinceLastStoc, closeReason: n.closeReason, probe: n.probe };
  addCheck('/net', report.netAlive ? 'GREEN' : 'YELLOW',
    `alive=${report.netAlive} state=${report.netState} connected=${report.netConnected} sinceLastStoc=${report.sinceLastStoc}ms` +
    (report.probe ? ` probe(rtt=${report.probe.rttMs ?? '-'}ms fails=${report.probe.fails ?? '-'})` : ''));
  if (!report.netAlive) hint(`客户端报告链路已断（state=${report.netState}，closeReason=${report.closeReason || 'n/a'}）：检查服务器/网络或重启客户端`);
} else {
  addCheck('/net', report.healthOk ? 'YELLOW' : 'RED', net.error || `status ${net.status}`);
  if (report.healthOk) hint('客户端没有 /net：这是旧构建。需要含控制层扩展的新客户端（参见 README「前置条件」的 exe 指纹）');
}

// ---------------------------------------------------------------- /ui
const ui = await getJson('/ui');
if (ui.ok && ui.data) {
  report.uiOk = true;
  report.chainMode = ui.data.chainMode ?? null;
  report.chainModeName = ui.data.chainModeName ?? null;
  addCheck('/ui', 'GREEN', `chainMode=${report.chainMode}(${report.chainModeName ?? '?'})`);
} else {
  addCheck('/ui', report.healthOk ? 'YELLOW' : 'RED', ui.error || `status ${ui.status}`);
  if (report.healthOk) hint('/ui 不可用：客户端可能是旧构建，或 UI 诊断被禁用（不影响 /actions 与 /act_id）');
}

// ---------------------------------------------------------------- binary fingerprint
const fp = fingerprintClient();
report.version = fp.version;
report.versionSource = fp.source;
report.versionSha256 = fp.sha256 ?? null;
if (fp.matchesExpected === true) {
  addCheck('client exe', 'GREEN',
    `matches expected build (${fp.version})` +
    (STRICT_BUILD ? ' [strict: size+sha256]' : ' [size check only; use --strict-build for sha256]'));
} else if (fp.matchesExpected === false) {
  const why = fp.sizeOk === false
    ? `size ${fp.size} differs from the tested build (${EXPECTED.size} B)`
    : `sha256 differs from the tested build (expected ${String(EXPECTED.sha256).slice(0, 12)}…)`;
  addCheck('client exe', 'YELLOW', `does not match the tested build: ${why}`);
  hint(`客户端 exe 与已测试构建不同（期望 ${EXPECTED.size} B / sha256 ${String(EXPECTED.sha256).slice(0, 12)}…）：某些字段（/net、isWin、sidePending、DUEL_START 重置）可能缺失或行为不同`);
} else if (CLIENT_EXE) {
  addCheck('client exe', 'YELLOW', `cannot stat ${String(CLIENT_EXE)}`);
} else {
  addCheck('client exe', 'INFO', 'not checked (pass --client <path> to fingerprint it)');
}
// uiActions is not exposed over HTTP (only the client's startup log has it) -> always unknown here.
addCheck('uiActions', 'INFO', 'not exposed over HTTP (client startup log: "control: started ... uiActions=1")');

// ---------------------------------------------------------------- overall + output
const hasRed = report.checks.some((c) => c.level === 'RED');
const hasYellow = report.checks.some((c) => c.level === 'YELLOW');
const coreOk = report.healthOk && report.stateOk && report.netOk;
report.overall = hasRed ? 'RED' : (coreOk && !hasYellow ? 'GREEN' : (coreOk ? 'YELLOW' : 'RED'));

if (!report.clientReachable) {
  hint(`连不上控制层 ${BASE}：先启动带控制层的 YGOPro 客户端（房主控制端口 7788 / 客机 7789）`);
  hint('确认客户端构建带控制层扩展：启动日志里应有 "control: started port=7788"');
  hint(`检查端口占用：Windows 上 netstat -ano | findstr :${PORT}`);
}
if (!report.hints.length) report.hints.push('全部通过：控制层可用。接下来用 MCP 宿主调用 control_state / control_wait_prompt / control_actions / control_act_id。');

if (!JSON_ONLY) {
  console.log(`ygopro-mcp doctor — probing ${BASE}`);
  for (const c of report.checks) console.log(`${c.level === 'GREEN' ? C.green(c.name + ': ' + (c.detail ?? '')) : c.level === 'YELLOW' ? C.yellow(c.name + ': ' + (c.detail ?? '')) : c.level === 'RED' ? C.red(c.name + ': ' + (c.detail ?? '')) : C.info(c.name + ': ' + (c.detail ?? ''))}`);
  console.log('');
  console.log(`OVERALL: ${report.overall}`);
  console.log('HINTS:');
  for (const h of report.hints) console.log('  - ' + h);
  console.log('');
  console.log('JSON:');
}
console.log(JSON.stringify(report, null, 2));
process.exit(report.overall === 'GREEN' ? 0 : 1);
