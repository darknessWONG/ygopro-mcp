#!/usr/bin/env node
// bridge/policy-naive.mjs - drive the instrumented client through a whole duel via its control API.
// Uses the long-poll /wait_prompt endpoint and answers with a very simple policy:
//   idle   -> end phase            (int32: (0<<16)|7 = 7)
//   battle -> end battle phase     (int32: (0<<16)|3 = 3)
//   chain  -> decline              (int32: -1)
//   yes/no, effectyn -> 0 (no)     option -> 0
//   card / place / position / tribute / sum / unselect / sort / counter / disfield -> naive first-index bytes
// Prints every prompt it handles. Stop condition: server-side MSG_WIN (state.curMsg==5) or /state not awaiting forever.
const BASE = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const MAX_STEPS = Number(process.env.MAX_STEPS || 400);
const log = (...a) => console.log('[naive]', ...a);

const MSG = {
  BATTLECMD: 10, IDLECMD: 11, EFFECTYN: 12, YESNO: 13, OPTION: 14, CARD: 15, CHAIN: 16,
  PLACE: 18, POSITION: 19, TRIBUTE: 20, COUNTER: 22, SUM: 23, DISFIELD: 24, SORT: 25,
  UNSELECT: 26, WIN: 5,
};
const NAME = Object.fromEntries(Object.entries(MSG).map(([k, v]) => [v, k]));

async function req(path, method = 'GET') {
  const res = await fetch(BASE + path, { method });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { raw: text }; }
}

// build a response for the given prompt; returns {i} or {hex}
function decide(p) {
  const m = p.curMsg;
  if (m === MSG.IDLECMD) return { i: 7 };              // TO_EP
  if (m === MSG.BATTLECMD) return { i: 3 };            // TO_EP (battle)
  if (m === MSG.CHAIN) return { i: -1 };               // decline
  if (m === MSG.YESNO || m === MSG.EFFECTYN) return { i: 0 };
  if (m === MSG.OPTION) return { i: 0 };
  if (m === MSG.POSITION) return { hex: '01' };         // attack position
  if (m === MSG.PLACE || m === MSG.DISFIELD) return { i: 0 };
  if (m === MSG.CARD || m === MSG.TRIBUTE) {
    const n = Math.max(1, p.selectMin || 1);
    return { hex: String(n).padStart(2, '0') + '00'.repeat(n) }; // count + first n indices
  }
  if (m === MSG.UNSELECT) return { i: -1 };
  if (m === MSG.SUM) return { i: -1 };
  if (m === MSG.SORT) return { hex: '00' };
  if (m === MSG.COUNTER) return { hex: '00' };
  return { i: 0 };
}

(async () => {
  let since = 0;
  let acted = 0;
  const deadline = Date.now() + Number(process.env.DEADLINE_MS || 240000);
  while (Date.now() < deadline && acted < MAX_STEPS) {
    const p = await req(`/wait_prompt?since=${since}&timeout_ms=15000`);
    if (!p || typeof p.seq !== 'number') { log('bad prompt response', p); break; }
    if (p.seq > since) {
      since = p.seq;
      const d = decide(p);
      const qs = Object.entries(d).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
      const r = await req(`/act?seq=${p.seq}&${qs}`, 'POST');
      log(`step ${acted} msg=${NAME[p.curMsg] || p.curMsg} turn=${p.turn} action=${JSON.stringify(d)} -> ${JSON.stringify(r)}`);
      acted++;
      if (!r.ok) { log('act rejected, aborting'); break; }
      continue;
    }
    const s = await req('/state');
    if (s.curMsg === MSG.WIN) { log('duel finished (MSG_WIN)', JSON.stringify(s.lp)); break; }
    log(`(no new prompt) turn=${s.turn} curMsg=${NAME[s.curMsg] || s.curMsg} awaiting=${s.awaiting}`);
  }
  log(`done, acted=${acted}`);
})();
