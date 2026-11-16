// bridge/verify-battle-target-monster.mjs - deterministic LAN check: attack the OPPONENT'S monster
// (not a direct attack), select it as MSG_SELECT_CARD(15) target, and prove the battle resolves.
//
// Scenario built deterministically:
//   host  (deck battle-test     : lv4 normal ATK 2000)
//   guest (deck battle-test-low : lv4 normal ATK 1500)
//   host turn 1: summon -> pass
//   guest turn 1: summon -> pass (defender never attacks, so the fields stay)
//   host turn 2: go to battle -> attack -> MSG_SELECT_CARD(15) with guest's monster selectable
//                -> answer raw bytes [1, seqNo] of the guest's monster
// Expected: guest monster destroyed, guest LP 8000 -> 7500, firstid=110(MSG_BATTLE), no
//           "RETRY after msg=15", timeLeft keeps running, no eof.
//
// Outputs into --dir: events.jsonl, summary.json, and prints "TARGET_DIR=<dir>".
// The .ps1 wrapper launches/kills clients and copies control logs.

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };

const DIR = path.resolve(get('dir', 'ranked/logs/battle-target-monster'));
const MAX_MIN = Number(get('max-min', '5'));
const STOP_AFTER_HITS = Number(get('stop-after-hits', '1'));
const MULTI = args.includes('--multi');
const HOST = get('host', 'http://127.0.0.1:7788');
const GUEST = get('guest', 'http://127.0.0.1:7789');
const POLL_MS = Number(get('poll-ms', '300'));

fs.mkdirSync(DIR, { recursive: true });
const out = fs.createWriteStream(path.join(DIR, 'events.jsonl'), { flags: 'w' });
const t0 = Date.now();
const el = () => +((Date.now() - t0) / 1000).toFixed(3);
const rec = (o) => out.write(JSON.stringify({ t: el(), ...o }) + '\n');
const log = (m) => console.log(`[${el().toFixed(1)}] ${m}`);

async function j(url) {
  try { const r = await fetch(url, { signal: AbortSignal.timeout(3000) }); return JSON.parse(await r.text()); }
  catch { return null; }
}

const R = {
  targetEvents: [], hits: 0, fails: 0, anomalies: [],
  hostFirstSeen: null, guestFirstSeen: null, endStates: null,
};

function ownOf(st) { return (st && st.monsters && st.monsters[0]) || []; }
function oppOf(st) { return (st && st.monsters && st.monsters[1]) || []; }
function bestAtk(list) { return list.reduce((m, c) => Math.max(m, c.atk || 0), 0); }
function cardAtk(c) { return c && typeof c.atk === 'number' ? c.atk : 0; }

// choose the attack action whose attacker has the highest ATK
function pickAttack(actions) {
  const atks = (actions || []).filter((a) => a.kind === 'attack');
  if (!atks.length) return null;
  // labels are "attack #<i> atk=<n>"; the #i is the index in attackableList (same order as actions)
  let best = atks[0], bestAtk = -1;
  for (const a of atks) {
    const m = /atk=(\d+)/.exec(a.label || '');
    const atk = m ? Number(m[1]) : 0;
    if (atk > bestAtk) { bestAtk = atk; best = a; }
  }
  return best;
}

function pickSummon(actions) {
  const su = (actions || []).filter((a) => a.kind === 'summon' || a.kind === 'set_monster');
  if (!su.length) return null;
  let best = su[0], bestAtk = -1;
  for (const a of su) {
    const m = /code=(\d+)/.exec(a.label || '');
    // no atk in label for summon; just take the first (deck is homogeneous)
    if (m) { best = a; break; }
  }
  return best;
}

async function act(base, seq, action) {
  // raw byte response (used for MSG_SELECT_CARD target)
  if (action.hex) {
    return await j(base + '/act?seq=' + seq + '&hex=' + action.hex);
  }
  return await j(base + '/act_id?id=' + action.id);
}

async function runSide(name, base, role) {
  let lastSeq = -1;
  let afterAttack = false;
  const isHost = role === 'attacker';
  while ((Date.now() - t0) / 60000 < MAX_MIN) {
    if (R.hits >= STOP_AFTER_HITS) { rec({ side: name, ev: 'hit-goal-reached' }); break; }
    const st = await j(base + '/state');
    const pr = await j(base + '/prompt');
    if (!st || !pr) { rec({ side: name, ev: 'unreachable' }); break; }
    if (st.match && st.match.over) { rec({ side: name, ev: 'match-over' }); break; }
    if (name === 'host' && !R.hostFirstSeen) R.hostFirstSeen = { turn: st.turn, mySeat: st.mySeat };
    if (name === 'guest' && !R.guestFirstSeen) R.guestFirstSeen = { turn: st.turn, mySeat: st.mySeat };

    if (pr.awaiting !== true || pr.seq === lastSeq) {
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }

    const actions = ((await j(base + '/actions')) || {}).actions || [];
    const own = ownOf(st), opp = oppOf(st);
    const curMsg = pr.curMsg;

    // pre-duel
    if (pr.sidePending) {
      const a = actions.find((x) => x.kind === 'side_ok');
      if (a) { await act(base, pr.seq, a); lastSeq = pr.seq; rec({ side: name, ev: 'side_ok' }); }
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }
    if (pr.tpPending) {
      const tp = actions.filter((x) => x.kind === 'tp');
      const a = tp.find((x) => x.index === 1) || tp[0];
      if (a) { await act(base, pr.seq, a); lastSeq = pr.seq; rec({ side: name, ev: 'tp', action: a }); }
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }

    // MSG_SELECT_CARD (15) = the attack-target window
    if (curMsg === 15 || st.curMsg === 15) {
      const sel = pr.selectableCards || [];
      rec({
        side: name, ev: 'card-select', seq: pr.seq, curMsg, selectMin: pr.selectMin, selectMax: pr.selectMax,
        selectable: sel.map((c) => ({ i: c.i, code: c.code, name: c.name, loc: c.loc, ctrl: c.ctrl, seq: c.seq, seqNo: c.seqNo, atk: c.atk })),
        actions: actions.map((a) => ({ id: a.id, kind: a.kind, label: a.label })),
        afterAttackFlag: afterAttack,
      });
      // The attack-target window is only recognised right after our own attack action; the
      // selectable list then contains exactly the legal defenders (client reports ctrl relative,
      // so do not filter on ctrl). Take the first selectable card as the target.
      if (isHost && afterAttack && sel.length > 0) {
        const target = sel[0];
        const n = pr.selectMin && pr.selectMin > 0 ? pr.selectMin : 1;
        // response = [count][seqNo...] (official bytes, no extra prefix)
        let hex = n.toString(16).padStart(2, '0');
        for (let k = 0; k < n; k++) hex += (sel[k].seqNo & 0xff).toString(16).padStart(2, '0');
        const before = {
          hostMonsters: own.length, targetCount: sel.length,
          hostState: { mz: own.length, lp: st.lp, timeLeft: st.timeLeft, turn: st.turn },
        };
        const resp = await act(base, pr.seq, { hex });
        afterAttack = false;
        rec({ side: name, ev: 'target-act', seq: pr.seq, target, hex, resp, before, selectableCount: sel.length });
        lastSeq = pr.seq;
        // poll until the battle actually resolves (damage/destroy), up to ~8s
        const preH = await j(HOST + '/state');
        const guestLpBefore = preH && Array.isArray(preH.lp) && preH.lp.length > 1 ? preH.lp[1] : null;
        let after = null, destroyed = false, lpChanged = false, hit = false;
        for (let k = 0; k < 16; k++) {
          await new Promise((r) => setTimeout(r, 500));
          const hs = await j(HOST + '/state');
          const gs = await j(GUEST + '/state');
          after = {
            host: hs && { mz: ownOf(hs).length, lp: hs.lp, curMsg: hs.curMsg, turn: hs.turn, timeLeft: hs.timeLeft, retryCount: hs.retryCount },
            guest: gs && { mz: ownOf(gs).length, lp: gs.lp, curMsg: gs.curMsg, turn: gs.turn, timeLeft: gs.timeLeft },
          };
          const guestLpAfter = hs && Array.isArray(hs.lp) ? hs.lp[1] : null;
          const guestMonAfter = gs && ownOf(gs).length;
          destroyed = guestMonAfter !== null && guestMonAfter < sel.length;
          lpChanged = guestLpBefore !== null && guestLpAfter !== null && guestLpAfter < guestLpBefore;
          if (destroyed || lpChanged) { hit = true; break; }
        }
        rec({ side: name, ev: 'target-after', seq: pr.seq, after, destroyed, lpChanged, hit, guestLpBefore });
        R.targetEvents.push({ seq: pr.seq, target, hex, hit, destroyed, lpChanged, before, after });
        if (hit) { R.hits++; rec({ ev: 'HIT', n: R.hits, seq: pr.seq }); } else { R.fails++; }
        await new Promise((r) => setTimeout(r, 400));
        continue;
      }
      // non-attack card selection (hand/effect) -> closest safe default
      const selAct = actions.find((a) => a.kind === 'select') || actions.find((a) => a.kind === 'sum');
      if (selAct) { await act(base, pr.seq, selAct); lastSeq = pr.seq; rec({ side: name, ev: 'card-select-default', action: selAct }); }
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }

    // MSG_SELECT_BATTLECMD (10)
    if (curMsg === 10 || st.curMsg === 10) {
      const attack = pickAttack(actions);
      if (isHost && attack && opp.length > 0) {
        rec({ side: name, ev: 'battle-attack', seq: pr.seq, action: attack, own: own.length, opp: opp.length });
        await act(base, pr.seq, attack);
        afterAttack = true;
        lastSeq = pr.seq;
        await new Promise((r) => setTimeout(r, 600));
        continue;
      }
      const end = actions.find((a) => a.kind === 'end_battle');
      if (end) { await act(base, pr.seq, end); lastSeq = pr.seq; rec({ side: name, ev: 'end-battle' }); }
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }

    // MSG_SELECT_IDLECMD (11)
    if (curMsg === 11 || st.curMsg === 11) {
      const summon = pickSummon(actions);
      let action = null;
      if (MULTI) {
        // build two attackers / two defenders first, then swing with both attackers
        const wantSummon = own.length < 2 && !!summon;
        if (wantSummon) action = summon;
        else if (isHost && own.length >= 2 && opp.length >= 2) {
          action = actions.find((a) => a.kind === 'to_bp') || actions.find((a) => a.kind === 'to_ep');
        } else action = actions.find((a) => a.kind === 'to_ep') || actions.find((a) => a.kind === 'to_bp');
      } else if (own.length === 0 && summon) action = summon;              // build our board
      else if (isHost && own.length > 0 && opp.length > 0) {
        action = actions.find((a) => a.kind === 'to_bp') || actions.find((a) => a.kind === 'to_ep');
      } else action = actions.find((a) => a.kind === 'to_ep') || actions.find((a) => a.kind === 'to_bp');
      if (action) { await act(base, pr.seq, action); lastSeq = pr.seq; rec({ side: name, ev: 'idle', seq: pr.seq, action, own: own.length, opp: opp.length }); }
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }

    // generic safe defaults
    const order = ['chain', 'decline', 'yes', 'no', 'option', 'position', 'place', 'sort', 'select', 'to_ep', 'end_battle', 'auto'];
    let a = null;
    for (const k of order) { a = (actions || []).find((x) => x.kind === k); if (a) break; }
    if (!a) a = (actions || [])[0];
    if (a) { await act(base, pr.seq, a); lastSeq = pr.seq; rec({ side: name, ev: 'default', seq: pr.seq, action: a }); }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

log('verify-battle-target-monster dir=' + DIR + ' maxMin=' + MAX_MIN);
await Promise.all([
  runSide('host', HOST, 'attacker').catch((e) => rec({ side: 'host', ev: 'crash', error: String(e) })),
  runSide('guest', GUEST, 'defender').catch((e) => rec({ side: 'guest', ev: 'crash', error: String(e) })),
]);
R.endStates = { host: await j(HOST + '/state'), guest: await j(GUEST + '/state') };
const verdict = {
  hits: R.hits, fails: R.fails, targetEvents: R.targetEvents.length,
  anomalyCount: R.anomalies.length,
  pass: R.hits >= STOP_AFTER_HITS,
};
fs.writeFileSync(path.join(DIR, 'summary.json'), JSON.stringify({ verdict, result: R }, null, 2), 'utf8');
out.end();
log('verdict=' + JSON.stringify(verdict));
console.log('TARGET_DIR=' + DIR);




