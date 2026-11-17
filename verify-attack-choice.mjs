// bridge/verify-attack-choice.mjs - deterministic LAN check for ATTACK TARGET CHOICE (task: choice bug)
//
// Layout:
//   host  = attacker, deck attack-test  (lv4 normal: ATK 1600 / 1900)
//   guest = defender, deck defense-two  (lv4 normal: ATK 1500 / 1900)
// Guest builds TWO monsters (first summon prefers the 1900 one, second prefers 1500) so the
// attack-target window has two candidates with different ATK. Host summons one attacker, waits for
// the guest's second monster, then attacks.
//
// Modes:
//   before : use /actions as-is (expected on the buggy build: exactly ONE select action ->
//            "select first N" -> always candidate[0]). Record /actions + selectable + outcome.
//   after  : the fixed client should expose one action per candidate (`select_card`, label with
//            code/atk/def/loc/seq) plus `select_auto`. Pick by --pick-atk (e.g. 1500) or
//            --pick auto|first.
//
// Output: events.jsonl + summary.json with actionsAtTarget / selectable / submitted / outcome.

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const has = (k) => args.includes('--' + k);

const DIR = path.resolve(get('dir', 'ranked/logs/attack-choice'));
const MAX_MIN = Number(get('max-min', '4'));
const HOST = get('host', 'http://127.0.0.1:7788');
const GUEST = get('guest', 'http://127.0.0.1:7789');
const MODE = get('mode', has('after') ? 'after' : 'before');
const DIRECT = has('direct');
const PICK = get('pick', 'first');            // first | auto | atk:<n>
const ATTEMPTS = Number(get('attempts', '1'));
const MULTI = has('multi');
const GUEST_NO_SUMMON = has('guest-no-summon');
const PICK_SEQ = (get('pick-seq', '') || '').split(',').map(s=>s.trim()).filter(Boolean);

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
const own = (st) => (st && st.monsters && st.monsters[0]) || [];
const opp = (st) => (st && st.monsters && st.monsters[1]) || [];
const atkOf = (c) => (c && typeof c.atk === 'number' ? c.atk : 0);

const R = { mode: MODE, attempts: [], results: [], actionsAtTarget: null, selectableAtTarget: null };

// pick a summon action by desired ATK from /prompt.summonableCards + /actions (same order)
function chooseSummon(st, pr, actions, wantAtk) {
  const cards = pr.summonableCards || [];
  const acts = (actions || []).filter((a) => a.kind === 'summon' || a.kind === 'set_monster');
  if (!acts.length) return null;
  const summonActs = (actions || []).filter((a) => a.kind === 'summon');
  if (wantAtk === 'high') {
    let best = null, bestAtk = -1;
    for (let i = 0; i < summonActs.length && i < cards.length; i++) {
      if (atkOf(cards[i]) > bestAtk) { bestAtk = atkOf(cards[i]); best = summonActs[i]; }
    }
    return best || summonActs[0];
  }
  if (wantAtk === 'low') {
    let best = null, bestAtk = 99999;
    for (let i = 0; i < summonActs.length && i < cards.length; i++) {
      if (atkOf(cards[i]) < bestAtk) { bestAtk = atkOf(cards[i]); best = summonActs[i]; }
    }
    return best || summonActs[0];
  }
  // numeric preference: closest atk
  if (typeof wantAtk === 'number') {
    let best = summonActs[0], bestD = 1e9;
    for (let i = 0; i < summonActs.length && i < cards.length; i++) {
      const dd = Math.abs(atkOf(cards[i]) - wantAtk);
      if (dd < bestD) { bestD = dd; best = summonActs[i]; }
    }
    return best;
  }
  return summonActs[0];
}

async function runHost() {
  let lastSeq = -1, afterAttack = false, inTarget = false;
  const deadline = Date.now() + MAX_MIN * 60000;
  while (Date.now() < deadline) {
    if (R.results.length >= ATTEMPTS) break;
    const st = await j(HOST + '/state');
    const pr = await j(HOST + '/prompt');
    if (!st || !pr) { rec({ side: 'host', ev: 'unreachable' }); break; }
    if (st.match && st.match.over) { rec({ side: 'host', ev: 'match-over' }); break; }
    if (pr.sidePending) { const a = ((await j(HOST + '/actions')) || {}).actions || []; const s = a.find((x) => x.kind === 'side_ok'); if (s) await j(HOST + '/act_id?id=' + s.id); await sleep(300); continue; }
    if (pr.tpPending) { const a = ((await j(HOST + '/actions')) || {}).actions || []; const tp = a.filter((x) => x.kind === 'tp'); const s = tp.find((x) => x.index === 1) || tp[0]; if (s) await j(HOST + '/act_id?id=' + s.id); await sleep(300); continue; }
    if (pr.awaiting !== true || pr.seq === lastSeq) { await sleep(250); continue; }

    const actions = ((await j(HOST + '/actions')) || {}).actions || [];
    const my = own(st), their = opp(st);

    if (pr.curMsg === 15) {
      const sel = pr.selectableCards || [];
      if (afterAttack && sel.length >= 1) {
        inTarget = true;
        const entry = {
          actions: actions.map((a) => ({ id: a.id, kind: a.kind, label: a.label })),
          selectable: sel.map((c) => ({ i: c.i, code: c.code, name: c.name, atk: c.atk, def: c.def, loc: c.loc, ctrl: c.ctrl, seq: c.seq, seqNo: c.seqNo })),
          selectMin: pr.selectMin, selectMax: pr.selectMax,
        };
        R.actionsAtTarget = entry.actions;
        R.selectableAtTarget = entry.selectable;
        rec({ side: 'host', ev: 'target-window', ...entry });

        // choose the action to submit
        let chosen = null;
        const selectCards = actions.filter((a) => a.kind === 'select_card' || a.kind === 'card');
        const pickNow = PICK_SEQ.length ? (PICK_SEQ[R.results.length] || PICK_SEQ[PICK_SEQ.length - 1]) : PICK;
        if (MODE === 'after' && selectCards.length) {
          if (pickNow === 'auto') chosen = actions.find((a) => a.kind === 'select_auto') || selectCards[0];
          else if (/^atk:\d+$/.test(pickNow)) {
            const want = Number(pickNow.split(':')[1]);
            chosen = selectCards.find((a) => new RegExp('atk=' + want + '\\b').test(a.label || '')) || null;
            if (!chosen) chosen = selectCards[0];
          } else chosen = selectCards[0];
        } else {
          const simple = actions.find((a) => a.kind === 'select') || actions.find((a) => a.kind === 'select_card');
          chosen = simple || actions[0];
        }
        if (!chosen) { rec({ side: 'host', ev: 'no-target-action' }); lastSeq = pr.seq; await sleep(500); continue; }

        // baseline right before the attack resolution
        const gsB = await j(GUEST + '/state');
        const hsB = await j(HOST + '/state');
        const base = {
          hostMz: own(hsB).length, guestMz: own(gsB).length,
          hostLp: hsB && hsB.lp, guestLp: gsB && gsB.lp,
          attackerAtkHint: R.lastAttackAtk ?? null,
        };
        const resp = await j(HOST + '/act_id?id=' + chosen.id);
        rec({ side: 'host', ev: 'target-submit', chosen, resp, base, picked: MODE === 'before' ? entry.selectable[0] : (chosen && /atk=(\d+)/.exec(chosen.label || '') ? { atk: Number(/atk=(\d+)/.exec(chosen.label)[1]) } : null) });
        lastSeq = pr.seq;
        afterAttack = false;

        // poll outcome up to 10s
        let outcome = null, guestDead = null, hostDead = null;
        for (let k = 0; k < 20; k++) {
          await sleep(500);
          const hs = await j(HOST + '/state');
          const gs = await j(GUEST + '/state');
          const nowGuestMz = own(gs).length, nowHostMz = own(hs).length;
          const guestLp = hs && Array.isArray(hs.lp) ? hs.lp[1] : null;
          const hostLp = hs && Array.isArray(hs.lp) ? hs.lp[0] : null;
          outcome = { hostMz: nowHostMz, guestMz: nowGuestMz, hostLp, guestLp, turn: hs && hs.turn, curMsg: hs && hs.curMsg, timeLeft: hs && hs.timeLeft };
          guestDead = nowGuestMz < base.guestMz;
          hostDead = nowHostMz < base.hostMz;
          if (guestDead || hostDead || (guestLp !== null && base.guestLp && guestLp < base.guestLp[1])) break;
        }
        const result = {
          mode: MODE, chosen: { id: chosen.id, kind: chosen.kind, label: chosen.label },
          base, outcome, guestMonsterDestroyed: !!guestDead, hostMonsterDestroyed: !!hostDead,
          submitted: resp,
        };
        R.results.push(result);
        rec({ side: 'host', ev: 'target-result', ...result });
        await sleep(600);
        continue;
      }
      const selAct = actions.find((a) => a.kind === 'select') || actions.find((a) => a.kind === 'select_card') || actions.find((a) => a.kind === 'sum');
      if (selAct) { await j(HOST + '/act_id?id=' + selAct.id); }
      lastSeq = pr.seq;
      await sleep(300);
      continue;
    }

    if (pr.curMsg === 10) {
      const atkActs = actions.filter((a) => a.kind === 'attack');
      const cards = pr.attackableCards || [];
      const canSwing = MULTI ? (their.length > 0)
        : DIRECT ? (their.length === 0)
        : (their.length >= 2);
      if (atkActs.length && canSwing && my.length > 0) {
        let best = atkActs[0], bestAtk = -1;
        for (let i = 0; i < atkActs.length && i < cards.length; i++) {
          if (atkOf(cards[i]) > bestAtk) { bestAtk = atkOf(cards[i]); best = atkActs[i]; }
        }
        R.lastAttackAtk = bestAtk;
        rec({ side: 'host', ev: 'attack', action: best, attackerAtk: bestAtk, oppCount: their.length, direct: their.length === 0 });
        await j(HOST + '/act_id?id=' + best.id);
        afterAttack = true;
        lastSeq = pr.seq;
        await sleep(500);
        continue;
      }
      const end = actions.find((a) => a.kind === 'end_battle');
      if (end) { await j(HOST + '/act_id?id=' + end.id); }
      lastSeq = pr.seq;
      await sleep(400);
      continue;
    }

    if (pr.curMsg === 11) {
      let a = null;
      const wantAttackers = MULTI ? 2 : 1;
      if (my.length < wantAttackers) a = chooseSummon(st, pr, actions, 1600);
      else if (MULTI ? their.length >= 2 : their.length >= 2) a = actions.find((x) => x.kind === 'to_bp') || actions.find((x) => x.kind === 'to_ep');
      else if (DIRECT) a = actions.find((x) => x.kind === 'to_bp') || actions.find((x) => x.kind === 'to_ep');
      else a = actions.find((x) => x.kind === 'to_ep') || actions.find((x) => x.kind === 'to_bp');
      if (a) { await j(HOST + '/act_id?id=' + a.id); rec({ side: 'host', ev: 'idle', action: a, my: my.length, their: their.length }); }
      lastSeq = pr.seq;
      await sleep(400);
      continue;
    }

    // generic
    const order = ['sort', 'select', 'sum', 'position', 'place', 'option', 'yes', 'no', 'decline', 'to_ep', 'auto'];
    let a = null;
    for (const k of order) { a = actions.find((x) => x.kind === k); if (a) break; }
    if (a) { await j(HOST + '/act_id?id=' + a.id); }
    lastSeq = pr.seq;
    await sleep(400);
  }
}

async function runGuest() {
  let lastSeq = -1;
  const deadline = Date.now() + MAX_MIN * 60000;
  while (Date.now() < deadline) {
    if (R.results.length >= ATTEMPTS) break;
    const st = await j(GUEST + '/state');
    const pr = await j(GUEST + '/prompt');
    if (!st || !pr) break;
    if (st.match && st.match.over) break;
    if (pr.sidePending) { const a = ((await j(GUEST + '/actions')) || {}).actions || []; const s = a.find((x) => x.kind === 'side_ok'); if (s) await j(GUEST + '/act_id?id=' + s.id); await sleep(300); continue; }
    if (pr.tpPending) { const a = ((await j(GUEST + '/actions')) || {}).actions || []; const tp = a.filter((x) => x.kind === 'tp'); const s = tp.find((x) => x.index === 1) || tp[0]; if (s) await j(GUEST + '/act_id?id=' + s.id); await sleep(300); continue; }
    if (pr.awaiting !== true || pr.seq === lastSeq) { await sleep(250); continue; }
    const actions = ((await j(GUEST + '/actions')) || {}).actions || [];
    const my = own(st);
    if (pr.curMsg === 11) {
      let a = null;
      if (GUEST_NO_SUMMON) a = actions.find((x) => x.kind === 'to_ep') || actions.find((x) => x.kind === 'to_bp');
      else if (my.length < 2) a = chooseSummon(st, pr, actions, my.length === 0 ? 'high' : 'low');
      else a = actions.find((x) => x.kind === 'to_ep');
      if (a) { await j(GUEST + '/act_id?id=' + a.id); rec({ side: 'guest', ev: 'idle', action: a, my: my.length }); }
      lastSeq = pr.seq;
      await sleep(400);
      continue;
    }
    if (pr.curMsg === 10) { const e = actions.find((x) => x.kind === 'end_battle'); if (e) await j(GUEST + '/act_id?id=' + e.id); lastSeq = pr.seq; await sleep(400); continue; }
    const order = ['sort', 'select', 'sum', 'position', 'place', 'option', 'yes', 'no', 'decline', 'to_ep', 'auto'];
    let a = null;
    for (const k of order) { a = actions.find((x) => x.kind === k); if (a) break; }
    if (a) await j(GUEST + '/act_id?id=' + a.id);
    lastSeq = pr.seq;
    await sleep(400);
  }
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

log('verify-attack-choice dir=' + DIR + ' mode=' + MODE + ' pick=' + PICK + ' attempts=' + ATTEMPTS);
await Promise.all([runHost().catch((e) => rec({ side: 'host', ev: 'crash', error: String(e) })), runGuest().catch((e) => rec({ side: 'guest', ev: 'crash', error: String(e) }))]);
const summary = {
  mode: MODE, pick: PICK, attempts: R.results.length,
  actionsAtTarget: R.actionsAtTarget, selectableAtTarget: R.selectableAtTarget,
  results: R.results,
  endStates: { host: await j(HOST + '/state'), guest: await j(GUEST + '/state') },
};
fs.writeFileSync(path.join(DIR, 'summary.json'), JSON.stringify(summary, null, 2), 'utf8');
out.end();
log('done results=' + R.results.length);
console.log('CHOICE_DIR=' + DIR);


