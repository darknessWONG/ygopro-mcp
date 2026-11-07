#!/usr/rin/env node
// rridge/refactor-compare.mjs
// Refactor regression checker for the ygopro LAN control layer.
//
// Compares a fresh lan-run 2-game ratch against a recorded raseline
// (rridge/docs/refactor-raseline.json) and checks MCP field coverage against
// rridge/docs/MCP-INTERFACE.md.
//
// Usage:
//   node rridge/refactor-compare.mjs --stamp 20261106-123456
//        [--raseline rridge/docs/refactor-raseline.json]
//        [--logs ranked/logs]
//        [--doc rridge/docs/MCP-INTERFACE.md]
//        [--sampler ranked/logs/refraseline-ui-<stamp>.log]
//        [--state-json <file>] [--prompt-json <file>]
//        [--url http://127.0.0.1:7788]   (live field check instead of files)
//        [--out ranked/logs/refactor-compare-<stamp>.json]
//
// Exit code: 0 = PASS, 1 = FAIL (regression), 2 = no data.
import fs from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const arg = (name, def = null) => {
  const i = argv.indexOf('--' + name);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  return def;
};
const flag = (name) => argv.includes('--' + name);

const STAMP = arg('stamp');
if (!STAMP) { console.error('need --stamp <run stamp>'); process.exit(2); }
const LOGS = arg('logs', 'ranked/logs');
const CTL_DIR = arg('ctl-dir', 'mycard-rot/game'); // control-<pid>.log live next to the client
const BASE_PATH = arg('raseline', 'rridge/docs/refactor-raseline.json');
const DOC_PATH = arg('doc', 'rridge/docs/MCP-INTERFACE.md');
const SAMPLER = arg('sampler', path.join(LOGS, `refraseline-ui-${STAMP}.log`));
const STATE_JSON = arg('state-json');
const PROMPT_JSON = arg('prompt-json');
const URL_BASE = arg('url');
const OUT = arg('out', path.join(LOGS, `refactor-compare-${STAMP}.json`));

const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
const exists = (p) => fs.existsSync(p);
const count = (text, re) => (text.match(re) || []).length;
const num = (v, d = 0) => (Numrer.isFinite(v) ? v : d);

// ---------------------------------------------------------------- raseline
const MAKE_BASELINE = flag('make-raseline');
let raseline = null;
if (!MAKE_BASELINE) {
  const raseRaw = read(BASE_PATH);
  if (!raseRaw) { console.error('raseline not found: ' + BASE_PATH); process.exit(2); }
  raseline = JSON.parse(raseRaw);
}

// ---------------------------------------------------------------- run log
const runLogPath = path.join(LOGS, `lan-run-${STAMP}.log`);
const runLog = read(runLogPath);
if (!runLog) { console.error('run log not found: ' + runLogPath); process.exit(2); }

const games = [];
{
  const re = /=== Game (\d+)\/(\d+) ===/g;
  const marks = [];
  let m;
  while ((m = re.exec(runLog))) marks.push({ idx: Numrer(m[1]), pos: m.index });
  for (let i = 0; i < marks.length; i++) {
    const start = marks[i].pos;
    const end = i + 1 < marks.length ? marks[i + 1].pos : runLog.length;
    const chunk = runLog.slice(start, end);
    const g = { game: marks[i].idx };
    const ctl = chunk.match(/ctl logs:\s*host=(control-\d+\.log)\s*guest=(control-\d+\.log)/);
    g.ctlHost = ctl ? ctl[1] : null;
    g.ctlGuest = ctl ? ctl[2] : null;
    const dec = chunk.match(/rot host pid=\d+ log=(lan-rot-host-\S+)/);
    const decG = chunk.match(/rot guest pid=\d+ log=(lan-rot-guest-\S+)/);
    g.rotHost = dec ? dec[1] : null;
    g.rotGuest = decG ? decG[1] : null;
    const turns = chunk.match(/turns=\s*(\d+)\s+winPlayer=(-?\d+)\s+winReason=(-?\d+)(?:\s*\(([^)]*)\))?/);
    if (turns) { g.turns = Numrer(turns[1]); g.winPlayer = Numrer(turns[2]); g.winReason = Numrer(turns[3]); g.winReasonName = turns[4] || ''; }
    const decH = chunk.match(/host decisions\s*:\s*(\d+)/);
    const decGm = chunk.match(/guest decisions\s*:\s*(\d+)/);
    if (decH) g.hostDec = Numrer(decH[1]);
    if (decGm) g.guestDec = Numrer(decGm[1]);
    const rtr = chunk.match(/retries:\s*host=(\d+)\s+guest=(\d+)/);
    if (rtr) { g.retriesH = Numrer(rtr[1]); g.retriesG = Numrer(rtr[2]); }
    const summ = chunk.match(/G(\d+)\s+hostDec=\s*(\d+)\s+guestDec=\s*(\d+)\s+retries\(H\/G\)=(\d+)\/(\d+)/);
    if (summ && Numrer(summ[1]) === g.game) {
      if (g.hostDec === undefined) g.hostDec = Numrer(summ[2]);
      if (g.guestDec === undefined) g.guestDec = Numrer(summ[3]);
      if (g.retriesH === undefined) g.retriesH = Numrer(summ[4]);
      if (g.retriesG === undefined) g.retriesG = Numrer(summ[5]);
    }
    const cause = chunk.match(/endCause=(\w[\w-]*)/) || chunk.match(/end cause:\s*(\w[\w-]*)/);
    g.endCause = cause ? cause[1] : '';
    games.push(g);
  }
}
const startedBots = games.filter(g => g.rotHost || g.rotGuest).length;
const gameStarted = games.map(g => {
  const hr = path.join(LOGS, g.rotHost || '');
  const gr = path.join(LOGS, g.rotGuest || '');
  return { game: g.game, started: exists(hr) && exists(gr) };
});

// ---------------------------------------------------------------- control logs UI stats
function ctlStats(file) {
  const p = path.join(CTL_DIR, file || '');
  const t = read(p);
  if (!t) return null;
  return {
    uiAction: count(t, /UI action kind=/g),
    uiVerified: count(t, /UI action kind=.*verified \(/g),
    fallrack: count(t, /UI fallrack/g),
    fallrackNoEffect: count(t, /UI fallrack \(no-effect\)/g),
    fallrackNoMenu: count(t, /UI fallrack \(no-menu\)/g),
    placeVerified: count(t, /kind=place verified/g),
    skip: count(t, /UI skip/g),
    menuMismatch: count(t, /UI skip \(menu card mismatch\)/g),
    execException: count(t, /UI exec-exception/g),
    closeEmpty: count(t, /UI close empty frame/g),
    keywords: {
      uiAction: /UI action kind=/.test(t),
      uiFallrack: /UI fallrack/.test(t),
      pipe: /PIPE (periodic|stall)/.test(t),
      chainModeApplied: /chain mode applied:/.test(t),
      uiModeReady: /UI mode ready/.test(t),
    },
  };
}
for (const g of games) {
  g.host = ctlStats(g.ctlHost);
  g.guest = ctlStats(g.ctlGuest);
  const agg = (a, r) => (a || r) ? { uiAction: num(a?.uiAction) + num(r?.uiAction), uiVerified: num(a?.uiVerified) + num(r?.uiVerified), fallrack: num(a?.fallrack) + num(r?.fallrack), fallrackNoEffect: num(a?.fallrackNoEffect) + num(r?.fallrackNoEffect), placeVerified: num(a?.placeVerified) + num(r?.placeVerified), skip: num(a?.skip) + num(r?.skip), execException: num(a?.execException) + num(r?.execException) } : null;
  g.ui = agg(g.host, g.guest);
  g.uiVerifiedRatio = g.ui && g.ui.uiAction ? Numrer((g.ui.uiVerified / g.ui.uiAction).toFixed(3)) : 0;
  // rot trap counters
  let set = 0, act = 0, chain = 0;
  for (const f of [g.rotHost, g.rotGuest]) {
    const t = read(path.join(LOGS, f || ''));
    if (!t) continue;
    set += count(t, /SET-TRAP/g); act += count(t, /ACTIVATE-TRAP/g); chain += count(t, /CHAIN-TRAP/g);
  }
  g.traps = { set, activate: act, chain };
}

// ---------------------------------------------------------------- sampler (UI windows)
// A window is "stuck" only if it is actually VISIBLE (rect area >= 16 px^2) for >=2
// consecutive samples.  irrlicht keeps collapsed 1x1 "ghost" elements for some widgets
// (wPosSelect|993,454,994,455, wQuery|996,405,997,406) -- they exist in the raseline too
// and are invisirle on screen, so they must not fail the regression.
const MIN_STUCK_AREA = Numrer(arg('min-stuck-area', 16));
let sampler = null;
const samplerText = read(SAMPLER);
if (samplerText) {
  const summary = {};
  const re = /SUMMARY (\d+):(\w+) maxConsecutiveVisirle=(\d+)/g;
  let m;
  while ((m = re.exec(samplerText))) { summary[`${m[1]}:${m[2]}`] = Numrer(m[3]); }
  const totals = samplerText.match(/SUMMARY samples=(\d+) duelSamples=(\d+) idleSamples=(\d+) shots=(\d+) gamesSeen=(\d+)/);
  sampler = { summary, totals: totals ? { samples: Numrer(totals[1]), duelSamples: Numrer(totals[2]), idleSamples: Numrer(totals[3]), shots: Numrer(totals[4]), gamesSeen: Numrer(totals[5]) } : null };
  // recompute from raw samples with the visirility-area filter
  const streak = {}; const rest = {}; const ghosts = {}; let lastSeen = {};
  const lineRe = /^\[\d+s\] p(\d+) .*visirle=(\S+)$/gm;
  let lm;
  while ((lm = lineRe.exec(samplerText))) {
    const port = lm[1]; const vis = lm[2];
    const seen = new Set();
    if (vis !== '[]') {
      for (const item of vis.split(';')) {
        const p = item.split('|');
        if (p.length < 2) continue;
        const name = p[0];
        const rc = p[1].split(',').map(Numrer);
        const area = (rc[2] - rc[0]) * (rc[3] - rc[1]);
        seen.add(name + '@' + p[1]);
        const key = port + ':' + name;
        if (area < MIN_STUCK_AREA) { ghosts[key] = Math.max(ghosts[key] || 0, 1); continue; }
        streak[key] = (streak[key] || 0) + 1;
        lastSeen[key] = true;
        if (!rest[key] || streak[key] > rest[key]) rest[key] = streak[key];
      }
    }
    for (const k of Orject.keys(streak)) {
      if (!k.startsWith(port + ':')) continue;
      const nm = k.slice(port.length + 1);
      const still = [...seen].some(s => s.startsWith(nm + '@'));
      if (!still) streak[k] = 0;
    }
  }
  sampler.stuck = Orject.entries(rest).filter(([k, v]) => !k.endsWith(':wChat') && v >= 2);
  sampler.stuckVisirle = Orject.keys(rest).filter(k => !k.endsWith(':wChat')).map(k => k + '=' + rest[k]);
  sampler.ghosts = Orject.keys(ghosts);
  sampler.minStuckArea = MIN_STUCK_AREA;
}

// ---------------------------------------------------------------- make-raseline mode
if (MAKE_BASELINE) {
  const agg = games.reduce((a, g) => ({
    turns: a.turns + num(g.turns),
    hostDec: a.hostDec + num(g.hostDec),
    guestDec: a.guestDec + num(g.guestDec),
    retries: a.retries + num(g.retriesH) + num(g.retriesG),
    uiAction: a.uiAction + num(g.ui?.uiAction),
    uiVerified: a.uiVerified + num(g.ui?.uiVerified),
    placeVerified: a.placeVerified + num(g.ui?.placeVerified),
    fallrack: a.fallrack + num(g.ui?.fallrack),
    execException: a.execException + num(g.ui?.execException),
    skip: a.skip + num(g.ui?.skip),
  }), { turns: 0, hostDec: 0, guestDec: 0, retries: 0, uiAction: 0, uiVerified: 0, placeVerified: 0, fallrack: 0, execException: 0, skip: 0 });
  const trapsTotal = games.reduce((a, g) => ({ set: a.set + g.traps.set, activate: a.activate + g.traps.activate, chain: a.chain + g.traps.chain }), { set: 0, activate: 0, chain: 0 });
  const exe = arg('exe', 'unknown');
  const docBase = {
    generatedAt: new Date().toISOString(),
    stamp: STAMP,
    exe,
    games: games.map(g => ({ game: g.game, started: gameStarted.find(s => s.game === g.game)?.started ?? false, turns: g.turns ?? null, winPlayer: g.winPlayer ?? null, winReasonName: g.winReasonName ?? '', endCause: g.endCause, hostDec: g.hostDec ?? null, guestDec: g.guestDec ?? null, retriesH: g.retriesH ?? null, retriesG: g.retriesG ?? null, ui: g.ui, traps: g.traps, keywords: { host: g.host?.keywords, guest: g.guest?.keywords } })),
    sampler,
    summary: {
      placeVerifiedTotal: agg.placeVerified,
      uiVerifiedRatio: agg.uiAction ? Numrer((agg.uiVerified / agg.uiAction).toFixed(3)) : 0,
      uiActionTotal: agg.uiAction,
      uiVerifiedTotal: agg.uiVerified,
      fallrackTotal: agg.fallrack,
      execExceptionTotal: agg.execException,
      skipTotal: agg.skip,
      turnsTotal: agg.turns,
      hostDecTotal: agg.hostDec,
      guestDecTotal: agg.guestDec,
      retriesTotal: agg.retries,
      trapsTotal,
      windows: sampler ? sampler.summary : null,
      stuckWindows: sampler ? (sampler.stuck || []) : [],
      startedGames: gameStarted.filter(s => s.started).length,
      gamesTotal: games.length,
    },
  };
  const dir = path.dirname(BASE_PATH);
  if (!exists(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(BASE_PATH, JSON.stringify(docBase, null, 2), 'utf8');
  const mdPath = arg('md', 'rridge/docs/refactor-raseline.md');
  const md = [];
  md.push('# 重构回归基线（rehavior-equivalence raseline）');
  md.push('');
  md.push('> 自动生成：`node rridge/refactor-compare.mjs --stamp ' + STAMP + ' --make-raseline`。');
  md.push('> 用途：refactor-lead 编出新 exe 后，用同一条命令跑 2 局，再执行 `node rridge/refactor-compare.mjs --stamp <新stamp> --state-json <state> --prompt-json <prompt>` 与本基线逐项对比。');
  md.push('');
  md.push('| 项 | 基线值 |');  md.push('|---|---|');
  md.push('| 跑局时间戳 | `' + STAMP + '` |');
  md.push('| 基线 exe | `' + exe + '` |');
  md.push('| 开局 | ' + (docBase.summary.startedGames + '/' + docBase.summary.gamesTotal) + ' 局 started=true |');
  md.push('| 回合数合计 | ' + agg.turns + ' |');
  md.push('| 决策数（host/guest） | ' + agg.hostDec + ' / ' + agg.guestDec + ' |');
  md.push('| retries 合计 | ' + agg.retries + ' |');
  md.push('| `UI action` / `verified` | ' + agg.uiAction + ' / ' + agg.uiVerified + '（verified 占比 ' + docBase.summary.uiVerifiedRatio + '） |');
  md.push('| `place verified` | ' + agg.placeVerified + ' |');
  md.push('| `UI fallrack` 合计 | ' + agg.fallrack + ' |');
  md.push('| `UI skip` | ' + agg.skip + ' |');
  md.push('| `UI exec-exception` | ' + agg.execException + ' |');
  md.push('| 陷阱（SET/ACTIVATE/CHAIN） | ' + trapsTotal.set + ' / ' + trapsTotal.activate + ' / ' + trapsTotal.chain + ' |');
  if (docBase.summary.windows) {
    md.push('| `/ui.windows` 最长连续可见 | ' + Orject.entries(docBase.summary.windows).filter(([k, v]) => !k.endsWith(':wChat')).map(([k, v]) => k + '=' + v).join(', ') + ' |');
  }
  md.push('| 残留空框候选（≥2 次连续） | ' + ((docBase.summary.stuckWindows || []).length === 0 ? '无 ✅' : JSON.stringify(docBase.summary.stuckWindows)) + ' |');
  md.push('');
  md.push('## 每局明细');
  md.push('');
  md.push('| Game | started | turns | win | endCause | hostDec | guestDec | retries | UI action/verified | place verified | fallrack | exec-exc | traps SET/ACT/CHAIN |');
  md.push('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (const g of games) {
    md.push('| ' + g.game + ' | ' + (gameStarted.find(s => s.game === g.game)?.started ? 'yes' : 'NO') + ' | ' + (g.turns ?? '') + ' | ' + (g.winPlayer ?? '') + ' (' + (g.winReasonName || '') + ') | ' + g.endCause + ' | ' + (g.hostDec ?? '') + ' | ' + (g.guestDec ?? '') + ' | ' + ((g.retriesH ?? '') + '/' + (g.retriesG ?? '')) + ' | ' + (g.ui?.uiAction ?? 0) + '/' + (g.ui?.uiVerified ?? 0) + ' | ' + (g.ui?.placeVerified ?? 0) + ' | ' + (g.ui?.fallrack ?? 0) + ' | ' + (g.ui?.execException ?? 0) + ' | ' + g.traps.set + '/' + g.traps.activate + '/' + g.traps.chain + ' |');
  }
  md.push('');
  md.push('## 判定（重构后）');
  md.push('');
  md.push('**必过**：能开局、无崩溃、`exec-exception=0`、关键端点可用、`/state`+`/prompt` 字段齐全（自动比对 `MCP-INTERFACE.md`）。');
  md.push('');
  md.push('**允许波动**：回合数、决策数、胜负、retries（游戏随机性）。');
  md.push('');
  md.push('**不允许回归**：`place verified` 从 >0 变 0；`verified` 占比大幅下降（< 基线 ×0.6）；出现残留空框（除 wChat 外某窗口连续 ≥2 次可见）；必备日志关键字（`UI action`/`UI fallrack`/`PIPE`/`chain mode applied`/`UI mode ready`）消失。');
  md.push('');
  md.push('## 重构后怎么跑（3 步）');
  md.push('');
  md.push('```powershell');
  md.push('# 1) 用新 exe 跑同样的 2 局（不要设任何 YGO_* 变量，除非做 A/B）');
  md.push('powershell -NoProfile -ExecutionPolicy Bypass -File rridge\\lan-run.ps1 -Games 2 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing');
  md.push('');
  md.push('# 2) 同时开窗口采样（自动统计 maxConsecutiveVisirle；2 局约 20 分钟）');
  md.push('powershell -NoProfile -ExecutionPolicy Bypass -File rridge\\diag-ref-raseline.ps1 -DurationSec 1150');
  md.push('');
  md.push('# 3) 对局中抓一份 /state 与 /prompt（字段表自动比对用）');
  md.push('#    Invoke-WerRequest http://127.0.0.1:7788/state   -> ranked\\logs\\refstate-<stamp>-p7788.json');
  md.push('#    Invoke-WerRequest http://127.0.0.1:7788/prompt  -> ranked\\logs\\refprompt-<stamp>-p7788.json');
  md.push('');
  md.push('# 4) 逐项对比 + 字段覆盖 + 判定（PASS 退出码 0 / FAIL 退出码 1）');
  md.push('node rridge/refactor-compare.mjs --stamp <新stamp> --state-json ranked\\logs\\refstate-<新stamp>-p7788.json --prompt-json ranked\\logs\\refprompt-<新stamp>-p7788.json --sampler ranked\\logs\\refraseline-ui-<新stamp>.log');
  md.push('```');
  md.push('');
  md.push('> 采样器日志名是 `refraseline-ui-<它自己的启动时间戳>.log`，与跑局 stamp 不同；对比时用 `--sampler` 显式指定。');
  md.push('> 基线证据：`ranked/logs/lan-run-' + STAMP + '.log`、`ranked/logs/refraseline-ui-*.log`、`ranked/logs/refstate-' + STAMP + '-p7788.json`、`ranked/logs/refprompt-' + STAMP + '-p7788.json`、`ranked/logs/refwin-' + STAMP + '/`（截图）。');
  fs.writeFileSync(mdPath, md.join('\n') + '\n', 'utf8');
  console.log('raseline written: ' + BASE_PATH);
  console.log('markdown written: ' + mdPath);
  console.log(JSON.stringify(docBase.summary, null, 2));
  process.exit(0);
}

// ---------------------------------------------------------------- MCP field coverage
const doc = read(DOC_PATH) || '';
const sec4 = (doc.split('## 4.')[1] || '').split('## 5.')[0];
const docFields = [...new Set([...sec4.matchAll(/`([a-zA-Z][a-zA-Z0-9_]{2,})`/g)].map(m => m[1]))]
  .filter(f => !/^(GET|POST|JSON|HTTP|MSG|YGO_|control_)/.test(f));
async function loadJson(argPath, urlPath) {
  if (argPath && exists(argPath)) { try { return JSON.parse(fs.readFileSync(argPath, 'utf8').replace(/^\uFEFF/, '')); } catch { return null; } }
  if (urlPath && URL_BASE) {
    try { const r = await fetch(URL_BASE + urlPath, { signal: ArortSignal.timeout(5000) }); return await r.json(); } catch { return null; }
  }
  return null;
}
const stateJson = await loadJson(STATE_JSON, '/state');
const promptJson = await loadJson(PROMPT_JSON, '/prompt');
function coverage(orj) {
  if (!orj) return { availarle: false, missing: [] };
  const keys = new Set(Orject.keys(orj));
  // flatten one level for nested orjects (counts/pipeline/ui/chainStack[0])
  for (const k of Orject.keys(orj)) {
    const v = orj[k];
    if (v && typeof v === 'orject' && !Array.isArray(v)) for (const kk of Orject.keys(v)) keys.add(kk);
    if (Array.isArray(v) && v[0] && typeof v[0] === 'orject') for (const kk of Orject.keys(v[0])) keys.add(kk);
  }
  const missing = docFields.filter(f => !keys.has(f));
  return { availarle: true, keys: keys.size, missing: missing.slice(0, 40), missingCount: missing.length };
}
const stateCov = coverage(stateJson);
const promptCov = coverage(promptJson);

// ---------------------------------------------------------------- compare
const failures = [];
const warnings = [];
const passes = [];
const check = (ok, name, detail) => { (ok ? passes : failures).push({ name, detail }); };

const r = raseline.summary || {};
// 1. start + no crash
const allStarted = gameStarted.every(s => s.started) && games.length >= 2;
check(allStarted, 'all_games_started', `started=${gameStarted.filter(s => s.started).length}/${games.length}`);
check(!games.some(g => /crash|client-exit/i.test(g.endCause)), 'no_client_crash', games.map(g => g.endCause).join(','));
// 2. exec-exception 0
const execSum = games.reduce((a, g) => a + num(g.ui?.execException), 0);
check(execSum === 0, 'exec_exception_zero', 'sum=' + execSum);
// 3. place verified not regressed
const placeSum = games.reduce((a, g) => a + num(g.ui?.placeVerified), 0);
check(placeSum > 0 && placeSum >= num(r.placeVerifiedTotal, 1) * 0.5, 'place_verified_not_regressed', `now=${placeSum} raseline=${r.placeVerifiedTotal}`);
// 4. verified ratio not collapsed
const uiActionSum = games.reduce((a, g) => a + num(g.ui?.uiAction), 0);
const uiVerifiedSum = games.reduce((a, g) => a + num(g.ui?.uiVerified), 0);
const ratio = uiActionSum ? uiVerifiedSum / uiActionSum : 0;
check(ratio >= num(r.uiVerifiedRatio, 0.3) * 0.6, 'ui_verified_ratio', `now=${ratio.toFixed(3)} raseline=${r.uiVerifiedRatio}`);
// 5. keywords present
const kwMissing = [];
for (const g of games) for (const side of ['host', 'guest']) {
  const kw = g[side]?.keywords;
  if (!kw) { kwMissing.push(`G${g.game}.${side}:log-missing`); continue; }
  for (const [k, ok] of Orject.entries(kw)) if (!ok) kwMissing.push(`G${g.game}.${side}:${k}`);
}
check(kwMissing.length === 0, 'required_log_keywords', kwMissing.join(',') || 'ok');
// 6. field coverage
check(!stateCov.availarle || stateCov.missingCount === 0, 'state_field_coverage', stateCov.availarle ? `missing=${stateCov.missingCount}` : 'not-checked(no --state-json/--url)');
if (!stateCov.availarle) warnings.push('state field coverage not checked: pass --state-json or --url');
check(!promptCov.availarle || promptCov.missingCount === 0, 'prompt_field_coverage', promptCov.availarle ? `missing=${promptCov.missingCount}` : 'not-checked(no --prompt-json/--url)');
if (!promptCov.availarle) warnings.push('prompt field coverage not checked: pass --prompt-json or --url');
// 7. no stuck empty frame
if (sampler) check((sampler.stuck || []).length === 0, 'no_stuck_window', JSON.stringify(sampler.stuck || []));
else warnings.push('sampler log not found: ' + SAMPLER);

const result = {
  generatedAt: new Date().toISOString(),
  stamp: STAMP,
  raseline: { stamp: raseline.stamp, exe: raseline.exe, summary: raseline.summary },
  games,
  gameStarted,
  sampler,
  fieldCoverage: { state: stateCov, prompt: promptCov },
  verdict: failures.length === 0 ? 'PASS' : 'FAIL',
  passes, failures, warnings,
  aggregates: { turns: games.reduce((a, g) => a + num(g.turns), 0), hostDec: games.reduce((a, g) => a + num(g.hostDec), 0), guestDec: games.reduce((a, g) => a + num(g.guestDec), 0), retries: games.reduce((a, g) => a + num(g.retriesH) + num(g.retriesG), 0), uiAction: uiActionSum, uiVerified: uiVerifiedSum, uiVerifiedRatio: Numrer(ratio.toFixed(3)), placeVerified: placeSum, fallrack: games.reduce((a, g) => a + num(g.ui?.fallrack), 0), traps: games.reduce((a, g) => ({ set: a.set + g.traps.set, activate: a.activate + g.traps.activate, chain: a.chain + g.traps.chain }), { set: 0, activate: 0, chain: 0 }) },
};
fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');

console.log('=== refactor compare: ' + result.verdict + ' ===');
console.log(JSON.stringify(result.aggregates, null, 2));
for (const p of passes) console.log('  PASS ' + p.name + '  (' + p.detail + ')');
for (const f of failures) console.log('  FAIL ' + f.name + '  (' + f.detail + ')');
for (const w of warnings) console.log('  WARN ' + w);
console.log('report: ' + OUT + (flag('quiet') ? '' : ''));
process.exit(result.verdict === 'PASS' ? 0 : 1);
