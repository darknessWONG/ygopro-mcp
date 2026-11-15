// bridge/verify-battle-target.mjs - LAN repro for "attack target selection rejected" (task-36 item 1)
//
// Drives BOTH clients of a local LAN duel (host :7788 / guest :7789) through the control
// layer HTTP API, plays aggressively until battle phase, then selects attack targets and
// records everything needed to prove/refute the bug:
//
//   - every prompt (curMsg / selectableCards / selectMin..Max / actions)
//   - every response (/act_id id -> action kind + result)
//   - /state.retryCount / retryStreak / lastMsg around each response
//   - the 10 (MSG_SELECT_BATTLECMD) -> 15 (MSG_SELECT_CARD target) -> 10 loop signature
//
// Output (into --dir):
//   events.jsonl   one JSON object per observation / action / anomaly
//   summary.json   counters + verdict hints
//
// Usage:
//   node bridge/verify-battle-target.mjs --dir ranked/logs/repro-battle-<stamp> [--max-min 6]
//
// This script never starts or kills clients; the .ps1 wrapper does that.

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
function arg(name, dflt) {
  const i = args.indexOf('--' + name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return dflt;
}
const DIR = path.resolve(arg('dir', 'ranked/logs/verify-battle-' + new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19)));
const MAX_MIN = Number(arg('max-min', '6'));
const HOST = arg('host', 'http://127.0.0.1:7788');
const GUEST = arg('guest', 'http://127.0.0.1:7789');
const POLL_MS = Number(arg('poll-ms', '350'));
// item 3 (net-dead false positive): keep one side idle for N seconds while it is its turn,
// sampling /net + /state.net so we can prove that "thinking" does not mark the client dead.
// format: --idle-probe host:25  (or guest:25 / empty = off)
const IDLE_PROBE = String(arg('idle-probe', '')).trim();
const IDLE_SIDE = IDLE_PROBE.split(':')[0] || '';
const IDLE_SEC = Number(IDLE_PROBE.split(':')[1] || '0');
// stop after this many battle-target selections (0 = run until timeout / match over)
const STOP_AFTER_TARGETS = Number(arg('stop-after-targets', '0'));

fs.mkdirSync(DIR, { recursive: true });
const events = fs.createWriteStream(path.join(DIR, 'events.jsonl'), { flags: 'w' });
const started = Date.now();
function ts() { return ((Date.now() - started) / 1000).toFixed(3); }
function rec(o) { events.write(JSON.stringify({ t: Number(ts()), ...o }) + '\n'); }
function log(msg) { console.log(`[${ts()}] ${msg}`); }

async function get(url, timeoutMs = 4000) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    return await r.text();
  } catch { return null; }
}
async function getJson(url) {
  const t = await get(url);
  if (!t) return null;
  try { return JSON.parse(t); } catch { return null; }
}

const stats = {
  side: {
    host: { answered: 0, battlePrompts: 0, attacks: 0, targetSelects: 0, loops: 0, retryBefore: 0, retryAfter: 0 },
    guest: { answered: 0, battlePrompts: 0, attacks: 0, targetSelects: 0, loops: 0, retryBefore: 0, retryAfter: 0 },
  },
  anomalies: [],
  battleTargetEvents: [],
  lastBattlePrompt: { host: null, guest: null },
  startState: null,
  endState: null,
};

function num(v) { return typeof v === 'number' ? v : null; }

/** Choose one action for this prompt. Aggressive battle-first behaviour. */
function chooseAction(st, prompt, actions) {
  // item 4/5: MSG_ANNOUNCE_NUMBER (143). Prefer the client's semantic announce action when the
  // fixed client publishes one (pick index 1 => number "2" so Card Advance sorts 2 cards);
  // otherwise fall back to the raw int32 response used before the announce fix.
  if ((prompt.curMsg === 143 || st.curMsg === 143) && (prompt.awaiting !== false)) {
    const announces = (actions || []).filter((a) => /^announce/.test(a.kind || ''));
    if (announces.length) {
      const pick = announces.find((a) => a.index === 1 || a.index === 2) || announces[0];
      return pick;
    }
    return { rawI: 1, kind: 'announce-raw', label: 'raw announce index 1 (=> 2 cards sorted)' };
  }
  if (!actions || !actions.length) return null;
  const has = (k) => actions.filter((a) => a.kind === k);
  const first = (k) => has(k)[0] || null;

  // pre-duel / between games synthetic prompts
  if (prompt.sidePending) return first('side_ok');
  if (prompt.tpPending || has('tp').length) {
    const tp = has('tp');
    return tp.find((a) => a.index === 1 || /first/i.test(a.label || '')) || tp[0];
  }

  // MSG_SELECT_CARD (15): this is both generic card selection AND the attack-target window.
  if (prompt.curMsg === 15 || st.curMsg === 15) {
    const sel = first('select') || first('sum') || first('card');
    if (sel) return sel;
  }

  // MSG_SELECT_BATTLECMD (10): attack whenever possible
  if (prompt.curMsg === 10 || st.curMsg === 10) {
    const atk = first('attack');
    if (atk) return atk;
    return first('end_battle') || first('to_m2');
  }

  // MSG_SELECT_IDLECMD (11): build a board, then go to battle
  if (prompt.curMsg === 11 || st.curMsg === 11) {
    // item 4 (SORT_CARD): activate a sort-trigger spell as soon as it is offered.
    //   12183332 = Card Shuffle (kept for completeness)
    //   10925955 = 与仪水镜的交信 -> Duel.SortDecktop(tp,tp,2) => MSG_SORT_CARD with 2 cards
    const SORT_CODES = /12183332|10925955|52112003|49998907/;
    const shuffleAct = actions.find((a) => a.kind === 'activate' && SORT_CODES.test(a.label || ''));
    if (shuffleAct) return shuffleAct;
    const shuffleSet = actions.find((a) => a.kind === 'set_spell' && SORT_CODES.test(a.label || ''));
    if (shuffleSet) return shuffleSet;
    return first('summon') || first('set_monster') || first('spsummon') ||
           first('to_bp') || first('to_ep');
  }

  // generic priority list
  const order = ['chain', 'decline', 'yes', 'no', 'option', 'position', 'place', 'select',
                 'sum', 'attack', 'to_bp', 'to_ep', 'end_battle', 'sort', 'counter', 'announce', 'auto'];
  for (const k of order) {
    const a = first(k);
    if (!a) continue;
    if (k === 'chain') {
      // avoid pointless chains: decline unless it is the only option
      const decline = first('decline');
      if (decline) return decline;
    }
    return a;
  }
  return actions[0];
}

function promptSig(p) {
  return p ? `${p.seq}|${p.curMsg}|${p.selectMin}|${p.selectMax}` : 'null';
}

async function sideLoop(name, base) {
  const S = stats.side[name];
  let lastSeq = -1;
  let lastPromptSig = 'null';
  let idleIter = 0;

  while (true) {
    if ((Date.now() - started) / 60000 > MAX_MIN) { rec({ side: name, ev: 'timeout' }); break; }

    const st = await getJson(base + '/state');
    if (!st) { rec({ side: name, ev: 'no-state' }); break; }
    if (st.match && st.match.over) { rec({ side: name, ev: 'match-over', match: st.match }); stats.endState = st; break; }
    if (typeof st.winPlayer === 'number' && st.winPlayer >= 0) { rec({ side: name, ev: 'game-over', winPlayer: st.winPlayer, winReason: st.winReasonName }); }

    const pr = await getJson(base + '/prompt');
    if (!pr) { rec({ side: name, ev: 'no-prompt' }); break; }

    // record state transitions worth seeing (curMsg / retry counters)
    const sig = `${promptSig(pr)}|${st.retryCount}|${st.pipeline ? st.pipeline.retryStreak : ''}|${st.turn}|${st.phase}`;
    if (sig !== lastPromptSig) {
      lastPromptSig = sig;
      rec({
        side: name, ev: 'state', seq: pr.seq, curMsg: pr.curMsg, awaiting: pr.awaiting,
        turn: st.turn, phase: st.phaseName, lp: st.lp, curMsgState: st.curMsg,
        retryCount: st.retryCount, retryStreak: st.pipeline && st.pipeline.retryStreak,
        lastMsg: st.lastMsg, selectMin: pr.selectMin, selectMax: pr.selectMax,
        selectable: (pr.selectableCards || []).map((c) => ({ i: c.i, code: c.code, loc: c.loc, ctrl: c.ctrl, seq: c.seq, seqNo: c.seqNo })),
      });
    }

    // --- item 3: idle probe (our turn, we deliberately think for N seconds) ---
    if (IDLE_SEC > 0 && name === IDLE_SIDE && !S.idleProbeDone) {
      S.idleProbeDone = true;
      const probeStart = Date.now();
      rec({ side: name, ev: 'idle-probe-start', sec: IDLE_SEC, curMsg: pr.curMsg, turn: st.turn });
      while ((Date.now() - probeStart) / 1000 < IDLE_SEC) {
        await new Promise((r) => setTimeout(r, 1000));
        const ns = await getJson(base + '/state');
        const nn = await getJson(base + '/net');
        rec({
          side: name, ev: 'idle-probe', tSec: Math.round((Date.now() - probeStart) / 1000),
          stateAlive: ns && ns.net && ns.net.alive,
          net: nn && { connected: nn.connected, alive: nn.alive, sinceLastStoc: nn.sinceLastStoc, probe: nn.probe },
          curMsg: ns && ns.curMsg, awaiting: ns && ns.awaiting,
          confirmedDead: ns && (ns.confirmedDead === true || (ns.pipeline && ns.pipeline.confirmedDead === true)),
          lastMsg: ns && ns.lastMsg,
        });
        if (!nn && !ns) { rec({ side: name, ev: 'idle-probe-dead-client' }); break; }
      }
      rec({ side: name, ev: 'idle-probe-end', ms: Date.now() - probeStart });
      continue;
    }

    if (!pr.awaiting || pr.seq === lastSeq) {
      idleIter++;
      if (idleIter > 40) { rec({ side: name, ev: 'idle-40-polls', seq: pr.seq, curMsg: pr.curMsg, awaiting: pr.awaiting }); idleIter = 0; }
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }

    const act = await getJson(base + '/actions');
    const actions = (act && act.actions) || [];
    const chosen = chooseAction(st, pr, actions);
    const baseRec = {
      side: name, seq: pr.seq, curMsg: pr.curMsg, turn: st.turn, phase: st.phaseName,
      lp: st.lp, retryCount: st.retryCount, retryStreak: st.pipeline && st.pipeline.retryStreak,
      selectMin: pr.selectMin, selectMax: pr.selectMax,
      selectable: (pr.selectableCards || []).map((c) => ({ i: c.i, code: c.code, loc: c.loc, ctrl: c.ctrl, seq: c.seq, seqNo: c.seqNo })),
      actions: actions.map((a) => ({ id: a.id, kind: a.kind, label: a.label })),
    };

    if (!chosen) {
      rec({ ...baseRec, ev: 'no-action' });
      lastSeq = pr.seq;
      await new Promise((r) => setTimeout(r, 600));
      continue;
    }

    // --- bookkeeping before the response ---
    const wasBattleCmd = (pr.curMsg === 10 || st.curMsg === 10);
    const wasTarget = (pr.curMsg === 15 || st.curMsg === 15);
    const before = {
      retryCount: st.retryCount ?? null,
      retryStreak: (st.pipeline && st.pipeline.retryStreak) ?? null,
      attackCount: (pr.attackableCards || []).length,
    };
    if (wasBattleCmd) S.battlePrompts++;
    if (wasTarget) S.targetSelects++;

    const resp = chosen.rawI !== undefined
      ? await getJson(base + '/act?seq=' + pr.seq + '&i=' + chosen.rawI)
      : await getJson(base + '/act_id?id=' + chosen.id);
    S.answered++;
    rec({ ...baseRec, ev: 'act', action: chosen, resp, wasBattleCmd, wasTarget, before });

    // --- sample the immediately following state a few times: catches RETRY -> same prompt again ---
    let replayedSame = 0;
    let next = null;
    for (let k = 0; k < 4; k++) {
      await new Promise((r) => setTimeout(r, 220));
      next = await getJson(base + '/state');
      if (!next) break;
      if (next.curMsg === pr.curMsg && next.seq === pr.seq) replayedSame++;
      // same curMsg but new seq => the prompt was re-issued (core rejected our response)
      if (next.curMsg === pr.curMsg && next.seq !== pr.seq) replayedSame++;
    }
    const after = next ? {
      curMsg: next.curMsg, seq: next.seq, turn: next.turn, phase: next.phaseName,
      lp: next.lp, retryCount: next.retryCount ?? null,
      retryStreak: (next.pipeline && next.pipeline.retryStreak) ?? null,
      lastMsg: next.lastMsg,
    } : null;
    if (after) rec({ side: name, ev: 'after', seq: pr.seq, after, replayedSame, actionKind: chosen.kind });

    // --- anomaly detection: battle target rejected / loop ---
    if (wasBattleCmd && chosen.kind === 'attack') S.attacks++;
    if (wasTarget && before.retryCount !== null && after && after.retryCount !== null &&
        after.retryCount > before.retryCount) {
      S.loops++;
      stats.anomalies.push({ side: name, kind: 'retry-after-target-select', seq: pr.seq, before, after });
      rec({ side: name, ev: 'ANOMALY retry-after-select', seq: pr.seq, before, after, action: chosen });
    }
    if (wasTarget && after && (after.curMsg === 10 || after.curMsg === 15) && replayedSame > 0) {
      S.loops++;
      stats.anomalies.push({ side: name, kind: 'target-select-loop-15-10', seq: pr.seq, after, replayedSame });
      rec({ side: name, ev: 'ANOMALY target-select-loop', seq: pr.seq, after, replayedSame });
    }
    if (wasTarget) {
      stats.battleTargetEvents.push({ side: name, seq: pr.seq, curMsg: pr.curMsg, action: chosen, after, replayedSame, before });
    }

    lastSeq = pr.seq;
    await new Promise((r) => setTimeout(r, POLL_MS));
    if (STOP_AFTER_TARGETS > 0 && stats.battleTargetEvents.length >= STOP_AFTER_TARGETS) {
      rec({ side: name, ev: 'stop-after-targets', n: stats.battleTargetEvents.length });
      break;
    }
  }
}

// --- main ---
log('verify-battle-target dir=' + DIR + ' maxMin=' + MAX_MIN + ' host=' + HOST + ' guest=' + GUEST);
const hs0 = await getJson(HOST + '/state');
const gs0 = await getJson(GUEST + '/state');
stats.startState = { host: hs0 && { started: hs0.started, turn: hs0.turn }, guest: gs0 && { started: gs0.started, turn: gs0.turn } };
rec({ ev: 'start', host: stats.startState.host, guest: stats.startState.guest });

await Promise.all([
  sideLoop('host', HOST).catch((e) => rec({ side: 'host', ev: 'crash', error: String(e) })),
  sideLoop('guest', GUEST).catch((e) => rec({ side: 'guest', ev: 'crash', error: String(e) })),
]);

const hs1 = await getJson(HOST + '/state');
stats.endState = hs1;
rec({ ev: 'end', host: hs1 && { started: hs1.started, curMsg: hs1.curMsg, turn: hs1.turn, lp: hs1.lp, retryCount: hs1.retryCount } });

// verdict hints
const verdict = {
  battlePrompts: stats.side.host.battlePrompts + stats.side.guest.battlePrompts,
  attacksIssued: stats.side.host.attacks + stats.side.guest.attacks,
  targetSelects: stats.side.host.targetSelects + stats.side.guest.targetSelects,
  loops: stats.side.host.loops + stats.side.guest.loops,
  anomalies: stats.anomalies.length,
  battleTargetEvents: stats.battleTargetEvents.length,
  bugReproduced: stats.anomalies.length > 0,
};
fs.writeFileSync(path.join(DIR, 'summary.json'), JSON.stringify({ stats, verdict }, null, 2), 'utf8');
events.end();
log('verdict=' + JSON.stringify(verdict));
console.log('EVIDENCE_DIR=' + DIR);



