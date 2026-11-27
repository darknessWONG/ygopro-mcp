# YGOPro MCP 控制层：接口与设计规范（面向 LLM 接入）

> **读者**：后续接手的 LLM / agent / 工程师。**只读本文档 + 附录即可接入**，不需要先读懂 ygopro 协议。
> **先读（操作流程）**：[`PLAYBOOK-FULL.md`](PLAYBOOK-FULL.md) —— 全流程权威操作手册（每步判定/工具速查/状态字典/排错）；本文档是字段与接口契约。
>
> **适用版本（当前正式版 exe）**：`mycard-client/bin/release/x64/YGOPro.exe`
> = **2026-11-27 17:22:16 / 6,338,048 B**，SHA256 `99FC53A3B2A7121A7EFBCF81A312F9499E603E8122ED6C37CC326C9B023C0708`
> （2026-11-27 **position 掩码 + `ignore` keep-own 版**：`MSG_SELECT_POSITION` 捕获合法掩码 → `/prompt.selectablePositions` + `selectablePositionsHex`；`/actions.position` 按掩码动态生成（表攻/里攻/表守/里守），旧版写死 `defense=0x02`（里侧攻击、非法响应 `seq` 连发）已修；**当前构建 action 项只有 `id/kind/label`（无 `index`），用 label 选、`act_id` 自动编码 POS；`index` 自下个 build（>17:22:16）提供**。`ignore` 保留含我方候选的窗口（`YGO_CHAIN_IGNORE_KEEP_OWN` 默认 1）。另含前版 side_ok `changed`/SelfSeat/时点四态/座位坐标；验收/历史见文末记录）
> `/state.resume.reason` 在加载成功时返回 `"loaded"`，行为不变；22:23:28 已做过冒烟）。
> 该版含重连基础能力：`GET /net`、自动 `/tip` 探活、`YGO_SUPPRESS_MODALS` 模态框抑制、
> `resume-context-<port>.json` journal、`POST /leave`（详见 [RECONNECT-DESIGN.md](RECONNECT-DESIGN.md)、[reconnect-lab.md](reconnect-lab.md)）。
> 控制层源码已从单文件 `control.cpp` 拆成 7 个模块，
> 代码位置见 [MODULE-MAP.md](MODULE-MAP.md)。**本文所有符号名均未改变**，只是所在文件与行号变了。
> 文档里的**字段名 / 工具名 / 环境变量 / 日志关键词都可以在代码里 grep 到**（grep 不到的是示例数据）。
> 代码行号会随改动漂移，**以符号名为准**（本文同时给符号名与当时的行号）。
>
> 设计细节附录（poc-wasm-duel 提供，UI 注入与连锁的深度说明）：[`MCP-INTERFACE-poc.md`](MCP-INTERFACE-poc.md)

---

## 0. 快速接入（TL;DR）

```
① 起一对局域网客户端（一条命令，见 §8.3）
   powershell -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 8 -Deck Blackwing

② 把一个 MCP server 接进你的 host：
   command = "node"
   args    = ["bridge/mcp-server.mjs"]
   env     = { CONTROL_URL: "http://127.0.0.1:7788" }   // 客机用 7789

③ 循环：
   r = control_wait_prompt({since: lastSeq})     // 只为"等下一个待答窗口"；不要用它判断进度（见 §5.9）
   a = control_actions()                          // 本 prompt 的语义候选（id+kind+label），新鲜
   control_act_id({id: <你选中的候选 id>})         // 提交（默认经 UI 点击执行）
   lastSeq = a.seq                                // 用 actions 的 seq（新鲜），不要用 wait 的旧快照

④ 对局走了、赢家出现后读 control_state().winPlayer / winReasonName 收尾
```

**三条铁律**

1. **动作必须针对当前 `seq`**：`control_wait_prompt` 返回新 `seq` 才做决策；`control_act` 用旧 seq 会被拒（`stale seq`）。**判断进度用 `control_state`/`control_actions`（新鲜），不要信 `wait_prompt` 返回的旧快照**（§5.9）。
2. **`/state.started` 与 `/health.started` 不是一回事**（§4.1、§10 有坑说明）。
3. **UI 路径是默认、直连是兜底**：看到 `UI fallback` 是正常现象，不是故障。

---

## 1. 总览与架构

```
        ┌────────────────────────┐
        │  LLM / agent（你）      │
        └───────────┬────────────┘
                    │ MCP (stdio, JSON-RPC)
        ┌───────────▼────────────┐
        │ bridge/mcp-server.mjs  │   薄桥：20 个工具 → HTTP
        └───────────┬────────────┘
                    │ HTTP 127.0.0.1:7788（房主）/ 7789（客人）
        ┌───────────▼───────────────────────────────────────┐
        │ YGOPro.exe 进程内控制层（gframe/control*.cpp 7 模块）│
        │  ┌─────────────┐   ┌──────────────────────────┐   │
        │  │ HTTP server │──▶│ 动作队列 g_actions        │   │
        │  └─────────────┘   └────────────┬─────────────┘   │
        │                                 │ Pump()（UI 线程）│
        │        ┌────────────────────────▼───────────┐      │
        │        │ ①UI 注入（点按钮/点卡/点格）       │      │
        │        │ ②600ms 无效果 → 直连 SetResponse   │      │
        │        └────────────────┬───────────────────┘      │
        │                         │ CTOS_RESPONSE            │
        │  ┌──────────────────────▼────────────────────┐     │
        │  │ ygopro 内核（ocgcore）+ 真实客户端窗口渲染 │     │
        │  └───────────────────────────────────────────┘     │
        └────────────────────────────────────────────────────┘
```

**为什么这样切**

- 协议编解码、线程安全（网络线程 vs UI 线程）、响应字节编码**全部在客户端进程内完成**；
  LLM 只面对「语义动作」，永远不用拼 CTOS/STOC 帧。
- UI 注入走客户端自己的事件分发（`device->postEventFromUser` / `receiver->OnEvent`），
  与真人点击**同一条 handler**，所以弹窗、动画、高亮、连锁特效都正常，且不会移动系统光标。
- 直连回退保证「点不中也绝不死锁」。实测一局 20 回合、各类 fallback 数十次，对局照常推进。

**目录与职责**

| 路径 | 职责 |
|---|---|
| `bridge/mcp-server.mjs` | MCP stdio 服务，198 行，工具→HTTP 薄映射 |
| `control.h` | **对外**接口（上游 6 文件只 include 它） |
| `control_internal.h` | 内部共享：Snap 结构 + extern 全局 + 跨 TU 声明 |
| `control.cpp` | 生命周期 + HTTP/RouteRequest + Pump + 钩子 + 日志（**全局定义唯一处**） |
| `control_state.cpp` | 快照采集 + 全部 JSON 序列化 |
| `control_ui.cpp` | UI 注入 / 窗口清理 / 连锁时点 / ExecUiAction |
| `control_lobby.cpp` | 卡组/准备/开始/加入/投降（ExecLobbyAction） |
| `control_actions.cpp` | ExecuteAction 分发 + 原始响应 |
| `control_sem.cpp` | 语义动作列表与编码（/actions 返回体） |

> 上述文件都在 `mycard-client/gframe/` 下。
| `bridge/lan-run.ps1` | 一键 LAN 跑局器（起 host/guest、备牌、准备、开局、双 bot、看门狗、证据） |
| `bridge/policy-semantic.mjs` | 参考策略（语义决策循环，可当 LLM 的替身） |
| `bridge/dev/diag-ui-windows.ps1` | `/ui.windows` 诊断采样器（每 5s 采样 + 每 20s 截图） |

---

## 2. MCP 工具清单（`bridge/mcp-server.mjs` 的 20 个工具）

> 全部无参数或只有简单参数；返回体就是对应 HTTP 端点的 JSON（原文透传，见 §4）。**例外**：`control_match` 返回派生的 `{match, summary}`（见 §5.6）。

| # | 工具 | 用途 | 参数 | HTTP |
|---|---|---|---|---|
| 1 | `control_health` | 存活探活 | — | `GET /health` |
| 2 | `control_state` | 完整局面（§4.1） | — | `GET /state` |
| 3 | `control_wait_prompt` | **只为"等下一个待答窗口"**：`14:53:57` 起**阻塞到新的 `awaiting=true`**（`seq>since && awaiting`），超时返回最新快照。**旧版（≤15:34:59）在 `awaiting=false` 会立刻返回旧快照，不能用来判断进度**；判进度用 `control_state`/`control_actions`，轮询用 `control_prompt`（§5.9） | `since`(number，上一次的 seq，首次 0)、`timeout_ms`(默认 30000) | `GET /wait_prompt?since&timeout_ms` |
| 4 | `control_actions` | 当前 prompt 的语义候选 | — | `GET /actions` |
| 5 | `control_act_id` | 按 id 执行候选（默认 UI 路径） | `id`(number) | `GET /act_id?id=` |
| 6 | `control_act` | 直接提交原始响应（调试/兜底） | `seq`(number)、`i`(int32) 或 `hex`(bytes hex) | `POST /act?seq&i\|hex` |
| 7 | `control_lobby` | 准备界面状态（座位/准备/牌组数） | — | `GET /lobby` |
| 8 | `control_deck` | 预载牌组（`deck/*.ydk`） | `name`(默认 Blackwing) | `POST /deck?name=` |
| 9 | `control_ready` | 点准备（CTOS_HS_READY） | — | `POST /ready` |
| 10 | `control_start` | 房主点开始（仅 seat 0 且双方准备） | — | `POST /start` |
| 11 | `control_join` | 连接服务器（LAN/房间） | `ip`(默认 127.0.0.1)、`port`(默认 7911)、`pass` | `POST /join?ip&port&pass` |
| 12 | `control_chat` | 服务器聊天/系统消息（房间被拒原因） | — | `GET /chat` |
| 13 | `control_surrender` | 投降 | — | `POST /surrender` |
| 14 | `control_msg` | 最近一条原始服务器消息（调试） | — | `GET /msg` |
| 15 | `control_side_move` | **Bo3 换备**：把 N 张卡在 side/main/extra 之间移动（详见 §5.5） | `code`(number，卡号)、`from`(side\|main\|extra)、`to`(main\|extra\|side)、`n`(默认 1) | `POST /side_swap?code&from&to&n` |
| 16 | `control_side_done` | **Bo3 换备**：换完牌点"确定"继续下一局（等价 `btnSideOK`） | — | 先 `GET /actions` 找 `kind=side_ok` 的 id，再 `GET /act_id?id=` |
| 17 | `control_match` | **整场结果一句话**（谁赢/为什么/大比分/是否结束，详见 §5.6） | — | `GET /state`，读 `state.match` 派生 |
| 18 | `control_prompt` | **当前 prompt 快照（不阻塞）**：seq/awaiting/curMsg/tpPending/sidePending/候选计数 | — | `GET /prompt` |
| 19 | `control_net` | **掉线/存活检查（轮询用，详见 §5.7）**：connected/joined/inDuel/alive/state/closeReason/lastStocName/sinceLastStoc/probe/lastNetMsg + `stallMs/oppTimeLeft/oppClockFresh` | — | `GET /net` |
| 20 | `control_leave` | **干净离桌回主菜单**（卡住时优先于 surrender，详见 §5.8） | — | `POST /leave` |

**MCP 连接示例（JSON-RPC over stdio）**

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"control_state","arguments":{}}}
```

```json
// control_actions 的返回（tools/call 的 result.content[0].text 是一段 JSON 字符串）
{"seq":42,"curMsg":11,"awaiting":true,"actions":[
  {"id":0,"kind":"summon","label":"summon #0 code=22835145 lv=2 tuner"},
  {"id":1,"kind":"summon","label":"summon #1 code=49003716 lv=4"},
  {"id":2,"kind":"set_monster","label":"set monster #0 code=22835145"},
  {"id":3,"kind":"activate","label":"activate #0 code=5318639"},
  {"id":4,"kind":"to_bp","label":"go to battle phase"},
  {"id":5,"kind":"to_ep","label":"end phase"}
]}
```

**先/后攻（`kind:"tp"`，MCP 驱动时必须由 LLM 选择）**

- 控制层**收到过任意 HTTP 请求**后（`g_controlDriven`），客户端收到 `STOC_SELECT_TP` 时**不再自动发**
  `CTOS_TPResult`：`/prompt` 会给出 `awaiting:true, tpPending:true, tpOptions:[1,2]`，`/actions` 返回：
  ```json
  {"actions":[
    {"id":0,"kind":"tp","label":"tp first (index=1)","index":1},
    {"id":1,"kind":"tp","label":"tp second (index=2)","index":2}
  ],"awaiting":true,"tpPending":true}
  ```
- `/act_id?id=0` → 先攻（`res=1`）；`/act_id?id=1` → 后攻（`res=2`）；日志 `TP choice res=N (from control)`。
- 纯手动（从未收到 HTTP 请求）保持旧行为：自动选 `res=2`，不发布 tp prompt。
- `YGO_TP=1|2` 仍作为强制覆盖（优先于以上两种），日志 `TP choice res=N (forced by YGO_TP)`。
- 等待选择期间该 prompt 与普通 prompt 一样被冻结（`/prompt`/`/actions` 快照一致）。

**HTTP 端点全表**（MCP 未全暴露，但可直连；`7788`=房主、`7789`=客人）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/health` | GET | `{"ok":true,"started":<server listening>}` |
| `/state` | GET | 完整快照（§4.1） |
| `/prompt` | GET | 当前 prompt（§4.2；`/wait_prompt` 返回的就是它） |
| `/wait_prompt?since=&timeout_ms=` | GET | 长轮询：`g_seq>since` 或 `!awaiting` 时返回 PromptJson |
| `/actions` | GET | `{seq,curMsg,awaiting,actions:[{id,kind,label}]}` |
| `/act_id?id=N` | GET | 执行候选；要求 `awaiting` 且 id 合法，否则 `{"ok":false,"error":..}` |
| `/act?seq=&i=\|hex=` | POST | 原始响应；seq 不匹配 → `{"ok":false,"error":"stale seq"}` |
| `/ui` | GET | 连锁时点 + 弹窗 + 窗口诊断（§4.4） |
| `/ui?chain=all\|avail\|ignore` | GET | 立即切换连锁时点（下一帧生效） |
| `/uiclick?x=&y=` | GET | 校准：注入一次屏幕像素点击 |
| 另有 | — | `/lobby` `/hs` `/chat` `/stoc` `/ctos` `/msg` `/deck` `/ready` `/start` `/surrender` `/notready` `/join` |

---

> **实战步骤（进房→选卡组→准备→开始→TP→决策→换备→下一局→收尾）见 [`MATCH-PLAYBOOK.md`](MATCH-PLAYBOOK.md)。**
> 最容易踩的坑：**双方 ready 不会自动开局，必须发 `/start` 并轮到 `state.started==true`**；一局打完要 `side_ok` 才算完成换备；整场以 `STOC_DUEL_END` 判定。
## 3. 标准交互循环

### 3.1 伪代码（推荐实现）

```js
let lastSeq = 0;
for (;;) {
  // ① 等新 prompt（长轮询；返回里 seq 可能是旧值/awaiting=false，需自己判）
  const p = await call('control_wait_prompt', { since: lastSeq, timeout_ms: 30000 });
  if (!p || p.awaiting !== true || p.seq === lastSeq) continue;   // 还没轮到我 / 无新提示
  lastSeq = p.seq;

  // ② 拿候选
  const { actions } = await call('control_actions', {});
  if (!actions || actions.length === 0) continue;                  // 极端情况：等下一轮

  // ③ 决策（LLM / 启发式 / 随机都行，只输出 actions 里的一个 id）
  const pick = decide(p, actions);
  if (pick == null) continue;

  // ④ 提交（默认经 UI 点击；失败会自动直连回退，不需要你重试）
  const r = await call('control_act_id', { id: pick.id });
  if (!r.ok) { /* "stale seq"/"not awaiting" → 丢掉这次决策，重新 wait */ }

  // ⑤ 终局检查
  const st = await call('control_state', {});
  if (st.winPlayer >= 0) break;
}
```

### 3.2 `wait_prompt` 的真实语义（必读）

代码（`/wait_prompt`，~L2393）：

```cpp
g_cv.wait_for(lk, ms(timeout), [since]() { return g_seq > since || !g_awaiting; });
body = PromptJson(g_shared);
```

- **`since` 传你上次处理过的 seq**；如果 `g_seq` 没变，它会一直等到超时。
- 唤醒条件里还有 `!g_awaiting`：**没在等响应时它会立刻返回旧快照**（但 `awaiting=false`）——
  所以调用方必须自己判 `awaiting === true && seq > lastSeq`，否则会拿到重复 prompt。
- 返回的是 `PromptJson`（§4.2），不是 `"ok"` 包裹。

### 3.3 stale seq 与失败处理

| 情况 | 返回 | 处理 |
|---|---|---|
| 你提交的 `seq` 落后于当前 | `{"ok":false,"error":"stale seq","seq":<当前>}` | 丢弃本决策，用返回的 `seq` 重新 `actions` |
| 当前没有等待中的响应 | `{"ok":false,"error":"not awaiting"}` | 说明另一个循环/自动处理器已经答了，重新 wait |
| `id` 超界 | `{"ok":false,"error":"bad action id"}` | 重新 `control_actions` 取 id（prompt 变了 id 会重排） |
| `act` 既没 `i` 也没 `hex` | `{"ok":false,"error":"need hex or i"}` | 用 `act_id` 而不是 `act` |

**建议节奏**：`timeout_ms` 取 10~30s；每 30~60s 打一次 `/state` 做健康检查（`pipeline.awaiting`、`retryStreak`）。
`policy-semantic.mjs` 就是这么做的（`WAIT_TIMEOUT_MS`/`HEARTBEAT_MS`/`STALL_MS` 可调，见 §8.2）。

---

## 4. `/state` 与 `/prompt` 字段表

### 4.0 座位坐标约定（`10:26:12` 起统一；旧版 guest 阵营反向）

**一句话**：对外 `ctrl` 一律是**服务端座位**；`isMine` 由 `ctrl` 推导，**恒有 `isMine == (ctrl == mySeat)`**。

| 概念 | 含义 |
|---|---|
| `myPlayer` | 本地视角恒 `0`（只是 `hand[0]`/`monsters[0]` 等的数组索引视角，不是座位号） |
| `mySeat` | **真实服务端座位**：0=房主、1=客人（guest 时 `mySeat=1`） |
| `ctrl`（所有卡/候选/连锁/places） | **服务端座位**：`0`=座位 0（房主侧）、`1`=座位 1（客人侧）、`>=2` 原样（额外区等） |
| `isMine` | `ctrl == mySeat`。guest（`mySeat=1`）时**自己的卡 `ctrl=1/isMine=true`，对手的卡 `ctrl=0/isMine=false`** |
| `ctrlRaw` | 仅 `places[]`：**本地视角原值**（调试用）；响应用 `bit`，不要用 `ctrl`/`ctrlRaw` 拼字节 |
| `name` | 候选/手牌/场面卡名已回填（`hidden=true` 的卡不出现） |

**旧版（≤ `2026-11-23 14:53:57`）问题**：guest 侧 `controler` 是本地视角，直接和 `mySeat`（服务端座位）比较 → 阵营反了（自己卡 `isMine:false`、label「对手」；对手卡 `isMine:true`）；host（`mySeat=0`）恰好掩盖。`10:26:12` 起 `ToServerSeat(localCtrl,mySeat)`（0→mySeat、1→1−mySeat、≥2 原样）在所有路径统一转换。

**适用字段**：`hand`/`monsters`/`spells`/`grave`/`banished`、`selectableCards[]`、`chainList`/`chainStackSnap`/`chainStackFull`/`chainCandidates`、`places[]`（`ctrl` 服务端 + `ctrlRaw` 本地）、`CaptureChainAnalyze` fallback、chain 路径 label「我方/对手」。`lastChainEvent` 不变（本来就是服务端座位）。

**`mySeat` 从哪来（`15:03:45` 版修复）**：对局/换备期间（`isInDuel || isStarted`）**以 `dInfo.isFirst` 为准**：`isFirst==true ⟺ 服务端座位 0`（`mySeat = isFirst ? 0 : 1`）。**MC 排位不保证发 `STOC_TYPE_CHANGE`**，且 launcher 用 `-d/-k` 会让 `-c/-j` 推断 fallback 失效——旧版在这种情况下 guest 会被错判成 seat 0（表现为 `lastChainEvent` 阵营反、`ctrl` 输出 0、`isMine` 全错）。核对方式：`MSG_START` 后看日志
```
SEAT resolved seat=%d isFirst=%d selftype=%d launch=%d
```
guest 应为 `seat=1 isFirst=0`、host `seat=0 isFirst=1`（`selftype` 依赖服务器是否发 TYPE_CHANGE，`launch` 是 `-c/-j` 推断值；两者都不是判定 seat 的依据）。

> 卡牌数组本身仍是 `[我方, 对手]` 的**本地索引顺序**；元素内部的 `ctrl/isMine` 才是服务端座位语义。判断敌我优先用 `isMine`（`ctrl==mySeat`），不要再靠卡名反查。


### 4.1 `/state`（完整快照，`Snapshot::Json`，~L1270）

**顶层局面**

| 字段 | 类型 | 说明 |
|---|---|---|
| `valid` | bool | 快照是否可用（未进对局时为 false） |
| `inDuel` | bool | `dInfo.isInDuel`：是否在决斗中 |
| `started` | bool | `dInfo.isStarted`：客户端认为决斗已开始。**注意与 `/health.started` 不同** |
| `turn` | int | 回合数 |
| `lp` | [int,int] | `[玩家0, 玩家1]` LP（按 server 座位） |
| `phase` / `phaseName` | int / string | 相位：`DRAW/STANDBY/MAIN1/BATTLE_START/BATTLE_STEP/DAMAGE/DAMAGE_CAL/BATTLE_END/MAIN2/END` |
| `curMsg` | int | 当前待响应的内核 MSG id（§5 表）；0/3 通常表示无待响应 |
| `seq` | int | prompt 序号，**动作必须匹配** |
| `awaiting` | bool | 是否有一个待响应 prompt |
| `myPlayer` | int | 本地视角（恒 0；对手是 1） |
| `mySeat` | int | 真实座位 0=房主、1=客人 |
| `playerType` | int | `dInfo.player_type`（原始值） |
| `turnPlayer` / `isMyTurn` | int / bool | 谁的回合 |
| `selftype` | int | 客户端自决类型（0=玩家…） |
| `winPlayer` / `winReason` / `winReasonName` | int/int/string | 赢家（-1 未定）；原因见下 |
| `chainMode` | int | 实际连锁时点：**0=all（显示时点）/1=avail（可用时点）/2=ignore（忽略时点）/3=normal（全不按，默认）** |
| `uiCleanupCount` | int | 动作后清理窗口的累计次数（诊断） |
| `ui` | object | §4.4 的同一份 UI 诊断 |
| `retryCount` / `retryStreak` / `lastRetryAfterMsg` | int | `MSG_RETRY` 统计（编码错了会飙升） |
| `placeVariant` | int | 选格坐标自愈变体（0..3，见 §5 `place`） |
| `deckMain` / `deckExtra` | int | 已载入牌组张数 |
| `lastMsg` | `{id,len,hex}` | 最近一条服务器消息原文 |
| `counts` | object | `hand/grave/remove/deck/extra`，各为 `[玩家0数, 玩家1数]` |
| `hand` / `monsters` / `spells` | Card[] | **本地视角**的手牌/怪兽/魔陷 |
| `grave` / `banished` | Card[][] | `[玩家0数组, 玩家1数组]` |
| `extraDeck` | Card[] | 我方额外（对手不可见） |
| `activeEffects` | string[] | 当前连锁栈的可读行（链结束清空，§6） |
| `continuousEffects` | Cand[] | 旧的持续效果列表（与链栈无关） |
| `timeLeft` | int | 剩余时间（毫秒，-1 未知） |
| `errorMsg` / `errorCode` | string/int | 客户端错误（如牌组非法） |
| `pipeline` | object | 管线诊断：`analyzeCount,pumpCount,msgCount,seq,awaiting,lastStoc,lastStocName,sinceLastAnalyzeMs,sinceLastPumpMs,retryCount,lastRetryAfterMsg,retryStreak,autoDismiss,dismissCount` |

**赢因**（`WinReasonName`）：`0 SURRENDER / 1 LP_ZERO / 2 DECK_OUT / 3 TIMEOUT / 4 DISCONNECT / 0x10+ 特殊胜利`
（`EXODIA / FINAL_COUNTDOWN / VENNOMINAGA / CREATORGOD / ...` 见代码常量表）。

**Card 对象（`hand/monsters/spells/grave/banished/extraDeck` 的元素）**

```json
{"code":84749824,"atk":0,"def":0,"pos":4,"faceup":false,"hidden":false,
 "ty":131072,"lv":0,"name":"神之警告","loc":8,"seq":0}
```

| 字段 | 说明 |
|---|---|
| `code` | 卡号（**用卡号判断卡，不要用名字**） |
| `atk` / `def` | 当前攻/守（覆盖卡值时以值为准） |
| `pos` | 表示形式位（`0x1` 攻表, `0x2` 守表, `0x4` 里侧, `0x8` 表侧…） |
| `faceup` / `hidden` | 是否表侧 / 是否对你是隐藏信息 |
| `ty` | 卡类型位（`0x1000` tuner, `0x2000` 同调, `0x800000` 超量, `0x4000000` 连接, `0x20000` 魔法/陷阱等） |
| `lv` | 等级/阶级 |
| `loc` | 位置：`0x01` 卡组, `0x02` 手牌, `0x04` 怪兽区, `0x08` 魔陷区, `0x10` 墓地, `0x20` 除外, `0x40` 额外 |
| `seq` | 该位置内的序号 |

### 4.2 `/prompt`（PromptJson，~L1168；`/wait_prompt` 返回体）

**计数与开关**

| 字段 | 含义 |
|---|---|
| `seq` / `curMsg` / `turn` / `awaiting` | 同 §4.1；`awaiting=true` 表示该答了 |
| `summonable` / `spsummonable` / `msetable` / `ssetable` | 通常召唤 / 特召 / 盖怪 / 盖魔陷 的候选数 |
| `reposable` / `activatable` / `attackable` | 可改表示形式 / 可发动 / 可攻击 数量 |
| `chains` | **历史遗留**：可连锁项数（与 §6 的 `chainStack` 无关，勿混） |
| `chainForced` | 连锁是否被迫（`canDecline` 的来源） |
| `lastChain` | 是否处于连锁中 |
| `selectMin` / `selectMax` / `selectCancelable` / `selectableCount` | 选卡 min/max、可否取消、可选张数 |
| `selectableCards[]` | 候选卡 `{i,code,atk,def,lv,position,loc,seq,seqNo,resp,ctrl,isMine,...}`（`15:18:21` 起含 `position`；`14:53:57` 起含 `resp`，`ctrl/isMine` 已修正）。**`i` 是列表下标（只给 `control_actions` 的 id 用）；响应字节用 `resp`（= `seqNo`，select_seq）：`hex="01"+resp hex`**（如 `resp=9` → `hex="0109"`）。首选 `control_actions` 的 `kind:"select_card"` id，不要手拼 hex |
| `isAttackTarget` | **`15:18:21` 起**：`MSG_SELECT_CARD && selectMax==1 && 战斗阶段` 时 `true`——这是"攻击目标窗"，必须用 `select_card` 按 `atk/def` 选，不要 `select_auto`/`id=0` |
| `awaitingSinceMs` | **仅 `awaiting=true` 时出现**：等待已持续毫秒；>45s 客户端打 `PROMPT idle warning`，默认 60s 自动兜底（`YGO_PROMPT_AUTO_DEFAULT_MS`，见 §8.1） |
| `announceNumberValues` | **仅 `MSG_ANNOUNCE_NUMBER(143)` 时出现**：可用数值列表（int32）；`/actions` 为每个值给一条 `kind:"announce_number"`，选中后响应 = **数值本身**（不是下标） |
| `canBp` / `canEp` | 可否进战阶 / 可否结束阶段 |
| `selectablePositions` | **仅 `MSG_SELECT_POSITION(19)` 时出现**：合法 POS **掩码**（`0x1` 表攻 / `0x2` 里攻 / `0x4` 表守 / `0x8` 里守 的按位或）；另带 `selectablePositionsHex`（如 `"0x5"`）。`/actions` 按该掩码**动态生成** position 动作；**单 bit 掩码时客户端自动应答、不弹窗口**（如只要守备 `0x4`） |
| `selectablePositionsHex` | 同上掩码的十六进制字符串（`"0x5"` / `"0x9"` 等），方便人/LLM 读 |
| `sumTarget` / `sumMode` | 素材合计目标值 / 合计方式（用于 `MSG_SELECT_SUM`） |
| `isFirst` / `placeCoords` | 是否先手 / 当前选格坐标口径（`server`\|`local`） |

**候选数组**（每个都是 Cand 对象，字段见表后）

`summonableCards / spsummonableCards / msetableCards / ssetableCards / activatableCards / attackableCards / selectableCards / chains`

```json
{"i":0,"code":53582587,"atk":0,"def":0,"loc":8,"seq":2,"seqNo":0,"op":0,
 "lv":0,"rk":0,"ty":131072,"desc":1142,"ctrl":1,"forced":false}
```

| Cand 字段 | 说明 |
|---|---|
| `i` | 该候选在**本数组**里的下标（与 `/actions` 的 index 对应，但 `/actions` 会重编 id） |
| `code` / `atk` / `def` / `lv` / `rk` / `ty` | 卡信息（`rk`=阶级） |
| `loc` / `seq` / `ctrl` | 位置/序号/控制者（`ctrl` 0=你 1=对手） |
| `desc` | 效果描述 id（`GetDesc` 可查文本；`/prompt.chainCandidates[].descText` 已带文本） |
| `forced` | 是否必发 |
| `op` / `seqNo` | 操作参数（少数 MSG 用） |

**选格与选项**

| 字段 | 说明 |
|---|---|
| `places` | `[{i,ctrl,loc,seq,bit}]`：可选的格子（`bit` 是该格在掩码里的位） |
| `placesMask` | 原始可选区域掩码（客户端已按规则做 `~` 与 swap，见 §5 `place`） |
| `options` | `int[]`：多效果/选项 id 列表（`MSG_SELECT_OPTION` 用） |

**链字段**：`chainDepth/chainStack/chainingTo/chainCandidates/canDecline/hint/lastChainEvent` 见 **§6**。

### 4.3 其它端点返回

| 端点 | 返回 |
|---|---|
| `/health` | `{"ok":true,"started":<控制服务是否在监听>}`（**不是对局状态**） |
| `/lobby` | `{self,isHost,launchSeat,ready:[r0,r1],bothReady,deckMain,statuses:[...]}`（`statuses` 是原始 HS 状态字节） |
| `/hs` | `{"statuses":[...]}`（同上，纯状态） |
| `/chat` | `{"chats":["..."]}`（服务器聊天/系统消息） |
| `/msg` | `{id,len,hex}`（最近一条服务器消息） |
| `/stoc` / `/ctos` | `{"packets":[int...]}`（最近包类型环，调试用） |
| `/ui` | §4.4 |
| `/uiclick?x&y` | `{"ok":true,"queued":true,"x":..,"y":..}` |

### 4.4 `/ui`（`UiJson`，~L1238）

```json
{"chainMode":1,"chainModeName":"avail",
 "alwaysChain":false,"chainWhenAvail":true,"ignoreChain":false,
 "desiredChainMode":1,"desiredChainModeName":"avail","appliedChainMode":1,"applyPending":false,
 "uiCleanupCount":37,"popupMask":0,
 "popups":{"posSelect":false,"options":false,"cardSelect":false,"cmdMenu":false,"message":false},
 "windows":[{"name":"wMessage","visible":false,"rect":{"l":0,"t":0,"r":0,"b":0},
             "x":0,"y":0,"w":0,"h":0,"textLen":-1}],
 "windowsVisible":["wChat"]}
```

| 字段 | 说明 |
|---|---|
| `chainMode` / `chainModeName` | **真实**连锁时点（从控件布尔反推）：`0=all（全部时点）` / `1=avail（全部可用时点）` / `2=ignore（无视所有时点）` / **`3=normal（常用时点，对局默认）`** |
| `alwaysChain` / `chainWhenAvail` / `ignoreChain` | 三个真实 bool（all / avail / ignore 的按钮状态）；**`normal` = 三个全 false**（实现细节：第 4 态没有单独按钮） |
| `desiredChainMode` / `appliedChainMode` / `applyPending` | 想要的 / 已应用的 / 是否待应用；`desiredChainMode` 同样支持 `3`（normal） |

**时点四态（官方行为语义；`normal` 为默认）**：

| 值 | 名称 | 行为语义 |
|---|---|---|
| 0 | **`all`**（全部时点） | 任何时候都给窗口，**不管有没有可用动作** |
| 1 | **`avail`**（全部可用时点） | **只要有合法动作就询问** |
| 2 | **`ignore`**（无视所有时点） | 不弹可选窗口、自动放弃；**但不会无视部分诱发效果**（强制/必发类仍会处理） |
| **3** | **`normal`**（常用时点，**默认**） | **`avail` 的基础上再过滤掉一些非常用的询问**（只问 spec/select-trigger 类窗口） |

> 实现对应（脚注，仅供排障）：auto-decline 门在客户端 `duelclient.cpp:1886`——`all` 永不放弃；`avail` 仅 `count==0`；`normal` 在 `count==0 || specount==0`；`ignore` 无条件（`forced` 除外）。旧版 `/ui` 曾把 `normal` 误报为 `avail`（≤11-23 14:53:57）。
> **`ignore` 不再吞我方诱发（`17:22:16` 起）**：`ignore` 的 auto-decline 现在会先看 `activatable_cards` 是否有 `controler==0`（我方）候选；有则**保留窗口正常弹 prompt**（`YGO_CHAIN_IGNORE_KEEP_OWN=1` 默认；`0`=旧行为）。日志 `CHAIN client auto-decline ... ownCand=.. ignoreDecline=.. keepOwn=..`。

| 其他字段 | 说明 |
|---|---|
| `popupMask` / `popups` | 五个主弹窗可见性（`posSelect/options/cardSelect/cmdMenu/message`） |
| `windows[]` | 17 个窗口的 `name/visible/rect{l,t,r,b}/x,y,w,h/textLen`（`textLen` 仅 `wMessage/wACMessage/wQuery` 有值，其余 -1；有正文时额外带 `text`（≤120 字）） |
| `windowsVisible[]` | 可见窗口名字数组（快速判空） |

> auto-decline 的判定在客户端 `duelclient.cpp:1886`（`count==0 || specount==0` 时放弃；`avail` 只看 `count==0`；`ignore` 无条件；`all` 永不）。`normal` 与 `avail` 的关键差异是**多了 `specount==0` 条件**，因此普通非常用询问会被过滤、只保留 spec/select-trigger 窗口（行为定义见上表）。

**设置与生效时机（`11:04:58` 版）**：
- 设置：`GET /ui?chain=all|avail|ignore|normal`（或 MCP 无对应工具时直接调 HTTP）；写 `desiredChainMode`。
- **`desiredChainMode` 立即变**；`real` 字段（`chainMode/chainModeName/alwaysChain/chainWhenAvail/ignoreChain`）在 apply 后**下一帧/≤1s** 刷新：`ApplyChainMode` 末尾立即更新 `g_shared` real 字段并置 `g_snapshotWanted`（修掉 guest 空闲时 `/ui` readback 旧值的问题）。
- **`/ui` 与 `/state.chainMode` 应一致**（guest 空闲切换后 150ms 首采样即正确；实测 28 采样 0 mismatch）。
- `applyPending=false` 表示已落地；若为 `true` 再等 ≤1s 重读。

窗口名（`CollectWindows`，~L669）：`wMessage wACMessage wQuery wSurrender wOptions wPosSelect wCardSelect wCardDisplay wANNumber wANCard wANAttribute wANRace wCmdMenu wHand wFTSelect wBigCard wChat`。

---

## 5. `/actions` 的 kind 全表

`BuildSemActions()`（~L2039）按 `curMsg` 生成候选，`EncodeSemAction()` 负责字节编码（LLM 不用管）。
`/actions` 返回 `{seq,curMsg,awaiting,actions:[{id,kind,label}]}`；**你只选 `id`**。

| `kind` | 出现场景（`curMsg`） | label 示例 | index/参数含义 |
|---|---|---|---|
| `summon` | `MSG_SELECT_IDLECMD`(11) | `summon #0 code=22835145 lv=2 tuner` | index=该数组下标，编码 `(index<<16)\|0` |
| `spsummon` | 11 | `special summon #0 code=81105204 lv=4` | `(index<<16)\|1` |
| `set_monster` | 11 | `set monster #0 code=22835145` | `(index<<16)\|3` |
| `set_spell` | 11 | `set spell/trap #0 code=53582587` | `(index<<16)\|4` |
| `activate` | 11 | `activate #0 code=5318639` | `(index<<16)\|5` |
| `to_bp` | 11（`canBp`） | `go to battle phase` | `6` |
| `to_ep` | 11 | `end phase` | `7` |
| `attack` | `MSG_SELECT_BATTLECMD`(10) | `attack #0 atk=1900` | `(index<<16)\|1` |
| `to_m2` | 10 | `go to main phase 2` | `2` |
| `end_battle` | 10 | `end battle phase` | `3` |
| `chain` | `MSG_SELECT_CHAIN`(16) | `chain #0 code=84749824` | `index` 直接回给内核（多效果卡再弹 option） |
| `decline` | 16 且 `!chainForced` | `do not chain` | `-1` |
| `yes` / `no` | `MSG_SELECT_YESNO`(13)/`MSG_SELECT_EFFECTYN`(12) | `yes` / `no` | `1` / `0` |
| `tp` | `STOC_SELECT_TP`（开局前，非 `curMsg`；`prompt.tpPending=true`） | `tp first (index=1)` / `tp second (index=2)` | 按 `id` 提交即发 `CTOS_TP_RESULT`：`index=1` 先攻 / `2` 后攻；仅 MCP 驱动时出现（手动或 `YGO_TP` 强制时客户端自动应答）。**19:05:42 版默认 2s 内自动答后攻（`res=2`，`YGO_TP_AUTO_RES` 可配）；13s 内必须有人答，否则服务端 `eof`** |
| `side_ok` | `STOC_CHANGE_SIDE`（Bo3 换备牌阶段；`prompt.sidePending=true`） | `keep side deck (no changes) and continue` | 按 `id=0` 提交 → UI 注入点 `btnSideOK`（= 真人"确定"，会 `SendUpdateDeck`）；仅 MCP 驱动时出现 |
| `option` | `MSG_SELECT_OPTION`(14) | `option #0`（另有一个兜底 `option 0`） | index=选项下标 → 直接回 |
| `select` | `MSG_SELECT_CARD`(15)/`SELECT_TRIBUTE`(20)/`SELECT_UNSELECT_CARD`(26) | `select first N card(s)` | 一次选前 N 张（N=`selectMin` 或 1）；**旧版只有这一条 → 永远选 selectable[0]** |
| `select_card`（15:18:21 起，单目标） | `MSG_SELECT_CARD`(15)/`SELECT_TRIBUTE`(20)/`SELECT_UNSELECT_CARD`(26) | `attack target: card #1 code=1500 atk=1500 def=1200 loc=4 seq=0` | **每个候选一条**，`index=i`；编码 `[1][候选 seqNo]`；**攻击目标必须用它按 atk/def 选** |
| `select_auto`（15:18:21 起） | 同上（`selectMin>1` 时只有它） | `select_auto` | 兜底：`[n][seqNo...]`；**单目标时等价旧 `id=0`（永远第一只）**，不要拿它打有对象的攻击 |
| `position` | `MSG_SELECT_POSITION`(19) | **按合法掩码动态生成 4 种**：`attack position (face-up ATK)` / `attack position (face-down ATK / set)` / `defense position (face-up DEF)` / `defense position (face-down DEF / set)` | **按 `label` 选即可**；**当前构建（`17:22:16`）action 项只有 `id/kind/label`，没有 `index` 字段**（`index` 自**下个 build（>17:22:16）**起提供）；POS 值由 `act_id` 内部按 label 编码（日志 `SEND RESPONSE realMsg=19 i=1/2/4/8`）。旧版写死 `defense=0x02`（=里侧攻击，非法响应导致 `seq` 连发）已修；`selectablePositions(Hex)` 只用于展示/校验 |
| `place` | `MSG_SELECT_PLACE`(18)/`MSG_SELECT_DISFIELD`(24) | `place bit=8 mask=0 ctrl=1 p0=1 seat=1 first=0 loc=8 seq=0` | index=places 下标；4 变体自愈（`placeVariant`） |
| `sum` | `MSG_SELECT_SUM`(23) | `auto-select materials` | 自动选素材 |
| `counter` | `MSG_SELECT_COUNTER`(22) | `auto-place counters` | 自动放指示物 |
| `sort` | `MSG_SORT_CARD`(25) | `keep current order` | 保持当前顺序（响应 = **裸位序字节、无长度前缀**，如 `hex=0001`；`20:11:00` 版起改直连字节、不再 UI fallback） |
| `announce_race` / `announce_attrib` / `announce_card` / `announce_number` | `MSG_ANNOUNCE_RACE(140)` / `ATTRIB(141)` / `CARD(142)` / `NUMBER(143)` | `announce race xxx` / `number 1000` 等 | 编码：**race/attrib=掩码、card=卡号、number=数值本身**（不是下标）；number 的候选见 `/prompt.announceNumberValues` |
| `auto` | 其它（如 `MSG_HINT`/`MSG_CONFIRM_*` 等） | `auto / safe default` | 安全默认（回 0 或空） |

**要点**

- `id` 是候选数组下标，**prompt 一变就重新编号**；`label` 只是给人/LLM 看的，不要解析出行为依赖。
- `kind` 是稳定语义；策略只判断 `kind` + `label`/卡号即可。
- `place` 的 `ctrl`/`loc`/`seq` 是客户端已按"本地半区"规则修正过的值；遇到 `MSG_RETRY` 客户端会自动换变体重试（`placeVariant`）。
- **`position`（`MSG_SELECT_POSITION`=19）**：合法位置来自该消息的**掩码**（`/prompt.selectablePositions` + `selectablePositionsHex`），`/actions` **按掩码动态生成**可选项；**当前构建（`17:22:16`）用 `label` 选**（action JSON 只有 `id/kind/label`，**无 `index`**），`act_id` 内部会按 label 发出正确 POS 值（`0x1` 表攻 / `0x2` 里攻 / `0x4` 表守 / `0x8` 里守，日志 `i=1/2/4/8` 可核对）——**不要用 1/2 猜**；`index` 字段自**下个 build（>17:22:16）**起提供。掩码单 bit（如 `0x4`）时客户端**自动应答**、不弹窗口；掩码常为 `0x1|0x4`（表攻或表守）→ 旧版固定送 `0x02`（里攻，不在掩码内）⇒ 服务器忽略并重发 prompt（`seq` 连发）。
- `MSG_SELECT_CHAIN` 的 `chain`/`decline` 与 §6 的 `chainCandidates[].index` **一一对应**。

---

### 5.5 Bo3 换备（side decking：`/state.side` + `/side_swap`）

Bo3 每两局之间，客户端进入换备牌阶段。**控制驱动模式下客户端不会自动点"确定"**，而是把状态暴露出来，
由 LLM 决定怎么换（也可以一张都不换，直接继续）。

**`/state.side`（换备阶段才有意义）**

```json
{"available":true,"pending":true,"waiting":false,"elapsedMs":0,"waitingSeen":false,"lastWaitMs":0,
 "main":[{"code":53582587,"name":"激流葬","count":2}],
 "extra":[], "side":[{"code":84749824,"name":"神之警告","count":1}],
 "counts":{"main":40,"extra":15,"side":15},
 "pre":{"main":40,"extra":15,"side":15},
 "limits":{"mainMin":40,"mainMax":40,"extraMax":15,"sideMax":15},
 "error":null,
 "note":"side decking: move cards with side_swap, then side_ok"}
```

| 字段 | 含义 |
|---|---|
| `available` | 客户端支持换备接口（新构建为 `true`；旧构建无此对象） |
| `pending` | `true` = 轮到我换备（此时 `/actions` 里有 `kind:"side_ok"`） |
| `waiting` | `true` = 我已确定、正在等对手换备（`pending=false`，客户端**不会退出**）。**瞬时值**：LAN 实测窗口 0–16ms（自己确认后同 tick 就收到下一局 `DUEL_START`），200ms 采样常常抓不到 |
| `waitingSeen` / `lastWaitMs` | **sticky**：本次换备是否等过对手 / 上次等待时长（保留到下次 `STOC_CHANGE_SIDE`）。**断言优先用这两个**（`waiting` 抓不到不代表没等过）。`lastWaitMs=0` = 自己是**最后确认**的一方（等 0ms，正常；对方先确认时才 >0） |
| `elapsedMs` | 正在 waiting 时已等待毫秒（不在 waiting 时为 0） |
| `main`/`extra`/`side` | 各池的卡（`code`/`name`/`count`），只能看到自己的 |
| `counts` | 当前张数 `{main,extra,side}` |
| `pre` | 进入换备前的张数（用于对比 "换了几张"） |
| `limits` | `{mainMin,mainMax,extraMax,sideMax}`：卡组下限/上限、额外上限、备牌上限 |
| `error` | 最近一次 `side_ok` 的校验错误（如 `counts must match`），成功为 `null` |
| `note` | 给 LLM 的可读提示 |

`/prompt` 同时带：`sidePending`、`sideSummary`（一行摘要）、`sideChooseBy`（如 `"act_id kind=side_ok id=0"`）、`sideError`。

**`/actions` 在 `sidePending` 时的返回（`side_ok` label 三态 + 顶格 `changed`）**：

```json
{"seq":12,"curMsg":0,"awaiting":true,"sidePending":true,
 "actions":[{"id":0,"kind":"side_ok",
             "label":"confirm side deck (changed) and continue"}],
 "changed":true,
 "counts":{"main":40,"extra":15,"side":15},
 "sideError":null}
```

> **字段位置**：`changed`/`counts`/`sideError` 是 `/actions` 返回对象的**顶格字段**（与 `actions[]` 同级），**不在 `actions[0]` 元素里**；action 元素只有 `id/kind/label`（label 三态见下表）。

| 字段 | 含义 |
|---|---|
| `label` | **三态文本**：① `keep side deck (no changes) and continue`（没换过）② `confirm side deck (changed) and continue`（换过）③ `counts mismatch: fix main/extra/side counts before confirming`（张数与 `pre` 不一致，不能 done） |
| `changed`（顶格） | **本轮换备窗口内是否真的换过牌**（`/side_swap` 成功 → `true`；每个新换备窗口复位 `false`）。**`counts` 相等 ≠ 没换牌**（合法互换后 main/extra/side 仍守恒），判断"我的换牌生效没有"用 `changed` |
| `counts`（顶格） | 当前 `{main,extra,side}` 张数 |
| `sideError`（顶格） | `"counts must match"` 等校验错误；有值时**先修正张数再 `side_ok`** |

> 旧版（≤ `2026-11-27 15:03:45`）`label` 是写死的 `"keep side deck (no changes) and continue"`（task-35/36 遗留字面量），即使已经换过牌也不变 → 与同 JSON 的 `counts` 矛盾，LLM 会误以为没生效而**重复换牌**（把 40/15/15 换重）。看到 `no changes` 但 `changed:true` = 旧版 label bug，升级即可；用 `changed` 判断。

**`POST /side_swap?code=<卡号>&from=side|main|extra&to=main|extra|side&n=1`**
移动 N 张同卡号：
- 成功：`{"ok":true,"queued":true,"main":<m>,"extra":<e>,"side":<s>}`（**预测值**；可再读 `/state.side.counts` 确认）
- 失败：`{"ok":false,"error":"<可读原因>"}`，例如 `not enough copies in side (have 1, need 2)`、`from/to must be main|extra|side`
- 客户端日志：`SIDE swap code=.. from=.. to=.. n=.. -> counts m/e/s=..`
- 允许方向（**双向**）：`side→main`、`side→extra`、`main→side`、`extra→side`；**只在 `side.pending` 时有效**

**`side_ok`（= MCP `control_side_done()`，等价点 `btnSideOK`）**
- **拒绝可靠**（不会误点）：
  - counts 与 `pre` 不一致 → `{"ok":false,"error":"counts must match","sideError":"counts must match"}`，日志 `SIDE ok rejected reason=counts must match` / `(exec-time)`
  - swap 还没在 UI 线程落地 → `{"ok":false,"error":"side swap pending, retry"}`；side prompt 尚未发布且没有 pending → `{"ok":false,"error":"side prompt not published yet, retry"}`
  - 收到 `retry` 类错误：等 100–300ms 重试（先读 `/state.side.counts` 确认已生效）
- 合法：`{"ok":true,"queued":true,"kind":"side_ok"}` → 点 `btnSideOK` → `SendUpdateDeck`，日志 `SIDE ok clicked (from control)`，随后进入下一局（会再走 `DUEL_START reset result state` + TP）
- 建议顺序：**swap 后先读 `/state.side.counts` 与目标一致，再 `side_ok`**（避免刚 swap 就 done）

**推荐顺序（LLM 侧）**

1. `control_state()` → 看 `side.pending`；不是换备阶段就照常打牌；
2. 需要换牌：反复 `control_side_move({code, from, to, n})`（对照 `side.counts` + `side.limits`，先换出再换入）；
   **每次成功后可再 `control_state()` 一次**确认 `side.counts`；
3. 换完（或决定不换）：`control_side_done()`（= `side_ok`）→ 客户端校验 `SendUpdateDeck`，进入下一局；
   若返回 `counts must match` → 按 `side.counts/limits` 调整后再 done；
4. 若 `side.waiting=true`：**等对手**（可能很慢，日志每 10s 打 `SIDE waiting for opponent (elapsed=..ms)`）。
   这**不是失败**，不要重复调 `control_side_done()`；期间用 `/net` 判链路：`alive=false` 或
   `sinceLastStoc` 长时间增长 → 按重连流程处理（见 [`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md)）。
   注意 `waiting` 是**瞬时值**（LAN 常为 0–16ms），事后判断用 **`waitingSeen` / `lastWaitMs`**；
5. 参考策略 `policy-semantic.mjs` 在换备阶段会**直接选 `side_ok`（不换备）**；LLM 要真换牌就用上面两个工具，
   不要同时跑参考策略（避免抢动作）。

> `/side_swap` 在非换备阶段会返回错误；`side_ok` 校验失败只改 `side.error`，不会让客户端退出。

---

### 5.6 整场结果（`/state.match` + `control_match`）

LLM 想回答"**我赢了吗/为什么赢/大比分多少/比赛结束没**"时，**优先用 `control_match`**（`GET /state` 派生），不要自己从 `winPlayer` 推。

**`/state.match`（新客户端提供；旧客户端没有这个对象）**

```json
{"game":2,"over":true,
 "games":[{"game":1,"win":true,"winnerSeat":0,"reason":1,"reasonName":"LP_ZERO"},
          {"game":2,"win":true,"winnerSeat":0,"reason":4,"reasonName":"DISCONNECT"}],
 "gamesWonLocal":2,"gamesWonOpp":0,
 "lastWinnerLocal":true,"lastReasonName":"DISCONNECT"}
```

| 字段 | 含义 |
|---|---|
| `game` | 当前第几局（1 起） |
| `over` | 整场是否结束（Bo3 某一方到 2 胜） |
| `games[]` | 逐局结果：`win`(bool，本地视角你赢没赢)、`winnerSeat`(raw 座位号 0/1)、`reason`(原始 enum)、`reasonName`(原名) |
| `gamesWonLocal` / `gamesWonOpp` | 大比分（你 / 对手）；缺失时 `control_match` 会按 `games[]` 计数 |
| `lastWinnerLocal` / `lastReasonName` | 最后一局你是否赢 / 原因原名（`LP_ZERO` 等） |

**原因翻译（`control_match` 自动做）**

| 原名 | 你赢时 | 你输时 |
|---|---|---|
| `SURRENDER` | 对手投降 | 你投降 |
| `LP_ZERO` | 对手 LP 归零 | 你 LP 归零 |
| `DECK_OUT` | 对手抽卡耗尽 | 你抽卡耗尽 |
| `TIMEOUT` | 对手超时 | 你超时 |
| `DISCONNECT` | 对手掉线/失联 | 你掉线/失联 |
| 其它 | 原样输出 | 原样输出 |

**`control_match` 返回**

```json
{"match": { "...原样 /state.match..." : "..." },
 "summary": "比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）"}
```

`summary` 覆盖 4 种状态：
- 未开局 → `还没有开始对局`
- 进行中 → `第 2 局进行中；当前大比分 1:0（你领先）`
- 某局刚结束（局间/换备） → `第 1 局：你赢了，原因 LP_ZERO（对手 LP 归零）；当前大比分 1:0（你领先）`
- 整场结束 → `比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：…` / `比赛结束：你输了这场 Bo3（0:2）。…`

**旧客户端降级**：没有 `state.match` 时返回 `{"match":null,"fallback":true,"summary":"..."}`，summary 用当前局字段（`inDuel`/`winPlayerLocal`/`winReasonName`）尽力表达（如 `第 1 局进行中（旧客户端无整场汇总，turn 7）`、`本局：你赢了，原因 LP_ZERO（对手 LP 归零）`），**不会报错**。
`control_state` 的返回里保留原样 `match`（透传），但要"给用户/自己报结果"时用 `control_match`。

### 5.7 掉线检查（`/net` + `control_net`）

**什么时候调**：长回合、对手长考、换备等对手、任何"感觉卡住了"的时候——**建议每 15–30s 调一次 `control_net`**（客户端自身 `net.heartbeat` 日志也是 15s 一条）。掉线检测不要只依赖客户端判死：`clockRunning` 用的 `g_timeLeft` 过期时，被动静默豁免可能永远成立（poc 修复中），所以 LLM 要自己看。

**返回字段**（`GET /net`）：

| 字段 | 含义 / 典型值 |
|---|---|
| `connected` / `joined` | `true/false`：TCP 已连 / 已进房 |
| `inDuel` / `turn` | 对局中 / 当前回合 |
| `alive` | `true`（正常）/ `false`（判定死亡）；**只信这个 + `state`** |
| `state` | `healthy`（正常）/ `idle`（未连）/ `probe_failed`（探活失败但未判死，`11:31:00+` 正常现象）/ `confirmed_dead`（被动静默判死）/ `disconnected`（socket 断）/ `unsupported` |
| `closeReason` | `none` / `eof`（服务端 FIN）/ `error`（socket 错误）/ `stop`/`exit`（我们主动）/ `unknown` |
| `lastStocAt`/`lastStocName`/`sinceLastStoc` | 最近服务器消息时间/名字/距今 ms（`-1`=没有；`STOC_DUEL_END` 表示整场结束） |
| `probe` | `{enabled,unsupported,lastSentAt,lastReplyAt,rttMs,fails,lastReplyPlayerType,lastReplyText}`：`fails` 涨只降级状态（`probe_failed`），**不单独判死** |
| `lastNetMsg` | `{id,text,ageMs}` 最近一条系统消息（`STOC_CHAT`） |
| 诊断（新 build） | `ourTurn`/`oppTurn`/`timeLeft`/`clockFresh`：看门狗诊断；`timeLeft` 是客户端认为的我方剩余秒数，`clockFresh` = 该值是否在 3s 内刚刷新（`false`=旧值，**不构成豁免**） |
| **stall 诊断（`15:34:59` 起）** | **`stallMs`** = 对局中无入站 STOC 的毫秒数；**`oppTimeLeft`** = 对手剩余时间；**`oppClockFresh`** = 对手倒计时是否 3s 内刚刷新。**`stallMs>120000 && oppClockFresh=false` = 对方客户端/服务端卡住**（不是我们掉线，也不是对手长考）→ 离桌重排。日志 `NET STALL since=.. awaiting=.. ourTurn=.. oppClockFresh=.. oppTimeLeft=.. state=..`（`YGO_STALL_WARN_MS` 默认 120000，每 30s，仅诊断不影响判死） |
| `net.heartbeat` | 客户端日志 `NET heartbeat alive=.. state=.. since=.. ourTurn=.. oppTurn=.. awaiting=.. timeLeft=.. clockFresh=..`；**只在空闲（`since>10s`）时每 15s 打一次**，连续操作/有包时不打——这是看门狗诊断日志，不是故障（要"无条件定时心跳"需后续版本加） |

**怎么判**：

| 观察 | 结论 | 动作 |
|---|---|---|
| `alive=true` 且 `state=healthy/idle` | 连接正常 | 继续等/正常对局 |
| `state=probe_failed`、`alive=true` | 探活失败但未判死（`11:31:00+` 正常） | 不用处理；继续观察 |
| `alive=false` 或 `state=confirmed_dead` | 被动静默判死（`sinceLastStoc` 超阈值） | 存证 → 中止本场 → `/leave` 重排 |
| `state=disconnected`（`closeReason=eof/error`） | 真实断线 | 中止本场；可选 `/join` 同房重连（有 journal） |
| `lastStocName=STOC_DUEL_END` | 对局正常结束 | 用 `control_match` 报结果，`/leave` 重排 |
| `sinceLastStoc` 持续增长但 `alive=true` | 对手在长考/长展开 | 继续等（不是掉线），每 15–30s 再看 |

> 注意：`NET DEAD reason=probe-fails` 只存在于旧版；当前版（`11:31:00+`）死因只有**真实断开**（`eof`/`error`）或**被动静默**（`idle-no-packet`）。`NET DEAD reason=idle-no-packet` 的 `since`/`eff` 在客户端日志里。
> **不要**再长期设 `YGO_NET_DEAD_SILENCE_MS=600000`（真掉线要 10 分钟才发现；probe 误判已修）。默认 **60000** 即可，最多 120000；`17:33:31` 版起看门狗用 `clockFresh`（3s 内刷新才算"倒计时在走"），`our-turn-idle` 不再因过期 `g_timeLeft` 永远豁免。

**旧客户端降级**：没有 `ourTurn/oppTurn/timeLeft/clockFresh` 时按 `alive`+`state`+`sinceLastStoc`+`closeReason` 判断。

### 5.8 离桌（`control_leave`，`POST /leave`）

**语义**：干净离开当前房间/对局，回到主菜单；释放本桌（服务端立即知道我们走了，不再等对局结算）。

**什么时候用**：
- **卡住时优先于 `control_surrender`**：`control_net` 显示 `stallMs>120000 && oppClockFresh=false`（对方客户端/服务端卡住）、或确认无法继续（对手掉线且不会回来）→ **`control_leave` 立即离桌重排**；
- `surrender` 会让本场结果**按规则结算完**（还要等 `STOC_DUEL_END`/换备等），`leave` 直接释放、更快重排；
- 正常整场结束（`STOC_DUEL_END`）后也可以直接 `leave` 收尾。

**不要用**：对局还有救、只是对手在长考（`oppClockFresh=true`）——离桌等于放弃本场。

**返回**：`{"ok":true,"queued":true}`（客户端会关对局/回主菜单；随后用 `control_state`/`control_net` 确认 `inDuel=false`、`joined=false`，再重新排队）。

**注意**：`leave` 虽然立即生效，但服务端可能仍把本场记为你的离场（与 surrender 的结算不同）；排位连续跑可用它跳过卡死桌、重排下一场。

### 5.9 `control_wait_prompt` 的正确语义（BUG-2，`14:53:57` 已修）

**设计语义（现版本已实现）**：`wait_prompt(since=上一个 seq)` **阻塞到"新的且 `awaiting=true`"的 prompt**（`seq>since && awaiting`）；超时则返回当前最新快照。它只用来"等下一个要你回答的窗口"。

**旧版行为（≤ `15:34:59`，已修）**：`awaiting=false`（对手回合/连锁在对方）时**不会阻塞**，而是**立刻返回上一份旧快照**。具体表现：`r.seq` 重复、`chainDepth` 等字段是旧的，而同一秒 `/state` 已经推进（`chainDepth` 1→2→3、`awaiting=true`）。升级后不再出现。

**正确用法（无论版本都建议）**：
| 目的 | 用什么 |
|---|---|
| **判断进度 / 当前真实状态** | `control_state` 或 `control_actions`（**新鲜**；`control_actions.seq` 才是该回的 seq） |
| 想"轮询看看" | `control_prompt`（**非阻塞**快照） |
| 想"等下一个决策点" | `control_wait_prompt(since=已处理的 seq, timeout_ms)`；`14:53:57` 起会阻塞到新 `awaiting`；**拿到返回值后仍可用 `control_actions` 核对 seq/kind** |
| 不要做 | 用旧版 `wait_prompt` 的快照判断"链推进到哪了/对手做了没有"；把重复 `seq` 当"没变化" |

**回动作的 seq**：用 `control_actions` 返回的 `seq`（与 `control_prompt` 一致），不要用旧快照的 seq；`control_act` 用旧 seq 会被拒（`stale seq`）。

**超时**：`timeout_ms` 到点返回当前最新快照（可能仍 `awaiting=false`），这是正常的"没轮到你"，不是错误。

### 5.10 调用节奏（机械约束；`240s` 回合时钟的玩法策略见 PLAYBOOK §3.13）

本节只说"接口层面怎么调不浪费往返"，不规定打法；完整的打牌纪律（先规划、批量查卡、每回合只读一次状态、机械步骤一次做完）在 `PLAYBOOK-FULL.md` §3.13 与 skill `ygopro-play` 的"打牌纪律 / 时间预算"。

| 约束 | 原因 |
|---|---|
| 不要在 `awaiting=false` 时 tight-loop 调 `control_wait_prompt` | `14:53:57+` 会阻塞到下一个待答窗口；重复调用只会白等，不能当轮询用（轮询用 `control_prompt`） |
| `control_state` 每回合开头读 **1 次**即可 | 返回是**全量** JSON（空场 3.7KB，对局中约 10–25KB；传输本身 15–30ms，但**LLM 分析这个 JSON 要 3–10s**）；之后用 `control_actions`/`control_prompt` 的小返回即可 |
| 判进度看 `control_state`/`control_actions`，不看 `wait_prompt` 返回值 | 后者只代表"最近一次发布"，旧版还会立刻返回旧快照（BUG-2） |
| 机械步骤（召唤→摆位→表示形式→攻击宣言）连续 `control_act_id`，不要每步再读一次状态 | 每步都读状态是 TIMEOUT 的主要来源（实测 240s 被耗尽判负） |
| 卡牌资料一次批量查（`card.py A B C`），中途不查 | 同上；卡组文档应在开局前读完 |

### 5.11 延迟模型：为什么有时"MCP 很慢"

**结论先说：MCP 传输本身几乎不耗时；感知到的"慢"来自 ①`control_wait_prompt` 的阻塞语义、②LLM 自己的推理往返、③服务端/对手的节奏。**

实测（2026-11-25，本机空场客户端；`mcp-server.mjs` 常驻进程 + HTTP 控制层）：

| 层 | 实测耗时 | 备注 |
|---|---|---|
| MCP stdio 工具往返（`control_actions`/`control_prompt`/`control_net`/`control_state`） | **2–4 ms**（首调用 34ms 冷启动） | 常驻进程，**不会**每次调用重启；这点不慢 |
| 控制层 HTTP（`/prompt` `/actions` `/net` `/ui`） | 13–22 ms | 本机 loopback |
| 控制层 HTTP（`/state`） | 13–54 ms（均值 27ms） | 负载大一点，仍毫秒级 |
| **`control_wait_prompt`** | **0 → timeout**（实测 timeout=5000 → 5006ms 返回） | **按设计阻塞**：等到"新的、`awaiting=true`"的 prompt 才返回；没有待答窗口就一直等到 `timeout_ms`。**这是"等下一次询问"，不是卡死** |
| LLM 每次工具调用的模型往返 | 3–10 s | 真正的最大开销；240s 回合≈30 次调用的来源 |
| 发出动作 → 下一个 prompt 出现 | 取决于服务端/对手（几十 ms ~ 数秒） | 我们 `act` 只是把响应排进 UI 队列（约 1 帧内发出），之后要等服务端推下一条 `STOC_GAME_MSG`；这期间 `wait_prompt` 会一直等 |

**怎么用才不觉得慢**：

- 想要"停一下，等下一次问我" → `control_wait_prompt(since=已处理 seq, timeout_ms=10000~30000)`；**等待时间是玩法节奏，不是接口问题**；超时返回 `awaiting=false` 属正常。
- 想要"看看现在什么情况" → `control_prompt`（非阻塞、约 700B、2–3ms）。
- 不要用 `wait_prompt` 轮询；也不要把它的长耗时当成掉线/卡死（判掉线看 `control_net` 的 `alive/state/stallMs/oppClockFresh`）。
- `timeout_ms` 不要超过 MCP 客户端的工具超时（DSH profile 里 `toolCallTimeoutMs: 180000`），否则客户端先报错。

---

## 6. 连锁设计（重点）

> 本节整合附录 [`MCP-INTERFACE-poc.md`](MCP-INTERFACE-poc.md) 的 B 节；细节以该附录为准。

### 6.1 数据从哪来（决定"你看到的链"是什么）

| 数据 | 来源 | 生命周期 |
|---|---|---|
| `dField.current_chain` | `MSG_CHAINING(70)` | 每来一次覆盖：`chain_card/code/desc/controler/location/sequence/solved/target` |
| `dField.chains` | **`MSG_CHAINED(71)`** 时 `push_back(current_chain)` | 已"成立"的环；`MSG_CHAIN_SOLVING(72)` 给对应环打 `solved`；`MSG_CHAIN_END(74)` 清空 |
| `dField.activatable_cards[]` + `activatable_descs[i]={desc,flag}` | `MSG_SELECT_CHAIN(16)` | 本次可连锁的候选；`flag & 0x100` = 强制，`EDESC_OPERATION` = 操作类 |
| `dField.chain_forced` | 同上 | `canDecline = !chain_forced` |
| `dField.select_hint` / `MSG_HINT(2)`（`HINT_SELECTMSG`） | 提示 | → `hint`（可能为空或滞后，仅供理解） |
| `GetName(code)` / `GetDesc(desc)` | 卡名/效果文本 | → `name` / `descText`（有兜底） |

> ⚠️ **关键口径**：`MSG_CHAINING` 只填 `current_chain`，**不立刻入栈**；真正入 `chainStack` 是在 `MSG_CHAINED`。
> 所以"提示你选连锁"的那一刻，`chainStack` 里是**已经成立的环**；当前正在发动/被连锁的那一环由
> `chainingTo` / `lastChainEvent` 体现。

### 6.2 字段定义（`/prompt` 与 `/state` 同名，`AppendChainJson()` ~L404）

| 字段 | 类型 | 含义 |
|---|---|---|
| `chainDepth` | int | 已成立的连锁环数（= `dField.chains.size()`），无链 0 |
| `chainStack[]` | array | 按成立顺序（link 1..N）：`{link,code,name,desc,descText,ctrl,loc,seq,type,forced,isMine,solved,summary}` |
| `chainingTo` | object\|null | 当前在回应哪一环：`{link,code,name,descText,summary}`；无链 `null` |
| `chainCandidates[]` | array | 本次 `MSG_SELECT_CHAIN` 的可选连锁项：`{index,code,name,desc,descText,forced,isMine,ctrl,loc,seq,summary}`；**`index` 就是 `/act_id` 里 `kind=chain` 候选的 index** |
| `canDecline` | bool | 可否不连锁（`!chain_forced`）；为 true 时 `/actions` 里有 `decline` |
| `hint` | string | 本 prompt 可读提示（`select_hint` 或 `HINT_SELECTMSG`），可为空/滞后 |
| `lastChainEvent` | string | 最近连锁事件可读文本：`我方/对手发动 [卡名]（效果）→ 连锁`、`连锁成立: [卡名]`、`连锁结算: [卡名]`、`连锁结束（清空）` |
| `/state.activeEffects[]` | string[] | 当前链栈的可读行（每环一条 `summary`），`MSG_CHAIN_END` 后清空 |
| `/state.continuousEffects[]` | Cand[] | 旧"持续效果"列表（与链栈无关） |

**文本兜底**：`descText` = `GetDesc(desc)` → 空则按 `chain_card` 回查 `activatable_descs` → `chain_card->cHint` → 兜底 `"<卡名> 的效果"`；`name` 未知卡兜底 `#<code>`。

**已知实现细节（LLM 必读，别踩）**

- `chainStack[].forced` **目前恒为 false**（环成立后客户端不再保留 forced 标志）；判断"必须连锁"请用 `canDecline` + `chainCandidates[].forced`。
- `type` 固定 `"effect"`（暂未区分 operation/reset）。
- `/state` 与 `/prompt` 的链字段来自 UI 线程快照，**可能比最新消息滞后约 1 帧**；要精确以 `chainStack` 为准。
- 历史遗留字段仍在：`/prompt.chains`（数量）、`chainForced`、`chainList[]`（code/seq）。**新代码只读 canonical 字段**。

### 6.3 单链决策示例（**真实样本**，exe 22:00:40 抓取）

场景：turn 4，双方 LP 6000/6000，`神之警告` 已成立（depth=1），轮到我方决定是否连锁。

`/prompt` 关键片段（真实数据，`ranked/logs/trap-EVIDENCE-84749824-chainStack.json`）：

```json
{
  "seq": 35, "curMsg": 16, "turn": 4, "awaiting": true,
  "chainDepth": 1,
  "chainStack": [
    {"link":1,"code":84749824,"name":"神之警告","desc":0,"descText":"",
     "ctrl":1,"loc":8,"seq":0,"type":"effect","forced":false,"isMine":true,
     "solved":false,"summary":"我方[神之警告] 已加入连锁"}
  ],
  "chainingTo": {"link":1,"code":84749824,"name":"神之警告","descText":"","summary":"我方[神之警告]"},
  "chainCandidates": [],
  "canDecline": true,
  "hint": "请选择要作为同调素材的卡",
  "lastChainEvent": "连锁成立: [神之警告]"
}
```

`/state.activeEffects` 同时刻：
```json
["我方[神之警告] 已加入连锁"]
```

> 注：该抓取来自 descText 修复前的版本（`descText=""`）；22:00:40 版对同样场景会给出如
> `"descText":"支付2000LP发动……"`。另见真实样本 `ranked/logs/ui-smoke-chainstack-descText.json`：
> `{"code":73652465,"name":"黑羽-突风之颪","descText":"改变表示形式", ...}`。
> `hint` 是 best-effort，可能残留上一条提示——**不要把它当强约束**。

**LLM 决策**：`chainCandidates` 为空 + `canDecline=true` → 只能 `decline`（选 `kind="decline"` 的动作）。

### 6.4 多链推演示例（depth=1 → 2 → 3，**推演，非实测**）

> 目前**只实测到 depth=1**（`神之警告`、`突风之颪`、`急袭猛禽-武力林鸮` 等多次，均 `chainDepth=1`）。
> 下面 3 环序列是按客户端消息语义**推演**的：字段格式真实，数值/卡名是构造的。

设 A 发动 → B 连锁 → C 连锁（共 3 环），每加一环都会给需要决定的一方发一次 `MSG_SELECT_CHAIN`：

**① A 的 `MSG_CHAINING`/`CHAINED` 之后，轮到 B（depth=1）**

```json
{"seq":101,"curMsg":16,"chainDepth":1,"canDecline":true,
 "chainStack":[{"link":1,"code":53582587,"name":"激流葬","descText":"场上怪兽全部破坏",
   "ctrl":1,"loc":8,"seq":2,"type":"effect","forced":false,"isMine":false,"solved":false,
   "summary":"对手[激流葬]（场上怪兽全部破坏） 已加入连锁"}],
 "chainingTo":{"link":1,"code":53582587,"name":"激流葬","descText":"场上怪兽全部破坏","summary":"对手[激流葬]"},
 "chainCandidates":[{"index":0,"code":84749824,"name":"神之警告","descText":"支付2000LP发动……",
   "forced":false,"isMine":true,"ctrl":0,"loc":8,"seq":0,
   "summary":"我方[神之警告]（支付2000LP发动……） 可以连锁 对手[激流葬] — 可选"}],
 "lastChainEvent":"对手发动 [激流葬]（场上怪兽全部破坏）→ 连锁"}
```
→ B 选 `chainCandidates[0]`：`control_act_id({id:<kind=chain, index=0 的动作 id>})`

**② B 的 `CHAINED` 之后，轮到 A（depth=2）**

```json
{"seq":103,"curMsg":16,"chainDepth":2,"canDecline":false,
 "chainStack":[
   {"link":1,"code":53582587,"name":"激流葬","descText":"场上怪兽全部破坏","ctrl":1,"loc":8,"seq":2,
    "forced":false,"isMine":false,"solved":false,"summary":"对手[激流葬]（场上怪兽全部破坏） 已加入连锁"},
   {"link":2,"code":84749824,"name":"神之警告","descText":"支付2000LP发动……","ctrl":0,"loc":8,"seq":0,
    "forced":false,"isMine":true,"solved":false,"summary":"我方[神之警告]（支付2000LP发动……） 已加入连锁"}],
 "chainingTo":{"link":2,"code":84749824,"name":"神之警告","descText":"支付2000LP发动……","summary":"我方[神之警告]"},
 "chainCandidates":[{"index":0,"code":73652465,"name":"黑羽-突风之颪","descText":"改变表示形式",
   "forced":true,"isMine":true,"ctrl":0,"loc":4,"seq":1,
   "summary":"我方[黑羽-突风之颪]（改变表示形式） 必须连锁 我方[神之警告] — 必发"}],
 "lastChainEvent":"我方发动 [神之警告]（支付2000LP发动……）→ 连锁"}
```
→ `canDecline=false`（必发）→ 只能选 `chainCandidates[0]`

**③ C 的 `CHAINED` 之后，轮到 B（depth=3），B 不连锁 → 结算**

```json
{"seq":105,"curMsg":16,"chainDepth":3,"canDecline":true,
 "chainStack":[
   {"link":1,"code":53582587,"name":"激流葬","descText":"场上怪兽全部破坏","solved":false},
   {"link":2,"code":84749824,"name":"神之警告","descText":"支付2000LP发动……","solved":false},
   {"link":3,"code":73652465,"name":"黑羽-突风之颪","descText":"改变表示形式","solved":false}],
 "chainingTo":{"link":3,"code":73652465,"name":"黑羽-突风之颪","descText":"改变表示形式","summary":"我方[黑羽-突风之颪]"},
 "chainCandidates":[],
 "lastChainEvent":"我方发动 [黑羽-突风之颪]（改变表示形式）→ 连锁"}
```
→ `decline` → `MSG_CHAIN_SOLVING/SOLVED` 按 **LIFO：C→B→A** 逐个 `solved=true`
→ `MSG_CHAIN_END`：`chainDepth=0`、`chainStack=[]`、`chainingTo=null`、`/state.activeEffects=[]`、`lastChainEvent="连锁结束（清空）"`

**时序速查**

| 事件 | `chainDepth` | `chainStack` | `chainingTo` | 谁要做决策 |
|---|---|---|---|---|
| A 的 `MSG_SELECT_CHAIN`（给 B） | 0 或已成立数 | `[]` 或已成立环 | `null` 或最后一环 | B 选候选/放弃 |
| A 的 `CHAINED` 后 | 1 | `[A]` | A | — |
| B 的 `SELECT_CHAIN` | 1 | `[A]` | A | B 选候选/放弃 |
| B 的 `CHAINED` 后 | 2 | `[A,B]` | B | — |
| C 的 `CHAINED` 后 | 3 | `[A,B,C]` | C | 下一方选/放弃 |
| `CHAIN_SOLVING/SOLVED` | 3 | `solved` 逐个 true | C（最后环） | — |
| `CHAIN_END` | 0 | `[]` | `null` | — |

### 6.5 给 LLM 的连锁决策规则（可直接照做）

1. **只在 `curMsg==16` 时读 `chainCandidates`**；其它 `curMsg` 下该数组可能为空/过期。
2. `chainCandidates=[]` 且 `canDecline=true` → 只能 `decline`。
3. 想加一环 → 选 `kind="chain"` 且 `index == chainCandidates[i].index` 的那个动作。
4. `canDecline=false` 或 `chainCandidates[i].forced=true` → **必须选**，不要放弃（放弃会 `MSG_RETRY`）。
5. 判断"值不值得连锁"：结合 `candidate.descText/summary`、`/state.lp/turn/phase`、`chainingTo` 是谁。
6. `chainDepth>0` 但 `curMsg` 已不是 16（而是 72/74 等）→ 链在结算/结束，别再引用旧候选。

---

## 7. UI 注入设计（"所有操作经 UI"）

> 本节整合附录 [`MCP-INTERFACE-poc.md`](MCP-INTERFACE-poc.md) 的 A 节；代码位置以该附录的行号表为准。

### 7.1 两条注入通道

**按钮**（`ClickButton()`，~L697）

```cpp
irr::SEvent ev;
ev.EventType = irr::EET_GUI_EVENT;
ev.GUIEvent.EventType = irr::gui::EGET_BUTTON_CLICKED;
ev.GUIEvent.Caller = btn;
mainGame->device->postEventFromUser(ev);          // 默认
// YGO_UI_EVENT_DIRECT=1 → mainGame->device->getEventReceiver()->OnEvent(ev);
```

**鼠标**（`InjectMouse()`，~L721）：`EMIE_MOUSE_MOVED` → `EMIE_LMOUSE_PRESSED_DOWN` → `EMIE_LMOUSE_LEFT_UP`，
`MouseInput.X/Y` 为屏幕像素，同样 `postEventFromUser`（或 `OnEvent`）。**不动系统光标**。

### 7.2 坐标换算（关键：`curPos` 不是屏幕坐标）

- 投影：`getScreenCoordinatesFrom3DPosition(worldPos, activeCamera)`（`WorldToScreenPos()`，~L769）
- 卡片：`worldPos = card->curPos`
- 格子：按 `ClientField::GetCardLocation()`（`client_field.cpp:865-905`）算中心：
  - MZONE: `X=(vFieldMzone[b][s][0].X+[1].X)/2`、`Y=([0].Y+[2].Y)/2`、`Z=0.020`
  - SZONE: 同式（带 `[rule]`）、`Z=0.01`
  - `b` 是**本地半区**（0=自己/下方，1=对手/上方），取自 `f.selectable_field` 的 bit 半区，**不要**再做 server→local 映射
- 早期错误实现（已修）：把 `curPos` 当虚拟坐标再 `Resize(x,y)` → 点全错。

### 7.3 动作 → 控件映射

| kind | UI 路径 |
|---|---|
| `yes`/`no` | 点 `btnYes`/`btnNo`（淡出后统一发送） |
| `position` | 点 `btnPSAU/PSAD/PSDU/PSDD` |
| `to_bp`/`to_m2`/`to_ep`/`end_battle` | 点 `btnBP`/`btnM2`/`btnEP` |
| `option` | 点 `btnOption[i]` |
| `decline` | 点 `btnCancelOrFinish` → `btnNo` |
| `chain`/`activate` | 点卡 → 等 `wCmdMenu` → 点 `BUTTON_CMD_ACTIVATE`（多效果再点 option0） |
| `summon`/`spsummon`/`set_monster`/`set_spell` | 点卡/手牌 → 菜单 → `BUTTON_CMD_SUMMON/SPSUMMON/MSET/SSET` |
| `place` | 直接点目标格（单步） |

### 7.4 五层安全（保证"点不中也不卡死"）

1. **600ms 校验 + 自动回退**（`BeginUiVerify()` ~L807；Pump 校验块 ~L2896-2925）
   - 记录 baseline（`g_ctosCount`/`g_analyzeCount`）→ 有变化即 `UI action kind=.. verified (ctos+N analyze+M) after ..ms`
   - 600ms 无变化 → `UI fallback (no-effect) kind=.. -> direct response`（用入队时预编码的字节直连）
2. **菜单两步**（`UiCardThenMenu()` ~L818；`ActionKind::UiMenu` ~L1757）
   - 点卡后菜单未出现 → `UI no-menu ... queued menu`，下一帧再点；最多重试 2 帧 → `UI fallback (no-menu)`
3. **菜单归属校验**（防崩溃）：`dField.menu_card == 目标卡` 才点菜单项，否则 `UI skip (menu card mismatch) -> fallback`
   （背景：菜单属于别的卡时客户端 `std::out_of_range` → 0xE06D7363 崩溃；实测 15 回合接住 3 次）
4. **异常防护**：`TryUiSemantic`/`UiMenu`/`ClickButton`/`InjectMouse`/Pump 外层全部 try/catch → `UI exec-exception ... -> fallback`
5. **判空 + 清理**：入口检查 `g_uiActions && mainGame && device && smgr`（缺→`UI skip (not ready)`）；`wCmdMenu` 缺失→`UI skip (no widget)`；
   动作后 `UiCleanup()`（~L595）关闭 `wPosSelect/wOptions/wCardSelect/wCmdMenu/wMessage`，扩展关闭
   `wACMessage/wQuery/wCardDisplay/wAN*/wBigCard`（`YGO_UI_HIDE_EXTRA=0` 关；**排除** `wHand/wFTSelect`）；
   `CloseEmptyFrames()`（~L1009，仅 `isInDuel && isStarted && !awaiting`）关正文为空的 `wMessage/wACMessage/wQuery`，
   日志 `UI close empty frame name=..`；关 `wMessage` 时强制 `actionSignal.Set()`（否则网络线程死等 OK）。

### 7.5 UI 相关开关（默认值以 22:00:40 exe 实测）

| 变量 | 默认 | 作用 |
|---|---|---|
| `YGO_UI_ACTIONS` | **1** | `0` = 全部走旧直连 `SetResponseI/B+SendResponse`（回退/对照） |
| `YGO_UI_EVENT_DIRECT` | 0 | `1` = 注入改走 `receiver->OnEvent(ev)`（A/B） |
| `YGO_UI_HIDE_EXTRA` | 1 | `0` = 不关扩展弹窗 |
| `YGO_UI_TASK22` | 1 | `0` = 一键关 task-22 全部新路径（扩展清理+空框兜底+窗口 debug 日志） |
| `YGO_UI_CLOSE_EMPTY` | 1 | `0` = 只关"空框兜底" |
| `YGO_CTRL_DEBUG` | 未设 | 设了才输出调试日志（含每 15 帧 `CDBG UI windows visible=[...]`） |

启动日志会打印：`control: started port=.. hooks=.. ... uiActions=1 uiEventDirect=0 hideExtra=1 task22=1 closeEmpty=1`。

### 7.6 UI 日志关键词（排障 grep）

```
UI inject button id=.. caller=.. path=postEvent|receiver sentSync=..
UI inject click x=.. y=.. card=.. world=(x,y,z) hovered=(ctrl,loc,seq) menu=0|1
UI no-menu kind=.. -> queued menu ...   /   UI no-menu retry=N kind=..
UI skip (menu card mismatch|not ready|no widget|place not in snapshot)
UI action kind=.. -> ... ok=1           /   UI action kind=.. verified (ctos+N analyze+M) after ..ms
UI fallback (no-effect|no-menu) kind=..  /  UI exec-exception kind=.. what=..
UI cleanup popups=0x.. extra=0x.. (...)  /  UI cleanup extra=0x.. after action
UI close empty frame name=wMessage|wACMessage|wQuery
```

---

## 8. 运行开关

### 8.1 控制层（`control.cpp`，`Control::EnsureStarted()` ~L744；环境变量统一在这里解析）

| 变量 | 默认 | 说明 |
|---|---|---|
| `YGO_CONTROL_PORT` | `7788` | HTTP 端口（第二个客户端请显式设，例如 `7789`） |
| `YGO_HOOKS` | `msg`+`analyze`（=3） | mask：`msg`=1、`analyze`=2、`stoc`=4、`all`=7。**房主用 `msganalyze`，客人 `all`；房主不能用 `all`**（开局会搞死进程） |
| `YGO_CHAIN_MODE` | **`normal`** | 连锁时点 **`all\|avail\|ignore\|normal`**（`normal`=三按钮全不按、对局默认；旧行为默认 `avail`）。开局自动应用、之后自愈重设（4 态比较）。normal 的 auto-decline 门见 §4.7（`duelclient.cpp:1886`） |
| `YGO_CHAIN_IGNORE_KEEP_OWN` | `1` | **`ignore` 是否保留我方诱发**（`17:22:16` 起）：`1`=若 `activatable_cards` 有我方候选则不自动放弃、正常弹 prompt；`0`=旧行为（无差别放弃，会吞自家抽卡诱发等）。日志 `CHAIN client auto-decline ... ownCand=.. ignoreDecline=.. keepOwn=..` |
| `YGO_AUTO_DISMISS` | 1 | 自动关 `MSG_RETRY`/提示框并 `actionSignal.Set()`；`0` 关（调试） |
| `YGO_PLACE_COORDS` | `server` | 选格坐标口径：`server`=按 LocalPlayer 规则修正；`local`=原始半区（A/B） |
| `YGO_UI_ACTIONS` … | 见 §7.5 | UI 注入系列 |
| `YGO_CTRL_DEBUG` | 未设 | debug 日志（窗口列表等） |
| `YGO_RPS` | 随机 1..3 | 猜拳结果（`CTOS_HAND_RESULT`）：1/2/3；不设则随机（种子含 PID，避免两端同值一直平局） |
| `YGO_TP` | `2` | 先后手选择（`CTOS_TP_RESULT`）：`1`=先攻、`2`=后攻 |
| `YGO_TP_AUTO` / `YGO_TP_AUTO_RES` | `1` / `2` | 先/后攻 2s 无外部应答自动作答（防 13s eof）；`YGO_TP_AUTO_RES`：`1`=先攻、`2`=后攻 |
| `YGO_NET_DEAD_SILENCE_MS` | `60000` | 被动静默判死阈值；我方回合/倒计时在走时**永不判死**（`NET ALIVE reason=our-turn-idle`） |
| `YGO_NET_PROBE_FAIL_MAX` | `5` | `/tip` 连续超时达该次数**只降级状态**（`probe_failed`）并打 `NET probe failed ... (defer to passive silence guard)`，**绝不单独判死/断线**；判死统一走 `YGO_NET_DEAD_SILENCE_MS` + 守卫 |
| `YGO_STALL_WARN_MS` | `120000` | **stall 诊断**阈值（`15:34:59` 起）：对局中无入站 STOC 超过该值后每 30s 打 `NET STALL since=.. awaiting=.. ourTurn=.. oppClockFresh=.. oppTimeLeft=.. state=..`；仅日志/诊断，**不影响判死** |
| `YGO_PROMPT_AUTO_DEFAULT_MS` | `60000` | **EOF guard**：已发布 prompt 超过该时间无任何 `CTOS_RESPONSE` → 自动发保守默认（日志 `PROMPT auto-default ... (idle guard, LLM silent)`）；`0`=关。服务端 AFK 约 90s 会 `eof` |
| `YGO_PROMPT_IDLE_WARN_MS` | `45000` | 空闲告警阈值（日志 `PROMPT idle warning seq=.. msg=.. idle=..ms`），便于上层 agent 感知 |

### 8.2 策略侧（`bridge/policy-semantic.mjs`，参考实现，非必须）

| 变量 | 默认 | 说明 |
|---|---|---|
| `CONTROL_URL` | `http://127.0.0.1:7788` | 控制层地址 |
| `MAX_MINUTES` | `20` | 单局上限 |
| `STALL_MS` / `EMPTY_ACTIONS_LIMIT` | `20000` / `5` | 卡住判定 |
| `HEARTBEAT_MS` / `DIAG_EVERY_MS` | `30000` / `30000` | 心跳/诊断间隔 |
| `WAIT_TIMEOUT_MS` | `15000` | `wait_prompt` 超时 |
| `ACT_RETRIES` | `1` | `/act_id` 失败重试次数 |
| `TRAP_GOAL` | 1 | 优先目标陷阱（`53582587/84749824/59839761`）的 SET/ACTIVATE/CHAIN |

### 8.3 一键跑局（`bridge/lan-run.ps1`）

```powershell
# 默认（UI 模式，exe 默认 uiActions=1）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 8 -Deck Blackwing
# 连跑 3 局 / 换牌组 / 对照直连
powershell ... bridge\lan-run.ps1 -Games 3 -MaxMinutes 8 -Deck Blackwing
$env:YGO_UI_ACTIONS='0'; powershell ... bridge\lan-run.ps1 -Games 1
```

参数：`-Games`(1) `-MaxMinutes`(8) `-Deck`(Blackwing) `-Hooks` / `-GuestHooks` `-StallSeconds`(120) `-PlaceCoords`(local|server) `-KeepClients`。
它负责：清场 → 起 host/guest（`bridge/lan-host.cmd` / `lan-guest.cmd`）→ `/deck` `/ready` `/start` → 起两个 bot → 2s 看门狗 → 收证据 → `finally` 清进程。
产物在 `ranked/logs/`：`lan-run-<stamp>.log`、`lan-bot-*`、`lan-state-*`、`lan-ctl-*`、截图 `lan-*.png`。

---

## 9. 已知限制（如实）

1. **不是字面 100% 全 UI**：以 [`direct-actions.md`](direct-actions.md) 为准 —— 当前无 UI 分支的 kind 是
   `auto / attack / select / sum / sort / counter / announce`（`yes / decline / option / position` 已走 UI 点击）；
   一局实测 `UI action` 79/74 次、其中 verified 37/31，其余是各类 fallback。
2. **`place` / `attack` 偶发点击失效**：600ms 后自动直连回退；实测残余 `UI fallback (no-effect)` 约 5%~11%（一局 12/7 次量级）。
3. **单链实测、深链未实测**：真实对局只抓到 `chainDepth=1`（多张卡多次）；`depth≥2` 的多重连锁是**按消息语义推演**（§6.4 已标注）。
4. **只支持本机/局域网**：固定端口 7911 + 两个客户端进程（7788/7789）；**同一时间只能跑一对**。
5. **链字段有 1 帧延迟**：`/state` 与 `/prompt` 的链字段来自 UI 线程快照；`chainStack[].forced` 恒 false、`type` 固定 `effect`。
6. **UI 模式个别动作有 600ms 校验延迟**（点不中时才会走满）。
7. **多效果卡默认点第 0 个 option**（可能不是最优效果）；`announce/counter/sort/sum` 是"安全默认"而非最优。
8. **线上排位：能完整打完，但胜率依赖策略**：客户端/管线侧已实测可拿房→进房→选卡组→准备→完整对局→自然结算（LP_ZERO 等），并支持受控掉线后约 13s 重连回同房继续打；输局主要是 policy 保守（大量 `decline`/`to_bp`/`end`），不是管线卡死。**排位相关新字段（`/state.deckError`、`/state.isWin/isLoss/isDraw`、`/state.lpOrder`、`/state.pipeline.recentMsgs`、`/state.tpPending`+`/state.tpOptions`、`/actions` 的先/后攻动作 `kind:"tp"`+`index:1|2`、`/state.sidePending`、`/actions` 的换备牌动作 `kind:"side_ok"`（Bo3 每局之间，`id=0` → `btnSideOK`/`SendUpdateDeck`）、**`/state.side`（`available/pending/waiting/elapsedMs/waitingSeen/lastWaitMs/main/extra/side/counts/pre/limits/error`）+ `POST /side_swap`（真正换牌）+ `side_ok` 竞态修复**、**`/state.match`（`game`/`over`/`games[]`（含 `win`/`winnerSeat`/`reasonName`）/`gamesWonLocal`/`gamesWonOpp`/`lastWinnerLocal`/`lastReasonName`，配合 `control_match` 一句话报结果）**、`CHAIN raw` 等；Bo3 Game2/3 开局客户端会 `DUEL_START reset result state` 重置 `winPlayer/winReason`）只在客户端 `2026-11-27 17:22:16 / 6,338,048 B`（sha256 `99FC53A3B2A7121A7EFBCF81A312F9499E603E8122ED6C37CC326C9B023C0708`）及之后存在**；旧 exe 请先升级。详见 [`RANKED-REPORT.md`](RANKED-REPORT.md)。
9. **被动判死（对手回合 60s eff + `NET silence diag`）**：对手长时间不出手时，客户端会按"对手回合 60s eff"推进判定，并在 `/net` 相关日志打 `NET silence diag`（链路静默诊断，不主动断线）；被动判死不是本仓库 policy 的行为，属客户端/服务端规则。`/net` 的 `alive`/`sinceLastStoc` 在静默期会持续增长——要区分"对手在思考（slow play）"和"对手掉线"，以 `NET silence diag` + `/net.probe` 的 `fails`/`rttMs` 判断；详见 `mycard-client/docs/CONTROL-API.md` 的 `/net` 一节。
10. **控制驱动下 `STOC_REPLAY` 直接跳过（`replay: dialog skipped`）**：不会弹回放对话框、**不阻塞网络线程**（否则回放保存框会卡住后续 STOC）。**已 LAN 实测**（2026-11-13：双方各 2 次 `replay: dialog skipped (control-driven, no wait)`、`replay-save=0`、`stoc=23 stall=0`）；排位 LP_ZERO 结算场景同样走该路径（不再需要"未实测"假设）。若上线后出现结算后收不到后续包，先查这里。
11. **prompt 空等 ~90s 会被服务端按 AFK `eof` 踢（MC 排位行为）；LAN srvpro 不踢 eof，而是 180s `TIMEOUT` 判负**（证据 `ranked/logs/eof-guard-validation.md`、`control-23776.log`）。`10:25:14` 版起默认 `YGO_PROMPT_AUTO_DEFAULT_MS=60000` 自动发保守默认动作兜底（45s 先打 `PROMPT idle warning`），可用 `/prompt.awaitingSinceMs` 看等待时长；`0`=关闭（不建议）。
12. **`/tip` 探活超时不再单独判死（`11:31:00` 版起）**：旧版 2 次 `probe fails` 就 `NET DEAD reason=probe-fails` + `disconnected error`（对手长展开 ~7.5s 静默被误踢）。现在 probe 失败只置 `probe_failed`（`NET probe failed fails=.. (defer to passive silence guard)`），判死只看 `YGO_NET_DEAD_SILENCE_MS` + 我方回合/倒计时/awaiting/busy 守卫；`YGO_NET_PROBE_FAIL_MAX`（默认 5）仅控制降级/日志。日志：`NET probe timeout fails=.. sinceStoc=.. ourTurn=.. awaiting=..`、`NET probe deferred (reason=our-turn/awaiting/busy/silence sinceStoc=..)`。
13. **看门狗（被动判死）修复（`17:33:31` 版起）**：旧版 `g_timeLeft` 不清零 → `clockRunning` 永久 true → 豁免永远成立（`NET ALIVE reason=our-turn-idle timeLeft=240` 一直 ALIVE、真掉线也发现不了）。新版 `g_timeLeftTick` + `clockFresh = timeLeft>0 && now-tick<3000` + `clockRunning = ourTurn && clockFresh`；判死 `!clockRunning && quiet && since > effSilence`（`effSilence=max(YGO_NET_DEAD_SILENCE_MS, oppTurn&&quiet?60000:0)`）。**`YGO_NET_DEAD_SILENCE_MS` 用默认 60000（最多 120000），不要再 600000**。验证 `net-watchdog-validation.md` 4/4 PASS：对手静默 60s `idle-no-packet` 判死、我方回合 idle 25s 不判死、正常 2min dead=0、真实断开 `state=disconnected closeReason=error`。

---

## 10. 排障

| 症状 | 先看 | 说明 |
|---|---|---|
| `wait_prompt` 一直超时、`awaiting=false` | `/state.turn/curMsg`、`/lobby` | 可能还没开局（看 `lobby.bothReady`），或对面没动 |
| `wait_prompt` 立刻返回且 `seq` 不变 | `pipeline.awaiting` | 唤醒条件含 `!awaiting`；用 `awaiting===true && seq>lastSeq` 过滤 |
| 提交总被 `stale seq` | 你用的 seq | 重新 `wait_prompt`；不要自己缓存旧 seq |
| 对局卡住、双方互等 | `/state.pipeline`（`analyzeCount`/`sinceLastAnalyzeMs`）、`PIPE stall` 日志 | 可能没有 bot 在答（`awaiting=true` 但没人提交） |
| `retryCount`/`retryStreak` 飙升 | `/state.retryStreak`、`placeVariant` | 动作编码不对；`place` 会自愈 4 变体，持续升说明别的 kind 有问题 |
| 刚开局就 `no-start` | `/health`、`/state` 是否能解析 | 曾因 `/ui` JSON 非法导致脚本解析失败（见 `ui-verify.md` §11.4）；先确认两端点都能 `ConvertFrom-Json` |
| `started` 一直是 false 但客户端在打 | `/state.inDuel`、`/health.started` | `/health.started`=控制服务在监听（恒 true）；`/state.started`=客户端 `dInfo.isStarted` |
| 屏幕中间有空白框 | `/ui.windows`、`UI close empty frame`、`UI cleanup extra` | 用 `bridge/dev/diag-ui-windows.ps1` 每 5s 采样：某窗口连续 ≥2 次 visible 才是残留（`wQuery` 曾长期空白，已修） |
| UI 动作"报成功但没效果" | `UI action ... verified` vs `UI fallback (no-effect)` | 只有 `verified` 才是真的生效；大量 no-effect 说明坐标/时序退化 |
| 客户端崩溃 0xE06D7363 | `UI exec-exception`、`UI menu check` | 历史上是"菜单属于别的卡"导致 `std::out_of_range`；`menu card mismatch` 防线会拦住 |

**常用诊断命令**

```powershell
# UI 窗口/弹窗采样（每 5s /ui.windows，每 20s 截图，自动统计最长连续可见次数）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\dev\diag-ui-windows.ps1 -DurationSec 300
# 抓客户端窗口截图
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\shot.ps1 -Tag mytag
# 看最近一局日志
Get-Content (Get-ChildItem ranked\logs\lan-run-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 40
```

---

## 11. 文档索引

| 文档 | 定位 |
|---|---|
| **`MCP-INTERFACE.md`（本文）** | **LLM 接入规范**：工具/字段/动作/连锁/UI/开关/限制/排障 |
| [`MCP-INTERFACE-poc.md`](MCP-INTERFACE-poc.md) | **设计细节附录**（poc-wasm-duel 提供）：UI 注入实现（代码行号表、坐标公式、五层安全）、连锁数据来源与 LIFO 细节、真实 JSON 样例 |
| [`DELIVERY.md`](DELIVERY.md) | 面向**人**的交付说明（一句话定位、能做什么、已知限制、一键跑局、证据清单） |
| [`chain-semantics.md`](chain-semantics.md) | 连锁语义的字段定义与"该不该连锁"判断方法（task-19 产出） |
| [`ui-actions.md`](ui-actions.md) | UI 点击实现：坐标投影、600ms 校验回退、两帧菜单重试、残留窗口清单与自动清理 |
| [`ui-verify.md`](ui-verify.md) | UI 验证与最终验收：默认 UI 模式、place verified、空框 `wQuery` 排查与"已消除"结论 |
| [`trap-goal.md`](trap-goal.md) | 目标陷阱（激流葬/神之警告/三角乌鸦阵）发动验证：`SET-TRAP → CHAIN-TRAP` 证据链、内核级 `chainStack`、LP 支付 |
| [`lan-run.md`](lan-run.md) | 一键跑局器用法、12 局实测对照、故障排查 |
| [`pipeline-diag.md`](pipeline-diag.md) | 管线/协议层排障记录（`MSG_RETRY`、place 索引、win_reason 解码等） |
| [`bot-diag.md`](bot-diag.md) | bot 自诊断/心跳/策略判读表（`trapsSet/trapsActivated` 等） |
| [`direct-actions.md`](direct-actions.md) | **直连动作清单**：哪些 kind 还没走 UI、为什么（设计兜底）、对 LLM 的影响与改进方案 |
| [`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md) | **重连设计稿**：目标/边界、三层职责（客户端 prober·supervisor·策略）、双状态机、探活、chain journal、LLM 语义、自动关模态框、测试与验收 |
| [`reconnect-lab.md`](reconnect-lab.md) | **重连实测记录**：LAN 掉线重进实验（服务端不支持续局）+ task-30 客户端检测/supervisor/journal 实测（freeze 6.75s、drop 0.6s、journal 按端口） |
| [`net-probe.md`](net-probe.md) | **netfault 故障注入 + net-probe 采样**用法、`-j` 忽略 `-p` 的坑、异常流量断言（工具文档） |
| [`supervisor.md`](supervisor.md) | **supervisor 使用说明**：`--profile lan|ranked`、状态机、JSONL 字段、`--mock` 自测、与 netfault 配合 |

**证据文件速查**（`ranked/logs/`）

| 文件 | 内容 |
|---|---|
| `trap-EVIDENCE-84749824-chainStack.json` | 真实 depth=1 连锁快照（神之警告） |
| `ui-smoke-chainstack-descText.json` | 真实 `descText`（黑羽-突风之颪："改变表示形式"） |
| `lan-run-20261104-145637.log` / `lan-final*.png` | 默认 UI 模式自然胜负（LP_ZERO）+ 激流葬发动 |
| `ui-windows-20261104-220717.log` / `uiwin-20261104-220717/` | 空框诊断采样 + 截图（`SUMMARY <port>:<window> maxConsecutiveVisible=N`） |
| `ui-EMPTY-FRAME-baseline-host-turn5/6.png` | 修复前 `wQuery` 空框复现证据 |

---

## 附：代码位置索引（重构后；行号仅供跳转，**以符号名为准**）

| 符号 | 现位置 |
|---|---|
| `Control::EnsureStarted`（环境变量解析） | `control.cpp:744` |
| `Control::OnMessageBegin` / `OnAnalyzeEnd` | `control.cpp:921` / `:1022` |
| `Control::Pump` | `control.cpp:1029` |
| `HandleClient` / `RouteRequest` | `control.cpp:391` / `:436` |
| `ExecuteAction`（分发器） | `control_actions.cpp:101` |
| `ExecUiAction` | `control_ui.cpp:540` |
| `ExecLobbyAction` | `control_lobby.cpp:125` |
| `TryUiSemantic` / `UiCleanup` / `ApplyChainMode` | `control_ui.cpp:388` / `:95` / `:73` |
| `SnapshotFromClient` | `control_state.cpp:465` |
| `SnapshotJson` / `PromptJson` / `UiJson` / `AppendChainJson` | `control_state.cpp:343` / `:226` / `:297` / `:116` |
| `BuildSemActions` / `EncodeSemAction` / `SemActionsJson` | `control_sem.cpp:77` / `:136` / `:286` |
| `LoadDeckBySections` / `FixupDeckSections` | `control_lobby.cpp:82` / `:65` |
| `HexBytes` / `Unhex` | `control_actions.cpp:65` / `:79` |

> 完整"函数 → 原 control.cpp 行号"对照见 [`MODULE-MAP.md`](MODULE-MAP.md) 附录 A。

---

## 附：维护约定

- 任何字段/工具/环境变量变更后，**先在 `mycard-client/gframe/control*.cpp` / `bridge/mcp-server.mjs` 里 grep 确认新名字**，再改本文档；
- 代码行号会漂移，**优先引用符号名**（`UiCleanup()` / `TryUiSemantic()` / `AppendChainJson()` / `BuildSemActions()` …）；
- 实测数据（fallback 次数、回合数、截图）来自 exe 22:00:40 的多局记录，换版本后请复核 §9 的数字。
- **skill 的 live 副本是权威**：`%USERPROFILE%\.dsh\skills\ygopro-play\` 会被打牌的那个 LLM **直接编辑**；仓库 `skill/ygopro-play/` 只是备份，可能落后。**改 skill 之前先跑 `bridge\sync-skill.ps1`**（只对比：哪边新、哈希、mtime），再按方向合并：
  - 推荐 `-Apply -Direction live`（live → repo，回写仓库）
  - `-Apply -Direction repo` 只在确认 live 不是更新版时用；live 更新时脚本会**拒绝**（需 `-Force`）
  - 绝不要用旧仓库副本直接覆盖 live；
  - 合并后 commit/push 仓库；live 对新会话立即生效，运行中的会话不会重载。
