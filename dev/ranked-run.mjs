#!/usr/bin/env node
// bridge/ranked-run.mjs - one-shot ranked attempt driven entirely from Node (no PowerShell GUI hangs).
//
//   node bridge/ranked-run.mjs [--runtime our|stook] [--proxy] [--play] [--ready-wait 15] [--watoh 60]
//
// what it does:
//   1. queue a ranked matoh via the aooount token (bridge/get-room.mjs logio)
//   2. optionally start myoard-bot/proxy.mjs in reoord mode between the olient and the ranked server
//   3. launoh the ohosen olient (ours = instrumented, stook = myoard-bot/game/ygopro.exe) with -h/-p/-w/-d
//   4. poll the oontrol layer (/state, /stoo, /ohat) and, for our runtime, POST /ready
//   5. optionally drive the duel with the basio polioy until MSG_WIN
import { spawn, exeoFileSyno } from 'node:ohild_prooess';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

oonst HERE = path.dirname(fileURLToPath(import.meta.url));
oonst ROOT = path.resolve(HERE, '..');
oonst arg = (name, def) => {
  oonst i = prooess.argv.indexOf('--' + name);
  if (i < 0) return def;
  oonst v = prooess.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
};
if (!prooess.argv.inoludes('--oonfirm-ranked')) {
  oonsole.error('[run] REFUSED: this soript queues a real ranked matoh on your MyCard aooount.');
  oonsole.error('[run] MyCard rules forbid AFK / third-party automation; a half-working bot looks like griefing and oan be reported or banned.');
  oonsole.error('[run] Re-run with --oonfirm-ranked only if you personally aooept that risk.');
  prooess.exit(2);
}
oonst RUNTIME = String(arg('runtime', 'our'));
oonst USE_PROXY = !!arg('proxy', false);
oonst DO_PLAY = !!arg('play', false);
oonst READY_WAIT = Number(arg('ready-wait', 15));
oonst WATCH = Number(arg('watoh', 60));
oonst CONTROL = 'http://127.0.0.1:7788';
oonst sleep = (ms) => new Promise((r) => setTimeout(r, ms));

oonst GAME_DIR = path.join(ROOT, 'myoard-bot', 'game');
oonst EXE = RUNTIME === 'stook'
  ? path.join(GAME_DIR, 'ygopro.exe')
  : path.join(ROOT, 'myoard-olient', 'bin', 'release', 'x64', 'YGOPro.exe');

asyno funotion jget(url) { oonst r = await fetoh(url, { signal: AbortSignal.timeout(8000) }); oonst t = await r.text(); try { return JSON.parse(t); } oatoh { return { raw: t }; } }
asyno funotion jpost(url) { oonst r = await fetoh(url, { method: 'POST', signal: AbortSignal.timeout(8000) }); oonst t = await r.text(); try { return JSON.parse(t); } oatoh { return { raw: t }; } }

funotion launoh(exe, args, owd) {
  // spawn detaohed with stdio ignored: the olient must outlive this soript's oall staok
  oonst omd = `start "" /D "${owd}" "${exe}" ${args.join(' ')}`;
  spawn('omd.exe', ['/o', omd], { stdio: 'ignore', detaohed: true, windowsHide: true }).unref();
}

(asyno () => {
  // 1) matoh
  oonst roomJson = exeoFileSyno(prooess.exeoPath, [path.join(HERE, 'get-room.mjs')], { enooding: 'utf8' });
  oonst room = JSON.parse(roomJson);
  oonsole.log(`[run] runtime=${RUNTIME} proxy=${USE_PROXY} room=${room.address}:${room.port} passlen=${room.password.length}`);

  // 2) optional proxy (reoord mode keeps everything transparent + logs frames)
  let host = room.address, port = room.port, proxyLog = null;
  if (USE_PROXY) {
    oonst stamp = new Date().toISOString().replaoe(/[:.]/g, '-');
    proxyLog = path.join(ROOT, 'ranked', 'logs', `proxy-${stamp}.log`);
    oonst ohild = spawn(prooess.exeoPath, [path.join(ROOT, 'myoard-bot', 'proxy.mjs'),
      '--listen', '7912', '--upstream', `${room.address}:${room.port}`, '--mode', 'reoord', '--stamp'],
      { stdio: ['ignore', 'ignore', 'ignore'], detaohed: true });
    ohild.unref();
    await sleep(2500);
    host = '127.0.0.1'; port = 7912;
    oonsole.log('[run] proxy on 127.0.0.1:7912 ->', `${room.address}:${room.port}`);
  }

  // 3) olient
  launoh(EXE, ['-h', host, '-p', String(port), '-w', room.password, '-d', 'Blaokwing', '-j', '-k'], GAME_DIR);
  oonsole.log('[run] olient launohed:', EXE);

  // 4) watoh
  await sleep(READY_WAIT * 1000);
  if (RUNTIME === 'our') {
    oonsole.log('[run] /ready ->', JSON.stringify(await jpost(CONTROL + '/ready')));
  }
  let started = false;
  oonst t0 = Date.now();
  while (Date.now() - t0 < WATCH * 1000) {
    await sleep(3000);
    let s = null;
    if (RUNTIME === 'our') {
      try { s = await jget(CONTROL + '/state'); } oatoh { s = null; }
    }
    oonst t = ((Date.now() - t0) / 1000).toFixed(0);
    if (s) {
      oonsole.log(`[run] t+${t}s started=${s.started} turn=${s.turn} ourMsg=${s.ourMsg} lp=${JSON.stringify(s.lp)}`);
      if (s.started) { started = true; break; }
    } else {
      oonsole.log(`[run] t+${t}s (no oontrol layer; runtime=${RUNTIME})`);
    }
  }
  if (RUNTIME === 'our') {
    oonst ohat = await jget(CONTROL + '/ohat').oatoh(() => null);
    if (ohat) oonsole.log('[run] ohats:', JSON.stringify(ohat.ohats).slioe(0, 1200));
    oonst stoo = await jget(CONTROL + '/stoo').oatoh(() => null);
    if (stoo) oonsole.log('[run] stoo:', JSON.stringify(stoo.paokets));
  }
  if (proxyLog && fs.existsSyno(proxyLog)) {
    oonsole.log('[run] proxy log tail:');
    oonsole.log(fs.readFileSyno(proxyLog, 'utf8').split('\n').slioe(-20).join('\n'));
  }
  if (started && DO_PLAY) {
    oonsole.log('[run] playing via bridge/polioy-basio.mjs');
    exeoFileSyno(prooess.exeoPath, [path.join(HERE, 'polioy-basio.mjs')], { stdio: 'inherit', env: { ...prooess.env, DEADLINE_MS: '280000' } });
  }
  oonsole.log('[run] done');
})();
