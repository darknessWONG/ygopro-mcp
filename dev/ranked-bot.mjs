#!/usr/bin/env node
// bridge/ranked-bot.mjs - unattended durable duel bot driving the instrumented client via its control API.
//
// Design goals (after the AFK incident):
//   * never look like AFK: every prompt is answered within ~1s, with human-ish jitter
//   * never loop on a rejected response: 3 retries on the same message -> auto-surrender (clean exit)
//   * never hang: global no-progress watchdog -> auto-surrender
//   * readiness: re-POST /ready every 3s until the duel starts (this is what made the ranked room accept us)
//
// Usage:
//   CONTROL_URL=http://127.0.0.1:7788 node bridge/ranked-bot.mjs            # play whatever the client is in
//   node bridge/ranked-bot.mjs --ready                                     # also drive /ready until started
const BASE = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const DO_READY = process.argv.includes('--ready');
const MAX_MS = Number(process.env.MAX_MINUTES || 25) * 60000;
const NO_PROGRESS_MS = Number(process.env.NO_PROGRESS_MS || 90000);
const jitter = (a = 220, b = 700) => new Promise((r) => setTimeout(r, a + Math.random() * (b - a)));
const log = (...a) => console.log('[bot]', ...a);

const MSG = { WIN: 5, BATTLECMD: 10, IDLECMD: 11, EFFECTYN: 12, YESNO: 13, OPTION: 14, CARD: 15, CHAIN: 16, PLACE: 18, POSITION: 19, TRIBUTE: 20, COUNTER: 22, SUM: 23, DISFIELD: 24, SORT: 25, UNSELECT: 26 };
const NAME = Object.fromEntries(Object.entries(MSG).map(([k, v]) => [v, k]));

async function req(path, method = 'GET') {
  const res = await fetch(BASE + path, { method, signal: AbortSignal.timeout(30000) });
  const t = await res.text();
  try { return JSON.parse(t); } catch { return { raw: t }; }
}
const idle = (cmd, index = 0) => (index << 16) | cmd;   // 0 summon 1 spsummon 3 mset 4 sset 5 activate 6 bp 7 ep
const battle = (cmd, index = 0) => (index << 16) | cmd; // 0 activate 1 attack 2 m2 3 ep

// choose the strongest monster from a candidate list (candidates carry code/atk/def)
function bestByAtk(list) {
  if (!list || !list.length) return 0;
  let bi = 0;
  for (let i = 1; i < list.length; i++) if ((list[i].atk || 0) > (list[bi].atk || 0)) bi = i;
  return bi;
}

function decide(p, st) {
  const mine = st?.myPlayer ?? 0;
  const myMon = (st?.monsters?.[mine] ?? []).length;
  switch (p.curMsg) {
    case MSG.IDLECMD: {
      if (p.summonableCards?.length) return { i: idle(0, bestByAtk(p.summonableCards)), why: 'summon best' };
      if (p.canBp && myMon > 0) return { i: idle(6), why: 'to battle' };
      if (p.msetableCards?.length) return { i: idle(3, 0), why: 'set monster' };
      if (p.ssetableCards?.length) return { i: idle(4, 0), why: 'set spell/trap' };
      return { i: idle(7), why: 'end phase' };
    }
    case MSG.BATTLECMD: {
      if (p.attackableCards?.length) return { i: battle(1, bestByAtk(p.attackableCards)), why: 'attack' };
      return { i: battle(3), why: 'end battle' };
    }
    case MSG.CHAIN: {
      const forced = (p.chains || []).findIndex((c) => c.forced);
      if (forced >= 0) return { i: forced, why: 'forced chain' };
      return { i: -1, why: 'decline chain' };
    }
    case MSG.YESNO:
    case MSG.EFFECTYN: return { i: 0, why: 'no' };
    case MSG.OPTION: return { i: 0, why: 'option 0' };
    case MSG.POSITION: return { hex: '01', why: 'attack pos' };
    case MSG.PLACE:
    case MSG.DISFIELD: {
      // response is 3 bytes per selected place: controller, location, sequence
      const pl = (p.places && p.places[0]) || { ctrl: st?.myPlayer ?? 0, loc: 4, seq: 0 };
      const hex = [pl.ctrl, pl.loc, pl.seq].map((x) => (x & 0xff).toString(16).padStart(2, '0')).join('');
      return { hex, why: 'place ctrl=' + pl.ctrl + ' loc=' + pl.loc + ' seq=' + pl.seq };
    }
    case MSG.CARD:
    case MSG.TRIBUTE: {
      const n = Math.max(1, p.selectMin || 1);
      return { hex: String(n).padStart(2, '0') + '00'.repeat(n), why: `select ${n}` };
    }
    case MSG.UNSELECT: return { i: -1, why: 'finish' };
    case MSG.SUM: return { i: -1, why: 'cancel sum' };
    case MSG.SORT: return { hex: '00', why: 'sort: keep order' };
    case MSG.COUNTER: return { hex: '00', why: 'counter: none' };
    default: return { i: 0, why: 'default' };
  }
}

async function surrender(reason) {
  log('AUTO-SURRENDER:', reason);
  try { await req('/surrender', 'POST'); } catch { }
}

(async () => {
  const t0 = Date.now();
  let lastProgress = Date.now();
  let lastTurn = -1, lastMsg = -1, since = 0, acted = 0;
  let readyTries = 0;
  let sameMsg = 0, lastMsgId = -1;

  while (Date.now() - t0 < MAX_MS) {
    const st = await req('/state').catch(() => null);
    if (st && st.curMsg === MSG.WIN) { log('duel finished (MSG_WIN)'); return; }

    if (DO_READY && st && !st.started) {
      if (readyTries++ < 20) { await req('/ready', 'POST').catch(() => { }); log('ready attempt', readyTries); }
      await jitter(1800, 2600);
      continue;
    }

    const p = await req(`/wait_prompt?since=${since}&timeout_ms=15000`).catch(() => null);
    if (!p || typeof p.seq !== 'number') { await jitter(300, 700); continue; }

    if (p.seq > since) {
      since = p.seq;
      if (st && (st.turn !== lastTurn || p.curMsg !== lastMsg)) { lastTurn = st.turn; lastMsg = p.curMsg; lastProgress = Date.now(); }
      sameMsg = (p.curMsg === lastMsgId) ? sameMsg + 1 : 1;
      lastMsgId = p.curMsg;
      if (sameMsg > 40) { await surrender("same prompt repeated " + sameMsg + "x (stuck loop)"); return; }
      await jitter();                       // human-ish thinking time
      const d = decide(p, st);
      const body = d.i !== undefined ? `i=${d.i}` : `hex=${encodeURIComponent(d.hex)}`;
      let r = await req(`/act?seq=${p.seq}&${body}`, 'POST').catch(() => null);
      acted++;
      lastProgress = Date.now();
      log(`#${acted} ${NAME[p.curMsg] || p.curMsg} turn=${p.turn} -> ${d.why} ${r && r.ok ? 'ok' : JSON.stringify(r)}`);
      if (!r || !r.ok) {
        // rejected response: one conservative retry, then give up on this prompt
        const safe = p.curMsg === MSG.IDLECMD ? 'i=7'
          : p.curMsg === MSG.BATTLECMD ? 'i=3'
          : p.curMsg === MSG.CHAIN ? 'i=-1'
          : (p.selectMin > 0 ? 'hex=' + (String(p.selectMin).padStart(2, '0') + '00'.repeat(p.selectMin)) : 'i=0');
        const r2 = await req(`/act?seq=${p.seq}&${safe}`, 'POST').catch(() => null);
        if (!r2 || !r2.ok) { await surrender('response rejected twice'); return; }
      }
      continue;
    }

    // no new prompt: check liveness
    if (Date.now() - lastProgress > NO_PROGRESS_MS) { await surrender('no progress for ' + Math.round(NO_PROGRESS_MS / 1000) + 's'); return; }
    await jitter(250, 600);
  }
  await surrender('max runtime reached');
})();
