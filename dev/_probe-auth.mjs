import fs from 'node:fs';
import path from 'node:path';
const ROOT='D:\\dsh_workspaces\\MC_bot_dsh'; const LS=path.join(ROOT,'ranked','ls-copy');
const dec=t=>{try{return JSON.parse(Buffer.from(t.split('.')[1],'base64url').toString('utf8'))}catch{return null}};
const toks=[]; for(const f of fs.readdirSync(LS)){const p=path.join(LS,f);let st;try{st=fs.statSync(p)}catch{continue};if(!st.isFile()||st.size===0)continue;for(const m of fs.readFileSync(p).toString('latin1').matchAll(/eyJ[A-Za-z0-9_\-.]{20,}/g)){const pl=dec(m[0]);toks.push({t:m[0],exp:pl?.exp??0})}}
toks.sort((a,b)=>b.exp-a.exp);
for(const c of toks){const r=await fetch('https://sapi.moecube.com:444/accounts/authUser',{headers:{authorization:'Bearer '+c.t},signal:AbortSignal.timeout(15000)}); if(r.status===200){const j=await r.json(); console.log('keys:', Object.keys(j).join(',')); console.log('json:', JSON.stringify(j).slice(0,400)); break;}}
