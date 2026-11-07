import fs from 'node:fs';
import path from 'node:path';
const ROOT='D:\\dsh_workspaces\\MC_bot_dsh'; const LS=path.join(ROOT,'ranked','ls-copy');
const dec=t=>{try{return JSON.parse(Buffer.from(t.split('.')[1],'base64url').toString('utf8'))}catch{return null}};
const toks=[]; for(const f of fs.readdirSync(LS)){const p=path.join(LS,f);let st;try{st=fs.statSync(p)}catch{continue};if(!st.isFile()||st.size===0)continue;for(const m of fs.readFileSync(p).toString('latin1').matchAll(/eyJ[A-Za-z0-9_\-.]{20,}/g)){const pl=dec(m[0]);toks.push({t:m[0],exp:pl?.exp??0})}}
toks.sort((a,b)=>b.exp-a.exp); let user=null;
for(const c of toks){try{const r=await fetch('https://sapi.moecube.com:444/accounts/authUser',{headers:{authorization:'Bearer '+c.t},signal:AbortSignal.timeout(15000)}); if(r.status===200){user=await r.json();break}}catch{}}
console.log('auth ok:', !!user, user && user.id);
if(!user) process.exit(0);
const basic=Buffer.from(`${user.username}:${user.u16Secret}`).toString('base64');
const t0=Date.now();
try {
  const r=await fetch('https://sapi.moecube.com:444/ygopro/match?arena=athletic&locale=zh-CN',{method:'POST',headers:{authorization:'Basic '+basic},signal:AbortSignal.timeout(90000)});
  const body=await r.text();
  console.log('match ->', r.status, 'after', ((Date.now()-t0)/1000).toFixed(1)+'s', body.slice(0,200));
} catch(e) {
  console.log('match ->', e.name, 'after', ((Date.now()-t0)/1000).toFixed(1)+'s');
}
