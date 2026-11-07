#!/usr/bin/env node
// bridge/policy-basic.mjs - minimal but functional policy driving the instrumented client
// through the control API until the duel ends (MSG_WIN) or a deadline.
//
// Logic (deliberately simple, enough to beat a passive opponent):
//   idle: summon if possible -> set monster if possible -> end phase
//   battle: attack if possible -> end battle phase
//   chain: decline (never chain)      yes/no & effectyn: no      option: 0
//   card/tribute: first N (min)       place: first     position: attack     unselect/sum: -1
const BASE = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const MAX_STEPS = Number(process.env.MAX_STEPS || 600);
const DEADLINE_MS = Number(process.env.DEADLINE_MS || 300000);
const log = (...a) => console.log('[basic]', ...a);

const MSG = { WIN: 5, BATTLECMD: 10, IDLECMD: 11, EFFECTYN: 12, YESNO: 13, OPTION: 14, CARD: 15, CHAIN: 16, PLACE: 18, POSITION: 19, TRIBUTE: 20, COUNTER: 22, SUM: 23, DISFIELD: 24, SORT: 25, UNSELECT: 26 };
const NAME = Object.fromEntries(Object.entries(MSG).map(([k, v]) => [v, k]));

async function req(path, method = 'GET') {
  const res = await fetch(BASE + path, { method });
  const t = await res.text();
  try { return JSON.parse(t); } catch { return { raw: t }; }
}
const idle = (cmd, index = 0) => (index << 16) | cmd; // cmd: 0 summon 1 spsummon 2 reposit 3 mset 4 sset 5 activate 6 bp 7 ep 8 shuffle
const battle = (cmd, index = 0) => (index << 16) | cmd; // cmd: 0 activate 1 attack 2 m2 3 ep

function decide(p, s) {
  const myMon = (s?.monsters?.[s.myPlayer ?? 0] ?? []).filter(Boolean).length;
  switch (p.curMsg) {
    case MSG.IDLECMD:
      if (p.summonable > 0) return { i: idle(0, 0), why: 'summon' };
      if (p.canBp && myMon > 0) return { i: idle(6), why: 'to battle' };
      if (p.msetable > 0) return { i: idle(3, 0), why: 'set monster' };
      if (p.activatable > 0) return { i: idle(5, 0), why: 'activate' };
      return { i: idle(7), why: 'end phase' };
    case MSG.BATTLECMD:
      if (p.attackable > 0) return { i: battle(1, 0), why: 'attack' };
      return { i: battle(3), why: 'end battle' };
    case MSG.CHAIN: return { i: -1, why: 'decline chain' };
    case MSG.YESNO:
    case MSG.EFFECTYN: return { i: 0, why: 'no' };
    case MSG.OPTION: return { i: 0, why: 'option 0' };
    case MSG.POSITION: return { hex: '01', why: 'attack pos' };
    case MSG.PLACE:
    case MSG.DISFIELD: return { hex: '00', why: 'first place (1 byte)' };
    case MSG.CARD:
    case MSG.TRIBUTE: {
      const n = Math.max(1, p.selectMin || 1);
      return { hex: String(n).padStart(2, '0') + '00'.repeat(n), why: `select ${n}` };
    }
    case MSG.UNSELECT: return { i: -1, why: 'finish' };
    case MSG.SUM: return { i: -1, why: 'cancel sum' };
    case MSG.SORT: return { hex: '00', why: 'sort: no reorder' };
    case MSG.COUNTER: return { hex: '00', why: 'counter: none' };
    default: return { i: 0, why: 'default' };
  }
}

(async () => {
  let since = 0, acted = 0;
  const deadline = Date.now() + DEADLINE_MS;
  while (Date.now() < deadline && acted < MAX_STEPS) {
    const p = await req(`/wait_prompt?since=${since}&timeout_ms=15000`);
    if (p && typeof p.seq === 'number' && p.seq > since) {
      since = p.seq;
      const st = await req('/state');
      const d = decide(p, st);
      const body = d.i !== undefined ? `i=${d.i}` : `hex=${encodeURIComponent(d.hex)}`;
      let r = await req(`/act?seq=${p.seq}&${body}`, 'POST');
      if (!r.ok) {
        // rejected (illegal response): retry once with a conservative fallback
        const safe = p.curMsg === MSG.IDLECMD ? 'i=7'
          : p.curMsg === MSG.BATTLECMD ? 'i=3'
          : p.curMsg === MSG.CHAIN ? 'i=-1'
          : (p.selectMin > 0 ? 'hex=' + (String(p.selectMin).padStart(2, '0') + '00'.repeat(p.selectMin)) : 'i=0');
        log(`#${acted} ${NAME[p.curMsg] || p.curMsg} rejected (${JSON.stringify(r)}) -> fallback ${safe}`);
        r = await req(`/act?seq=${p.seq}&${safe}`, 'POST');
        acted++;
        if (!r.ok) { log('fallback also rejected; continue'); }
        continue;
      }
      log(`#${acted} ${NAME[p.curMsg] || p.curMsg} turn=${p.turn} -> ${d.why} ${JSON.stringify(r)}`);
      acted++;
      continue;
    }
    const s = await req('/state');
    if (s.curMsg === MSG.WIN) { log('*** DUEL FINISHED (MSG_WIN) ***', JSON.stringify(s.lp)); process.exit(0); }
  }
  const s = await req('/state');
  log(`deadline reached; turn=${s.turn} curMsg=${NAME[s.curMsg] || s.curMsg} acted=${acted} lp=${JSON.stringify(s.lp)}`);
})();
