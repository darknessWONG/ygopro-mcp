#!/usr/bin/env node
// bridge/get-room.mjs - token -> authUser -> /ygopro/match, prints {"address":..,"port":..,"password":..,"name":..}
// Reads the token from ranked/ls-copy (same logic as ranked/launcher.mjs). Prints JSON to stdout only.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const LS = path.join(ROOT, 'ranked', 'ls-copy');

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
  const r = await fetch('https://sapi.moecube.com:444/accounts/authUser', { headers: { authorization: 'Bearer ' + token }, signal: AbortSignal.timeout(15000) });
  return { status: r.status, json: await r.json().catch(() => null) };
}
async function match(name, secret, leave) {
  const basic = Buffer.from(`${name}:${secret}`).toString('base64');
  const url = 'https://sapi.moecube.com:444/ygopro/match?arena=athletic&locale=zh-CN' + (leave ? '&leave=1' : '');
  const r = await fetch(url, {
    method: 'POST', headers: { authorization: 'Basic ' + basic }, signal: AbortSignal.timeout(20000),
  });
  return { status: r.status, json: await r.json().catch(() => null) };
}

(async () => {
  // Account pin: when MC_ACCOUNT_ID is set, only tokens for that account id are considered.
  // This prevents accidentally queueing a ranked match on another account present in ls-copy.
  const wantId = process.env.MC_ACCOUNT_ID ? Number(process.env.MC_ACCOUNT_ID) : null;
  const all = tokens();
  const cands = wantId ? all.filter((t) => Number(t.id) === wantId) : all;
  if (!cands.length) throw new Error(`no token for account id ${wantId} in ranked/ls-copy`);
  let user = null;
  for (const c of cands) {
    const a = await authUser(c.token);
    if (a.status === 200 && a.json) { user = a.json; break; }
  }
  if (!user) throw new Error('no valid token in ranked/ls-copy');
  if (wantId && Number(user.id) !== wantId) throw new Error(`authUser id ${user.id} != pinned ${wantId}`);
  if (!user.u16Secret) throw new Error('authUser has no u16Secret');
  let m = await match(user.name ?? user.username, user.u16Secret);
  if (m.status === 409) {
    // 409 = still queued/in a previous room; the leave=1 variant leaves it and queues again.
    process.stderr.write('[get-room] match returned 409, retrying with leave=1\n');
    m = await match(user.name ?? user.username, user.u16Secret, true);
  }
  if (!m.json?.password) throw new Error('match failed: ' + JSON.stringify(m));
  const out = { address: m.json.address, port: m.json.port, password: m.json.password, name: user.name ?? user.username, id: user.id };
  // a re-queued match can hand back the SAME (already dead) room password; flag it so callers can wait for a fresh one
  let stale = false;
  try {
    const stateFile = path.join(ROOT, 'ranked', 'last-room.json');
    if (fs.existsSync(stateFile)) {
      const prev = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
      stale = prev && prev.password === out.password;
    }
    fs.writeFileSync(stateFile, JSON.stringify({ password: out.password, at: Date.now() }));
  } catch { }
  out.stale = stale;
  process.stdout.write(JSON.stringify(out));
})();
