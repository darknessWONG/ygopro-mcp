#!/usr/bin/env node
// bridge/queue-loop.mjs
// 反复请求 /ygopro/match 直到配上房间或到达总时限。
//
// 背景：服务端对 match 长轮询有约 10 分钟上限，到点返回 504（不是 409，也不是无限挂）。
// 单次 get-room.mjs 遇到 504 会直接抛错退出，于是每次都要手动重排。
// 本脚本把「504 / 超时 / 409」都当成「这一轮没配上」，自动重排，直到：
//   - 配上 → 打印房间 JSON（退出码 0）
//   - 超过 QUEUE_TOTAL_MS → 退出码 2
//
// 用法：
//   $env:MC_ACCOUNT_ID='1173810'; $env:QUEUE_TOTAL_MS='3600000'; node bridge/queue-loop.mjs
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const LS = path.join(ROOT, 'ranked', 'ls-copy');
const TOTAL_MS = Number(process.env.QUEUE_TOTAL_MS || 3600000);
const ROUND_MS = Number(process.env.QUEUE_ROUND_MS || 630000);
const t0 = Date.now();
const el = () => Math.round((Date.now() - t0) / 1000) + 's';
const info = (m) => process.stderr.write(`[${el()}] ${m}\n`);

function decodeJwt(t) {
  try { return JSON.parse(Buffer.from(t.split('.')[1], 'base64url').toString('utf8')); } catch { return null; }
}
function tokens() {
  const out = [];
  for (const f of fs.readdirSync(LS)) {
    const p = path.join(LS, f);
    let st; try { st = fs.statSync(p); } catch { continue; }
    if (!st.isFile() || st.size === 0) continue;
    const txt = fs.readFileSync(p).toString('latin1');
    for (const m of txt.matchAll(/eyJ[A-Za-z0-9_\-.]{20,}/g)) {
      const pl = decodeJwt(m[0]);
      out.push({ token: m[0], id: pl?.id, exp: pl?.exp ?? 0, file: f });
    }
  }
  const seen = new Set();
  return out.filter((t) => (seen.has(t.token) ? false : (seen.add(t.token), true))).sort((a, b) => b.exp - a.exp);
}
async function authUser(token) {
  try {
    const r = await fetch('https://sapi.moecube.com:444/accounts/authUser', { headers: { authorization: 'Bearer ' + token }, signal: AbortSignal.timeout(20000) });
    return { status: r.status, json: await r.json().catch(() => null) };
  } catch (e) { return { status: -1, json: null, err: String(e.message || e) }; }
}
function match(name, secret, timeoutMs) {
  const basic = Buffer.from(`${name}:${secret}`).toString('base64');
  return new Promise((resolve) => {
    const req = https.request({
      host: 'sapi.moecube.com', port: 444,
      path: '/ygopro/match?arena=athletic&locale=zh-CN', method: 'POST',
      headers: { authorization: 'Basic ' + basic },
    }, (res) => {
      let data = ''; res.setEncoding('utf8');
      res.on('data', (c) => { data += c; });
      res.on('end', () => { let json = null; try { json = JSON.parse(data); } catch {} resolve({ status: res.statusCode, json }); });
    });
    req.setTimeout(timeoutMs, () => { req.destroy(); resolve({ status: -1, json: null, err: 'client timeout' }); });
    req.on('error', (e) => resolve({ status: -1, json: null, err: String(e.message || e) }));
    req.end();
  });
}

const wantId = process.env.MC_ACCOUNT_ID ? Number(process.env.MC_ACCOUNT_ID) : null;
const all = tokens();
const cands = wantId ? all.filter((t) => Number(t.id) === wantId) : all;
if (!cands.length) { process.stderr.write(`no token for account id ${wantId}\n`); process.exit(1); }

let user = null;
for (const c of cands) {
  const a = await authUser(c.token);
  if (a.status === 200 && a.json) { user = a.json; break; }
  info(`authUser status=${a.status}`);
}
if (!user) { process.stderr.write('no valid token\n'); process.exit(1); }
if (!user.u16Secret) { process.stderr.write('no u16Secret\n'); process.exit(1); }
info(`account ${user.name ?? user.username} (id ${user.id}) — 开始排队，总时限 ${Math.round(TOTAL_MS / 60000)} 分钟`);

let round = 0;
let authFails = 0;
while (Date.now() - t0 < TOTAL_MS) {
  round++;
  const budget = Math.max(30000, Math.min(ROUND_MS, TOTAL_MS - (Date.now() - t0)));
  info(`第 ${round} 轮长轮询（最多 ${Math.round(budget / 1000)}s）`);
  const m = await match(user.name ?? user.username, user.u16Secret, budget);
  if (m.json?.password) {
    const out = { address: m.json.address, port: m.json.port, password: m.json.password, name: user.name ?? user.username, id: user.id, stale: false };
    try {
      const stateFile = path.join(ROOT, 'ranked', 'last-room.json');
      if (fs.existsSync(stateFile)) {
        const prev = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
        out.stale = prev && prev.password === out.password;
      }
      fs.writeFileSync(stateFile, JSON.stringify({ password: out.password, at: Date.now() }));
    } catch {}
    info('配上房间');
    process.stdout.write(JSON.stringify(out));
    process.exit(0);
  }
  info(`本轮未配上：status=${m.status} ${m.err || ''}`);
  // 401 = Basic(name:u16Secret) 被拒，通常是 u16Secret 已轮换；重新 authUser 取一次新的。
  if (m.status === 401 || m.status === 403) {
    authFails++;
    let refreshed = null;
    for (const c of cands) {
      const a = await authUser(c.token);
      if (a.status === 200 && a.json?.u16Secret) { refreshed = a.json; break; }
    }
    if (refreshed) {
      info(`401 → 重新 authUser 成功，换用新的 u16Secret（第 ${authFails} 次）`);
      user = refreshed;
    } else {
      info(`401 → authUser 也没拿到有效 secret，本轮跳过`);
    }
  }
  await new Promise((r) => setTimeout(r, 3000));
}
process.stderr.write(`[${el()}] 总时限内未配到对手，退出\n`);
process.exit(2);
