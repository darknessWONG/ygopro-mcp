#!/usr/bin/env node
// bridge/policy-heuristic.mjs - adapt the control API's prompt/state to policy/heuristic.mjs and back.
// Falls back to bridge/policy-basic style answers when the heuristic has no opinion.
import { decide as heuristicDecide } from '../policy/heuristic.mjs';

const BASE = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const OVERLAY = process.env.OVERLAY_URL || 'http://127.0.0.1:7790';
const overlayPost = (path, body) => fetch(OVERLAY + path, { method: 'POST', body, signal: AbortSignal.timeout(3000) }).catch(() => {});
const SHOW = { 10: '战斗阶段决策', 11: '主要阶段决策', 16: '连锁', 15: '选卡', 18: '选区域', 19: '表示形式', 12: '是否发动', 13: '是否', 14: '选项', 20: '解放', 22: '指示物', 23: '合计', 24: '禁区域', 25: '排序', 26: '选/取消' };
const MSG = { WIN: 5, BATTLECMD: 10, IDLECMD: 11, EFFECTYN: 12, YESNO: 13, OPTION: 14, CARD: 15, CHAIN: 16, PLACE: 18, POSITION: 19, TRIBUTE: 20, COUNTER: 22, SUM: 23, DISFIELD: 24, SORT: 25, UNSELECT: 26 };
const NAME = Object.fromEntries(Object.entries(MSG).map(([k, v]) => [v, k]));
const PHASES = { 1: 'draw', 2: 'standby', 4: 'main1', 8: 'battle', 0x10: 'main2', 0x20: 'end' };

async function req(path, method = 'GET') {
  const res = await fetch(BASE + path, { method, signal: AbortSignal.timeout(30000) });
  const t = await res.text();
  try { return JSON.parse(t); } catch { return { raw: t }; }
}
const jitter = (a = 200, b = 650) => new Promise((r) => setTimeout(r, a + Math.random() * (b - a)));
let placeTurn = 0;
const log = (...a) => console.log('[heur]', ...a);

function toState(st) {
  const mine = st.myPlayer ?? 0;
  const field = [0, 1].map((i) => ({
    monsters: (st.monsters?.[i] ?? []).map((c) => ({
      code: c.code, atk: c.atk, def: c.def, level: 0,
      position: (c.pos & 0x5) ? 'attack' : 'defense',
      faceUp: !!c.faceup, sequence: c.seq, hidden: !!c.hidden,
    })),
    spellsTraps: (st.spells?.[i] ?? []).length,
  }));
  return {
    turn: st.turn, turnPlayer: mine, phase: PHASES[st.phase] || 'main1',
    lp: st.lp, handCount: st.counts?.hand ?? [0, 0], deckCount: st.counts?.deck ?? [0, 0],
    graveCount: st.counts?.grave ?? [0, 0], myTeam: mine, field,
  };
}

function toRequest(p) {
  switch (p.curMsg) {
    case MSG.IDLECMD: {
      const c = [];
      (p.summonableCards ?? []).forEach((x) => c.push({ id: 'summon:' + x.i, kind: 'summon', index: x.i, card: { code: x.code, atk: x.atk, def: x.def } }));
      (p.spsummonableCards ?? []).forEach((x) => c.push({ id: 'spsummon:' + x.i, kind: 'sp_summon', index: x.i, card: { code: x.code, atk: x.atk, def: x.def, level: x.lv } }));
      (p.reposableCards ?? []).forEach((x) => c.push({ id: 'repos:' + x.i, kind: 'pos_change', index: x.i }));
      (p.msetableCards ?? []).forEach((x) => c.push({ id: 'mset:' + x.i, kind: 'monster_set', index: x.i, card: { code: x.code, atk: x.atk, def: x.def } }));
      (p.ssetableCards ?? []).forEach((x) => c.push({ id: 'sset:' + x.i, kind: 'spell_set', index: x.i }));
      (p.activatableCards ?? []).forEach((x) => c.push({ id: 'act:' + x.i, kind: 'activate', index: x.i, card: { code: x.code } }));
      if (p.canBp) c.push({ id: 'to_bp', kind: 'to_bp', index: 0 });
      c.push({ id: 'to_ep', kind: 'to_ep', index: 0 });
      return { kind: 'idle', candidates: c };
    }
    case MSG.BATTLECMD: {
      const c = [];
      (p.attackableCards ?? []).forEach((x) => c.push({ id: 'atk:' + x.i, kind: 'attack', index: x.i, attacker: { code: x.code, atk: x.atk } }));
      c.push({ id: 'to_m2', kind: 'to_m2', index: 0 });
      c.push({ id: 'to_ep', kind: 'to_ep', index: 0 });
      return { kind: 'battle', candidates: c };
    }
    case MSG.CHAIN: {
      const list = p.chains ?? [];
      const c = list.map((x, i) => ({ id: 'chain:' + i, kind: 'chain', index: i, forced: !!x.forced, card: { code: x.code, desc: x.desc } }));
      const forcedIdx = list.findIndex((x) => x.forced);
      // forced chains cannot be declined - only offer the chain(s)
      if (p.chainForced || forcedIdx >= 0) return { kind: 'chain', candidates: [c[forcedIdx >= 0 ? forcedIdx : 0]] };
      c.push({ id: 'decline', kind: 'decline', index: -1 });
      return { kind: 'chain', candidates: c };
    }
    case MSG.CARD:
    case MSG.TRIBUTE: {
      const c = (p.selectableCards ?? []).map((x, i) => ({
        id: 'card:' + i, kind: 'card', index: i,
        card: { code: x.code, atk: x.atk, def: x.def, controller: 0, location: x.loc, zone: 'monster', position: null, faceUp: true, hidden: false, sequence: x.seq },
      }));
      return { kind: 'card', candidates: c, min: p.selectMin || 1, max: p.selectMax || 1, canCancel: !!p.selectCancelable };
    }
    case MSG.SUM: {
      const n = Math.min(p.selectMax || 1, (p.selectableCards || []).length || 1);
      return { kind: 'sum', candidates: [{ id: 'sum:all', kind: 'sum', count: n }] };
    }
    case MSG.POSITION: return { kind: 'position', candidates: [{ id: 'pos:attack', kind: 'position', position: 'attack' }] };
    case MSG.PLACE:
    case MSG.DISFIELD: {
      const all = (p.places ?? []).map((x, i) => ({ id: 'place:' + i, kind: 'place', index: i, player: x.ctrl, zone: x.loc === 8 ? 'spell' : 'monster', seq: x.seq, ctrl: x.ctrl, loc: x.loc }));
      if (all.length > 1) { const k = placeTurn++ % all.length; all.push(...all.splice(0, k)); }
      return { kind: p.curMsg === MSG.PLACE ? 'place' : 'disfield', candidates: all };
    }
    default: return null;
  }
}

function encode(p, chosen) {
  const m = p.curMsg;
  const one = Array.isArray(chosen) ? chosen[0] : chosen;
  if (m === MSG.IDLECMD) {
    const cmd = { summon: 0, sp_summon: 1, pos_change: 2, monster_set: 3, spell_set: 4, activate: 5, to_bp: 6, to_ep: 7, shuffle: 8 }[one?.kind ?? 'to_ep'];
    return { i: ((one?.index ?? 0) << 16) | (cmd ?? 7) };
  }
  if (m === MSG.BATTLECMD) {
    const cmd = { chain: 0, activate: 0, attack: 1, to_m2: 2, to_ep: 3 }[one?.kind ?? 'to_ep'];
    return { i: ((one?.index ?? 0) << 16) | (cmd ?? 3) };
  }
  if (m === MSG.CHAIN) return { i: one && one.kind === 'chain' ? one.index : -1 };
  if (m === MSG.CARD || m === MSG.TRIBUTE) {
    const picks = (Array.isArray(chosen) ? chosen : chosen ? [chosen] : []).filter(Boolean);
    const n = Math.max(p.selectMin || 1, picks.length || 1);
    // the engine expects select_seq values, not our list indices
    const idx = picks.map((c) => (c.card && c.card.seqNo !== undefined) ? c.card.seqNo : c.index);
    while (idx.length < n) idx.push(0);
    return { hex: String(n).padStart(2, '0') + idx.map((x) => x.toString(16).padStart(2, '0')).join('') };
  }
  if (m === MSG.SUM) {
    const cards = p.selectableCards || [];
    const target = p.sumTarget || 0;
    const mode = p.sumMode || 0;              // 0 = sum must equal target, 1 = must be >= target
    const maxN = Math.max(1, Math.min(p.selectMax || cards.length, cards.length));
    const minN = Math.max(1, p.selectMin || 1);
    const val = (c) => ((c.op || 0) & 0xffff) || 0;
    const items = cards.map((c, i) => ({ i, v: val(c), seq: (c.seqNo !== undefined ? c.seqNo : i) }))
      .sort((a, b) => b.v - a.v);
    let chosen = [];
    let sum = 0;
    for (const it of items) {
      if (chosen.length >= maxN) break;
      chosen.push(it); sum += it.v;
      if (mode === 0 ? sum === target : sum >= target) break;
    }
    if (mode === 0 && sum !== target) {
      const n = Math.min(items.length, 14);
      for (let mask = 1; mask < (1 << n) && !chosen.length; mask++) {
        let s = 0, c = 0;
        for (let k = 0; k < n; k++) if (mask & (1 << k)) { s += items[k].v; c++; }
        if (s === target && c >= minN && c <= maxN) chosen = items.filter((_, k) => k < n && (mask & (1 << k)));
      }
      if (!chosen.length) chosen = items.slice(0, Math.min(minN, items.length));
    }
    return { hex: String(chosen.length).padStart(2, '0') + chosen.map((it) => it.seq.toString(16).padStart(2, '0')).join('') };
  }
  if (m === MSG.POSITION) return { hex: '01' };
  if (m === MSG.PLACE || m === MSG.DISFIELD) {
    const pl = one ?? { ctrl: 0, loc: 4, seq: 0 };
    return { hex: [(pl.ctrl ?? 0), (pl.loc ?? 4), (pl.seq ?? 0)].map((x) => (x & 0xff).toString(16).padStart(2, '0')).join('') };
  }
  return null;
}

function safeFallback(p) {
  if (p.curMsg === MSG.IDLECMD) return { i: 7 };
  if (p.curMsg === MSG.BATTLECMD) return { i: 3 };
  if (p.curMsg === MSG.CHAIN) return { i: -1 };
  if (p.curMsg === MSG.POSITION) return { hex: '01' };
  if (p.curMsg === MSG.PLACE || p.curMsg === MSG.DISFIELD) {
    const pl = (p.places && p.places[0]) || { ctrl: 0, loc: 4, seq: 0 };
    return { hex: [pl.ctrl, pl.loc, pl.seq].map((x) => (x & 0xff).toString(16).padStart(2, '0')).join('') };
  }
  if (p.selectMin > 0) return { hex: String(p.selectMin).padStart(2, '0') + '00'.repeat(p.selectMin) };
  return { i: 0 };
}

(async () => {
  const t0 = Date.now();
  const MAX = Number(process.env.MAX_MINUTES || 20) * 60000;
  let since = 0, acted = 0, lastAct = Date.now();
  let lastKey = '', sameKey = 0, sameKeyAt = 0;
  let escMsg = -1, escCount = 0;
  while (Date.now() - t0 < MAX) {
    const st = await req('/state').catch(() => null);
    if (st && st.curMsg === MSG.WIN) { log('duel finished (MSG_WIN)'); return; }
    const p = await req(`/wait_prompt?since=${since}&timeout_ms=15000`).catch(() => null);
    if (!p || typeof p.seq !== 'number') { await jitter(250, 600); continue; }
    if (p.seq > since) {
      since = p.seq;
      await jitter();
      // the prompt may have been superseded while we were "thinking" - verify it is still current
      const cur = await req('/prompt').catch(() => null);
      if (cur && (cur.seq !== p.seq || !cur.awaiting)) {
        log(`skip stale prompt seq=${p.seq} now=${cur && cur.seq} awaiting=${cur && cur.awaiting}`);
        continue;
      }
      let body = null;
      try {
        const request = toRequest(p);
        if (request && st) {
          const chosen = heuristicDecide({ state: toState(st), request });
          body = encode(p, chosen);
          if (!body) body = safeFallback(p);
        } else {
          body = safeFallback(p);
        }
      } catch (e) {
        log('heuristic error:', e.message);
        body = safeFallback(p);
      }
      const mineM = (st?.monsters?.[st.myPlayer ?? 0] ?? []).length;
      const TUNER = 0x1000;
      // 1) extra-deck summon as soon as we have 2 materials
      if (p.curMsg === MSG.IDLECMD && (p.spsummonableCards || []).length && mineM >= 2) {
        body = { i: 1 }; // idle cmd SPSUMMON, index 0
        log('prefer extra-deck summon: code=' + (p.spsummonableCards[0] || {}).code + ' lv=' + (p.spsummonableCards[0] || {}).lv);
      }
      // 2) while setting up, normal-summon a tuner first (pairs with a non-tuner next turn)
      else if (p.curMsg === MSG.IDLECMD && mineM < 2 && (p.summonableCards || []).length) {
        const tuner = (p.summonableCards || []).findIndex((x) => ((x.ty || 0) & TUNER) !== 0);
        if (tuner >= 0) { body = { i: (tuner << 16) | 0 }; log('summon tuner for synchro setup: code=' + p.summonableCards[tuner].code + ' lv=' + p.summonableCards[tuner].lv); }
      }
      // 3) keep materials on board: don't attack while we have fewer than 3 monsters
      if (p.curMsg === MSG.BATTLECMD && mineM <= 2 && (p.attackableCards || []).length) {
        body = { i: 3 }; // end battle phase, keep materials
      }
      // escalation: if the server keeps re-asking the same prompt, change the answer instead of repeating it
      if (p.curMsg === escMsg) escCount++; else { escMsg = p.curMsg; escCount = 1; }
      if (escCount >= 3) {
        if (p.curMsg === MSG.CHAIN) body = { i: (p.chains && p.chains.length) ? 0 : -1 };
        else if ((p.curMsg === MSG.PLACE || p.curMsg === MSG.DISFIELD) && (p.places || []).length) {
          const pl = p.places[(escCount - 3) % p.places.length];
          body = { hex: [pl.ctrl, pl.loc, pl.seq].map((x) => (x & 0xff).toString(16).padStart(2, '0')).join('') };
        } else if (p.curMsg === MSG.SUM) {
          const n = Math.min(p.selectMax || 1, (p.selectableCards || []).length || 1);
          body = { hex: String(n).padStart(2, '0') + Array.from({ length: n }, (_, i) => i.toString(16).padStart(2, '0')).join('') };
        } else if ((p.curMsg === MSG.CARD || p.curMsg === MSG.TRIBUTE) && (p.selectableCards || []).length > 1) {
          const n = Math.max(1, p.selectMin || 1);
          const idx = Array.from({ length: n }, (_, k) => (escCount + k) % p.selectableCards.length);
          body = { hex: String(n).padStart(2, '0') + idx.map((x) => x.toString(16).padStart(2, '0')).join('') };
        }
      }
      const qs = body.i !== undefined ? `i=${body.i}` : `hex=${encodeURIComponent(body.hex)}`;
      // loop guard: the server re-asks the same prompt when our answer is invalid
      {
        const key = `${p.curMsg}:${qs}`;
        const nowMs = Date.now();
        if (key === lastKey && nowMs - sameKeyAt < 20000) sameKey += 1;
        else { lastKey = key; sameKey = 1; sameKeyAt = nowMs; }
        if (sameKey > 12) {
          log('AUTO-SURRENDER: same answer repeated ' + sameKey + 'x (server keeps re-asking)');
          await req('/surrender', 'POST').catch(() => {});
          return;
        }
      }
      const r = await req(`/act?seq=${p.seq}&${qs}`, 'POST').catch(() => null);
      acted++; lastAct = Date.now();
      log(`#${acted} ${NAME[p.curMsg] || p.curMsg} turn=${p.turn} -> ${JSON.stringify(body)} ${r && r.ok ? 'ok' : JSON.stringify(r)}`);
      if (!r || !r.ok) {
        const fb = safeFallback(p);
        const q2 = fb.i !== undefined ? `i=${fb.i}` : `hex=${encodeURIComponent(fb.hex)}`;
        const r2 = await req(`/act?seq=${p.seq}&${q2}`, 'POST').catch(() => null);
        if (!r2 || !r2.ok) { log('AUTO-SURRENDER: rejected twice'); await req('/surrender', 'POST').catch(() => { }); return; }
      }
      continue;
    }
    if (Date.now() - lastAct > 90000) { log('AUTO-SURRENDER: no progress'); await req('/surrender', 'POST').catch(() => { }); return; }
    await jitter(250, 600);
  }
})();
