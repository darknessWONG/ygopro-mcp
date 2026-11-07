#!/usr/bin/env node
// bridge/custom-room-test.mjs - zero-rating test on MyCard's own server (custom room, port 7911).
//
// stock client (host, -c) + instrumented client (guest, -j) both go through our recording proxy,
// then we compare what each of them sends around "ready" and whether the duel starts.
//
//   node bridge/custom-room-test.mjs
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const GAME_DIR = path.join(ROOT, 'mycard-bot', 'game');
const OUR_EXE = path.join(ROOT, 'mycard-client', 'bin', 'release', 'x64', 'YGOPro.exe');
const STOCK_EXE = path.join(path.join(GAME_DIR, 'ygopro.exe'));
const UPSTREAM = process.env.UPSTREAM || 'tiramisu.moenext.com:7911';
const PASS = 'aiprobe' + Math.floor(Math.random() * 900 + 100);
const CONTROL = 'http://127.0.0.1:7788';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ps = (cmd) => spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd], { encoding: 'utf8', timeout: 20000 });
const launch = (exe, args, cwd) => spawn('cmd.exe', ['/c', `start "" /D "${cwd}" "${exe}" ${args.join(' ')}`], { stdio: 'ignore', detached: true, windowsHide: true }).unref();
const startProxy = (port, stamp) => {
  const log = path.join(ROOT, 'ranked', 'logs', `proxy-${stamp}-${port}.log`);
  const child = spawn(process.execPath, [path.join(ROOT, 'mycard-bot', 'proxy.mjs'),
    '--listen', String(port), '--upstream', UPSTREAM, '--mode', 'record', '--stamp'],
    { stdio: ['ignore', 'ignore', 'ignore'], detached: true });
  child.unref();
  return log;
};
async function jget(u) { const r = await fetch(u, { signal: AbortSignal.timeout(8000) }); const t = await r.text(); try { return JSON.parse(t); } catch { return { raw: t }; } }
async function jpost(u) { const r = await fetch(u, { method: 'POST', signal: AbortSignal.timeout(8000) }); const t = await r.text(); try { return JSON.parse(t); } catch { return { raw: t }; } }
function hwndFor(filter) {
  const r = ps(`(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -like '${filter}' } | Select-Object -First 1).MainWindowHandle`);
  return (r.stdout || '').trim();
}
function click(h, x, y) {
  ps(`& "${path.join(ROOT, 'mycard-bot', 'tools', 'gui.ps1')}" click ${h} ${x} ${y}`);
}

(async () => {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  console.log('[test] upstream =', UPSTREAM, ' room pass =', PASS);
  const logA = startProxy(7912, stamp);
  const logB = startProxy(7913, stamp);
  await sleep(2500);

  // stock client = host (creates the custom room)
  launch(STOCK_EXE, ['-h', '127.0.0.1', '-p', '7912', '-w', PASS, '-c', '-d', 'Blackwing', '-k'], GAME_DIR);
  await sleep(9000);
  // instrumented client = guest
  launch(OUR_EXE, ['-h', '127.0.0.1', '-p', '7913', '-w', PASS, '-j', '-d', 'Blackwing', '-k'], GAME_DIR);
  await sleep(11000);

  const hStock = hwndFor('*mycard-bot\\game*');
  const hOur = hwndFor('*mycard-client*');
  console.log('[test] hwnd stock =', hStock, ' hwnd our =', hOur);

  // stock: click ready; ours: POST /ready
  click(hStock, 744, 452);
  await sleep(1500);
  console.log('[test] our /ready ->', JSON.stringify(await jpost(CONTROL + '/ready')));

  for (let i = 1; i <= 10; i++) {
    await sleep(3000);
    const s = await jget(CONTROL + '/state').catch(() => null);
    console.log(`[test] t+${i * 3}s started=${s?.started} turn=${s?.turn} curMsg=${s?.curMsg} lp=${JSON.stringify(s?.lp)} deckMain=${s?.deckMain}`);
    if (s?.started) break;
  }
  const chat = await jget(CONTROL + '/chat').catch(() => null);
  console.log('[test] chats:', JSON.stringify(chat?.chats).slice(0, 800));

  for (const [name, log] of [['stock(host)', logA], ['our(guest)', logB]]) {
    console.log(`\n[test] ---- ${name} frames ----`);
    try {
      const lines = fs.readFileSync(log, 'utf8').split('\n').filter(Boolean);
      console.log(lines.slice(-25).join('\n'));
    } catch (e) { console.log('  (no log)', log); }
  }
})();
