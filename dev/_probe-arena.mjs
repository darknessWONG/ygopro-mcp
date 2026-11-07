import fs from 'node:fs';
import path from 'node:path';
const ROOT = 'D:\\dsh_workspaces\\MC_bot_dsh';
const LS = path.join(ROOT,'ranked','ls-copy');
const decode = t => { try { return JSON.parse(Buffer.from(t.split('.')[1],'base64url').toString('utf8')); } catch { return null; } };
const toks=[];
for (const f of fs.readdirSync(LS)) { const p=path.join(LS,f); let st; try{st=fs.statSync(p)}catch{continue}; if(!st.isFile()||st.size===0)continue;
  const txt=fs.readFileSync(p).toString('latin1');
  for (const m of txt.matchAll(/eyJ[A-Za-z0-9_\-.]{20,}/g)) { const pl=decode(m[0]); toks.push({t:m[0],exp:pl?.exp??0}); } }
toks.sort((a,b)=>b.exp-a.exp);
let user=null;
for (const c of toks) { const r=await fetch('https://sapi.moecube.com:444/accounts/authUser',{headers:{authorization:'Bearer '+c.t}}); if(r.status===200){user=await r.json();break} }
if(!user){console.log('NO USER');process.exit(1)}
const arenas=['athletic','casual','entertainment','entertain','normal','legend','fun','rank','match'];
for (const a of arenas) {
  const basic=Buffer.from(`${user.name??user.username}:${user.u16Secret}`).toString('base64');
  const r=await fetch(`https://sapi.moecube.com:444/ygopro/match?arena=${a}`,{method:'POST',headers:{authorization:'Basic '+basic}});
  let j=null; try{ j=await r.json(); }catch{}
  console.log(a, r.status, j?JSON.stringify(j).slice(0,120):'(no json)');
}
