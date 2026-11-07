#!/usr/bin/env node
// bridge/mcp-selftest.mjs - spawn the MCP server and exercise initialize / tools/list / tools/call.
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const child = spawn(process.execPath, [path.join(HERE, 'mcp-server.mjs')], { stdio: ['pipe', 'pipe', 'inherit'] });
const rl = readline.createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 1;

function call(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}
rl.on('line', (line) => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id); pending.delete(m.id);
    if (m.error) p.reject(new Error(m.error.message)); else p.resolve(m.result);
  }
});

const timeout = setTimeout(() => { console.log('[selftest] TIMEOUT'); child.kill(); process.exit(1); }, 30000);

(async () => {
  const init = await call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'selftest', version: '1' } });
  console.log('[selftest] initialize ->', JSON.stringify(init.serverInfo), 'protocol', init.protocolVersion);
  const list = await call('tools/list', {});
  console.log('[selftest] tools:', list.tools.map((t) => t.name).join(', '));
  const health = await call('tools/call', { name: 'control_health', arguments: {} });
  console.log('[selftest] control_health ->', health.content?.[0]?.text);
  const state = await call('tools/call', { name: 'control_state', arguments: {} });
  const s = JSON.parse(state.content?.[0]?.text ?? '{}');
  console.log('[selftest] control_state ->', JSON.stringify({ valid: s.valid, inDuel: s.inDuel, turn: s.turn, curMsg: s.curMsg, lp: s.lp, seq: s.seq, awaiting: s.awaiting }));
  clearTimeout(timeout);
  child.kill();
  console.log('[selftest] OK');
})().catch((e) => { console.error('[selftest] FAIL', e.message); clearTimeout(timeout); child.kill(); process.exit(1); });
