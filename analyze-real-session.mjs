// bridge/analyze-real-session.mjs - mine existing client control logs for the 4 reported bug
// signatures (task-36). Read-only: it only parses control-*.log files; it never talks to a client.
//
// Usage:
//   node bridge/analyze-real-session.mjs --log mycard-bot/game/control-18264.log --out ranked/logs/evidence-real-18264
//
// What it looks for:
//   1) battle-target rejection: MSG_SELECT_CARD (firstid=15 / prompt msg=15) right after
//      MSG_SELECT_BATTLECMD (firstid=10), followed by 10 again / repeated 15 -> loop window
//   2) TP 13s: STOC_SELECT_TP (stoc=4) still awaiting when NET disconnected reason=eof
//   3) net-dead: NET DEAD reason=..., NET ALIVE reason=..., confirmed_dead
//   4) SORT_CARD: firstid=25 / prompt msg=25 responses (len/hex) and repeated asks

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const get = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const LOG = get('log');
const OUT = get('out', 'ranked/logs/evidence-real');
if (!LOG || !fs.existsSync(LOG)) { console.error('missing --log'); process.exit(1); }
fs.mkdirSync(OUT, { recursive: true });

const lines = fs.readFileSync(LOG, 'utf8').split(/\r?\n/);
const R = { log: LOG, lines: lines.length };

// --- generic scans ---
function scan(pattern) { return lines.map((l, i) => [l, i]).filter(([l]) => pattern.test(l)); }

R.counts = {
  retry: scan(/RETRY after msg=/).length,
  retry15: scan(/RETRY after msg=15/).length,
  prompt15Responses: scan(/response: prompt=15/).length,
  sendResponses: scan(/SEND RESPONSE/).length,
  sendSort: scan(/SEND RESPONSE realMsg=25|prompt=25|MSG_SORT_CARD/).length,
  netDead: scan(/NET DEAD reason=/).length,
  netAliveOurTurn: scan(/NET ALIVE reason=our-turn-idle/).length,
  confirmedDead: scan(/confirmed_dead/).length,
  eof: scan(/NET disconnected reason=eof/).length,
  selectTp: scan(/stoc=4\(STOC_SELECT_TP\)|STOC_SELECT_TP/).length,
};

// --- item 4: SORT_CARD windows ---
R.sortCard = [];
for (const [l, i] of scan(/firstid=25|msg=25|MSG_SORT_CARD/)) {
  const from = Math.max(0, i - 3), to = Math.min(lines.length, i + 6);
  R.sortCard.push({ lineNo: i + 1, window: lines.slice(from, to).map((x) => x.trim().slice(0, 160)) });
  if (R.sortCard.length >= 8) break;
}

// --- item 2: STOC_SELECT_TP -> eof windows ---
R.tpEof = [];
for (const [l, i] of scan(/NET disconnected reason=eof/)) {
  const from = Math.max(0, i - 20);
  const win = lines.slice(from, i + 3);
  const hasTp = win.some((x) => /STOC_SELECT_TP|stoc=4\(/.test(x));
  R.tpEof.push({ lineNo: i + 1, tpPendingBeforeEof: hasTp, window: win.map((x) => x.trim().slice(0, 150)) });
  if (R.tpEof.length >= 5) break;
}

// --- item 3: net dead reasons ---
R.netDead = [];
for (const [l, i] of scan(/NET DEAD reason=/)) {
  R.netDead.push({ lineNo: i + 1, line: l.trim(), prev: (lines[i - 1] || '').trim().slice(0, 150) });
  if (R.netDead.length >= 25) break;
}

// --- item 1: battle target loop detection ---
// Reconstruct a compact timeline of game-message ids and prompts around every 15-prompt that
// follows a battle command (firstid=10) within the same turn.
const timeline = [];
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  let m;
  if ((m = l.match(/STOC_GAME_MSG len=\d+ firstid=(\d+)/))) timeline.push({ i, kind: 'msg', id: Number(m[1]) });
  else if ((m = l.match(/PROMPT publish seq=(\d+) msg=(\d+)/))) timeline.push({ i, kind: 'prompt', seq: Number(m[1]), id: Number(m[2]) });
  else if ((m = l.match(/response: prompt=(\d+) streak=(\d+) kind=(\w+)(?: len=(\d+))? (?:val=(-?\d+)|hex=([0-9a-f]*))/))) timeline.push({ i, kind: 'resp', id: Number(m[1]), streak: Number(m[2]), len: m[4] ? Number(m[4]) : null, hex: m[6] || (m[5] || null) });
  else if (/RETRY after msg=/.test(l)) timeline.push({ i, kind: 'retry', line: l.trim() });
}

// windows: battle command (10) then target select (15), look ahead 3 seconds of log lines
R.battleWindows = [];
for (let k = 0; k < timeline.length; k++) {
  const t = timeline[k];
  if (t.kind !== 'msg' || t.id !== 10) continue;
  const win = timeline.slice(k, k + 14);
  const has15 = win.some((x) => x.kind === 'msg' && x.id === 15);
  if (!has15) continue;
  const seq10Again = win.slice(1).some((x) => (x.kind === 'msg' && x.id === 10) || (x.kind === 'prompt' && x.id === 10));
  const seq15Again = win.slice(1).filter((x) => (x.kind === 'msg' && x.id === 15) || (x.kind === 'prompt' && x.id === 15)).length;
  R.battleWindows.push({
    atLine: t.i + 1,
    seq10Again,
    seq15Count: seq15Again,
    events: win.map((x) => x.kind === 'msg' ? `msg=${x.id}` : x.kind === 'prompt' ? `prompt=${x.id}(seq${x.seq})` : x.kind === 'retry' ? x.line : `resp=${x.id} len=${x.len} hex=${x.hex} streak=${x.streak}`),
    raw: lines.slice(t.i - 1, t.i + 12).map((x) => x.trim().slice(0, 160)),
  });
  if (R.battleWindows.length >= 10) break;
}

R.battleLoopCandidates = R.battleWindows.filter((w) => w.seq10Again && w.seq15Count >= 2);

fs.writeFileSync(path.join(OUT, 'real-session-analysis.json'), JSON.stringify(R, null, 2), 'utf8');
console.log(JSON.stringify({
  log: LOG, out: OUT, counts: R.counts,
  battleWindows: R.battleWindows.length, battleLoopCandidates: R.battleLoopCandidates.length,
  tpEofWithTpPending: R.tpEof.filter((x) => x.tpPendingBeforeEof).length,
}, null, 2));
