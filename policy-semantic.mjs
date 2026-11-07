#!/usr/bin/env node
// bridge/policy-semantic.mjs - drives the duel purely through the client's SEMANTIC action API.
// The bot never builds kernel packets: it reads /actions (id + kind + label) and posts /act_id.
//
// ---------------------------------------------------------------------------------------------
// SELF-DIAGNOSTICS (v2)  -- answers the "bot stopped acting while the process is still alive" bug
// ---------------------------------------------------------------------------------------------
// The control API only advances `seq` when a *new prompt* is created (Control::Pump: ++g_seq,
// g_awaiting=true), and /wait_prompt returns either when seq advances or when `awaiting` drops.
// So "no new seq for a long time" can mean three very different things, and this file now
// distinguishes them in the log instead of going silent:
//   (a) the client is not producing prompts at all  -> curMsg==0 / awaiting=false / seq frozen,
//       lastMsg.id is still the previous MSG_* -> pipeline dead (see bridge/docs/pipeline-diag.md)
//   (b) a prompt exists but we never answered       -> awaiting=true with the same seq
//   (c) we answered but the kernel rejected it      -> /act_id ok:false, or seq jumped while
//       awaiting=false (prompt superseded) -> counted as skipped stale
//
// Signals printed:
//   [sem] hb ...            heartbeat every HEARTBEAT_MS    -> proves the bot loop is alive
//   [sem] STALL ...         every STALL_MS without a new seq -> full snapshot + last 3 actions
//   [sem] EMPTY ...         5 consecutive /actions==[]       -> snapshot
//   [sem] http-err ...      consecutive HTTP failures        -> client's HTTP thread gone?
//   [sem] act-retry ...     /act_id ok:false -> one retry    -> shows rejection reason
//   [sem] escalate ...      same curMsg >= ESCALATE_AFTER    -> "same prompt keeps coming back"
//   [sem] ACTIVATE-TRAP ...  a goal trap can be activated now -> picks it (MISSION yields)
//   [sem] SET-TRAP ...       a goal trap is SET face-down so it can fire later (this was missing
//                            entirely -> traps stayed in hand and never activated)
//   [sem] SET-MONSTER ...    optional one monster set as a wall (never a tuner)
//   [sem] CHAIN-TRAP ...     chaining a goal trap             -> 用[激流葬]连锁[对手的XXX]
//   [sem] CHAIN-FORCED ...   canDecline=false                 -> must chain, reason printed
//   [sem] CHAIN-INTERFERE ... optional chain that hurts the opponent
//   [sem] CHAIN-DECLINE ...  declining (canDecline=true, no goal trap)
//   [sem] stats ...         on exit (timer, SIGINT, or win)  -> totals for post-mortem
//
// TRAP GOAL (task-21): the user acceptance is "successfully activate one of 激流葬 53582587 /
// 神之警告 84749824 / 三角乌鸦阵-反埋伏 59839761". So a goal trap that can be activated (kind
// `activate`) or chained (kind `chain`) is taken BEFORE anything else, and MISSION mode yields to
// it. Chain decisions use the semantics that the control layer exposes (/prompt: chainStack,
// chainDepth, chainingTo, chainCandidates[], canDecline, hint); when those fields are absent we
// derive the same information from the action labels ("chain #0 code=53582587") and chainForced,
// so the trap-chain path works on older clients too.
//
// ESCALATION (anti RETRY-loop): the server answers an illegal response with MSG_RETRY and the
// client re-issues the *same* prompt (same curMsg, new seq). If choose() keeps returning the same
// answer, the duel deadlocks. So when the same curMsg arrives >= ESCALATE_AFTER times in a row we
// deliberately pick a DIFFERENT legal candidate instead:
//     chain kind present      -> chain it (i=0) instead of declining
//     place kind present      -> rotate to the next place
//     select/sum/card present -> rotate the picked index (+1, wrapping)
//     position present        -> toggle attack <-> defense
//     anything else           -> the LAST candidate (differs from choose()'s "first")
// The counter resets as soon as curMsg changes, so normal play is untouched.
//
// Env:
//   CONTROL_URL             default http://127.0.0.1:7788  (host 7788 / guest 7789)
//   MAX_MINUTES             default 20
//   STALL_MS                default 20000   no-new-seq threshold
//   EMPTY_ACTIONS_LIMIT     default 5       consecutive empty /actions before shouting
//   HEARTBEAT_MS            default 30000
//   WAIT_TIMEOUT_MS         default 15000   /wait_prompt long-poll budget
//   ACT_RETRIES             default 1       extra attempts when /act_id says ok:false
//   DIAG_EVERY_MS           default 30000   minimum gap between repeated STALL blocks
//   ESCALATE_AFTER          default 3       same-curMsg repeats before switching answers
//   TRAP_GOAL               default 1       priority for the three goal traps (=0 disables)
//   TP_PREF                 default first   first|second turn choice when the client offers
//                                           `kind:"tp"` actions (logs `TP-PICK first (index=1)`)
//   MAX_IDLE_ACTIONS        default 5       hard guard: consecutive answer attempts that leave the
//                                           duel state unchanged (turn/phase/LP/hand/deck/grave/mon/
//                                           chain/win/curMsg all identical) -> STALL HARD + exit 2
//   --max-idle-actions N    same as MAX_IDLE_ACTIONS, from the command line
//
// SAFETY GUARDS (added after a real ranked game spun 43 "safe default" responses at turn 1):
//   * `auto` (the control layer's catch-all "safe default") is only answered for messages that are
//     purely informational / ack-only and therefore cannot move the duel (MSG_HINT/NEW_TURN/...).
//     An unknown msg whose only candidate is `auto` means the client could not model a REAL prompt:
//     we refuse to answer it (no response is sent) instead of spinning.
//   * an `/actions` result with `awaiting == false` is never acted on (nothing is waiting for us).
//   * if `MAX_IDLE_ACTIONS` consecutive answer attempts leave the state unchanged (or an awaiting
//     prompt never receives a new seq), we print
//         STALL HARD reason=no-progress seq=.. turn=.. autos=.. idle=../..
//     and exit with code 2 so the supervisor can restart the client/policy.
import process from 'node:process';

/** command-line override: node policy-semantic.mjs --max-idle-actions 5 */
function cliArg(name) {
  const i = process.argv.indexOf('--' + name);
  if (i === -1) return null;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}

const CFG = {
  base: process.env.CONTROL_URL || 'http://127.0.0.1:7788',
  maxMin: Number(process.env.MAX_MINUTES || 20),
  stallMs: Number(process.env.STALL_MS || 20000),
  emptyLimit: Number(process.env.EMPTY_ACTIONS_LIMIT || 5),
  hbMs: Number(process.env.HEARTBEAT_MS || 30000),
  waitMs: Number(process.env.WAIT_TIMEOUT_MS || 15000),
  actRetries: Number(process.env.ACT_RETRIES ?? 1),
  diagEveryMs: Number(process.env.DIAG_EVERY_MS || 30000),
  escalateAfter: Math.max(2, Number(process.env.ESCALATE_AFTER || 3)),
  maxIdleActions: Math.max(1, Number(cliArg('max-idle-actions') ?? process.env.MAX_IDLE_ACTIONS ?? 5)),
  // first/second-turn preference when the client offers `kind:"tp"` actions (tpPending):
  //   first  = 先攻 (default; Blackwing likes to go first)   second = 后攻
  tpPref: String(process.env.TP_PREF || 'first').toLowerCase() === 'second' ? 'second' : 'first',
};

// Msg ids for which answering with the generic "safe default" (`auto`) is harmless: these are
// informational / acknowledge-only messages that the control layer still exposes as an action.
// Verified against mycard-client/ocgcore/common.h and against real-duel logs, where `auto` was used
// almost exclusively for MSG_NEW_PHASE(41), MSG_NEW_TURN(40), MSG_CHAIN_SOLVING(72), MSG_MOVE(50)...
// NOT in this list: every real prompt (SELECT_*/CONFIRM_*/ANNOUNCE_*) - an `auto`-only answer there
// would be a blind response, which is exactly the bug that spun 43 answers in a ranked game.
const AUTO_SAFE_MSGS = new Set([
  2,   // MSG_HINT
  30,  // MSG_CONFIRM_DECKTOP (ack-only)
  31,  // MSG_CONFIRM_CARDS   (ack-only)
  40,  // MSG_NEW_TURN
  41,  // MSG_NEW_PHASE
  42,  // MSG_CONFIRM_EXTRATOP (ack-only)
  50,  // MSG_MOVE
  53,  // MSG_POS_CHANGE
  54,  // MSG_SET
  55,  // MSG_SWAP
  70,  // MSG_CHAINING
  71,  // MSG_CHAINED
  72,  // MSG_CHAIN_SOLVING
  73,  // MSG_CHAIN_SOLVED
  74,  // MSG_CHAIN_END
  75,  // MSG_CHAIN_NEGATED
  76,  // MSG_CHAIN_DISABLED
  90,  // MSG_DRAW
  91,  // MSG_DAMAGE
  92,  // MSG_RECOVER
  93,  // MSG_EQUIP
  94,  // MSG_LPUPDATE
  96,  // MSG_CARD_TARGET
  97,  // MSG_CANCEL_TARGET
  100, // MSG_PAY_LPCOST
  101, // MSG_ADD_COUNTER
  102, // MSG_REMOVE_COUNTER
  110, // MSG_ATTACK
  111, // MSG_BATTLE
  112, // MSG_ATTACK_DISABLED
  113, // MSG_DAMAGE_STEP_START
  114, // MSG_DAMAGE_STEP_END
  120, // MSG_MISSED_EFFECT
  130, // MSG_TOSS_COIN
  131, // MSG_TOSS_DICE
]);

const T0 = Date.now();
const log = (...a) => console.log('[sem]', ...a);
const jitter = (a = 250, b = 700) => new Promise((r) => setTimeout(r, a + Math.random() * (b - a)));
const uptime = () => Math.round((Date.now() - T0) / 1000);

// ---------------------------------------------------------------- stats shared by all exits
const S = {
  acted: 0,
  skippedStale: 0,
  heartbeats: 0,
  stalls: 0,
  emptyBursts: 0,
  actErrors: 0,
  actRetries: 0,
  escalations: 0,
  trapsActivated: 0,   // target traps (53582587/84749824/59839761) activated or chained
  trapsSet: 0,         // face-down sets of spells/traps (goal traps + generic)
  autos: 0,            // `auto` safe-default actions actually sent (whitelisted msgs only)
  autoBlocked: 0,      // `auto`-only prompts on unknown msgs that we refused to answer
  tpPicks: 0,          // first/second-turn (tp) choices sent to the kernel
  notAwaitingSkips: 0, // /actions results with awaiting=false that we refused to act on
  chainsTaken: 0,
  chainsDeclined: 0,
  httpErrors: 0,
  loops: 0,
  since: 0,          // last seq we have consumed
  lastCurMsg: 0,
  lastAwaiting: null,
  recent: [],        // last 3 own actions
  finished: false,
  win: null,         // true | false | null - verdict from the LOCAL player's perspective (isWin)
  result: null,      // win | loss | draw | unknown - same vocabulary as supervisor's duel_result
  winReason: null,
  exitReason: null,
};

function recentActionsText() {
  if (!S.recent.length) return '(none yet)';
  return S.recent.map((r, i) => `#${i + 1} seq=${r.seq} ${r.kind} "${r.label}"`).join(' | ');
}

function printStats(reason) {
  if (S.exitReason) return;      // only once
  S.exitReason = reason;
  log(`stats reason=${reason} uptime=${uptime()}s acted=${S.acted} skippedStale=${S.skippedStale}` +
    ` escalations=${S.escalations} heartbeats=${S.heartbeats} stalls=${S.stalls} emptyBursts=${S.emptyBursts}` +
    ` trapsActivated=${S.trapsActivated} trapsSet=${S.trapsSet} chainsTaken=${S.chainsTaken} chainsDeclined=${S.chainsDeclined}` +
    ` autos=${S.autos} autoBlocked=${S.autoBlocked} notAwaiting=${S.notAwaitingSkips} tpPicks=${S.tpPicks}` +
    ` win=${S.win === null ? 'unknown' : S.win} result=${S.result ?? 'unknown'}` +
    `${S.winReason ? '(' + S.winReason + ')' : ''}` +
    ` actErrors=${S.actErrors} actRetries=${S.actRetries} httpErrors=${S.httpErrors} loops=${S.loops}` +
    ` lastSeq=${S.since} lastCurMsg=${S.lastCurMsg} lastAwaiting=${S.lastAwaiting} finished=${S.finished}`);
  log('stats recent=' + recentActionsText());
}

/** most recent /state snapshot: lets the stall guards give way to "the duel is already over" */
let LAST_STATE = null;

// WIN ACCOUNTING (important, easy to get wrong):
//   /state.winPlayer is the RAW seat number (0/1) or 2 for a draw; our client joins as raw seat 1,
//   so winPlayer==0 means the OPPONENT won. dInfo.lp[0] is the LOCAL player's LP, which is why the
//   patched client now exposes `winPlayerLocal` (LocalPlayer(raw)) and the canonical `isWin`.
//   Preference order: isWin -> winPlayerLocal === 0 -> unknown (never guess).
function numOrNull(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
function winInfo(st) {
  const s = st || {};
  const raw = numOrNull(s.winPlayer);
  const local = numOrNull(s.winPlayerLocal);
  // draw: explicit isDraw, raw seat 2, or winPlayerLocal === -1 (client contract: 0=us,1=opponent,-1=draw)
  const draw = s.isDraw === true || raw === 2 || local === -1;
  if (typeof s.isWin === 'boolean') return { win: s.isWin, draw, raw, local, src: 'isWin' };
  if (local !== null && local >= 0) return { win: local === 0, draw, raw, local, src: 'winPlayerLocal' };
  if (local === -1) return { win: false, draw: true, raw, local, src: 'winPlayerLocal' };
  return { win: null, draw, raw, local, src: 'unknown' };
}
function isWinText(info) {
  if (!info || info.win === null) return 'unknown';
  return info.win ? 'true' : 'false';
}
/** single-word verdict, same vocabulary as the supervisor's `duel_result.result` */
function resultText(info) {
  if (!info) return 'unknown';
  if (info.draw) return 'draw';
  if (info.win === true) return 'win';
  if (info.win === false) return 'loss';
  return 'unknown';
}

/** true when the client reports a finished duel (win player known, or MSG_WIN is current) */
function isGameOver(st) {
  if (!st) return false;
  return Number(st.winPlayer) >= 0 || st.curMsg === 5;
}

/**
 * The duel is over: print the verdict + totals and exit 0.
 * Runs BEFORE any stall guard: after MSG_WIN the client stops issuing prompts, which used to look
 * like "no progress" and could print STALL HARD / exit 2 at the end of a perfectly normal game.
 * The verdict uses `isWin` (local player's perspective), never the raw seat number.
 */
function gameOver(st, why) {
  if (S.exitReason && S.exitReason !== 'game-over') return;   // already exiting for another reason
  const src = st || LAST_STATE || {};
  const info = winInfo(src);
  const reasonName = src.winReasonName && src.winReasonName !== '' ? src.winReasonName : (src.winReason ?? '?');
  S.finished = true;
  S.win = info.win;                 // true | false | null  (null = client did not expose it)
  S.result = resultText(info);      // win | loss | draw | unknown (same vocabulary as supervisor)
  S.winReason = reasonName;
  S.lastCurMsg = typeof src.curMsg === 'number' ? src.curMsg : S.lastCurMsg;
  log(`GAME OVER isWin=${isWinText(info)} reason=${reasonName} turn=${src.turn}` +
    ` result=${S.result} raw=${info.raw ?? '?'} local=${info.local ?? '?'} draw=${info.draw} src=${info.src}` +
    (info.win === null ? ' (unknown isWin)' : '') +
    ` acted=${S.acted} up=${uptime()}s (${why})`);
  printStats('game-over');
  // flush stdout before the supervisor reads the exit code (0 = clean finish)
  setTimeout(() => process.exit(0), 50);
}

/** kept for existing call sites: same behaviour as gameOver() */
function finishFromState(st) {
  gameOver(st, 'state');
}

// ---------------------------------------------------------------- HTTP helpers
/** GET path -> { data, error, ms }. Never throws. */
async function getJson(path, timeoutMs = 30000) {
  const t = Date.now();
  try {
    const res = await fetch(CFG.base + path, { signal: AbortSignal.timeout(timeoutMs) });
    const text = await res.text();
    let data = null;
    try { data = JSON.parse(text); } catch { data = { raw: text.slice(0, 200) }; }
    return { data, error: null, ms: Date.now() - t };
  } catch (e) {
    return { data: null, error: e?.name === 'TimeoutError' ? `timeout(${timeoutMs}ms)` : String(e?.message || e), ms: Date.now() - t };
  }
}

const req = async (path, method = 'GET') => {
  const r = await getJson(path);
  return r.data;
};

// ---------------------------------------------------------------- attack picking
// Attack labels look like: "attack #0 atk=2000" (index + ATK), sometimes "direct attack".
// We parse the ATK out of the label so we can prefer a swing that actually wins a battle, and
// prefer a direct attack (LP damage) when the opponent's field is empty.
const RE_ATK = /atk\s*[=:]\s*(\d+)/i;
function parseAtk(label) {
  const m = RE_ATK.exec(String(label || ''));
  return m ? Number(m[1]) : null;
}

function pickAttack(atks) {
  if (!atks.length) return null;
  const scored = atks.map((a) => ({ a, atk: parseAtk(a.label) }));
  const direct = scored.filter((x) => /direct/i.test(String(x.a.label || '')));
  if (direct.length) {
    // direct attacks are always the best swing: take the hardest hitter
    return direct.sort((p, q) => (q.atk ?? 0) - (p.atk ?? 0))[0].a;
  }
  const known = scored.filter((x) => x.atk != null);
  if (!known.length) return atks[0];
  const oppAtks = Array.isArray(globalThis.__oppAtks) ? globalThis.__oppAtks : [];
  if (!oppAtks.length) {
    // opponent has no visible monster: any attack is safe
    return known.sort((p, q) => q.atk - p.atk)[0].a;
  }
  const weakestOpp = Math.min(...oppAtks);
  // can beat at least one opponent monster -> prefer those, hardest hitter first
  const beat = known.filter((x) => x.atk >= weakestOpp);
  const pool = beat.length ? beat : known;
  return pool.sort((p, q) => q.atk - p.atk)[0].a;
}

// ---------------------------------------------------------------- TRAP GOAL + chain semantics
// User acceptance: successfully ACTIVATE one of the three traps in the Blackwing deck:
//   激流葬 53582587 (Torrential Tribute) / 神之警告 84749824 (Solemn Warning) /
//   三角乌鸦阵-反埋伏 59839761 (Delta Crow - Anti Reverse).
// TRAP_GOAL=0 disables the priority (default: on).
//
// Chain semantics come from the control layer (task-19 adds them to /prompt + /state.prompt):
//   chainStack[] / chainDepth / chainingTo / chainCandidates[] / canDecline / hint
// Older clients only expose "chains" (=CandSnap[] with code, because PromptJson has a duplicate
// key) and "chainForced"; chainCandidatesFromActions() derives the same shape from the action list
// (labels look like "chain #0 code=53582587"), so trap-chain selection already works today.
const TRAP_GOAL = process.env.TRAP_GOAL !== '0';
const TRAP_CODES = new Map([
  [53582587, '激流葬'],
  [84749824, '神之警告'],
  [59839761, '三角乌鸦阵-反埋伏'],
]);
const TRAP_REASON = new Map([
  [53582587, '破坏全场怪兽'],
  [84749824, '无效特殊召唤/效果并破坏'],
  [59839761, '破坏对手魔法陷阱区的盖卡'],
]);
const RE_CODE = /code=(\d+)/;
const RE_INDEX = /#(\d+)/;
const codeFromLabel = (label) => {
  const m = RE_CODE.exec(String(label || ''));
  return m ? Number(m[1]) : null;
};
const idxOfLabel = (label) => {
  const m = RE_INDEX.exec(String(label || ''));
  return m ? Number(m[1]) : null;
};
const trapNameOf = (code) => TRAP_CODES.get(Number(code)) || null;

// semantics of the prompt we are currently answering (filled by the main loop)
let LAST_PROMPT = null;
function promptChain() {
  const p = LAST_PROMPT || {};
  const semantic = Array.isArray(p.chainCandidates) && p.chainCandidates.length ? p.chainCandidates : null;
  const listish = Array.isArray(p.chains) ? p.chains : null;   // old client: duplicate-key "chains" is CandSnap[]
  return {
    semantic: !!semantic,
    cands: semantic || listish || [],
    stack: Array.isArray(p.chainStack) ? p.chainStack : [],
    depth: typeof p.chainDepth === 'number' ? p.chainDepth : (Array.isArray(p.chainStack) ? p.chainStack.length : 0),
    chainingTo: p.chainingTo || null,
    canDecline: p.canDecline === undefined ? !p.chainForced : p.canDecline !== false,
    hint: p.hint || '',
    forcedAll: !!p.chainForced,
  };
}
function chainTargetText(sem) {
  if (!sem.chainingTo) return '当前连锁';
  const t = sem.chainingTo;
  return `[${t.name || trapNameOf(t.code) || ('code ' + t.code)}]`;
}
/** normalize candidates: task-19 semantic fields, or derive them from the chain action labels */
function chainCandsOf(sem, chainActs) {
  if (sem.cands.length) {
    return sem.cands.map((c, k) => ({
      index: Number.isInteger(c.index) ? c.index : (Number.isInteger(c.i) ? c.i : k),
      code: Number(c.code) || null,
      name: c.name || trapNameOf(c.code),
      descText: c.descText || c.descText === '' ? c.descText : (c.desc || ''),
      forced: !!c.forced || sem.forcedAll,
      isMine: c.isMine,
    }));
  }
  return chainActs.map((a, k) => ({
    index: idxOfLabel(a.label) ?? k,
    code: codeFromLabel(a.label),
    name: trapNameOf(codeFromLabel(a.label)),
    descText: '',
    forced: sem.forcedAll,
    isMine: null,
  }));
}
function chainActionFor(cand, chainActs) {
  if (!chainActs.length) return null;
  const byIdx = chainActs.find((a) => idxOfLabel(a.label) === cand.index);
  if (byIdx) return byIdx;
  if (cand.code != null) {
    const byCode = chainActs.find((a) => codeFromLabel(a.label) === cand.code);
    if (byCode) return byCode;
  }
  return chainActs[cand.index] || chainActs[0];
}
/** the prompt's activatable/hand card entry for a code (to tell whether an effect desc exists) */
function promptCardByCode(code) {
  const p = LAST_PROMPT || {};
  for (const key of ['activatableCards', 'ssetableCards', 'chainCandidates', 'chains']) {
    const arr = Array.isArray(p[key]) ? p[key] : null;
    if (!arr) continue;
    const hit = arr.find((c) => Number(c.code) === Number(code));
    if (hit) return hit;
  }
  return null;
}
/** a target trap that can be ACTIVATED right now (IDLECMD "activate" window) */
function pickTrapActivate(actions, byKind) {
  if (!TRAP_GOAL) return null;
  for (const a of byKind('activate')) {
    const code = codeFromLabel(a.label);
    if (code != null && TRAP_CODES.has(code)) {
      const entry = promptCardByCode(code);
      const noDesc = entry && (entry.desc === 0 || entry.desc == null || entry.descText === '');
      log(`ACTIVATE-TRAP ${TRAP_CODES.get(code)}(${code}) -> ${a.label}${noDesc ? ' (no desc)' : ''}`);
      return a;
    }
  }
  return null;
}
/** chain decision driven by semantics; returns null when there is no chain candidate at all */
function decideChain(actions, byKind) {
  const chainActs = byKind('chain');
  if (!chainActs.length) return null;
  const declineActs = byKind('decline');
  const sem = promptChain();
  const cands = chainCandsOf(sem, chainActs);
  const target = chainTargetText(sem);
  const whyOf = (c) => c.descText || TRAP_REASON.get(Number(c.code)) || '目标陷阱/效果';

  // 1) goal trap first (this also makes MISSION yield; see choose())
  if (TRAP_GOAL) {
    const goal = cands.find((c) => c.code != null && TRAP_CODES.has(Number(c.code)));
    if (goal) {
      const act = chainActionFor(goal, chainActs);
      if (act) {
        const noDesc = goal.descText === '' || goal.descText === null || goal.descText === undefined;
        log(`CHAIN-TRAP 用[${goal.name || TRAP_CODES.get(Number(goal.code))}]连锁${target}` +
          `（理由：${whyOf(goal)}${sem.depth ? `；depth=${sem.depth}` : ''}）` +
          (noDesc && TRAP_REASON.get(Number(goal.code)) ? ' (no desc)' : ''));
        return act;
      }
    }
  }

  // 2) cannot decline -> must chain something
  if (!sem.canDecline) {
    const pickCand = cands.find((c) => c.forced) || cands[0];
    const act = chainActionFor(pickCand, chainActs) || chainActs[0];
    log(`CHAIN-FORCED 必须连锁${target} -> ${act.label}（canDecline=false）`);
    return act;
  }

  // 3) optional: only chain when it looks disruptive and it answers the opponent
  const oppTarget = sem.chainingTo && sem.chainingTo.isMine === false;
  const disruptive = cands.find((c) => /破坏|无效|除外|返回|送去墓地|negate|destroy/i.test(String(c.descText || '')));
  if (disruptive && (oppTarget || !sem.semantic)) {
    const act = chainActionFor(disruptive, chainActs);
    if (act) {
      log(`CHAIN-INTERFERE 用[${disruptive.name || ('code ' + disruptive.code)}]连锁${target}` +
        `（理由：${disruptive.descText || '能干扰对手'}）`);
      return act;
    }
  }

  // 4) decline when allowed
  if (declineActs.length) {
    log(`CHAIN-DECLINE 不连锁${target}（canDecline=true，无目标陷阱）${sem.hint ? ` hint=${sem.hint}` : ''}`);
    return declineActs[0];
  }

  // 5) no decline candidate at all -> we still have to answer
  log(`CHAIN-ANSWER 无 decline 候选，只能连锁${target} -> ${chainActs[0].label}`);
  return chainActs[0];
}
/** trapsActivated / chainsTaken / chainsDeclined counters */
function noteActionStats(act) {
  if (!act) return;
  const code = codeFromLabel(act.label);
  const isGoalTrap = TRAP_CODES.has(Number(code));
  if (act.kind === 'activate') {
    if (isGoalTrap) S.trapsActivated++;
  } else if (act.kind === 'chain') {
    S.chainsTaken++;
    if (isGoalTrap) S.trapsActivated++;
  } else if (act.kind === 'decline') {
    S.chainsDeclined++;
  } else if (act.kind === 'set_spell' || act.kind === 'set_monster') {
    // remember what we already set this turn (keeps choose() from re-setting the same card)
    syncSetTurn();
    if (code != null) SET_PER_TURN.codes.add(Number(code));
    SET_PER_TURN.count++;
    if (act.kind === 'set_spell') S.trapsSet++;   // a face-down spell/trap (goal trap or generic)
  } else if (act.kind === 'tp') {
    S.tpPicks++;                                  // first/second-turn choice sent to the kernel
  }
}

// ---------------------------------------------------------------- SET (盖放) policy
// ROOT CAUSE of "the three traps never fire": choose() had no branch for kind 'set_spell' /
// 'set_monster', so the traps were never placed face-down -- and a trap can only be activated from
// the field. /actions already offers them:
//   "set spell/trap #i code=53582587"  (kind=set_spell,   from ssetable_cards)
//   "set monster #i code=..."          (kind=set_monster, from msetable_cards)
// Priority (lead): spsummon > summon > ACTIVATE-TRAP > set_spell(goal) > attack > to_bp > ...
// SET_PER_TURN stops us from dumping the whole hand / re-setting the same card in one turn; it is
// reset whenever `turn` changes (globalThis.__turn is fed by the main loop).
const SET_PER_TURN = { turn: null, codes: new Set(), count: 0 };
function syncSetTurn() {
  const t = globalThis.__turn;
  if (t !== SET_PER_TURN.turn) {
    SET_PER_TURN.turn = t;
    SET_PER_TURN.codes = new Set();
    SET_PER_TURN.count = 0;
  }
}
/** a goal trap that can be SET face-down right now -> {act, code, name, why} | null */
function pickTrapSet(actions, byKind) {
  if (!TRAP_GOAL) return null;
  syncSetTurn();
  const sets = byKind('set_spell');
  if (!sets.length) return null;
  // 1) a goal trap we recognise by code (this is the acceptance path)
  for (const a of sets) {
    const code = codeFromLabel(a.label);
    if (code != null && TRAP_CODES.has(code) && !SET_PER_TURN.codes.has(code)) {
      return { act: a, code, name: TRAP_CODES.get(code), why: 'goal-trap' };
    }
  }
  // 2) code unknown (missing or 0) but it IS a spell/trap set -> set at most ONE per turn
  if (SET_PER_TURN.count === 0) {
    const unknown = sets.find((a) => {
      const c = codeFromLabel(a.label);
      return (c == null || c === 0) && /set\s+spell/i.test(String(a.label || ''));
    });
    if (unknown) return { act: unknown, code: null, name: null, why: 'unknown-spell/trap?1' };
  }
  return null;
}
/** optional: set one monster as a wall when there is no better summon (never a tuner) */
function pickMonsterSet(actions, byKind) {
  if (!TRAP_GOAL) return null;
  syncSetTurn();
  if (SET_PER_TURN.count >= 1) return null;
  const sets = byKind('set_monster');
  if (!sets.length) return null;
  const a = sets.find((x) => !/tuner/i.test(String(x.label || '')));
  return a ? { act: a, code: codeFromLabel(a.label), name: null, why: 'monster-wall' } : null;
}

// pick an action id by priority; this is exactly the decision an LLM would make from labels
// Priority (v4, task-21 supplement): spsummon > summon(tuner/normal) > ACTIVATE-TRAP >
// SET-TRAP(set_spell goal) > SET-MONSTER(optional wall) > attack > other activate > to_bp >
// chain > decline > place > position > select > sum > yes > no > option > end_battle > to_ep.
// NOTE: SET was missing entirely before -> the goal traps stayed in hand and could never be
// activated, which is why the trap goal never fired.
// ATTACK POLICY (v3): attacking used to require >=4 monsters, so both bots just passed forever and
// LP never moved (9 turns at 8000/8000). Now we attack by default; we only hold back for the
// "keep materials for the extra deck" case: exactly 2 monsters on our field AND (an extra-deck
// special summon is available OR a tuner is in hand). Everything else (including 1 monster) swings.
// ---- MISSION MODE: the user asked for one game that performs a Synchro Summon AND an Xyz Summon,
// then wins. Until both have been seen on our field we avoid battle (keep materials) and steer the
// summons towards the missing type; once both are done the normal aggressive policy takes over.
const MISSION = (globalThis.__mission = globalThis.__mission || { synchro: false, xyz: false, attacks: 0 });
const TY_SYNCHRO = 0x2000, TY_XYZ = 0x800000, TY_TUNER = 0x1000;
// MISSION mode (synchro + xyz before attacking) is a demo/goal mode and makes bots passive,
// which can drag a normal game to the time limit. Default OFF; enable with MISSION=1.
const MISSION_MODE = process.env.MISSION === '1';
function missionPending() { return MISSION_MODE && (!MISSION.synchro || !MISSION.xyz); }
function missionText() {
  return `synchro=${MISSION.synchro ? 'OK' : 'TODO'} xyz=${MISSION.xyz ? 'OK' : 'TODO'}`;
}
function chooseMission(actions) {
  const byKind = (k) => actions.filter((a) => a.kind === k);
  const sp = byKind('spsummon');
  if (sp.length) {
    const pickSyn = sp.find((a) => (a.label || '').includes('synchro'));
    const pickXyz = sp.find((a) => (a.label || '').includes('xyz'));
    if (!MISSION.synchro && pickSyn) { log(`MISSION -> spsummon synchro (${pickSyn.label})`); return pickSyn; }
    if (!MISSION.xyz && pickXyz) { log(`MISSION -> spsummon xyz (${pickXyz.label})`); return pickXyz; }
    if (pickSyn || pickXyz) { const a = pickSyn || pickXyz; log(`MISSION -> spsummon (${a.label})`); return a; }
  }
  const summon = byKind('summon');
  if (summon.length) {
    const tunerSum = summon.find((a) => (a.label || '').includes('tuner'));
    const nonTuner = summon.find((a) => !(a.label || '').includes('tuner'));
    if (!MISSION.synchro) {
      // need one tuner + one non-tuner on the field
      if (!globalThis.__tunerOnField && tunerSum) { log(`MISSION -> summon tuner (${tunerSum.label})`); return tunerSum; }
      if (globalThis.__tunerOnField && nonTuner) { log(`MISSION -> summon non-tuner (${nonTuner.label})`); return nonTuner; }
    } else if (nonTuner) {
      // XYZ needs two monsters of the SAME level: prefer a summon whose level matches a monster we control
      const levels = Array.isArray(globalThis.__fieldLevels) ? globalThis.__fieldLevels : [];
      const lvOf = (a) => { const m = /lv=(\d+)/.exec(a.label || ''); return m ? parseInt(m[1], 10) : 0; };
      const match = nonTuner && levels.length ? summon.find((a) => !(a.label || '').includes('tuner') && levels.includes(lvOf(a))) : null;
      const pick = match || nonTuner;
      log(`MISSION -> summon non-tuner for xyz (${pick.label}) levels=${JSON.stringify(levels)}`);
      return pick;
    }
  }
  // do not swing while we still need material on the board
  const endBattle = byKind('end_battle');
  if (endBattle.length) { log('MISSION -> end battle (keep materials)'); return endBattle[0]; }
  const place = byKind('place');
  if (place.length) return place[0];
  const position = byKind('position');
  if (position.length) return position[0];
  const select = byKind('select');
  if (select.length) return select[0];
  const sum = byKind('sum');
  if (sum.length) return sum[0];
  const yes = byKind('yes');
  if (yes.length) return yes[0];
  const no = byKind('no');
  if (no.length) return no[0];
  const opt = byKind('option');
  if (opt.length) return opt[0];
  const decline = byKind('decline');
  if (decline.length) return decline[0];
  const chain = byKind('chain');
  if (chain.length) return chain[0];
  return null;
}
/** first/second-turn (tp) choice: prefer first by default (Blackwing wants to go first). */
function pickTp(actions, byKind) {
  const tps = byKind('tp');
  if (!tps.length) return null;
  const pref = CFG.tpPref === 'second' ? 2 : 1;
  // The client may put the semantic index on the action itself ({"kind":"tp","index":1}) and/or in
  // the label ("tp first (index=1)"). Trust the field first (1=first, 2=second), then the label,
  // then the array order (the client lists [first, second]).
  const idxOf = (a) => {
    const field = Number(a.index);
    if (field === 1 || field === 2) return field;
    const label = String(a.label || '');
    const m = /index\s*[=:]\s*(\d+)/i.exec(label);
    if (m) return Number(m[1]);
    if (/first|先攻/i.test(label)) return 1;
    if (/second|后攻/i.test(label)) return 2;
    return null;                          // no explicit signal: fall back to array order
  };
  // If the label carries no index/word, assume the client lists them in order (1 = first, 2 = second).
  const cands = tps.map((a, i) => ({ act: a, index: idxOf(a) ?? (i + 1) }));
  const want = cands.find((c) => c.index === pref) || cands.find((c) => c.index === 1) || cands[0];
  return { act: want.act, index: want.index, pref: want.index === 1 ? 'first' : 'second' };
}

function choose(actions) {
  const byKind = (k) => actions.filter((a) => a.kind === k);

  // ---- 0) TP (first/second turn) choice, when the client offers it (tpPending):
  //         default = first (Blackwing likes to go first); TP_PREF=second flips it.
  const tp = pickTp(actions, byKind);
  if (tp) {
    // /act_id takes the action id (client: id 0 = first, id 1 = second); the index is the semantic value.
    log(`TP-PICK ${tp.pref} (index=${tp.index}) id=${tp.act.id} [TP_PREF=${CFG.tpPref}]`);
    return tp.act;
  }

  // Trap opportunities are computed up-front: MISSION has to yield to them (otherwise it would
  // swallow the set/activate/chain window and the traps would stay in hand forever), and they are
  // used a bit later in the priority order (after the summons).
  const trapSet = pickTrapSet(actions, byKind);
  const trapAct = pickTrapActivate(actions, byKind);

  if (missionPending()) {
    // MISSION must not swallow a trap window:
    //   - a goal trap is chainable, or
    //   - a goal trap can be set/activated, or
    //   - we are not allowed to decline (choosing "decline" would be an illegal response -> RETRY)
    const sem = promptChain();
    const goalChainable = sem.cands.some((c) => TRAP_CODES.has(Number(c.code)));
    const forcedChain = byKind('chain').length > 0 && !sem.canDecline;
    const trapWindow = !!trapSet || !!trapAct || goalChainable || forcedChain;
    if (trapWindow) {
      log(`MISSION yields -> trap window (set=${!!trapSet} activate=${!!trapAct}` +
        ` chain=${goalChainable} forced=${forcedChain}) ${missionText()}`);
    } else {
      const m = chooseMission(actions);
      if (m) return m;
    }
  }

  // ---- 1) special summon
  const sp = byKind('spsummon');
  if (sp.length) return sp[0];

  // ---- 2) normal summon (tuner first, then any monster)
  const summon = byKind('summon');
  const tuner = summon.find((a) => (a.label || '').includes('tuner'));
  if (tuner) return tuner;
  if (summon.length) return summon[0];

  // ---- 3) ACTIVATE-TRAP: a goal trap already face-down on our field can be flipped up now
  if (trapAct) return trapAct;

  // ---- 4) SET-TRAP: a goal trap in hand must be SET first, otherwise it can never activate
  if (trapSet) {
    log(`SET-TRAP 盖放[${trapSet.name || '未知陷阱'}](` +
      `${trapSet.code != null ? 'code=' + trapSet.code : 'code=?'}) -> ${trapSet.act.label}`);
    return trapSet.act;
  }

  // ---- 5) optional: one monster face-down as a wall (never a tuner; keeps the main plan intact)
  const monSet = pickMonsterSet(actions, byKind);
  if (monSet) {
    log(`SET-MONSTER 盖放 ${monSet.act.label}（当墙；本回合没有更好的召唤）`);
    return monSet.act;
  }

  // ---- 6) attack (see ATTACK POLICY above)
  const atk = byKind('attack');
  if (atk.length) {
    const myMon = globalThis.__myMon || 0;
    const spSummonable = globalThis.__spSummonable || 0;
    const handTuner = !!tuner || (globalThis.__handTuner || 0) > 0;
    const keepMaterials = myMon === 2 && (spSummonable > 0 || handTuner);
    if (keepMaterials) {
      log(`keep-materials: hold attack (myMon=${myMon} spSummonable=${spSummonable} handTuner=${handTuner}) -> fall through`);
    } else {
      const best = pickAttack(atk);
      if (best) {
        log(`attack-pick: ${JSON.stringify(best.label || '')} (myMon=${myMon} attacks=${atk.length}` +
          ` oppAtks=${JSON.stringify(Array.isArray(globalThis.__oppAtks) ? globalThis.__oppAtks : [])})`);
        return best;
      }
    }
  }

  // ---- 7) any other activate (non-goal spells/traps/effects)
  const act = byKind('activate');
  if (act.length) return act[0];
  const toBp = byKind('to_bp');
  if (toBp.length) return toBp[0];
  // ---- chain: driven by chain semantics (goal trap > forced > disruptive > decline)
  const chainDecision = decideChain(actions, byKind);
  if (chainDecision) return chainDecision;
  const decline = byKind('decline');
  if (decline.length) {
    const sem = promptChain();
    log(`CHAIN-DECLINE 不连锁${chainTargetText(sem)}（没有 chain 候选）`);
    return decline[0];
  }
  const place = byKind('place');
  if (place.length) return place[0];
  const position = byKind('position');
  if (position.length) return position[0];
  const select = byKind('select');
  if (select.length) return select[0];
  const sum = byKind('sum');
  if (sum.length) return sum[0];
  const yes = byKind('yes');
  if (yes.length) return yes[0];
  const no = byKind('no');
  if (no.length) return no[0];
  const opt = byKind('option');
  if (opt.length) return opt[0];
  const endBattle = byKind('end_battle');
  if (endBattle.length) return endBattle[0];
  const ep = byKind('to_ep');
  if (ep.length) return ep[0];
  return actions[0] || null;
}

// ---------------------------------------------------------------- escalation (anti RETRY-loop)
// If the same prompt keeps coming back (our answer was illegal -> server sent MSG_RETRY -> the
// client re-issued the prompt), choose() would answer it identically forever. Once the same curMsg
// has been seen ESCALATE_AFTER times in a row we deliberately answer DIFFERENTLY. The counter is
// reset the moment curMsg changes, so ordinary play never reaches this branch.
const ESC = {
  lastCurMsg: null,
  sameMsgCount: 0,
  rot: {},            // per-kind rotation cursors: repeated escalations try different candidates
  posToggle: false,
};

/** count consecutive prompts with the same curMsg; reset on change. Returns the current count. */
function trackPrompt(curMsg) {
  if (curMsg === ESC.lastCurMsg) {
    ESC.sameMsgCount++;
  } else {
    ESC.lastCurMsg = curMsg;
    ESC.sameMsgCount = 1;
    ESC.rot = {};
    ESC.posToggle = false;
  }
  return ESC.sameMsgCount;
}

function rotatePick(key, arr) {
  if (!arr.length) return null;
  const next = ((ESC.rot[key] ?? -1) + 1) % arr.length;
  ESC.rot[key] = next;
  return arr[next];
}

/** deliberately answer DIFFERENTLY from choose(); always returns a candidate from `list` */
function pickEscalated(list) {
  const of = (...kinds) => list.filter((a) => kinds.includes(a.kind));

  // 1) chain present -> chain it (i=0 on the first escalation) instead of declining
  const chains = of('chain');
  if (chains.length) return { act: rotatePick('chain', chains), why: 'chain' };

  // 2) place present -> rotate to the next place
  const places = of('place');
  if (places.length) return { act: rotatePick('place', places), why: 'place-rotate' };

  // 3) select / sum / card -> move the picked index (+1, wrapping inside the legal list)
  const picks = of('select', 'sum', 'card');
  if (picks.length) return { act: rotatePick('pick', picks), why: 'index-rotate' };

  // 4) position -> toggle attack <-> defense
  const positions = of('position');
  if (positions.length) {
    const isDef = (a) => /def/i.test(String(a.label || '') + ' ' + String(a.kind || ''));
    const attackish = positions.filter((a) => !isDef(a));
    const defendish = positions.filter(isDef);
    let pool = positions;
    if (attackish.length && defendish.length) {
      ESC.posToggle = !ESC.posToggle;
      pool = ESC.posToggle ? defendish : attackish;
    }
    return { act: rotatePick('position', pool), why: 'pos-toggle' };
  }

  // 5) anything else -> first escalation takes the LAST candidate (choose() takes the first);
  //    if that is rejected too, keep walking backwards so the loop eventually tries every action
  if (list.length) {
    const idx = ESC.rot.else ?? list.length - 1;
    ESC.rot.else = (idx - 1 + list.length) % list.length;
    return { act: list[idx], why: idx === list.length - 1 ? 'last-candidate' : `candidate#${idx}` };
  }
  return { act: null, why: 'nothing' };
}

/** single entry point for the loop: escalate only while the same prompt keeps repeating */
function pickAction(list, curMsg) {
  if (ESC.sameMsgCount >= CFG.escalateAfter) {
    const { act, why } = pickEscalated(list);
    if (act) {
      S.escalations++;
      log(`escalate msg=${curMsg} count=${ESC.sameMsgCount} -> ${act.kind}(${JSON.stringify(act.label || '')}) [${why}]`);
      return act;
    }
  }
  return choose(list);
}

// ---------------------------------------------------------------- diagnostics
/** one-line /state digest: what the client thinks is going on */
function stateDigest(st) {
  if (!st) return 'state=(unavailable)';
  const c = st.counts || {};
  const hand = c.hand ? c.hand.join('/') : '?';
  const deck = c.deck ? c.deck.join('/') : '?';
  const grave = c.grave ? c.grave.join('/') : '?';
  const mon = Array.isArray(st.monsters)
    ? `${(st.monsters[0] || []).length}/${(st.monsters[1] || []).length}`
    : '?';
  const lm = st.lastMsg || {};
  // lp[0] is the LOCAL player's LP (client exposes lpOrder:"local"), lp[1] is the opponent's
  return `turn=${st.turn} phase=${st.phaseName || st.phase} lp=${(st.lp || []).join('/')}` +
    `${st.lpOrder ? '(lpOrder=' + st.lpOrder + ')' : ''}` +
    ` hand=${hand} deck=${deck} grave=${grave} mon=${mon} myTurn=${st.isMyTurn} turnPlayer=${st.turnPlayer}` +
    ` timeLeft=${st.timeLeft} win=${st.winPlayer}/${st.winReason}(isWin=${isWinText(winInfo(st))})` +
    ` lastMsg=${lm.id}(len ${lm.len}) err=${st.errorMsg || 0}`;
}

function actionDigest(acts) {
  const list = (acts && acts.actions) || [];
  if (!list.length) return 'actions=[]';
  const kinds = {};
  for (const a of list) kinds[a.kind] = (kinds[a.kind] || 0) + 1;
  const head = list.slice(0, 4).map((a) => `${a.id}:${a.kind}:${JSON.stringify(a.label || '')}`).join(' ');
  return `actions=${list.length} [${head}${list.length > 4 ? ' ...' : ''}] kinds=${JSON.stringify(kinds)}`;
}

let lastDiagAt = 0;
/** the "I think I'm stuck" block: prints the evidence, never throws, never exits */
async function diagnose(tag, extra = {}) {
  const now = Date.now();
  if (now - lastDiagAt < CFG.diagEveryMs && tag !== 'EMPTY' && tag !== 'HTTP') return;
  lastDiagAt = now;
  if (tag === 'STALL') S.stalls++;
  if (tag === 'EMPTY') S.emptyBursts++;

  const st = await req('/state');
  const acts = await req('/actions');
  const frozenSec = Math.round((now - (S.lastSeqAt || T0)) / 1000);

  log(`${tag} stuck? uptime=${uptime()}s frozenSeq=${frozenSec}s seq=${S.since}` +
    ` curMsg=${S.lastCurMsg} awaiting=${S.lastAwaiting}` +
    ` | ${stateDigest(st)} | ${actionDigest(acts)}`);
  if (st && st.prompt) {
    const p = st.prompt;
    log(`${tag} prompt: seq=${p.seq} curMsg=${p.curMsg} awaiting=${p.awaiting}` +
      ` summonable=${p.summonable} spsummonable=${p.spsummonable} activatable=${p.activatable}` +
      ` attackable=${p.attackable} chains=${p.chains} canBp=${p.canBp} canEp=${p.canEp}`);
  }
  log(`${tag} recent actions: ${recentActionsText()}`);
  if (Object.keys(extra).length) log(`${tag} extra: ${JSON.stringify(extra)}`);

  // quick verdict so a human reading the log does not have to guess
  let verdict;
  if (!st) verdict = 'control API unreachable (HTTP thread dead or client closed)';
  else if (st.winPlayer >= 0) verdict = 'duel already ended';
  else if (st.awaiting) verdict = 'prompt EXISTS but we did not answer it (our loop/action path is the problem)';
  else if (st.isMyTurn === false) verdict = 'not our turn: waiting for the opponent (normal)';
  else if (st.curMsg === 0) verdict = 'no prompt pending (curMsg=0): kernel/pipeline not producing prompts';
  else verdict = 'prompt was consumed; waiting for the next one (client may be stuck before it)';
  log(`${tag} verdict: ${verdict}`);
  return st;
}

// heartbeat bookkeeping
let lastHbAt = Date.now();
let nextHbIn = CFG.hbMs;
function heartbeatIfDue(stateForHb) {
  const now = Date.now();
  nextHbIn = Math.max(0, CFG.hbMs - (now - lastHbAt));
  if (now - lastHbAt < CFG.hbMs) return;
  lastHbAt = now;
  nextHbIn = CFG.hbMs;
  S.heartbeats++;
  const hbWin = LAST_STATE ? winInfo(LAST_STATE) : { win: null, raw: null, local: null };
  const winText = LAST_STATE
    ? `isWin=${isWinText(hbWin)} raw=${hbWin.raw ?? '?'} local=${hbWin.local ?? '?'}` +
      `${LAST_STATE.winReasonName ? '(' + LAST_STATE.winReasonName + ')' : ''}`
    : 'isWin=unknown raw=? local=?';
  log(`hb acted=${S.acted} seq=${S.since} curMsg=${S.lastCurMsg} awaiting=${S.lastAwaiting} win=${winText}` +
    ` stale=${S.skippedStale} actErr=${S.actErrors} esc=${S.escalations} stalls=${S.stalls} hb=${S.heartbeats}` +
    // trap counters are repeated here on purpose: a killed bot (Stop-Process on Windows) never
    // prints the final `stats` line, so the last heartbeat is the only survivable evidence.
    ` trapsSet=${S.trapsSet} trapsAct=${S.trapsActivated} chains=${S.chainsTaken}/${S.chainsDeclined}` +
    ` autos=${S.autos} autoBlocked=${S.autoBlocked}` +
    ` up=${uptime()}s${stateForHb ? ' ' + stateSummaryShort(stateForHb) : ''}`);
}
function stateSummaryShort(st) {
  const c = st.counts || {};
  // lp[0] is the LOCAL player's LP (client exposes lpOrder:"local"), lp[1] is the opponent's
  return `turn=${st.turn} phase=${st.phaseName || st.phase} lp=${(st.lp || []).join('/')}` +
    `${st.lpOrder ? '(lpOrder=' + st.lpOrder + ')' : ''}` +
    ` hand=${c.hand ? c.hand.join('/') : '?'} win=${st.winPlayer}/${st.winReason}`;
}

// ---------------------------------------------------------------- no-progress hard guard
// Progress is measured on the duel state itself, not on the prompt seq: in the ranked-game spin the
// client kept accepting answers while turn/LP/counts/phase never changed (43 answers, zero progress).
// If MAX_IDLE_ACTIONS consecutive answer attempts leave the state signature untouched -> STALL HARD.
const IDLE = { sig: null, count: 0 };
const AWAIT = { seq: null, count: 0 };

/** compact "did anything actually happen" signature from /state */
function sigOf(st) {
  if (!st) return 'null';
  const c = st.counts || {};
  const pair = (x) => (Array.isArray(x) ? x.join('/') : '?');
  const mon = Array.isArray(st.monsters) ? `${(st.monsters[0] || []).length}/${(st.monsters[1] || []).length}` : '?';
  return `t=${st.turn}|p=${st.phase}|lp=${pair(st.lp)}|hand=${pair(c.hand)}|deck=${pair(c.deck)}` +
    `|grave=${pair(c.grave)}|mon=${mon}|chain=${st.chainDepth ?? '?'}|win=${st.winPlayer ?? '?'}|msg=${st.curMsg}`;
}

function hardStall(reason, sig, extra = '') {
  // GAME-OVER WINS OVER THE STALL GUARD: after MSG_WIN the client stops issuing prompts, which looks
  // exactly like "no progress". Never report STALL HARD / exit 2 for a finished duel.
  if (isGameOver(LAST_STATE)) {
    log(`stall-guard skipped: duel already over (${reason})`);
    gameOver(LAST_STATE, 'state-read-by-stall-guard');
    return;
  }
  S.stalls++;
  log(`STALL HARD reason=${reason} seq=${S.since} turn=${globalThis.__turn} idle=${IDLE.count}/${CFG.maxIdleActions}` +
    ` autos=${S.autos} autoBlocked=${S.autoBlocked} acted=${S.acted} esc=${S.escalations} state=${sig}${extra ? ' ' + extra : ''}`);
  printStats('stall-hard');
  // let stdout flush before the supervisor sees exit code 2
  setTimeout(() => process.exit(2), 50);
}

/** call after every answer attempt: trips when the state signature did not change N times in a row */
function noteSig(st, reason) {
  const sig = sigOf(st);
  if (IDLE.sig === sig) IDLE.count++;
  else { IDLE.sig = sig; IDLE.count = 1; }
  if (IDLE.count >= CFG.maxIdleActions) hardStall(reason, sig);
  return IDLE.count;
}

/** awaiting prompt that never receives a new seq (poll loop) - separate bounded counter */
function bumpAwaiting(seq, turn, reason) {
  if (AWAIT.seq === seq) AWAIT.count++;
  else { AWAIT.seq = seq; AWAIT.count = 1; }
  if (AWAIT.count >= CFG.maxIdleActions) {
    hardStall(reason, `awaiting seq=${seq} turn=${turn}`, `wait=${AWAIT.count}`);
  }
  return AWAIT.count;
}

// ---------------------------------------------------------------- main loop
process.on('SIGINT', () => { printStats('sigint'); process.exit(0); });
process.on('SIGTERM', () => { printStats('sigterm'); process.exit(0); });

(async () => {
  let since = 0;
  S.lastSeqAt = Date.now();
  let emptyStreak = 0;
  let httpErrStreak = 0;

  log(`start base=${CFG.base} maxMin=${CFG.maxMin} stall=${CFG.stallMs}ms hb=${CFG.hbMs}ms` +
    ` wait=${CFG.waitMs}ms emptyLimit=${CFG.emptyLimit} actRetries=${CFG.actRetries}`);

  while (Date.now() - T0 < CFG.maxMin * 60000) {
    S.loops++;
    try {
      // ---- 1. state (also feeds the attack gate + finish detection)
      const st = await req('/state');
      if (!st) {
        httpErrStreak++;
        S.httpErrors++;
        if (httpErrStreak === 5) {
          log(`http-err consecutive=${httpErrStreak} /state unreachable (control API dead? client closed?)`);
          await diagnose('HTTP', { stage: '/state', streak: httpErrStreak });
        }
        heartbeatIfDue(null);
        await jitter(400, 900);
        continue;
      }
      if (httpErrStreak >= 5) log(`http-recover after ${httpErrStreak} failures`);
      httpErrStreak = 0;
      globalThis.__myMon = ((st.monsters && st.monsters[st.myPlayer || 0]) || []).length;
      globalThis.__turn = typeof st.turn === 'number' ? st.turn : globalThis.__turn;   // SET_PER_TURN reset key
      {
        const myField = (st.monsters && st.monsters[st.myPlayer || 0]) || [];
        globalThis.__myField = myField;
        globalThis.__tunerOnField = myField.some((c) => ((c.ty || 0) & 0x1000) !== 0);
        globalThis.__fieldLevels = myField.map((c) => c.lv || c.level || 0).filter((n) => n > 0);
        const hasSyn = myField.some((c) => ((c.ty || 0) & 0x2000) !== 0);
        const hasXyz = myField.some((c) => ((c.ty || 0) & 0x800000) !== 0);
        if (hasSyn && !MISSION.synchro) { MISSION.synchro = true; log(`MISSION synchro DONE (field type 0x2000) -> ${missionText()}`); }
        if (hasXyz && !MISSION.xyz) { MISSION.xyz = true; log(`MISSION xyz DONE (field type 0x800000) -> ${missionText()}`); }
      }
      S.lastCurMsg = st.curMsg;
      S.lastAwaiting = st.awaiting;
      LAST_STATE = st;

      // ---- 1a. GAME OVER takes priority over every guard: the duel is finished, nothing to answer.
      //     (After MSG_WIN the client stops producing prompts; without this check the no-progress
      //     guard would print STALL HARD and exit 2 at the end of a perfectly normal game.)
      if (isGameOver(st)) {
        gameOver(st, 'state');
        return;
      }

      // ---- 2. heartbeat (bounded so a 15s long-poll cannot starve it)
      heartbeatIfDue(st);
      const hbBudget = Math.max(1000, Math.min(CFG.waitMs, nextHbIn || CFG.waitMs));

      // ---- 3. long-poll for a new prompt
      const wp = await getJson(`/wait_prompt?since=${since}&timeout_ms=${hbBudget}`, hbBudget + 5000);
      const p = wp.data;
      if (wp.error) {
        httpErrStreak++;
        S.httpErrors++;
        if (httpErrStreak === 5) log(`http-err consecutive=${httpErrStreak} /wait_prompt failed: ${wp.error}`);
        await diagnose('HTTP', { error: wp.error });
        await jitter(500, 1000);
        continue;
      }
      if (!p || typeof p.seq !== 'number') { await jitter(); continue; }
      LAST_PROMPT = p;                     // chain semantics for choose()/decideChain()
      S.lastCurMsg = typeof p.curMsg === 'number' ? p.curMsg : S.lastCurMsg;
      S.lastAwaiting = !!p.awaiting;

      if (p.seq <= since) {
        // no new prompt in this poll window -> check whether we are stuck
        // hard guard: an *awaiting* prompt that never gets a new seq means our answers are not
        // moving the duel (the ranked-game spin had exactly this shape) -> count it as no progress.
        if (p.awaiting) {
          const n = bumpAwaiting(p.seq, Number(globalThis.__turn), 'no-progress-awaiting');
          if (n >= 2) log(`no-progress awaiting seq=${p.seq} turn=${globalThis.__turn} idle=${n}/${CFG.maxIdleActions}`);
        } else {
          AWAIT.count = 0;          // nothing to answer: normal wait (opponent thinking etc.)
        }
        if (Date.now() - S.lastSeqAt >= CFG.stallMs) {
          const st2 = await diagnose('STALL', { waitedMs: Date.now() - S.lastSeqAt, emptyStreak });
          S.lastSeqAt = Date.now();      // re-arm so we report about every stallMs, not every loop
          // the duel may have ended while we were polling: that is not a stall
          if (st2 && (st2.curMsg === 5 || st2.winPlayer >= 0)) { finishFromState(st2); return; }
        }
        await jitter();
        continue;
      }

      // ---- 4. new seq. Record it, then verify the action list still belongs to it.
      const seqBefore = p.seq;
      const prevSince = since;
      since = p.seq;
      S.since = since;
      S.lastSeqAt = Date.now();
      S.lastAwaiting = !!p.awaiting;
      // NOTE: a new seq is NOT progress by itself (the ranked spin kept issuing seqs while the duel
      // state never changed) - progress is measured by noteSig() on /state below.

      // a seq bump with awaiting=false means somebody already answered that prompt
      // (another bot on the same control port, or a human click in the client window)
      if (!p.awaiting) {
        S.skippedStale++;
        log(`seq advanced but awaiting=false seq=${seqBefore} (prev ${prevSince}) curMsg=${p.curMsg} -> already answered elsewhere`);
        await jitter();
        continue;
      }

      await jitter();

      const actsResp = (await req('/actions')) || { actions: [], seq: -1 };
      S.lastAwaiting = actsResp.awaiting === undefined ? S.lastAwaiting : !!actsResp.awaiting;
      // SAFETY (double insurance with the client-side fix): only act on an /actions result that
      // explicitly says awaiting==true. A not-awaiting result means nothing is waiting for us and any
      // response we send would be a blind/extra one (this is what used to spin `auto` answers).
      if (actsResp.awaiting === false) {
        S.notAwaitingSkips = (S.notAwaitingSkips || 0) + 1;
        if (S.notAwaitingSkips <= 3 || S.notAwaitingSkips % 20 === 0) {
          log(`skip /actions awaiting=false seq=${p.seq} curMsg=${p.curMsg} reason=${JSON.stringify(actsResp.reason || '')}` +
            ` (not answering; skips=${S.notAwaitingSkips})`);
        }
        AWAIT.count = 0;
        await jitter();
        continue;
      }
      if (actsResp.seq !== p.seq) {
        S.skippedStale++;
        log(`skip stale prompt seq=${p.seq} now=${actsResp.seq} curMsg=${p.curMsg}`);
        continue;
      }
      const list = actsResp.actions || [];
      if (!list.length) {
        emptyStreak++;
        S.lastAwaiting = !!actsResp.awaiting;
        // throttle: first of a burst + every emptyLimit-th, so a hot loop cannot flood the log
        if (emptyStreak === 1 || emptyStreak >= CFG.emptyLimit) {
          log(`empty actions seq=${p.seq} curMsg=${p.curMsg} awaiting=${actsResp.awaiting}` +
            ` streak=${emptyStreak}/${CFG.emptyLimit} (client says awaiting but built no actions)`);
        }
        if (emptyStreak >= CFG.emptyLimit) {
          await diagnose('EMPTY', { seq: p.seq, curMsg: p.curMsg, streak: emptyStreak });
          emptyStreak = 0;
        }
        await jitter();
        continue;
      }
      emptyStreak = 0;

      // ---- 5. decide + act (with one retry when /act_id refuses)
      // repeated-prompt guard: the same curMsg coming back means our last answer did not stick
      // (typically MSG_RETRY). After ESCALATE_AFTER repeats we stop repeating ourselves.
      const repeatCount = trackPrompt(p.curMsg);
      if (repeatCount === CFG.escalateAfter) {
        log(`same prompt again msg=${p.curMsg} count=${repeatCount} -> enabling escalation`);
      }
      const pick = pickAction(list, p.curMsg);
      if (!pick) { await jitter(); continue; }

      // ---- 5a. SAFETY: `auto` (generic safe default) may only answer known informational msgs.
      // An `auto`-only candidate list on any other msg means the client could not model a real
      // prompt; answering it blindly is what produced 43 useless responses in a ranked game.
      const curTurn = Number(globalThis.__turn);
      if (pick.kind === 'auto') {
        if (!AUTO_SAFE_MSGS.has(Number(p.curMsg))) {
          S.autoBlocked++;
          const n = noteSig(st, 'auto-not-allowed');
          log(`auto-blocked msg=${p.curMsg} seq=${p.seq} turn=${curTurn} idle=${n}/${CFG.maxIdleActions}` +
            ` (unknown msg with only auto -> refusing to answer)`);
          await jitter();
          continue;
        }
        S.autos++;
        log(`auto-use #${S.autos} msg=${p.curMsg} seq=${p.seq} turn=${curTurn} (whitelisted informational msg)`);
      }
      noteActionStats(pick);            // trapsActivated / chainsTaken / chainsDeclined

      let r = await req(`/act_id?id=${pick.id}`);
      if (!r || !r.ok) {
        S.actErrors++;
        log(`act rejected seq=${seqBefore} ${pick.kind} "${pick.label}" -> ${JSON.stringify(r)}` +
          ` [actions=${list.length} curMsg=${p.curMsg} awaiting=${S.lastAwaiting}]`);
        // one retry: re-read /actions (ids may have been rebuilt) and act on the fresh list
        for (let attempt = 1; attempt <= CFG.actRetries; attempt++) {
          S.actRetries++;
          await jitter(150, 350);
          const again = (await req('/actions')) || { actions: [], seq: -1 };
          if (again.seq !== since) {
            log(`act-retry#${attempt} aborted: seq moved ${since} -> ${again.seq}`);
            break;
          }
          const list2 = again.actions || [];
          if (!list2.length) { log(`act-retry#${attempt} aborted: actions empty`); break; }
          // on a retry prefer a DIFFERENT answer than the one that was just rejected
          const pick2 = pickAction(list2, p.curMsg);
          if (!pick2) { log(`act-retry#${attempt} aborted: no pick`); break; }
          const r2 = await req(`/act_id?id=${pick2.id}`);
          if (r2 && r2.ok) {
            r = r2;
            noteActionStats(pick2);
            S.acted++;
            S.recent.push({ seq: since, kind: pick2.kind, label: pick2.label });
            if (S.recent.length > 3) S.recent.shift();
            log(`act-retry#${attempt} ok`);
            break;
          }
          log(`act-retry#${attempt} failed -> ${JSON.stringify(r2)}`);
        }
        if (!r || !r.ok) {
          await jitter();
          continue;
        }
      } else {
        S.acted++;
        S.recent.push({ seq: since, kind: pick.kind, label: pick.label });
        if (S.recent.length > 3) S.recent.shift();
      }

      // ---- 6. seq before/after, so the log shows whether the action actually moved the duel
      const after = await req('/state');
      const seqAfter = after && typeof after.seq === 'number' ? after.seq : '?';
      if (after) {
        S.lastCurMsg = after.curMsg;
        S.lastAwaiting = after.awaiting;
      }
      const idleNow = noteSig(after || st, 'no-progress');
      log(`#${S.acted} seq=${seqBefore}->${seqAfter} msg=${p.curMsg} -> ${pick.kind} "${pick.label}" ok` +
        ` awaitingNow=${S.lastAwaiting} acted=${S.acted} idle=${idleNow}/${CFG.maxIdleActions} autos=${S.autos}`);
    } catch (e) {
      // never die on a single bad iteration: log and keep going
      S.httpErrors++;
      log(`loop-error ${String(e && e.message || e)}`);
      await jitter(500, 1200);
    }
  }

  log(`max-minutes reached (${CFG.maxMin}min)`);
  printStats('max-minutes');
})();
