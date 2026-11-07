#!/usr/bin/env node
// bridge/mcp-server.mjs - MCP (stdio) server exposing the instrumented client's control API.
//
// Tools:
//   control_state        -> GET  /state
//   control_wait_prompt  -> GET  /wait_prompt?since&timeout_ms   (long poll, the main loop primitive)
//   control_act          -> POST /act?seq&i|hex
//   control_ready        -> POST /ready
//   control_join         -> POST /join?ip&port&pass
//   control_msg          -> GET  /msg
//   control_health       -> GET  /health
//
// Run:  node bridge/mcp-server.mjs        (env CONTROL_URL=http://127.0.0.1:7788)
// Wire it into an MCP host with command "node", args ["bridge/mcp-server.mjs"].
import readline from 'node:readline';

const BASE = process.env.CONTROL_URL || 'http://127.0.0.1:7788';
const PROTOCOL = '2024-11-05';

async function http(path, method = 'GET') {
  const res = await fetch(BASE + path, { method, signal: AbortSignal.timeout(120000) });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { raw: text }; }
}
const qs = (o) => Object.entries(o || {})
  .filter(([, v]) => v !== undefined && v !== null && v !== '')
  .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');

const TOOLS = [
  {
    name: 'control_state',
    description: 'Get the full duel state: turn, phase, LP, hand/field/grave/deck counts with card details, pending prompt counters.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_wait_prompt',
    description: 'Long-poll until it is this client\'s turn to respond. Returns the prompt: seq (pass it back to control_act), curMsg (what kind of decision), and candidate counters. This is the main agent loop primitive.',
    inputSchema: {
      type: 'object',
      properties: {
        since: { type: 'number', description: 'last seq you handled (0 for the first call)' },
        timeout_ms: { type: 'number', description: 'max wait, default 30000' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'control_act',
    description: 'Submit a response for the prompt with the given seq. Use either i (int32 encoded response, e.g. idle (index<<16)|cmd, -1 for chain decline) or hex (raw response bytes, e.g. card selection "0100" = select 1 card at index 0).',
    inputSchema: {
      type: 'object',
      properties: {
        seq: { type: 'number' },
        i: { type: 'number', description: 'int32 response' },
        hex: { type: 'string', description: 'raw bytes as hex' },
      },
      required: ['seq'],
      additionalProperties: false,
    },
  },
  {
    name: 'control_ready',
    description: 'Send CTOS_HS_READY (click the Ready button) for the current room.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_actions',
    description: 'List the semantic actions available for the current prompt (id + kind + human label, e.g. summon/special summon/attack/chain/zone). The caller only picks an id; the client encodes the kernel response itself.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_act_id',
    description: 'Execute one of the actions returned by control_actions, by id.',
    inputSchema: { type: 'object', properties: { id: { type: 'number' } }, required: ['id'], additionalProperties: false },
  },
  {
    name: 'control_lobby',
    description: 'Room/prep-screen state: our seat (0=host,1=guest), whether we are host, readiness of both seats, deck loaded, raw HS status bytes. Use this before ready/start.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_deck',
    description: 'Preload a deck by name (file under deck/*.ydk). Call before control_ready so the deck update is valid.',
    inputSchema: { type: 'object', properties: { name: { type: 'string', description: 'deck name, e.g. Blackwing' } }, additionalProperties: false },
  },
  {
    name: 'control_start',
    description: 'Click "Start" (CTOS_HS_START). Only valid when we are the host (seat 0) and both players are ready.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_surrender',
    description: 'Surrender the current duel (CTOS_SURRENDER).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_chat',
    description: 'Recent server chat / system messages (useful to see why a room was rejected or a duel was kicked).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_join',
    description: 'Connect to a game server (LAN or a matchmade room).',
    inputSchema: {
      type: 'object',
      properties: {
        ip: { type: 'string', description: 'server host, default 127.0.0.1' },
        port: { type: 'number', description: 'server port, default 7911' },
        pass: { type: 'string', description: 'room password' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'control_msg',
    description: 'Last raw server message (id, length, hex) - debug only.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'control_health',
    description: 'Health check of the control layer.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
];

async function callTool(name, args) {
  switch (name) {
    case 'control_state': return http('/state');
    case 'control_msg': return http('/msg');
    case 'control_health': return http('/health');
    case 'control_lobby': return http('/lobby');
    case 'control_actions': return http('/actions');
    case 'control_act_id': return http('/act_id?id=' + encodeURIComponent(args?.id ?? 0));
    case 'control_chat': return http('/chat');
    case 'control_start': return http('/start', 'POST');
    case 'control_surrender': return http('/surrender', 'POST');
    case 'control_deck': return http('/deck?name=' + encodeURIComponent(args?.name ?? 'Blackwing'), 'POST');
    case 'control_ready': return http('/ready', 'POST');
    case 'control_join': return http('/join?' + qs(args), 'POST');
    case 'control_wait_prompt': {
      const since = args?.since ?? 0;
      const timeout = args?.timeout_ms ?? 30000;
      return http(`/wait_prompt?since=${encodeURIComponent(since)}&timeout_ms=${encodeURIComponent(timeout)}`);
    }
    case 'control_act': {
      const q = { seq: args?.seq };
      if (args?.hex !== undefined) q.hex = args.hex;
      if (args?.i !== undefined) q.i = args.i;
      return http('/act?' + qs(q), 'POST');
    }
    default:
      throw new Error('unknown tool: ' + name);
  }
}

const rl = readline.createInterface({ input: process.stdin });
const send = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

rl.on('line', async (line) => {
  const t = line.trim();
  if (!t) return;
  let msg;
  try { msg = JSON.parse(t); } catch { return; }
  const { id, method, params } = msg;
  if (method === undefined) return; // response to us; ignore
  try {
    switch (method) {
      case 'initialize':
        reply(id, {
          protocolVersion: PROTOCOL,
          capabilities: { tools: {} },
          serverInfo: { name: 'ygopro-control', version: '0.1.0' },
        });
        break;
      case 'notifications/initialized':
        break;
      case 'ping':
        reply(id, {});
        break;
      case 'tools/list':
        reply(id, { tools: TOOLS });
        break;
      case 'tools/call': {
        const name = params?.name;
        const args = params?.arguments ?? {};
        const out = await callTool(name, args);
        reply(id, { content: [{ type: 'text', text: JSON.stringify(out) }] });
        break;
      }
      default:
        fail(id, -32601, 'method not found: ' + method);
    }
  } catch (e) {
    fail(id, -32603, String(e && e.message ? e.message : e));
  }
});
