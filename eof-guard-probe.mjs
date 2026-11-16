// bridge/eof-guard-probe.mjs - verify the "prompt published but never answered -> server EOF" guard.
//
// Modes:
//   idle : wait until a real prompt appears on the chosen side, then deliberately DO NOT answer
//          for N seconds and sample /prompt + /state every second. The client is expected to log
//          `PROMPT idle warning` (~45s) and `PROMPT auto-default ...` (~60s, YGO_PROMPT_AUTO_DEFAULT_MS),
//          after which the prompt advances and the duel continues instead of being EOF-kicked.
//   fast : answer prompts quickly (normal play) and check that auto-default never fires while
//          still recording `awaitingSinceMs` from /prompt.
//
// It never starts or kills anything; bridge/verify-eof-guard.ps1 does that.
//
// Usage:
//   node bridge/eof-guard-probe.mjs --dir <evd> --mode idle --idle-sec 70 --side host --max-min 3
//   node bridge/eof-guard-probe.mjs --dir <evd> --mode fast --max-min 2

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };

const DIR = path.resolve(get('dir', 'ranked/logs/eof-guard'));
const MODE = get('mode', 'idle');
const IDLE_SEC = Number(get('idle-sec', '70'));
const MAX_MIN = Number(get('max-min', '3'));
const SIDE = get('side', 'host'); // host | guest | any
const HOST = get('host', 'http://127.0.0.1:7788');
const GUEST = get('guest', 'http://127.0.0.1:7789');

fs.mkdirSync(DIR, { recursive: true });
const out = fs.createWriteStream(path.join(DIR, 'probe.jsonl'), { flags: 'w' });
const t0 = Date.now();
const el = () => (Date.now() - t0) / 1000;
const rec = (o) => out.write(JSON.stringify({ t: +el().toFixed(3), ...o }) + '\n');
const log = (m) => console.log(`[${el().toFixed(1)}] ${m}`);

async function j(url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(3000) });
    return JSON.parse(await r.text());
  } catch { return null; }
}

const sides = SIDE === 'any' ? [['host', HOST], ['guest', GUEST]]
  : SIDE === 'guest' ? [['guest', GUEST]] : [['host', HOST]];

const RESULT = {
  mode: MODE, idleSec: IDLE_SEC,
  promptSeen: null, samples: 0,
  sawEof: false, closeReason: null,
  sawPromptAdvance: false, promptAdvancedAt: null,
  awaitingSinceMsValues: [], awaitingSinceMsPresent: false,
  autoDefaultObserved: false, eofAtSec: null,
  finalState: null,
};

function pickPrompt(pr) {
  if (!pr || pr.awaiting !== true) return null;
  if (pr.sidePending || pr.tpPending) return null;
  return pr;
}

// ---------- idle mode ----------
async function idleMode(base) {
  let target = null;
  let targetSide = null;
  const deadline = Date.now() + MAX_MIN * 60000;
  while (Date.now() < deadline) {
    for (const [name, url] of sides) {
      const st = await j(url + '/state');
      const pr = await j(url + '/prompt');
      if (!st || !pr) continue;
      if (st.match && st.match.over) { rec({ side: name, ev: 'match-over' }); break; }
      const p = pickPrompt(pr);
      if (p && st.started) { target = p; targetSide = name; break; }
    }
    if (target) break;
    await new Promise((r) => setTimeout(r, 700));
  }
  if (!target) { rec({ ev: 'no-prompt-found' }); return; }

  const baseUrl = targetSide === 'host' ? HOST : GUEST;
  const TARGET = {
    side: targetSide, seq: target.seq, curMsg: target.curMsg,
    awaitingSinceMs: target.awaitingSinceMs ?? null,
    selectMin: target.selectMin, selectMax: target.selectMax,
    turn: target.turn,
  };
  RESULT.promptSeen = TARGET;
  rec({ ev: 'prompt-seen', target: TARGET });
  log('holding prompt ' + JSON.stringify(TARGET));

  const start = Date.now();
  let eofSeen = false;
  let advanced = false;
  while ((Date.now() - start) / 1000 < IDLE_SEC + 40) {
    const sec = Math.round((Date.now() - start) / 1000);
    const st = await j(baseUrl + '/state');
    const pr = await j(baseUrl + '/prompt');
    if (!st || !pr) {
      rec({ side: targetSide, ev: 'unreachable', sec });
      break;
    }
    const sample = {
      side: targetSide, ev: 'sample', sec,
      seq: pr.seq, curMsg: pr.curMsg, awaiting: pr.awaiting,
      awaitingSinceMs: pr.awaitingSinceMs ?? null,
      turn: st.turn, lp: st.lp, started: st.started,
      netAlive: st.net && st.net.alive, closeReason: st.net && st.net.closeReason,
      lastStoc: st.net && st.net.lastStocName,
      sinceLastStoc: st.net && st.net.sinceLastStoc,
      matchOver: st.match && st.match.over,
    };
    rec(sample);
    RESULT.samples++;
    if (typeof sample.awaitingSinceMs === 'number') {
      RESULT.awaitingSinceMsPresent = true;
      RESULT.awaitingSinceMsValues.push(sample.awaitingSinceMs);
    }
    if (sample.closeReason && sample.closeReason !== 'none') {
      RESULT.sawEof = true;
      RESULT.closeReason = sample.closeReason;
      RESULT.eofAtSec = sec;
      eofSeen = true;
      rec({ side: targetSide, ev: 'disconnected', closeReason: sample.closeReason, sec });
      break;
    }
    // prompt advanced => auto-default (or something else) resolved it
    if (!advanced && (pr.seq !== TARGET.seq || !pr.awaiting)) {
      advanced = true;
      RESULT.sawPromptAdvance = true;
      RESULT.promptAdvancedAt = sec;
      rec({ side: targetSide, ev: 'prompt-advanced', sec, newSeq: pr.seq, newCurMsg: pr.curMsg, newAwaiting: pr.awaiting });
      // keep sampling a bit to prove the duel continues
    }
    if (advanced && sec > (RESULT.promptAdvancedAt ?? 0) + 5) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  RESULT.sawEof = RESULT.sawEof || eofSeen;
  RESULT.finalState = await j(baseUrl + '/state');
  rec({ ev: 'idle-end', eof: RESULT.sawEof, advanced: RESULT.sawPromptAdvance });
}

// ---------- fast mode ----------
function chooseFast(st, pr, actions) {
  const has = (k) => (actions || []).filter((a) => a.kind === k);
  const first = (k) => (actions || []).find((a) => a.kind === k) || null;
  if (pr.sidePending) return first('side_ok');
  if (pr.tpPending) { const tp = has('tp'); return tp.find((a) => a.index === 1) || tp[0]; }
  if (pr.curMsg === 10) return first('attack') || first('end_battle');
  if (pr.curMsg === 11) return first('summon') || first('set_monster') || first('to_bp') || first('to_ep');
  const order = ['sort', 'select', 'sum', 'position', 'place', 'option', 'yes', 'no', 'decline', 'to_ep', 'end_battle', 'counter', 'auto'];
  for (const k of order) { const a = first(k); if (a) return a; }
  const announce = (actions || []).find((a) => /^announce/.test(a.kind || ''));
  if (announce) return announce;
  return (actions || [])[0] || null;
}

async function fastSide(name, base) {
  const deadline = Date.now() + MAX_MIN * 60000;
  let lastSeq = -1;
  let answered = 0;
  while (Date.now() < deadline) {
    if (answered >= 25) break;
    const st = await j(base + '/state');
    const pr = await j(base + '/prompt');
    if (!st || !pr) break;
    if (st.match && st.match.over) { rec({ side: name, ev: 'match-over' }); break; }
    if (pr.awaiting !== true || pr.seq === lastSeq) {
      await new Promise((r) => setTimeout(r, 250));
      continue;
    }
    const hasSince = typeof pr.awaitingSinceMs === 'number';
    if (hasSince) { RESULT.awaitingSinceMsPresent = true; RESULT.awaitingSinceMsValues.push(pr.awaitingSinceMs); }
    const acts = await j(base + '/actions');
    const chosen = chooseFast(st, pr, (acts && acts.actions) || []);
    if (!chosen) { await new Promise((r) => setTimeout(r, 300)); continue; }
    const resp = await j(base + '/act_id?id=' + chosen.id);
    lastSeq = pr.seq;
    answered++;
    rec({ side: name, ev: 'fast-act', seq: pr.seq, curMsg: pr.curMsg, awaitingSinceMs: pr.awaitingSinceMs ?? null, action: chosen, resp });
    await new Promise((r) => setTimeout(r, 250));
  }
  RESULT.answered = (RESULT.answered || 0) + answered;
  RESULT[`answered_${name}`] = answered;
  rec({ side: name, ev: 'fast-end', answered });
}

async function fastMode(base) {
  // drive BOTH clients: the un-driven side would otherwise idle 60s and legitimately trip the guard
  await Promise.all([fastSide('host', HOST), fastSide('guest', GUEST)]);
  RESULT.finalState = await j(base + '/state');
}

log(`eof-guard probe mode=${MODE} idleSec=${IDLE_SEC} maxMin=${MAX_MIN}`);
if (MODE === 'fast') await fastMode(HOST);
else await idleMode(HOST);

fs.writeFileSync(path.join(DIR, 'probe-summary.json'), JSON.stringify(RESULT, null, 2), 'utf8');
out.end();
log('done ' + JSON.stringify({
  promptSeen: !!RESULT.promptSeen, samples: RESULT.samples, sawEof: RESULT.sawEof,
  awaitingSinceMsPresent: RESULT.awaitingSinceMsPresent,
  sawPromptAdvance: RESULT.sawPromptAdvance, promptAdvancedAt: RESULT.promptAdvancedAt,
  answered: RESULT.answered,
}));
console.log('PROBE_DIR=' + DIR);
