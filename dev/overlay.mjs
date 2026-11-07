#!/usr/bin/env node
// bridge/overlay.mjs - OBS-friendly overlay for the duel bot.
//   GET  /            -> HTML page (add as OBS "Browser" source, 1280x720)
//   GET  /events      -> SSE stream of the current state
//   POST /decision    -> body text = one AI decision line (bot calls this)
//   POST /state       -> JSON body {turn, lp:[a,b], prompt, awaiting}
// Keeps the last 12 decisions.
import http from 'node:http';

const PORT = Number(process.env.OVERLAY_PORT || 7790);
const clients = new Set();
const decisions = [];
let state = { turn: 0, lp: [8000, 8000], prompt: '', awaiting: false };

const send = (obj) => { const s = `data: ${JSON.stringify(obj)}\n\n`; for (const c of clients) { try { c.write(s); } catch { } } };

const page = () => `<!doctype html><html><head><meta charset="utf-8"><title>duel overlay</title>
<style>
 html,body{margin:0;height:100%;background:transparent;font-family:"Microsoft YaHei",sans-serif;color:#fff}
 #wrap{position:absolute;left:24px;bottom:24px;padding:14px 18px;border-radius:10px;background:rgba(12,16,28,.78);min-width:520px}
 #top{display:flex;gap:18px;font-size:20px;opacity:.9}
 #lp b{color:#7fd1ff}
 #prompt{font-size:26px;margin:8px 0 6px}
 #dec{font-size:18px;line-height:1.5;min-height:80px;color:#c9f7a4}
 .t{opacity:.5;font-size:14px}
</style></head><body>
<div id="wrap">
  <div id="top"><span>回合 <b id="turn">-</b></span><span id="lp">LP <b>-</b> / <b>-</b></span><span id="aw" class="t"></span></div>
  <div id="prompt">等待开局…</div>
  <div id="dec"></div>
</div>
<script>
const decs=[];
const es=new EventSource('/events');
es.onmessage=(e)=>{
  const d=JSON.parse(e.data);
  if(d.type==='decision'){ decs.push(d.text); while(decs.length>8) decs.shift(); document.getElementById('dec').innerHTML=decs.map(x=>'▸ '+x).join('<br>'); return; }
  if(d.type==='state'){
    document.getElementById('turn').textContent=d.turn;
    const lp=document.getElementById('lp'); lp.innerHTML='LP <b>'+d.lp[0]+'</b> / <b>'+d.lp[1]+'</b>';
    document.getElementById('prompt').textContent=d.prompt||'…';
    document.getElementById('aw').textContent=d.awaiting?'（AI 决策中）':'';
  }
};
</script></body></html>`;

const srv = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(page());
  }
  if (req.method === 'GET' && req.url === '/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.write(': hello\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 100000) req.destroy(); });
    req.on('end', () => {
      if (req.url === '/decision') {
        const text = body.slice(0, 500);
        decisions.push(text); while (decisions.length > 12) decisions.shift();
        send({ type: 'decision', text });
        res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"ok":true}');
      }
      if (req.url === '/state') {
        try { state = JSON.parse(body); } catch { }
        send({ type: 'state', ...state });
        res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"ok":true}');
      }
      res.writeHead(404); res.end();
    });
    return;
  }
  res.writeHead(404); res.end();
});
srv.listen(PORT, '127.0.0.1', () => console.log(`[overlay] http://127.0.0.1:${PORT}/`));
