#!/usr/bin/env node
// bridge/mcp-server.mjs - MCP (stdio) server exposing the instrumented client's control API.
//
// Tools (20):
//   control_state        -> GET  /state  (whole match result is passed through as `match`; see control_match)
//   control_match        -> GET  /state  -> {match, summary}   (one-line human-readable Bo3 result)
//   control_prompt       -> GET  /prompt (current prompt snapshot, non-blocking)
//   control_wait_prompt  -> GET  /wait_prompt?since&timeout_ms   (long poll, the main loop primitive)
//   control_actions      -> GET  /actions
//   control_act_id       -> GET  /act_id?id=N
//   control_act          -> POST /act?seq&i|hex
//   control_ready        -> POST /ready
//   control_lobby        -> GET  /lobby
//   control_deck         -> POST /deck?name=
//   control_start        -> POST /start
//   control_surrender    -> POST /surrender
//   control_leave        -> POST /leave (clean exit to main menu; prefer over surrender when the table is stuck)
//   control_chat         -> GET  /chat
//   control_join         -> POST /join?ip&port&pass
//   control_msg          -> GET  /msg
//   control_health       -> GET  /health
//   control_net          -> GET  /net (liveness/disconnect check; poll every 15-30s)
//   control_side_move    -> POST /side_swap?code&from&to&n     (Bo3 side decking)
//   control_side_done    -> GET  /actions then /act_id (kind=side_ok)  (confirm side deck, Bo3)
//
// Run:  node bridge/mcp-server.mjs        (env CONTROL_URL=http://127.0.0.1:7788)
// Wire it into an MCP host with command "node", args ["bridge/mcp-server.mjs"].
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

const BASE = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const PROTOCOL = '2024-11-05';

async function http(path, method = 'GET') {
  const res = await fetch(BASE + path, { method, signal: AbortSignal.timeout(120000) });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { raw: text }; }
}
const qs = (o) => Object.entries(o || {})
  .filter(([, v]) => v !== undefined && v !== null && v !== '')
  .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');

// ---------------------------------------------------------------- match result summary
// Newer clients expose /state.match:
//   { games:[{game,winPlayerLocal,reasonName,...}], gamesWonLocal, gamesWonOpp, over, lastReasonName }
// Older clients omit it -> control_match degrades to the current-game view from /state (no crash).
const MATCH_REASON_ZH_WIN = {
  SURRENDER: '对手投降',
  LP_ZERO: '对手 LP 归零',
  DECK_OUT: '对手抽卡耗尽',
  TIMEOUT: '对手超时',
  DISCONNECT: '对手掉线/失联',
};
const MATCH_REASON_ZH_LOSS = {
  SURRENDER: '你投降',
  LP_ZERO: '你 LP 归零',
  DECK_OUT: '你抽卡耗尽',
  TIMEOUT: '你超时',
  DISCONNECT: '你掉线/失联',
};

function reasonRaw(...vals) {
  for (const v of vals) {
    if (v === undefined || v === null) continue;
    const s = String(v).trim();
    if (s !== '') return s;
  }
  return '';
}

function reasonZh(raw, weWon) {
  const s = String(raw || '').trim();
  if (!s) return '未知';
  const table = weWon ? MATCH_REASON_ZH_WIN : MATCH_REASON_ZH_LOSS;
  return table[s.toUpperCase()] || s;
}

// best-effort: which side won a single game entry (true = local/we won)
// Real client schema: {game, win:<bool local>, winnerSeat:<raw seat>, reason, reasonName}
// (older/proposed variants winPlayerLocal/isWin/winner are kept as fallbacks)
function gameLocalWin(g, st) {
  if (!g || typeof g !== 'object') return null;
  if (typeof g.win === 'boolean') return g.win;
  if (typeof g.winPlayerLocal === 'number') {
    if (g.winPlayerLocal === 0) return true;
    if (g.winPlayerLocal === 1) return false;
    return null;
  }
  if (typeof g.isWin === 'boolean') return g.isWin;
  if (typeof g.winner === 'number') return g.winner === 0;
  if (typeof g.winnerSeat === 'number') {
    const mySeat = Number.isFinite(Number(st?.mySeat)) ? Number(st.mySeat) : null;
    if (mySeat !== null) return g.winnerSeat === mySeat;
    return g.winnerSeat === 0;
  }
  if (typeof g.result === 'string') {
    const r = g.result.toLowerCase();
    if (r === 'win') return true;
    if (r === 'loss' || r === 'lose') return false;
  }
  return null;
}

function gameReason(g) {
  if (!g || typeof g !== 'object') return '';
  return reasonRaw(g.reasonName, g.winReasonName, g.reasonText, g.reason);
}

// "原因 LP_ZERO（对手 LP 归零）" for a single game; unknown names stay as-is (no duplicate brackets).
function gameCause(raw, weWon) {
  if (!raw) return '';
  const zh = reasonZh(raw, weWon === true);
  return zh === raw ? `，原因 ${raw}` : `，原因 ${raw}（${zh}）`;
}

// "。最后一局原因：对手掉线/失联（DISCONNECT）" for the match summary.
function lastCause(raw, weWon) {
  if (!raw) return '';
  const zh = reasonZh(raw, weWon === true);
  return zh === raw ? `。最后一局原因：${raw}` : `。最后一局原因：${zh}（${raw}）`;
}

function scoreText(local, opp) {
  return `${local}:${opp}`;
}

function leadText(local, opp) {
  if (local === opp) return '（平）';
  return local > opp ? '（你领先）' : '（你落后）';
}

function summarizeMatch(st) {
  const s = st && typeof st === 'object' ? st : {};
  const m = s.match && typeof s.match === 'object' ? s.match : null;
  const games = Array.isArray(m?.games) ? m.games
    : Array.isArray(m?.results) ? m.results
      : Array.isArray(m?.duels) ? m.duels : [];
  const inDuel = !!s.inDuel;
  const started = !!(s.started || inDuel || s.turn > 0);

  let local = Number.isFinite(Number(m?.gamesWonLocal)) ? Number(m.gamesWonLocal) : null;
  let opp = Number.isFinite(Number(m?.gamesWonOpp)) ? Number(m.gamesWonOpp) : null;
  if (local === null || opp === null) {
    const counted = games.map((g) => gameLocalWin(g, s));
    if (local === null) local = counted.filter((w) => w === true).length;
    if (opp === null) opp = counted.filter((w) => w === false).length;
  }

  const over = m ? (m.over === true || m.finished === true || m.done === true) : false;
  const bo3Over = local >= 2 || opp >= 2;

  // --- no match object (old client): degrade to current-game view
  if (!m) {
    if (inDuel) return { match: null, fallback: true, summary: `第 1 局进行中（旧客户端无整场汇总，turn ${s.turn ?? '?'}）` };
    const w = typeof s.winPlayerLocal === 'number' ? s.winPlayerLocal : -1;
    if (w === 0 || s.isWin === true) {
      const raw = reasonRaw(s.winReasonName, s.winReason);
      return { match: null, fallback: true, summary: `本局：你赢了，原因 ${raw || '未知'}（${reasonZh(raw, true)}）` };
    }
    if (w === 1 || s.isWin === false) {
      const raw = reasonRaw(s.winReasonName, s.winReason);
      return { match: null, fallback: true, summary: `本局：你输了，原因 ${raw || '未知'}（${reasonZh(raw, false)}）` };
    }
    return { match: null, fallback: true, summary: '还没有开始对局' };
  }

  // --- match over (either explicit flag or a Bo3 side reaching 2 wins)
  if (over || bo3Over) {
    const last = games.length ? games[games.length - 1] : null;
    const lastLocal = gameLocalWin(last, s);
    const raw = reasonRaw(m.lastReasonName, gameReason(last));
    const weWon = local > opp ? true : local < opp ? false : (lastLocal === null ? null : lastLocal);
    // reason wording is from the last game's perspective when the client tells us (lastWinnerLocal)
    const lastWeWon = typeof m.lastWinnerLocal === 'boolean' ? m.lastWinnerLocal : (weWon === null ? lastLocal : weWon);
    const tail = lastCause(raw, lastWeWon === true);
    if (weWon === null) return { match: m, summary: `比赛结束：大比分 ${scoreText(local, opp)}${tail}` };
    return { match: m, summary: `比赛结束：${weWon ? '你赢了' : '你输了'}这场 Bo3（${scoreText(local, opp)}）${tail}` };
  }

  // --- duel in progress
  if (inDuel) {
    const g = Number(m?.game);
    const gameNo = Number.isFinite(g) && g > 0 ? g : games.length + 1;
    return { match: m, summary: `第 ${gameNo} 局进行中；当前大比分 ${scoreText(local, opp)}${leadText(local, opp)}` };
  }

  // --- between games (a game just ended, next not started)
  if (games.length) {
    const last = games[games.length - 1];
    const won = gameLocalWin(last, s);
    const raw = gameReason(last);
    const who = won === true ? '你赢了' : won === false ? '你输了' : '本局结果未知';
    const cause = gameCause(raw, won === true);
    return { match: m, summary: `第 ${games.length} 局：${who}${cause}；当前大比分 ${scoreText(local, opp)}${leadText(local, opp)}` };
  }

  return { match: m, summary: started ? '还没有开始对局' : '还没有开始对局' };
}

const TOOLS = [
  {
    name: 'control_state',
    description: 'Get the full duel state: turn, phase, LP, hand/field/grave/deck counts with card details, pending prompt counters. ' +
      'The whole Bo3 result is passed through as state.match; for a ready-to-read Chinese summary of the match result use control_match.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_match',
    description:
      'Whole-match (Bo3) result for the LLM, in one line of Chinese: who won the match, why, the series score, and whether the match is over. ' +
      'Reads GET /state and derives the summary from state.match (games[], gamesWonLocal/gamesWonOpp, over, lastReasonName). ' +
      'Returns {match, summary} (match is the raw /state.match object; on older clients without it, match=null + fallback=true and the summary degrades to the current game). ' +
      'Use this instead of reading /state.winPlayer when you need "did I win this match and why".',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_prompt',
    description:
      'Read the CURRENT prompt snapshot without waiting (GET /prompt): seq, awaiting, curMsg, the pending-decision counters (summonable/activatable/chains/...) and the semantic flags (tpPending / sidePending / canBp / canEp). ' +
      'Use it to inspect "what is being asked right now"; use control_wait_prompt when you need to BLOCK until the next prompt arrives. ' +
      'selectableCards[] lists every candidate of a card-selection prompt (code/atk/def/loc/seq/position) and isAttackTarget=true marks a battle target window.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_wait_prompt',
    description: 'Long-poll until it is this client\'s turn to respond. Returns the prompt: seq (pass it back to control_act), curMsg (what kind of decision), and candidate counters. This is the main agent loop primitive.',
    inputSchema: {
      type: 'object',
      properties: {
        since: { type: 'number', description: 'last seq you handled (0 for the first call)' },
        timeout_ms: { type: 'number', description: 'max wait, default 30000' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'control_act',
    description: 'Submit a response for the prompt with the given seq. Use either i (int32 encoded response, e.g. idle (index<<16)|cmd, -1 for chain decline) or hex (raw response bytes, e.g. card selection "0100" = select 1 card at index 0).',
    inputSchema: {
      type: 'object',
      properties: {
        seq: { type: 'number' },
        i: { type: 'number', description: 'int32 response' },
        hex: { type: 'string', description: 'raw bytes as hex' },
      },
      required: ['seq'],
      additionalProperties: false,
    },
  },
  {
    name: 'control_ready',
    description: 'Send CTOS_HS_READY (click the Ready button) for the current room.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_actions',
    description: 'List the semantic actions available for the current prompt (id + kind + human label, e.g. summon/special summon/attack/chain/zone). The caller only picks an id; the client encodes the kernel response itself. ' +
      'For MSG_SELECT_CARD the list contains ONE entry per candidate: kind select_card, label "attack target: card #i code=.. atk=.. def=.. loc=.. seq=.." (the prefix appears for battle target windows), plus a select_auto entry that keeps the legacy "pick the first N" behaviour. To choose a specific card (for example which monster to attack) pass the matching select_card id - select_auto always takes the first candidate and is usually wrong when several targets are legal.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_act_id',
    description: 'Execute one of the actions returned by control_actions, by id. Prefer the semantic entry you actually want: for card selection pass the select_card id whose label matches the card (attack target: card #i code=.. atk=.. def=..); select_auto / legacy id=0 means "take the first candidate" and is kept for compatibility.',
    inputSchema: { type: 'object', properties: { id: { type: 'number' } }, required: ['id'], additionalProperties: false },
  },
  {
    name: 'control_lobby',
    description: 'Room/prep-screen state: our seat (0=host,1=guest), whether we are host, readiness of both seats, deck loaded, raw HS status bytes. Use this before ready/start.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_deck',
    description: 'Preload a deck by name (file under deck/*.ydk). Call before control_ready so the deck update is valid.',
    inputSchema: { type: 'object', properties: { name: { type: 'string', description: 'deck name, e.g. Blackwing' } }, additionalProperties: false },
  },
  {
    name: 'control_start',
    description: 'Click "Start" (CTOS_HS_START). Only valid when we are the host (seat 0) and both players are ready.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_surrender',
    description: 'Surrender the current duel (CTOS_SURRENDER).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_leave',
    description: 'Leave the current room/duel cleanly and return to the main menu (POST /leave). Use it when the table is stuck - e.g. control_net shows stallMs > 120000 with oppClockFresh=false, which means the opponent or the server stopped advancing (not our link dropping) - then requeue. Prefer this over control_surrender: surrender still plays out the result, leaving frees the client immediately.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_chat',
    description: 'Recent server chat / system messages (useful to see why a room was rejected or a duel was kicked).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_join',
    description: 'Connect to a game server (LAN or a matchmade room).',
    inputSchema: {
      type: 'object',
      properties: {
        ip: { type: 'string', description: 'server host, default 127.0.0.1' },
        port: { type: 'number', description: 'server port, default 7911' },
        pass: { type: 'string', description: 'room password' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'control_msg',
    description: 'Last raw server message (id, length, hex) - debug only.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_health',
    description: 'Health check of the control layer.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_net',
    description:
      'Liveness / disconnect check (GET /net) - the tool to call periodically (every 15-30s) during a long turn or an opponent\'s slow play. ' +
      'Returns connected, joined, inDuel, alive, state (healthy|idle|probe_failed|confirmed_dead|disconnected), closeReason (none|eof|error|stop|exit|unknown), ' +
      'lastStocName, sinceLastStoc, probe {enabled,unsupported,fails,rttMs}, lastNetMsg {id,text,ageMs}, plus diagnostics (ourTurn/oppTurn/timeLeft/clockFresh on newer builds). ' +
      'What to do: only act when alive=false or state is confirmed_dead/disconnected (or net.lastStocName shows a server-side end like STOC_DUEL_END). ' +
      'A growing probe.fails with state=probe_failed is NOT a disconnect on builds after 2026-11-16 11:31 (probe failures only degrade the status; real death comes from passive silence / real EOF). ' +
      'Note: NET DEAD reason=probe-fails only exists on older builds; current builds report idle-no-packet (passive silence) or a real disconnect. ' +
      'Until the client\'s clockRunning bug is fixed, the passive-silence exemption can be always-on (stale g_timeLeft), so do NOT rely on the client alone: poll this tool and judge yourself.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_side_move',
    description:
      'Bo3 side decking: move N copies of one card between pools while the side phase is pending ' +
      '(POST /side_swap?code&from&to&n). Only valid between duels of a match (check control_state().side.pending first). ' +
      'Allowed directions: side->main, side->extra, main->side, extra->side. ' +
      'Returns the client response: ok:true with predicted {"main","extra","side"} counts, or ok:false with a ' +
      'readable error (e.g. "not enough copies in side (have 1, need 2)"). After a successful move, call ' +
      'control_state() again to read side.counts. Use at most the limits (side.limits).',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'number', description: 'card passcode (e.g. 53582587)' },
        from: { type: 'string', enum: ['side', 'main', 'extra'], description: 'source pool' },
        to: { type: 'string', enum: ['main', 'extra', 'side'], description: 'destination pool' },
        n: { type: 'number', description: 'how many copies to move (default 1)' },
      },
      required: ['code', 'from', 'to'],
      additionalProperties: false,
    },
  },
  {
    name: 'control_side_done',
    description:
      'Bo3 side decking: finish side decking and continue to the next duel. Finds the pending ' +
      'kind="side_ok" action in control_actions() and submits it (i.e. /act_id?id=0, same as clicking "OK"; ' +
      'the client validates the counts/deck). Call this after control_side_move calls. ' +
      'Returns {ok, id, action, result}; when the counts are illegal the client answers ' +
      '{ok:false, error:"counts must match", sideError:"counts must match"}. If side.waiting=true (waiting for the ' +
      'opponent) do NOT treat it as a failure - just wait (use /net to detect a dead link).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
];

async function callTool(name, args) {
  switch (name) {
    case 'control_state': return http('/state');
    case 'control_prompt': return http('/prompt');
    case 'control_match': {
      // Never throw for a dead/missing control layer: the MCP caller should get a readable summary either way.
      try {
        return summarizeMatch(await http('/state'));
      } catch (e) {
        return { match: null, fallback: true, error: String(e?.message || e), summary: '读不到 /state（客户端未连接或控制层无响应）' };
      }
    }
    case 'control_msg': return http('/msg');
    case 'control_health': return http('/health');
    case 'control_net': return http('/net');
    case 'control_lobby': return http('/lobby');
    case 'control_actions': return http('/actions');
    case 'control_act_id': return http('/act_id?id=' + encodeURIComponent(args?.id ?? 0));
    case 'control_chat': return http('/chat');
    case 'control_start': return http('/start', 'POST');
    case 'control_surrender': return http('/surrender', 'POST');
    case 'control_leave': return http('/leave', 'POST');
    case 'control_deck': return http('/deck?name=' + encodeURIComponent(args?.name ?? 'Blackwing'), 'POST');
    case 'control_ready': return http('/ready', 'POST');
    case 'control_join': return http('/join?' + qs(args), 'POST');
    case 'control_wait_prompt': {
      const since = args?.since ?? 0;
      const timeout = args?.timeout_ms ?? 30000;
      return http(`/wait_prompt?since=${encodeURIComponent(since)}&timeout_ms=${encodeURIComponent(timeout)}`);
    }
    case 'control_act': {
      const q = { seq: args?.seq };
      if (args?.hex !== undefined) q.hex = args.hex;
      if (args?.i !== undefined) q.i = args.i;
      return http('/act?' + qs(q), 'POST');
    }
    case 'control_side_move': {
      const code = Number(args?.code);
      if (!Number.isFinite(code) || code <= 0) throw new Error('control_side_move: "code" (card passcode, number) is required');
      const from = String(args?.from ?? '');
      const to = String(args?.to ?? '');
      const allowed = { side: ['main', 'extra'], main: ['side'], extra: ['side'] };
      if (!allowed[from] || !allowed[from].includes(to)) {
        throw new Error(`control_side_move: invalid from/to (${from || '?'} -> ${to || '?'}); allowed: side->main, side->extra, main->side, extra->side`);
      }
      const n = Math.max(1, Math.trunc(Number(args?.n ?? 1)) || 1);
      // client contract: POST /side_swap?code&from&to&n
      //   ok:    {"ok":true,"queued":true,"main":<m>,"extra":<e>,"side":<s>}   (predicted counts)
      //   error: {"ok":false,"error":"not enough copies in side (have 1, need 2)" | "from/to must be main|extra|side"}
      return http('/side_swap?' + qs({ code, from, to, n }), 'POST');
    }
    case 'control_side_done': {
      const acts = await http('/actions');
      const list = (acts && Array.isArray(acts.actions)) ? acts.actions : [];
      const side = list.find((a) => a && a.kind === 'side_ok');
      if (!side) {
        return {
          ok: false,
          error: 'no side_ok action: not in the Bo3 side phase (or this client build has no side-deck support)',
          awaiting: acts?.awaiting ?? null,
          sidePending: acts?.sidePending ?? null,
          actions: list.map((a) => ({ id: a.id, kind: a.kind })),
        };
      }
      const r = await http('/act_id?id=' + encodeURIComponent(side.id));
      return { ok: !!(r && r.ok !== false), id: side.id, action: side, result: r };
    }
    default:
      throw new Error('unknown tool: ' + name);
  }
}

const isMain = (() => {
  try { return !!process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href; } catch { return false; }
})();

if (isMain) {
const rl = readline.createInterface({ input: process.stdin });
const send = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

rl.on('line', async (line) => {
  const t = line.trim();
  if (!t) return;
  let msg;
  try { msg = JSON.parse(t); } catch { return; }
  const { id, method, params } = msg;
  if (method === undefined) return; // response to us; ignore
  try {
    switch (method) {
      case 'initialize':
        reply(id, {
          protocolVersion: PROTOCOL,
          capabilities: { tools: {} },
          serverInfo: { name: 'ygopro-control', version: '0.1.0' },
        });
        break;
      case 'notifications/initialized':
        break;
      case 'ping':
        reply(id, {});
        break;
      case 'tools/list':
        reply(id, { tools: TOOLS });
        break;
      case 'tools/call': {
        const name = params?.name;
        const args = params?.arguments ?? {};
        const out = await callTool(name, args);
        reply(id, { content: [{ type: 'text', text: JSON.stringify(out) }] });
        break;
      }
      default:
        fail(id, -32601, 'method not found: ' + method);
    }
  } catch (e) {
    fail(id, -32603, String(e && e.message ? e.message : e));
  }
});
} // if (isMain)

// exported for tests / embedding (running this file directly still starts the stdio server)
export { TOOLS, callTool, http, qs, BASE, PROTOCOL };
