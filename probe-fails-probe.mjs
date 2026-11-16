// bridge/probe-fails-probe.mjs - task-37 A: verify that /tip probe timeouts no longer mark the
// client dead (probe-failed is degraded, passive silence guard stays in charge).
//
// Flow: drive both clients normally until the chosen side has no prompt and it is the opponent's
// turn, then stay silent for --silent-sec seconds (< passive 60s guard) while sampling /net and
// /state. Expected with YGO_NET_PROBE=1 YGO_NET_PROBE_FAIL_MAX=1:
//   NET probe timeout ... -> NET probe failed ... (defer to passive silence guard)
//   /net.alive stays true, /net.state at most "probe_failed", no NET DEAD reason=probe-fails,
//   no disconnect. Afterwards play resumes normally.
//
// Usage: node bridge/probe-fails-probe.mjs --dir <evd> --max-min 2 --silent-sec 12 --side host

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };

const DIR = path.resolve(get('dir', 'ranked/logs/probe-fails'));
const MAX_MIN = Number(get('max-min', '2'));
const SILENT_SEC = Number(get('silent-sec', '12'));
const SILENT_SIDE = get('side', 'host');
const HOST = get('host', 'http://127.0.0.1:7788');
const GUEST = get('guest', 'http://127.0.0.1:7789');

fs.mkdirSync(DIR, { recursive: true });
const out = fs.createWriteStream(path.join(DIR, 'probe.jsonl'), { flags: 'w' });
const t0 = Date.now();
const el = () => +((Date.now() - t0) / 1000).toFixed(3);
const rec = (o) => out.write(JSON.stringify({ t: el(), ...o }) + '\n');
const log = (m) => console.log(`[${el().toFixed(1)}] ${m}`);

async function j(url) {
  try { const r = await fetch(url, { signal: AbortSignal.timeout(3000) }); return JSON.parse(await r.text()); }
  catch { return null; }
}

function choose(st, pr, actions) {
  const has = (k) => (actions || []).filter((a) => a.kind === k);
  const first = (k) => (actions || []).find((a) => a.kind === k) || null;
  if (pr.sidePending) return first('side_ok');
  if (pr.tpPending) { const tp = has('tp'); return tp.find((a) => a.index === 1) || tp[0]; }
  if (pr.curMsg === 10) return first('attack') || first('end_battle');
  if (pr.curMsg === 11) return first('summon') || first('set_monster') || first('to_bp') || first('to_ep');
  if (pr.curMsg === 15) return first('select') || first('sum');
  const order = ['sort', 'select', 'sum', 'position', 'place', 'option', 'yes', 'no', 'decline', 'to_ep', 'end_battle', 'auto'];
  for (const k of order) { const a = first(k); if (a) return a; }
  const an = (actions || []).find((a) => /^announce/.test(a.kind || ''));
  return an || (actions || [])[0] || null;
}

async function sideLoop(name, base) {
  let lastSeq = -1;
  let silentDone = false;
  const deadline = Date.now() + MAX_MIN * 60000;
  while (Date.now() < deadline) {
    const st = await j(base + '/state');
    const pr = await j(base + '/prompt');
    if (!st || !pr) { rec({ side: name, ev: 'unreachable' }); break; }
    if (st.match && st.match.over) { rec({ side: name, ev: 'match-over' }); break; }

    const isOpponentTurn = typeof st.turnPlayerLocal === 'number' ? st.turnPlayerLocal !== 0 : (st.turnPlayer !== st.mySeat);

    // enter the silent window once: it's the opponent's turn and we have no prompt to answer
    if (name === SILENT_SIDE && !silentDone && isOpponentTurn && pr.awaiting !== true) {
      silentDone = true;
      rec({ side: name, ev: 'silent-start', turn: st.turn, net: st.net && { alive: st.net.alive, state: st.net.state, probe: st.net.probe } });
      const tSil = Date.now();
      while ((Date.now() - tSil) / 1000 < SILENT_SEC) {
        await new Promise((r) => setTimeout(r, 1000));
        const ns = await j(base + '/state');
        const nn = await j(base + '/net');
        rec({
          side: name, ev: 'silent-sample', sec: Math.round((Date.now() - tSil) / 1000),
          alive: ns && ns.net && ns.net.alive, netState: ns && ns.net && ns.net.state,
          closeReason: ns && ns.net && ns.net.closeReason,
          sinceLastStoc: ns && ns.net && ns.net.sinceLastStoc,
          net: nn && { connected: nn.connected, alive: nn.alive, state: nn.state, probe: nn.probe },
          curMsg: ns && ns.curMsg, awaiting: ns && ns.awaiting,
        });
        if (!ns) { rec({ side: name, ev: 'silent-client-gone' }); break; }
        if (ns.net && ns.net.closeReason && ns.net.closeReason !== 'none') { rec({ side: name, ev: 'silent-disconnected', closeReason: ns.net.closeReason }); break; }
      }
      rec({ side: name, ev: 'silent-end', ms: Date.now() - tSil });
      continue;
    }

    if (pr.awaiting !== true || pr.seq === lastSeq) { await new Promise((r) => setTimeout(r, 300)); continue; }
    const acts = await j(base + '/actions');
    const a = choose(st, pr, (acts && acts.actions) || []);
    if (!a) { await new Promise((r) => setTimeout(r, 400)); continue; }
    const resp = await j(base + '/act_id?id=' + a.id);
    lastSeq = pr.seq;
    rec({ side: name, ev: 'act', seq: pr.seq, curMsg: pr.curMsg, action: a, resp });
    await new Promise((r) => setTimeout(r, 250));
  }
}

log('probe-fails probe dir=' + DIR + ' silentSec=' + SILENT_SEC + ' side=' + SILENT_SIDE);
await Promise.all([
  sideLoop('host', HOST).catch((e) => rec({ side: 'host', ev: 'crash', error: String(e) })),
  sideLoop('guest', GUEST).catch((e) => rec({ side: 'guest', ev: 'crash', error: String(e) })),
]);
const endStates = { host: await j(HOST + '/state'), guest: await j(GUEST + '/state') };
fs.writeFileSync(path.join(DIR, 'probe-summary.json'), JSON.stringify({ endStates }, null, 2), 'utf8');
out.end();
log('done');
console.log('PROBE_DIR=' + DIR);
