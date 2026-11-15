// bridge/observe-battle.mjs - read-only battle recorder for the LAN fix verification (task-36 #1)
//
// Does NOT act. It watches both control ports while two policy-semantic bots play, and records
// the exact evidence needed for the "attack target rejected" bug:
//   - every prompt (seq / curMsg / selectMin..Max / selectable[] / actions[])
//   - /state retry counters + pipeline retryStreak around each 10 -> 15 transition
//   - attack-target selections (curMsg 10 prompt, then curMsg 15 prompt) and whether the
//     battle actually resolved (LP moves / curMsg moves on / MSG_RETRY appears)
//
// Usage: node bridge/observe-battle.mjs --dir <evd> --max-min 4 [--stop-after-targets 2]

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const DIR = path.resolve(get('dir', 'ranked/logs/observe-battle'));
const MAX_MIN = Number(get('max-min', '4'));
const STOP_AFTER_TARGETS = Number(get('stop-after-targets', '2'));
const HOST = get('host', 'http://127.0.0.1:7788');
const GUEST = get('guest', 'http://127.0.0.1:7789');
const POLL_MS = Number(get('poll-ms', '300'));

fs.mkdirSync(DIR, { recursive: true });
const out = fs.createWriteStream(path.join(DIR, 'observe.jsonl'), { flags: 'w' });
const t0 = Date.now();
const rec = (o) => out.write(JSON.stringify({ t: +((Date.now() - t0) / 1000).toFixed(3), ...o }) + '\n');
const log = (m) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}] ${m}`);

async function j(url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(3000) });
    return JSON.parse(await r.text());
  } catch { return null; }
}

const S = {
  host: { lastSeq: -1, lastCurMsg: null, battlePending: false, lp: null, targets: 0, retriesBefore: 0 },
  guest: { lastSeq: -1, lastCurMsg: null, battlePending: false, lp: null, targets: 0, retriesBefore: 0 },
};
const events = [];
const targets = [];

async function loop(name, base) {
  const s = S[name];
  while ((Date.now() - t0) / 60000 < MAX_MIN) {
    const st = await j(base + '/state');
    const pr = await j(base + '/prompt');
    if (!st || !pr) { rec({ side: name, ev: 'unreachable' }); break; }
    if (st.match && st.match.over) { rec({ side: name, ev: 'match-over', match: st.match }); break; }
    if (!st.started) { await new Promise((r) => setTimeout(r, 800)); continue; }

    const retry = st.retryCount ?? null;
    const streak = st.pipeline ? st.pipeline.retryStreak : null;

    // 10 -> 15: attack declared, now the target window
    if (pr.curMsg === 10 && pr.awaiting && pr.seq !== s.lastSeq) {
      rec({ side: name, ev: 'battlecmd', seq: pr.seq, turn: st.turn, lp: st.lp, retry, streak, attackable: (pr.attackableCards || []).length });
      s.battlePending = true;
      s.retriesBefore = retry;
      s.lastSeq = pr.seq;
    }
    if (pr.curMsg === 15 && pr.awaiting && pr.seq !== s.lastSeq) {
      const wasBattle = s.battlePending;
      const acts = await j(base + '/actions');
      const entry = {
        side: name, seq: pr.seq, turn: st.turn, phase: st.phaseName, lp: st.lp,
        retry, streak, wasBattle, selectMin: pr.selectMin, selectMax: pr.selectMax,
        selectable: (pr.selectableCards || []).map((c) => ({ i: c.i, code: c.code, name: c.name, loc: c.loc, ctrl: c.ctrl, seq: c.seq, seqNo: c.seqNo })),
        actions: ((acts && acts.actions) || []).map((a) => ({ id: a.id, kind: a.kind, label: a.label })),
      };
      rec({ side: name, ev: 'cardselect', ...entry });
      if (wasBattle) { s.targets++; targets.push(entry); }
      s.lastSeq = pr.seq;
    }
    // resolution / retry check after a target window
    if (s.battlePending && pr.curMsg !== 15 && pr.curMsg !== 10) {
      rec({ side: name, ev: 'battle-after', seq: pr.seq, curMsg: pr.curMsg, turn: st.turn, lp: st.lp, retry, streak, retryDelta: retry !== null ? retry - s.retriesBefore : null });
      s.battlePending = false;
      s.lastSeq = -1;
    }
    if (retry !== null && retry !== s.lastRetry) {
      s.lastRetry = retry;
      if (retry > 0) rec({ side: name, ev: 'retry', retry, streak, curMsg: pr.curMsg, seq: pr.seq });
    }
    if (targets.length >= STOP_AFTER_TARGETS) { rec({ ev: 'stop-after-targets', n: targets.length }); break; }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

log('observe dir=' + DIR + ' maxMin=' + MAX_MIN);
await Promise.all([
  loop('host', HOST).catch((e) => rec({ side: 'host', ev: 'crash', error: String(e) })),
  loop('guest', GUEST).catch((e) => rec({ side: 'guest', ev: 'crash', error: String(e) })),
]);
const summary = { targets: targets.length, hostTargets: S.host.targets, guestTargets: S.guest.targets, targetsDetail: targets };
fs.writeFileSync(path.join(DIR, 'observe-summary.json'), JSON.stringify(summary, null, 2), 'utf8');
out.end();
log('done targets=' + targets.length);
console.log('OBSERVE_DIR=' + DIR);
