# YGOPro MCP 控制层：接口与设计规范（面向 LLM 接入）

> **读者**：后续接手的 LLM / agent / 工程师。**只读本文档 + 附录即可接入**，不需要先读懂 ygopro 协议。
>
> **适用版本（当前正式版 exe）**：`mycard-client/bin/release/x64/YGOPro.exe`
> = **2026-11-13 01:11:32 / 6,316,032 B**，SHA256 `4D9FE13673CD042A8CBCF73367D0E34AE743622EA24ED728C50081B7C5AD1F2E`
> （2026-11-13 实机 3/3 Bo3 验收版：Bo3 换备可操作（`/state.side` + `POST /side_swap` + `side_ok` 竞态修复）+ 控制驱动跳过 `STOC_REPLAY` + 被动判死诊断 + 回放框跳过 + Game2/3 结果重置；验收/历史版本见文末记录）
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
   r = control_wait_prompt({since: lastSeq})     // 长轮询，拿到本轮 prompt
   a = control_actions()                          // 本 prompt 的语义候选（id+kind+label）
   control_act_id({id: <你选中的候选 id>})         // 提交（默认经 UI 点击执行）
   lastSeq = r.seq

④ 对局走了、赢家出现后读 control_state().winPlayer / winReasonName 收尾
```

**三条铁律**

1. **动作必须针对当前 `seq`**：`control_wait_prompt` 返回新 `seq` 才做决策；`control_act` 用旧 seq 会被拒（`stale seq`）。
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
        │ bridge/mcp-server.mjs  │   薄桥：16 个工具 → HTTP
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

## 2. MCP 工具清单（`bridge/mcp-server.mjs` 的 16 个工具）

> 全部无参数或只有简单参数；返回体就是对应 HTTP 端点的 JSON（原文透传，见 §4）。

| # | 工具 | 用途 | 参数 | HTTP |
|---|---|---|---|---|
| 1 | `control_health` | 存活探活 | — | `GET /health` |
| 2 | `control_state` | 完整局面（§4.1） | — | `GET /state` |
| 3 | `control_wait_prompt` | **主循环原语**：长轮询等新 prompt | `since`(number，上一次的 seq，首次 0)、`timeout_ms`(默认 30000) | `GET /wait_prompt?since&timeout_ms` |
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
| `chainMode` | int | 实际连锁时点（0=all 1=avail 2=ignore） |
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
| `canBp` / `canEp` | 可否进战阶 / 可否结束阶段 |
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
| `chainMode` / `chainModeName` | **真实**连锁时点（从控件布尔反推） |
| `alwaysChain` / `chainWhenAvail` / `ignoreChain` | 三个真实 bool（all / avail / ignore） |
| `desiredChainMode` / `appliedChainMode` / `applyPending` | 想要的 / 已应用的 / 是否待应用 |
| `popupMask` / `popups` | 五个主弹窗可见性（`posSelect/options/cardSelect/cmdMenu/message`） |
| `windows[]` | 17 个窗口的 `name/visible/rect{l,t,r,b}/x,y,w,h/textLen`（`textLen` 仅 `wMessage/wACMessage/wQuery` 有值，其余 -1；有正文时额外带 `text`（≤120 字）） |
| `windowsVisible[]` | 可见窗口名字数组（快速判空） |

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
| `tp` | `STOC_SELECT_TP`（开局前，非 `curMsg`；`prompt.tpPending=true`） | `tp first (index=1)` / `tp second (index=2)` | 按 `id` 提交即发 `CTOS_TP_RESULT`：`index=1` 先攻 / `2` 后攻；仅 MCP 驱动时出现（手动或 `YGO_TP` 强制时客户端自动应答） |
| `side_ok` | `STOC_CHANGE_SIDE`（Bo3 换备牌阶段；`prompt.sidePending=true`） | `keep side deck (no changes) and continue` | 按 `id=0` 提交 → UI 注入点 `btnSideOK`（= 真人"确定"，会 `SendUpdateDeck`）；仅 MCP 驱动时出现 |
| `option` | `MSG_SELECT_OPTION`(14) | `option #0`（另有一个兜底 `option 0`） | index=选项下标 → 直接回 |
| `select` | `MSG_SELECT_CARD`(15)/`SELECT_TRIBUTE`(20)/`SELECT_UNSELECT_CARD`(26) | `select first N card(s)` | 一次选前 N 张（N=`selectMin` 或 1） |
| `position` | `MSG_SELECT_POSITION`(19) | `attack position` / `defense position` | `0x01` / `0x02` |
| `place` | `MSG_SELECT_PLACE`(18)/`MSG_SELECT_DISFIELD`(24) | `place bit=8 mask=0 ctrl=1 p0=1 seat=1 first=0 loc=8 seq=0` | index=places 下标；4 变体自愈（`placeVariant`） |
| `sum` | `MSG_SELECT_SUM`(23) | `auto-select materials` | 自动选素材 |
| `counter` | `MSG_SELECT_COUNTER`(22) | `auto-place counters` | 自动放指示物 |
| `sort` | `MSG_SORT_CARD`(25) | `keep current order` | 保持当前顺序 |
| `announce` | `MSG_ANNOUNCE_RACE/ATTRIB/NUMBER/CARD` | `auto announce (first option)` | 自动选第一项 |
| `auto` | 其它（如 `MSG_HINT`/`MSG_CONFIRM_*` 等） | `auto / safe default` | 安全默认（回 0 或空） |

**要点**

- `id` 是候选数组下标，**prompt 一变就重新编号**；`label` 只是给人/LLM 看的，不要解析出行为依赖。
- `kind` 是稳定语义；策略只判断 `kind` + `label`/卡号即可。
- `place` 的 `ctrl`/`loc`/`seq` 是客户端已按"本地半区"规则修正过的值；遇到 `MSG_RETRY` 客户端会自动换变体重试（`placeVariant`）。
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
| `YGO_CHAIN_MODE` | `avail` | 连锁时点 `all\|avail\|ignore`（开局自动应用，之后自愈重设） |
| `YGO_AUTO_DISMISS` | 1 | 自动关 `MSG_RETRY`/提示框并 `actionSignal.Set()`；`0` 关（调试） |
| `YGO_PLACE_COORDS` | `server` | 选格坐标口径：`server`=按 LocalPlayer 规则修正；`local`=原始半区（A/B） |
| `YGO_UI_ACTIONS` … | 见 §7.5 | UI 注入系列 |
| `YGO_CTRL_DEBUG` | 未设 | debug 日志（窗口列表等） |
| `YGO_RPS` | 随机 1..3 | 猜拳结果（`CTOS_HAND_RESULT`）：1/2/3；不设则随机（种子含 PID，避免两端同值一直平局） |
| `YGO_TP` | `2` | 先后手选择（`CTOS_TP_RESULT`）：`1`=先攻、`2`=后攻 |

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
8. **线上排位：能完整打完，但胜率依赖策略**：客户端/管线侧已实测可拿房→进房→选卡组→准备→完整对局→自然结算（LP_ZERO 等），并支持受控掉线后约 13s 重连回同房继续打；输局主要是 policy 保守（大量 `decline`/`to_bp`/`end`），不是管线卡死。**排位相关新字段（`/state.deckError`、`/state.isWin/isLoss/isDraw`、`/state.lpOrder`、`/state.pipeline.recentMsgs`、`/state.tpPending`+`/state.tpOptions`、`/actions` 的先/后攻动作 `kind:"tp"`+`index:1|2`、`/state.sidePending`、`/actions` 的换备牌动作 `kind:"side_ok"`（Bo3 每局之间，`id=0` → `btnSideOK`/`SendUpdateDeck`）、**`/state.side`（`available/pending/waiting/elapsedMs/waitingSeen/lastWaitMs/main/extra/side/counts/pre/limits/error`）+ `POST /side_swap`（真正换牌）+ `side_ok` 竞态修复**、`CHAIN raw` 等；Bo3 Game2/3 开局客户端会 `DUEL_START reset result state` 重置 `winPlayer/winReason`）只在客户端 `2026-11-13 01:11:32 / 6,316,032 B`（sha256 `4D9FE13673CD042A8CBCF73367D0E34AE743622EA24ED728C50081B7C5AD1F2E`）及之后存在**；旧 exe 请先升级。详见 [`RANKED-REPORT.md`](RANKED-REPORT.md)。
9. **被动判死（对手回合 60s eff + `NET silence diag`）**：对手长时间不出手时，客户端会按"对手回合 60s eff"推进判定，并在 `/net` 相关日志打 `NET silence diag`（链路静默诊断，不主动断线）；被动判死不是本仓库 policy 的行为，属客户端/服务端规则。`/net` 的 `alive`/`sinceLastStoc` 在静默期会持续增长——要区分"对手在思考（slow play）"和"对手掉线"，以 `NET silence diag` + `/net.probe` 的 `fails`/`rttMs` 判断；详见 `mycard-client/docs/CONTROL-API.md` 的 `/net` 一节。
10. **控制驱动下 `STOC_REPLAY` 直接跳过（`replay: dialog skipped`）**：不会弹回放对话框、**不阻塞网络线程**（否则回放保存框会卡住后续 STOC）。注意：该路径在排位 LP_ZERO 自然结算场景**尚未触发**，待 LAN 补验；若上线后出现结算后收不到后续包，先查这里。

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
