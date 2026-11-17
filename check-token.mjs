#!/usr/bin/env node
// bridge/check-token.mjs — 列出 ranked/ls-copy 里各 JWT 的账号与到期时间
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LS = path.join(path.resolve(HERE, '..'), 'ranked', 'ls-copy');
const now = Math.floor(Date.now() / 1000);

let files = [];
try { files = fs.readdirSync(LS); } catch (e) { console.log('ls-copy 不存在:', LS); process.exit(1); }
console.log('ls-copy files:', files.join(', ') || '(空)');

for (const f of files) {
  const p = path.join(LS, f);
  let st; try { st = fs.statSync(p); } catch { continue; }
  if (!st.isFile() || st.size === 0) continue;
  const txt = fs.readFileSync(p).toString('latin1');
  let n = 0;
  for (const m of txt.matchAll(/eyJ[A-Za-z0-9_\-.]{20,}/g)) {
    let pl = null;
    try { pl = JSON.parse(Buffer.from(m[0].split('.')[1], 'base64url').toString('utf8')); } catch { continue; }
    n++;
    const expT = pl.exp ? new Date(pl.exp * 1000).toISOString() : '(none)';
    const left = pl.exp ? Math.round((pl.exp - now) / 60) : '?';
    console.log(`  ${f}  id=${pl.id}  exp=${expT}  剩余=${left}min  ${pl.exp && pl.exp < now ? '<<< 已过期' : ''}`);
  }
  if (!n) console.log(`  ${f}  (没有 JWT)`);
}
console.log('now =', new Date(now * 1000).toISOString());
