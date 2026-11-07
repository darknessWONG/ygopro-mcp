#!/usr/bin/env node
// bridge/supervisor.mjs — 常驻 supervisor：检测掉线 → 按 profile 处理（lan 只记账，ranked 完整重连）
//
// 设计依据：bridge/docs/RECONNECT-DESIGN.md（§2 职责、§3.2 状态机）
// 客户端契约：GET /net  {connected,connectState,closeReason,joined,inDuel,turn,lastStocAt,
//                        sinceLastStoc,alive,probe:{lastSentAt,lastReplyAt,rttMs,fails,lastReplyPlayerType}}
//             POST /leave, POST /reconnect（可选，优先用 join+ready 组合）, GET /join?ip&port&pass,
//             GET /ready, GET /state, GET /health
//
// 用法：
//   node bridge/supervisor.mjs --profile ranked --port 7788 \
//        --client "mycard-client/bin/release/x64/YGOPro.exe" --game-dir "mycard-bot/game" \
//        --join-ip 127.0.0.1 --join-port 7911 --nick GuestB --deck Blackwing \
//        --policy "node bridge/policy-semantic.mjs"
//   node bridge/supervisor.mjs --profile lan --port 7789
//   node bridge/supervisor.mjs --profile lan --lan-restart-game --port 7789 \
//        --client ... --game-dir ... --policy "node bridge/policy-semantic.mjs"
//   node bridge/supervisor.mjs --mock            # 无客户端自测（5 个场景）
//
// 不启动任何客户端，除非 ranked 重连 / lan --lan-restart-game 需要重启它。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

// ------------------------------------------------------------------ args
function parseArgs(argv) {
  const o = {
    profile: 'ranked',
    port: 7788,
    host: 'http://127.0.0.1',
    intervalMs: 1000,
    maxRetries: 5,
    backoff: [1000, 2000, 4000, 8000, 15000],
    verifyTimeoutMs: 30000,
    startTimeoutMs: 30000,
    heartbeatMs: 30000,
    jsonl: '',
    mock: false,
    mockVerbose: false,
    lanRestartGame: false,
    client: '',
    clientStart: '',
    clientKill: '',
    gameDir: '',
    policy: '',
    joinIp: '127.0.0.1',
    joinPort: 7911,
    joinPass: '',
    lastRoom: '',
    clientJoinMode: 'http', // http = 不带 -j，由 supervisor GET /join；cmdline = 带 -j，不再 HTTP join
    portReleaseTimeoutMs: 5000,
    nick: 'GuestB',
    deck: 'Blackwing',
    leave: true,
    netFallbackHealthStreak: 2,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const need = () => { if (i + 1 >= argv.length) throw new Error('missing value for ' + a); return argv[++i]; };
    switch (a) {
      case '--profile': o.profile = need(); break;
      case '--port': o.port = Number(need()); break;
      case '--host': o.host = need(); break;
      case '--interval': o.intervalMs = Number(need()); break;
      case '--max-retries': o.maxRetries = Number(need()); break;
      case '--backoff': o.backoff = need().split(',').map(Number); break;
      case '--verify-timeout': o.verifyTimeoutMs = Number(need()); break;
      case '--start-timeout': o.startTimeoutMs = Number(need()); break;
      case '--heartbeat': o.heartbeatMs = Number(need()); break;
      case '--jsonl': o.jsonl = need(); break;
      case '--mock': o.mock = true; break;
      case '--mock-verbose': o.mockVerbose = true; break;
      case '--lan-restart-game': o.lanRestartGame = true; break;
      case '--client': o.client = need(); break;
      case '--client-start': o.clientStart = need(); break;
      case '--client-kill': o.clientKill = need(); break;
      case '--game-dir': o.gameDir = need(); break;
      case '--policy': o.policy = need(); break;
      case '--join-ip': o.joinIp = need(); break;
      case '--join-port': o.joinPort = Number(need()); break;
      case '--join-pass': o.joinPass = need(); break;
      case '--last-room': o.lastRoom = need(); break;
      case '--client-cmdline-join': case '--no-http-join': o.clientJoinMode = 'cmdline'; break;
      case '--port-release-timeout': o.portReleaseTimeoutMs = Number(need()); break;
      case '--nick': o.nick = need(); break;
      case '--deck': o.deck = need(); break;
      case '--no-leave': o.leave = false; break;
      case '--help': case '-h': o.help = true; break;
      default: throw new Error('unknown arg: ' + a);
    }
  }
  if (!['lan', 'ranked'].includes(o.profile)) throw new Error('--profile must be lan|ranked');
  if (o.backoff.length === 0) o.backoff = [1000];
  return o;
}

const O = parseArgs(process.argv.slice(2));
if (O.help) {
  console.log(`bridge/supervisor.mjs — reconnect supervisor

--profile ranked|lan      ranked=完整重连（默认），lan=只检测+记账+收尾（不重连）
--port N                  客户端控制端口（默认 7788）
--interval N              监控循环间隔 ms（默认 1000）
--max-retries N           ranked 最大重连次数（默认 5）
--backoff "1,2,4,8,15"    退避序列 ms（默认 1000,2000,4000,8000,15000）
--client <exe>            客户端可执行文件（ranked 重连时重启用）
--game-dir <dir>          客户端工作目录（默认 = exe 所在目录）
--client-start "<cmd>"    自定义启动命令（优先于 --client）
--client-kill "<cmd>"     自定义 kill 命令（默认先杀自己 spawn 的 pid，再按路径过滤 mycard-client）
--client-cmdline-join     用命令行 -j 加入（默认 http：不带 -j，由 supervisor GET /join）
--join-ip/--join-port/--join-pass  房间参数（优先级：/net.room → --last-room → 这三个）
--last-room <file>        房间参数文件（JSON：{addr,port,pass} 或 {joinIp,joinPort,joinPass}）
--port-release-timeout N  等端口释放的超时 ms（默认 5000）
--nick/--deck             重启客户端用的昵称/卡组（默认 GuestB / Blackwing）
--policy "<cmd>"          策略进程命令（DUELING 时拉起）
--lan-restart-game        lan profile 下掉线后以“新局”重启（日志 new-game (NOT resume)）
--no-leave                不调 POST /leave
--jsonl <file>            JSONL 记账（默认 ranked/logs/supervisor.jsonl）
--mock                    无客户端自测（6 场景，退出码 0=全过）
--mock-verbose            打印 mock 细节
--help                    显示本帮助
`);
  process.exit(0);
}

const SELF_DIR = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const ROOT = path.resolve(SELF_DIR, '..'); // bridge/supervisor.mjs -> repo root
const JSONL = O.jsonl || path.join(ROOT, 'ranked', 'logs', 'supervisor.jsonl');

// ------------------------------------------------------------------ small utils
const now = () => Date.now();
const iso = () => new Date().toISOString();
const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
function ensureDir(p) { try { fs.mkdirSync(p, { recursive: true }); } catch {} }

function logJsonl(obj) {
  if (O.mock && !O.jsonl) return; // mock 默认不落盘
  ensureDir(path.dirname(JSONL));
  try { fs.appendFileSync(JSONL, JSON.stringify(obj) + '\n'); } catch (e) { console.error('[supervisor] jsonl write failed: ' + e.message); }
}

function fmtNet(n) {
  if (!n) return 'net=unavailable';
  const p = n.probe || {};
  return `net alive=${n.alive} connected=${n.connected} inDuel=${n.inDuel} turn=${n.turn} sinceLastStoc=${n.sinceLastStoc}ms probe(fails=${p.fails ?? '-'},rtt=${p.rttMs ?? '-'}ms)`;
}

// ------------------------------------------------------------------ real client (HTTP + child processes)
class RealClient {
  constructor(o) { this.o = o; this.policyChild = null; this.clientChild = null; this._netMissingLogged = false; }
  base() { return `${this.o.host}:${this.o.port}`; }

  async http(pathname, opts = {}) {
    const url = this.base() + pathname;
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), opts.timeoutMs || 3000);
    try {
      const r = await fetch(url, { method: opts.method || 'GET', signal: ac.signal });
      const text = await r.text();
      let json = null;
      try { json = JSON.parse(text); } catch {}
      return { ok: r.ok, status: r.status, json, text };
    } catch (e) {
      return { ok: false, status: 0, error: e.name === 'AbortError' ? 'timeout' : String(e.message || e) };
    } finally { clearTimeout(t); }
  }

  async getNet() {
    const r = await this.http('/net', { timeoutMs: 2500 });
    if (!r.ok || !r.json) {
      if (!this._netMissingLogged) { this._netMissingLogged = true; console.error('[supervisor] /net unavailable (client build without /net?), falling back to /health + /state'); }
      return { ok: false, reason: r.error || ('status ' + r.status) };
    }
    return { ok: true, data: r.json };
  }
  async getState() { const r = await this.http('/state'); return r.ok ? r.json : null; }
  async getHealth() { const r = await this.http('/health'); return r.ok ? r.json : null; }
  async leave() { if (!this.o.leave) return { ok: true, skipped: true }; const r = await this.http('/leave', { method: 'POST' }); return { ok: r.ok, status: r.status }; }
  // spec：GET /join?ip=&port=&pass=（房间参数优先 /net.room → --last-room → CLI）
  async join(room) {
    const r0 = room || { addr: this.o.joinIp, port: this.o.joinPort, pass: this.o.joinPass };
    const q = new URLSearchParams({ ip: r0.addr, port: String(r0.port), pass: r0.pass || '' });
    const r = await this.http('/join?' + q.toString(), { method: 'GET', timeoutMs: 5000 });
    return { ok: r.ok, status: r.status };
  }
  async ready() { const r = await this.http('/ready', { method: 'POST' }); return { ok: r.ok, status: r.status }; }

  hasChildExited() {
    if (!this.clientChild) return null;
    if (this.clientChild.exitCode !== null && this.clientChild.exitCode !== undefined) return { code: this.clientChild.exitCode, at: this._clientExit ? this._clientExit.at : iso() };
    return this._clientExit || null;
  }

  // 等端口释放（旧客户端完全退出/端口不再 LISTEN），最多 ms 毫秒
  async waitPortFree(port, ms = 5000) {
    const deadline = now() + ms;
    while (now() < deadline) {
      const h = await this.http('/health', { timeoutMs: 600 });
      if (!h.ok) return true; // 控制端口已不可达 = 已释放
      await sleep(300);
    }
    return false;
  }

  async killClient() {
    // 精度：先杀自己 spawn 的 pid；再退回路径过滤（只 mycard-client 目录）
    const killed = [];
    if (this.clientChild && this.clientChild.pid) {
      try { process.kill(this.clientChild.pid); killed.push(this.clientChild.pid); } catch {}
    }
    if (this.o.clientKill) {
      const r = await this._runShell(this.o.clientKill, 'client-kill');
      return { ok: r.ok, killed, output: r.output };
    }
    const ps = 'Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like \'*mycard-client*\' } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; "killed pid=$($_.Id)" } catch {} }';
    const r = await this._runProc('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps], 'client-kill');
    r.killed = killed;
    if (r.output) console.log('[supervisor] ' + r.output.split(/\r?\n/).join(' | '));
    return r;
  }

  async startClient(room) {
    if (this.o.clientStart) return this._runShell(this.o.clientStart, 'client-start', true);
    if (!this.o.client) return { ok: false, reason: 'no --client / --client-start' };
    const r0 = room || { addr: this.o.joinIp, port: this.o.joinPort };
    const exe = path.resolve(ROOT, this.o.client);
    const cwd = this.o.gameDir ? path.resolve(ROOT, this.o.gameDir) : path.dirname(exe);
    // 二选一：http 模式不带 -j（由 supervisor GET /join 加入）；cmdline 模式带 -j（不再 HTTP join）
    const args = [];
    if (this.o.clientJoinMode === 'cmdline') args.push('-j');
    args.push('-h', r0.addr, '-p', String(r0.port), '-n', this.o.nick, '-d', this.o.deck, '-k');
    const env = { ...process.env, YGO_CONTROL_PORT: String(this.o.port) };
    try {
      this.clientChild = spawn(exe, args, { cwd, env, stdio: 'ignore', detached: false });
      this._clientExit = null;
      this.clientChild.on('exit', (code) => { this._clientExit = { code, at: iso() }; });
      return { ok: true, pid: this.clientChild.pid };
    } catch (e) { return { ok: false, reason: String(e.message || e) }; }
  }

  async waitHealth(timeoutMs) {
    const deadline = now() + timeoutMs;
    while (now() < deadline) {
      const h = await this.getHealth();
      if (h && h.ok) return true;
      await sleep(500);
    }
    return false;
  }

  async startPolicy() {
    if (!this.o.policy || this.policyChild) return { ok: true, skipped: true };
    try {
      this.policyChild = spawn(this.o.policy, { shell: true, cwd: ROOT, stdio: 'ignore' });
      this.policyChild.on('exit', () => { this.policyChild = null; });
      return { ok: true, pid: this.policyChild.pid };
    } catch (e) { return { ok: false, reason: String(e.message || e) }; }
  }
  stopPolicy() { if (!this.policyChild) return; try { this.policyChild.kill(); } catch {} this.policyChild = null; }

  async _runShell(cmd, tag, allowFail = false) { return this._runProc(process.platform === 'win32' ? 'cmd' : 'sh', process.platform === 'win32' ? ['/c', cmd] : ['-c', cmd], tag, allowFail); }
  _runProc(file, args, tag, allowFail = false) {
    return new Promise((resolve) => {
      let out = '';
      let p;
      try { p = spawn(file, args, { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] }); }
      catch (e) { return resolve({ ok: false, reason: tag + ': ' + (e.message || e) }); }
      p.stdout.on('data', (d) => { out += d.toString(); });
      p.stderr.on('data', (d) => { out += d.toString(); });
      p.on('exit', (code) => {
        if (O.mockVerbose) console.error(`[${tag}] exit=${code} ${out.trim()}`);
        resolve({ ok: code === 0 || allowFail, code, output: out.trim() });
      });
      p.on('error', (e) => resolve({ ok: false, reason: tag + ': ' + (e.message || e) }));
    });
  }
}

// ------------------------------------------------------------------ mock client (no network / no processes)
class MockClient {
  constructor(cfg) {
    this.cfg = cfg || {};           // {net:[...], state:[...]}
    this.netCalls = 0;
    this.stateCalls = 0;
    this.calls = [];
    this.killed = false;
    this.started = 0;
    this.policyRuns = 0;
  }
  base() { return 'mock://' + O.port; }
  _call(name, extra) { this.calls.push({ name, tick: this.netCalls, ...extra }); }
  _pick(seq, n) { return seq[Math.min(n, seq.length - 1)]; }
  async getNet() {
    if (this.cfg.noNet) { this.netCalls++; return { ok: false, reason: 'mock /net 404' }; }
    const seq = this.cfg.net || [{ alive: true, connected: true, inDuel: true, turn: 3, sinceLastStoc: 200 }];
    const item = this._pick(seq, this.netCalls++);
    if (item && item.__down) return { ok: false, reason: 'mock down' };
    if (item && item.__gone) return { ok: true, data: item };
    return { ok: true, data: item };
  }
  async getState() {
    if (this.cfg.getState) return this.cfg.getState(this.stateCalls++);
    const seq = this.cfg.state || [{ started: true, inDuel: true, turn: 3, lp: [8000, 8000] }];
    return { ...this._pick(seq, this.stateCalls++) };
  }
  async getHealth() { this._call('health'); return { ok: this.cfg.noNet ? this._healthSeq() : !this.killed }; }
  _healthSeq() {
    const seq = this.cfg.health || [true, true, true, true];
    return seq[Math.min(this.netCalls, seq.length - 1)];
  }
  async leave() { this._call('leave'); return { ok: true }; }
  async join(room) { this._call('join', room ? { room } : {}); return { ok: true }; }
  async ready() { this._call('ready'); return { ok: true }; }
  async killClient() { this._call('kill'); this.killed = true; return { ok: true, killed: [1] }; }
  async startClient(room) { this._call('start', room ? { room } : {}); this.killed = false; this.started++; return { ok: true, pid: 1000 + this.started }; }
  async waitHealth() { return true; }
  async waitPortFree() { this._call('wait-port-free'); return true; }
  hasChildExited() { return null; }
  async startPolicy() { this._call('policy'); this.policyRuns++; return { ok: true }; }
  stopPolicy() {}
  getStateCalls() { return this.calls; }
}

// ------------------------------------------------------------------ supervisor FSM
class Supervisor {
  constructor(client, opts) {
    this.c = client;
    this.o = opts;
    this.state = 'IDLE';
    this.tick = 0;
    this.deadStreak = 0;
    this.healthFailStreak = 0;
    this.attempt = 0;
    this.events = [];
    this.stats = { detections: 0, reconnectAttempts: 0, reconnectOk: 0, reconnectFail: 0, newGames: 0, falseAlarms: 0, lastGapMs: 0, totalGapMs: 0, avgGapMs: 0, startTs: now() };
    this.lastHeartbeat = now();
    this.pre = null;
    this.running = true;
    this.result = null;
    this.room = null;
    this.duelResultDone = false;   // 当前对局是否已记录过 duel_result
    this._lastStateCheck = 0;
  }

  // 对局结果记录：raw winPlayer 是座位号（不代表"我们赢"），必须用 isWin/isLoss 或 winPlayerLocal
  // 判断；未知时 JSONL 留 null 并在 reason 标注，绝不猜 false。
  _maybeRecordResult(st) {
    if (!st) return;
    const winRaw = Number(st.winPlayer);
    const hasWin = (typeof st.isWin === 'boolean') || (typeof st.isLoss === 'boolean')
      || Number.isFinite(Number(st.winPlayerLocal)) || (Number.isFinite(winRaw) && winRaw >= 0);
    if (!hasWin) { this.duelResultDone = false; return; }
    if (this.duelResultDone) return;
    this.duelResultDone = true;
    let isWin = null;
    if (typeof st.isWin === 'boolean') isWin = st.isWin;
    else if (typeof st.isLoss === 'boolean') isWin = !st.isLoss;
    else if (Number.isFinite(Number(st.winPlayerLocal))) isWin = Number(st.winPlayerLocal) === 0;
    const isDraw = st.isDraw === true || Number(st.winPlayerLocal) === -1 || winRaw === 2;
    // 平局 ≠ 输：isDraw 为权威字段，isWin 置 null（ok=false），避免把 draw 记成 loss
    if (isDraw) isWin = null;
    const reason = (st.winReasonName && st.winReasonName !== 'UNKNOWN') ? String(st.winReasonName) : null;
    const resultText = isDraw ? 'draw' : (isWin === true ? 'win' : (isWin === false ? 'loss' : 'unknown'));
    this.emit('duel_result', {
      ok: isWin === true,
      isWin,
      isLoss: isWin === false,
      isDraw,
      result: resultText,
      winPlayer: Number.isFinite(winRaw) ? winRaw : null,
      winPlayerLocal: Number.isFinite(Number(st.winPlayerLocal)) ? Number(st.winPlayerLocal) : null,
      winReason: Number.isFinite(Number(st.winReason)) ? Number(st.winReason) : null,
      winReasonName: reason,
      turn: typeof st.turn === 'number' ? st.turn : null,
      reason: isDraw ? (reason || 'draw') : (reason || (isWin === null ? 'isWin unknown (no isWin/winPlayerLocal in /state)' : null)),
    });
  }

  emit(event, extra = {}) {
    const e = {
      ts: iso(), event, profile: this.o.profile, state: this.state,
      attempt: this.attempt,
      preTurn: null, nowTurn: null, gapMs: null, ok: null, reason: null,
      ...extra,
    };
    // 规范字段不允许出现 undefined（否则 JSON.stringify 会丢 key）
    for (const k of ['preTurn', 'nowTurn', 'gapMs', 'ok', 'reason']) if (e[k] === undefined) e[k] = null;
    this.events.push(e);
    logJsonl(e);
    const net = extra.net ? ' ' + fmtNet(extra.net) : '';
    const line = `[supervisor] ${event}${extra.reason ? ' reason=' + extra.reason : ''}${extra.ok !== undefined && extra.ok !== null ? ' ok=' + extra.ok : ''}${net}`;
    console.log(line);
    if (O.mockVerbose) console.log('    ' + JSON.stringify(e));
  }

  async _snapshot() {
    const st = await this.c.getState();
    return {
      turn: st && typeof st.turn === 'number' ? st.turn : 0,
      lp: st && Array.isArray(st.lp) ? st.lp : [0, 0],
      chainDepth: st && typeof st.chainDepth === 'number' ? st.chainDepth : 0,
      ts: now(),
    };
  }

  async poll() {
    this.tick++;
    const t0 = now();
    const netRes = await this.c.getNet();
    let net = null;
    let alive = null;
    let dead = false;
    let reason = '';
    if (netRes.ok) {
      net = netRes.data;
      alive = net.alive !== false;
      if (net.alive === false) this.deadStreak++; else this.deadStreak = 0;
      const since = typeof net.sinceLastStoc === 'number' ? net.sinceLastStoc : -1;
      const stateName = typeof net.state === 'string' ? net.state : '';
      // 硬判死：客户端已明确 confirmed_dead / 已进入 disconnected 状态 / connected=false
      // （实测 drop 后 alive 仍是 true，但 state=disconnected, closeReason=eof）
      if (stateName === 'confirmed_dead' || stateName === 'disconnected' || net.connected === false) {
        dead = true; reason = 'net.state=' + (stateName || 'unknown') + (net.closeReason && net.closeReason !== 'none' ? ' closeReason=' + net.closeReason : '');
      } else if (this.deadStreak >= 2) { dead = true; reason = 'alive=false x' + this.deadStreak; }
      else if (net.inDuel && since > 15000) { dead = true; reason = 'sinceLastStoc=' + since + 'ms'; }
    } else {
      // 客户端还没有 /net（task-28 未落地）或客户端已死：退化到 /health
      const h = await this.c.getHealth();
      if (h && h.ok) { this.healthFailStreak = 0; alive = null; }
      else { this.healthFailStreak++; this.deadStreak++; if (this.deadStreak >= (this.o.netFallbackHealthStreak ?? 2)) { dead = true; reason = 'health unavailable x' + this.deadStreak; } }
    }

    // 客户端进程退出同样算判死（spec：alive=false 或 sinceLastStoc>15000 或 进程退出）
    const exited = this.c.hasChildExited ? this.c.hasChildExited() : null;
    if (!dead && exited) { dead = true; reason = 'client-process-exit' + (exited.code !== undefined ? ' code=' + exited.code : ''); }

    // heartbeat
    if (now() - this.lastHeartbeat >= this.o.heartbeatMs) {
      this.lastHeartbeat = now();
      const st = await this.c.getState();
      console.log(`[supervisor] hb state=${this.state} ${fmtNet(net)} turn=${st && st.turn} lp=${st && st.lp} reconnects=${this.stats.reconnectOk}/${this.stats.reconnectAttempts} uptime=${Math.round((now() - this.stats.startTs) / 1000)}s`);
    }

    // 对局结果（每 2s 检查一次；用 isWin/isLoss/winPlayerLocal，不用 raw winPlayer 猜输赢）
    if (!O.mock && this.state !== 'RESULT' && now() - this._lastStateCheck >= 2000) {
      this._lastStateCheck = now();
      try { this._maybeRecordResult(await this.c.getState()); } catch (e) { /* ignore */ }
    }

    if (dead) {
      this.stats.detections++;
      this.emit('dead_detected', { reason, net });
      if (this.o.profile === 'lan') { await this.lanFlow(reason); return 'RESULT'; }
      const ok = await this.reconnectFlow(reason);
      return ok ? 'DUELING' : 'RESULT';
    }

    // 误报自愈：进入 QUEUED/soft-failed 后又恢复 alive → 记 falseAlarms，回到 DUELING
    if (!dead && (this.state === 'QUEUED' || this.state === 'PROBE_FAILED')) {
      this.stats.falseAlarms++;
      this.state = 'DUELING';
      this.emit('false_alarm', { reason: 'recovered before retry', net });
      return this.state;
    }

    if (this.state === 'IDLE' && (netRes.ok ? alive !== false : alive === null && this.healthFailStreak === 0)) { this.state = 'READY'; this.emit('state_ready', { net }); }
    else if (this.state === 'READY') {
      const inDuel = net ? !!net.inDuel : !!(await this.c.getState())?.inDuel;
      if (inDuel) { this.state = 'DUELING'; await this.c.startPolicy(); this.emit('state_dueling', { net }); }
    }
    return this.state;
  }

  // 房间参数优先级：/net.room → --last-room 文件 → --join-* CLI
  async resolveRoom() {
    if (this.room) return this.room;
    let room = null;
    let src = '';
    try {
      const n = await this.c.getNet();
      const r = n && n.ok && n.data && n.data.room;
      if (r && (r.addr || r.ip) && r.port) { room = { addr: r.addr || r.ip, port: Number(r.port), pass: r.pass || '' }; src = 'net.room'; }
    } catch {}
    if (!room && this.o.lastRoom) {
      try {
        const f = path.isAbsolute(this.o.lastRoom) ? this.o.lastRoom : path.resolve(ROOT, this.o.lastRoom);
        const j = JSON.parse(fs.readFileSync(f, 'utf8'));
        const addr = j.addr || j.joinIp || j.ip; const port = j.port || j.joinPort; const pass = j.pass || j.joinPass || '';
        if (addr && port) { room = { addr, port: Number(port), pass }; src = 'last-room:' + path.basename(f); }
      } catch (e) { console.error('[supervisor] --last-room read failed: ' + (e && e.message || e)); }
    }
    if (!room) { room = { addr: this.o.joinIp, port: this.o.joinPort, pass: this.o.joinPass }; src = 'cli'; }
    this.room = room;
    this.emit('room_resolved', { room: { addr: room.addr, port: room.port, pass: room.pass ? '***' : '' }, source: src });
    return room;
  }

  async _backoff(attempt) {
    const b = this.o.backoff[Math.min(attempt - 1, this.o.backoff.length - 1)] || 1000;
    this.emit('backoff', { attempt, waitMs: b });
    if (!O.mock) await sleep(b);
  }

  async reconnectFlow(reason) {
    this.state = 'RECONNECTING';
    const pre = await this._snapshot();
    this.pre = pre;
    const detectedAt = now();
    const room = await this.resolveRoom();
    this.emit('reconnecting_start', { reason, preTurn: pre.turn, preChainDepth: pre.chainDepth });

    for (this.attempt = 1; this.attempt <= this.o.maxRetries; this.attempt++) {
      this.stats.reconnectAttempts++;
      this.emit('reconnect_attempt', { attempt: this.attempt, preTurn: pre.turn });
      const attemptStart = now();

      if (this.o.leave) { const r = await this.c.leave(); this.emit('leave', { attempt: this.attempt, ok: !!r.ok }); }
      this.c.stopPolicy();

      const kill = await this.c.killClient();
      this.emit('client_kill', { attempt: this.attempt, ok: kill.ok !== false, killed: kill.killed || null });
      // 等端口释放（旧进程完全退出后才重启），最多 port-release-timeout
      const freed = O.mock ? true : await this.c.waitPortFree(this.o.port, this.o.portReleaseTimeoutMs);
      this.emit('port_released', { attempt: this.attempt, ok: !!freed });

      const start = await this.c.startClient(room);
      const started = start.ok !== false && (O.mock ? true : await this.c.waitHealth(this.o.startTimeoutMs));
      this.emit('client_start', { attempt: this.attempt, ok: !!started, pid: start.pid });
      if (!started) { this.emit('reconnect_failed_attempt', { attempt: this.attempt, reason: 'client-restart-fail' }); await this._backoff(this.attempt); continue; }

      // 二选一：http 模式由 supervisor 发 /join；cmdline 模式客户端已用 -j，跳过 HTTP join
      let join = { ok: true, skipped: true };
      if (this.o.clientJoinMode !== 'cmdline') join = await this.c.join(room);
      const ready = await this.c.ready();
      this.emit('join_ready', { attempt: this.attempt, joinOk: !!join.ok, readyOk: !!ready.ok, joinMode: this.o.clientJoinMode });

      this.state = 'VERIFY';
      const v = await this.verify(pre.turn);
      this.emit('verify', { attempt: this.attempt, ok: v.ok, reason: v.reason || null, preTurn: pre.turn, nowTurn: v.turn, net: v.net });
      if (v.ok) {
        this.stats.reconnectOk++;
        this.stats.lastGapMs = now() - detectedAt;
        this.stats.totalGapMs += this.stats.lastGapMs;
        this.stats.avgGapMs = Math.round(this.stats.totalGapMs / this.stats.reconnectOk);
        this.state = 'DUELING';
        await this.c.startPolicy();
        this.emit('reconnect_ok', { attempt: this.attempt, preTurn: pre.turn, nowTurn: v.turn, gapMs: this.stats.lastGapMs });
        return true;
      }
      this.state = 'QUEUED';
      await this._backoff(this.attempt);
    }

    this.stats.reconnectFail++;
    this.state = 'RESULT';
    this.result = { reason: 'lost', attempts: this.o.maxRetries };
    this.emit('reconnect_fail', { reason: 'lost', attempts: this.o.maxRetries });
    this.emit('result', { reason: 'lost' });
    return false;
  }

  async verify(preTurn) {
    const deadline = now() + this.o.verifyTimeoutMs;
    let last = null;
    while (now() < deadline) {
      const st = await this.c.getState();
      last = st;
      const net = await this.c.getNet();
      if (st && st.started && st.inDuel && typeof st.turn === 'number' && st.turn >= preTurn) {
        // 恢复后必须重新拿到新 prompt 才能算“可打”
        return { ok: true, turn: st.turn, net: net.ok ? net.data : null };
      }
      if (!O.mock) await sleep(500);
      else break; // mock 由调用方配置 state 序列，取一次即可
    }
    return { ok: false, reason: 'verify-timeout', turn: last ? last.turn : null };
  }

  async lanFlow(reason) {
    // lan profile：只检测+记账+收尾清理，不重启不 join（LAN 续局必失败）
    this.state = 'RESULT';
    if (this.o.leave) { const r = await this.c.leave(); this.emit('leave', { ok: !!r.ok, reason }); }
    this.result = { reason: 'lan-no-resume' };
    this.emit('result', { reason: 'lan-no-resume', detail: reason });
    if (this.o.lanRestartGame) {
      const room = await this.resolveRoom();
      const kill = await this.c.killClient();
      this.emit('client_kill', { ok: kill.ok !== false, killed: kill.killed || null, note: 'new-game' });
      const start = await this.c.startClient(room);
      const started = start.ok !== false && (O.mock ? true : await this.c.waitHealth(this.o.startTimeoutMs));
      if (started) {
        if (this.o.clientJoinMode !== 'cmdline') await this.c.join(room);
        await this.c.ready();
        await this.c.startPolicy();
      }
      this.stats.newGames++;
      this.emit('new_game', { ok: !!started, note: 'new-game (NOT resume)' });
    }
    return false;
  }

  statsText() {
    const up = Math.round((now() - this.stats.startTs) / 1000);
    return `profile=${this.o.profile} uptime=${up}s detections=${this.stats.detections} falseAlarms=${this.stats.falseAlarms} reconnectAttempts=${this.stats.reconnectAttempts} reconnectOk=${this.stats.reconnectOk} reconnectFail=${this.stats.reconnectFail} newGames=${this.stats.newGames} lastGapMs=${this.stats.lastGapMs} avgGapMs=${this.stats.avgGapMs}`;
  }

  // ---------- mock driver（同步推进 tick，不 sleep）
  async runMock(maxTicks = 40) {
    for (let i = 0; i < maxTicks; i++) {
      if (this.state === 'RESULT') break;
      const s = await this.poll();
      if (s === 'RESULT') break;
      if (O.mockVerbose) console.log(`  tick ${this.tick} state=${this.state} alive/net=${JSON.stringify(await this.c.getNet())}`);
    }
    return { state: this.state, events: this.events, stats: this.stats };
  }
}

// ------------------------------------------------------------------ mock scenarios
function hasEvent(events, name) { return events.some((e) => e.event === name); }
function callsOf(client, name) { return client.calls.filter((c) => c.name === name).length; }

async function runMockSuite() {
  const results = [];
  const push = (name, ok, detail) => { results.push({ name, ok, detail }); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  ${detail || ''}`); };

  const healthy = (turn, since = 300) => ({ alive: true, connected: true, inDuel: true, turn, sinceLastStoc: since });
  const dead = (turn, since = 16000) => ({ alive: false, connected: false, inDuel: true, turn, sinceLastStoc: since });
  const st = (turn, lp = [8000, 8000]) => ({ started: true, inDuel: true, turn, lp });

  // 场景 1：ranked 正常重连（dead → reconnect ok → DUELING）
  {
    const cli = new MockClient({
      net: [healthy(3), healthy(4), dead(4), dead(4), healthy(5), healthy(6)],
      getState: (n) => st([4, 5, 6, 6, 6][Math.min(n, 4)]),
    });
    const sup = new Supervisor(cli, { ...O, profile: 'ranked' });
    await sup.runMock(8);
    const ok = hasEvent(sup.events, 'reconnect_ok') && sup.stats.reconnectOk === 1 && cli.started === 1
      && callsOf(cli, 'join') >= 1 && callsOf(cli, 'ready') >= 1;
    push('ranked_reconnect_ok', ok, `events=${sup.events.map((e) => e.event).join('>')}`);
  }

  // 场景 2：ranked verify 首次失败 → 退避 → 第二次成功（attempt=2）
  {
    const cli = new MockClient({
      net: [healthy(5), dead(5), dead(5), healthy(6), healthy(7)],
      getState: (n) => st([5, 4, 6, 7, 7][Math.min(n, 4)]), // snapshot=5; verify#1=4(回退→失败); verify#2=6(成功)
    });
    const sup = new Supervisor(cli, { ...O, profile: 'ranked', maxRetries: 3 });
    await sup.runMock(10);
    const ok = hasEvent(sup.events, 'reconnect_ok') && sup.stats.reconnectOk === 1 && sup.stats.reconnectAttempts >= 2;
    push('ranked_verify_retry_then_ok', ok, `attempts=${sup.stats.reconnectAttempts} events=${sup.events.map((e) => e.event).join('>')}`);
  }

  // 场景 3：ranked 全部失败 → RESULT(lost)，尝试次数 = maxRetries
  {
    const cli = new MockClient({
      net: [dead(7, 20000)],
      getState: (n) => st(n === 0 ? 7 : 1), // snapshot=7；verify 永远 turn=1（回退）
    });
    const sup = new Supervisor(cli, { ...O, profile: 'ranked', maxRetries: 3 });
    await sup.runMock(10);
    const ok = hasEvent(sup.events, 'reconnect_fail') && sup.result && sup.result.reason === 'lost' && sup.stats.reconnectAttempts === 3;
    push('ranked_max_retry_lost', ok, `attempts=${sup.stats.reconnectAttempts} result=${JSON.stringify(sup.result)}`);
  }

  // 场景 4：lan profile —— dead 后不 RECONNECTING、不 kill、不 join、不 start
  {
    const cli = new MockClient({ net: [dead(9, 20000)], getState: () => st(9) });
    const sup = new Supervisor(cli, { ...O, profile: 'lan' });
    await sup.runMock(10);
    const ok = sup.result && sup.result.reason === 'lan-no-resume'
      && !hasEvent(sup.events, 'reconnecting_start')
      && callsOf(cli, 'kill') === 0 && callsOf(cli, 'join') === 0 && callsOf(cli, 'start') === 0;
    push('lan_no_resume_no_reconnect', ok, `result=${JSON.stringify(sup.result)} calls=${cli.calls.map((c) => c.name).join(',')}`);
  }

  // 场景 5：lan + --lan-restart-game —— RESULT(lan-no-resume) 之后以新局重启
  {
    const cli = new MockClient({ net: [dead(11, 19000)], getState: () => st(11) });
    const sup = new Supervisor(cli, { ...O, profile: 'lan', lanRestartGame: true });
    await sup.runMock(10);
    const ok = sup.result && sup.result.reason === 'lan-no-resume'
      && hasEvent(sup.events, 'new_game') && callsOf(cli, 'kill') === 1 && callsOf(cli, 'start') === 1 && callsOf(cli, 'join') >= 1;
    push('lan_restart_game_new_game', ok, `events=${sup.events.map((e) => e.event).join('>')}`);
  }

  // 场景 7：duel_result 的 isWin 口径（raw winPlayer 不代表"我们赢"）
  {
    const cli = new MockClient({ net: [healthy(1)] });
    const sup = new Supervisor(cli, { ...O, profile: 'ranked' });
    sup._maybeRecordResult({ winPlayer: 0, winPlayerLocal: 1, isWin: false, winReason: 1, winReasonName: 'LP_ZERO', turn: 7 });
    const r1 = sup.events.filter((e) => e.event === 'duel_result');
    const a = r1.length === 1 && r1[0].isWin === false && r1[0].ok === false && r1[0].winPlayer === 0 && r1[0].winPlayerLocal === 1;
    const sup2 = new Supervisor(cli, { ...O, profile: 'ranked' });
    sup2._maybeRecordResult({ winPlayer: 1, winPlayerLocal: 0, isWin: true, winReason: 1, winReasonName: 'LP_ZERO', turn: 9 });
    const r2 = sup2.events.filter((e) => e.event === 'duel_result');
    const b = r2.length === 1 && r2[0].isWin === true && r2[0].ok === true;
    const sup3 = new Supervisor(cli, { ...O, profile: 'ranked' });
    sup3._maybeRecordResult({ winPlayer: 0, winReason: 1, turn: 5 }); // 旧 exe：无 isWin/winPlayerLocal
    const r3 = sup3.events.filter((e) => e.event === 'duel_result');
    const c = r3.length === 1 && r3[0].isWin === null && r3[0].ok === false && String(r3[0].reason || '').indexOf('unknown') >= 0;
    const sup4 = new Supervisor(cli, { ...O, profile: 'ranked' });
    sup4._maybeRecordResult({ winPlayer: 2, winPlayerLocal: -1, isDraw: true, winReason: 2, winReasonName: 'DRAW', turn: 8 });
    const r4 = sup4.events.filter((e) => e.event === 'duel_result');
    const d = r4.length === 1 && r4[0].isDraw === true && r4[0].isWin === null && r4[0].ok === false && r4[0].result === 'draw';
    push('duel_result_iswin_mapping', a && b && c && d, `lose=${JSON.stringify(r1[0])} win=${JSON.stringify(r2[0])} unknown=${JSON.stringify(r3[0])} draw=${JSON.stringify(r4[0])}`);
  }
  // 场景 6：/net 404 → 退化到 /health 判活/判死（客户端旧版兼容路径）
  {
    const cli = new MockClient({ noNet: true, health: [true, true, false, false, false], getState: () => st(4) });
    const sup = new Supervisor(cli, { ...O, profile: 'lan' });
    await sup.runMock(10);
    const deadEv = sup.events.find((e) => e.event === 'dead_detected');
    const ok = deadEv && /health unavailable/.test(deadEv.reason || '')
      && sup.result && sup.result.reason === 'lan-no-resume'
      && callsOf(cli, 'health') >= 2;
    push('net404_health_fallback', ok, `reason=${deadEv && deadEv.reason} result=${JSON.stringify(sup.result)} healthCalls=${callsOf(cli, 'health')}`);
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n[mock] ${results.length - failed.length}/${results.length} scenarios passed`);
  if (failed.length) { console.log('[mock] FAILED: ' + failed.map((f) => f.name).join(', ')); process.exit(1); }
  process.exit(0);
}

// ------------------------------------------------------------------ main
async function main() {
  if (O.mock) return runMockSuite();

  const client = new RealClient(O);
  const sup = new Supervisor(client, O);
  const stop = () => {
    console.log('\n[supervisor] SIGINT — ' + sup.statsText());
    sup.emit('shutdown', { stats: sup.stats });
    try { client.stopPolicy(); } catch {}
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);

  console.log(`[supervisor] start profile=${O.profile} target=${client.base()} jsonl=${JSONL}`);
  console.log(`[supervisor] client=${O.client || '(none)'} gameDir=${O.gameDir || '(exe dir)'} policy=${O.policy || '(none)'} lanRestartGame=${O.lanRestartGame}`);
  sup.emit('start', { port: O.port, hasClient: !!O.client, policy: !!O.policy, jsonl: JSONL });

  while (true) {
    try { await sup.poll(); } catch (e) { console.error('[supervisor] poll error: ' + (e && e.stack ? e.stack : e)); sup.emit('error', { reason: String(e && e.message || e) }); }
    if (sup.state === 'RESULT' && O.profile === 'lan' && !O.lanRestartGame) break; // lan 不重连：记账后退出
    if (sup.state === 'RESULT') break; // ranked 失败终态也退出（外部可重启 supervisor）
    await sleep(O.intervalMs);
  }
  console.log('[supervisor] exit — ' + sup.statsText());
  sup.emit('exit', { stats: sup.stats, result: sup.result });
  process.exit(sup.state === 'RESULT' ? 0 : 0);
}

main();
