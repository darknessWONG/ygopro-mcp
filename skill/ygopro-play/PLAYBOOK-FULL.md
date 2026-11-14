# PLAYBOOK-FULL：YGOPro MCP 全流程操作手册（LLM agent 权威版）

> **读者**：要真正操作这套桥接去排位/局域网打牌的 LLM agent（以及维护它的工程师）。
> **目标**：零歧义——每一步"做什么、调什么、返回什么、怎么判定成功/失败、失败怎么修"。
> **当前客户端构建**：`2026-11-13 14:51:46 / 6,319,104 B`，SHA256 `CDB25977ED3A568D724B90B738595CAB1B7ED8F2C870939E9461944C925DE2FC`（`node doctor.mjs --client <exe> --strict-build` 可校验）。
> **权威性**：本文是操作流程的权威；字段级契约见 [`MCP-INTERFACE.md`](MCP-INTERFACE.md)，排位实战记录见 [`RANKED-REPORT.md`](RANKED-REPORT.md)，精简单页见 [`MATCH-PLAYBOOK.md`](MATCH-PLAYBOOK.md)。
> **本文所有示例字段名都按当前客户端真实输出**（可对照 `ranked/logs/playbook-samples/` 下的真实采样）。

---

## 0. 先读这一段（TL;DR，10 条铁律）

1. **一次只操作一个客户端**：控制端口房主 `7788`、客机 `7789`（`YGO_CONTROL_PORT`）；两个客户端在同机时**必须**用不同端口。
2. **主循环只有三步**：`control_wait_prompt(since=上一个 seq)` → `control_actions()` → `control_act_id(id=<选一个>)`。不要自己发明响应字节。
3. **`awaiting=false` 时绝对不要动作**：那不是给你的选择；动作会被内核当成非法响应（`MSG_RETRY`），严重时被服务端踢（`eof`）。
4. **每条 prompt 只回一次**：用 `seq` 去重；重复回同一条会触发 `MSG_RETRY` 并可能被服务器以 `retry` 超限踢掉。
5. **整场胜负只信 `control_match`**：`/state.winPlayer` 是**当前局**的原始座位号（我们 seat 0 时 `winPlayer=1` 表示"我们输了"），不要用它推整场。
6. **排队是长轮询**：`get-room.mjs` 的正常"超时"=还在排队，不是故障；不要疯狂 abort 重排（`cancel=1` 是无效参数）。
7. **`/start` 要反复发**：双方 ready ≠ 开局；每次发 `CTOS_HS_START`，直到 `state.started==true`（以 `STOC_DUEL_START` 为准）。
8. **Bo3 换备必须两端都点 `side_ok`**：一端确认后另一端看到 `side.waiting=true`（瞬时）+ `waitingSeen=true`（sticky）；不要重复点。
9. **决策要快**：单步决策必须 < 60s（目标 < 30s）。服务端对不响应者约 **90s** 后踢人（`eof`），踢前有红色聊天警告。
10. **出问题先取证**：`/net.closeReason`、`/net.lastStocName`、`/state.lastStocName`、`/chat`、`/state.pipeline.recentMsgs`、`/state.retryCount/retryStreak` 是六大证据。

---

## 1. 系统怎么串起来

```
LLM / agent
   │  MCP (JSON-RPC over stdio)
   ▼
bridge/mcp-server.mjs        ← 18 个 MCP 工具（薄桥，返回就是 HTTP JSON 原文，control_match 例外）
   │  HTTP 127.0.0.1:7788（房主）/ :7789（客机）
   ▼
YGOPro 客户端（带控制层的构建，gframe/control*.cpp）
   │  控制层把 HTTP 请求翻译成：真实 UI 点击（注入）/ 内核消息直连 / 只读快照
   ▼
游戏内核 + 服务器（LAN: 127.0.0.1:7911；排位: tiramisu.moenext.com:8911，房间密码由 MC 匹配服务给）
```

### 1.1 三种动作形态（决定"你会看到什么副作用"）

| 形态 | 含义 | 典型 kind | 风险 |
|---|---|---|---|
| **UI 注入**（真实点击） | 控制层在客户端 UI 线程点按钮/卡/格子，走真人同一条路径 | `summon` `spsummon` `set_monster` `set_spell` `activate` `chain` `decline` `yes` `no` `option` `position` `place` `to_bp` `to_m2` `to_ep` `end_battle` | 点击可能因界面动画/弹窗失效，客户端会自动直连回退（日志 `UI fallback`） |
| **内核直连** | 控制层直接发响应字节（无对应 UI 分支时的兜底/自动） | `auto` `attack` `select` `sum` `sort` `counter` `announce` | 不经过 UI，快，但语义是"安全默认"不是"最优" |
| **只读查询** | 不改任何状态 | `/state` `/prompt` `/actions` `/lobby` `/net` `/ui` `/chat` `/msg` `/health` | 无 |

> 结论：**所有对局动作统一用 `control_actions` + `control_act_id`**，不要用底层 `control_act`（那是调试/兜底）。`control_act` 只在需要 `i/hex` 原始编码时使用。

### 1.2 谁负责什么

- `bridge/mcp-server.mjs`：MCP stdio 桥，18 个工具 → HTTP。
- `bridge/get-room.mjs`：登录态的 token → `authUser` → `POST /ygopro/match`（长轮询）→ 打印 `{address,port,password,name,id,stale}`。
- `bridge/ranked-loop.ps1`：连续排位自动化（排队→进房→deck→ready→start→对局→换备→下一局→DUEL_END→重排）。
- `bridge/policy-semantic.mjs`：参考策略（可当 LLM 的替身；LLM 自己操作时**不要同时跑**，会抢动作）。
- `bridge/doctor.mjs`：自检（端口/字段/指纹）。

---

## 2. 工具速查表（18 个，按 `mcp-server.mjs` 实际注册顺序核对）

> 通用约定：**除 `control_match` 外，返回值就是对应 HTTP 端点的 JSON 原文**（失败/异常时 MCP 返回 `isError` 文本，不会静默）。所有工具**无必填参数**，除 `control_act`(`seq`)、`control_act_id`(`id`)、`control_side_move`(`code/from/to`)。

| # | 工具 | 参数 | HTTP | 一句话 |
|---|---|---|---|---|
| 1 | `control_state` | — | `GET /state` | 完整局面（含 `match`/`side`/`net`/`pipeline`） |
| 2 | `control_match` | — | `GET /state` | 整场结果 `{match, summary}`（**中文一句话**） |
| 3 | `control_prompt` | — | `GET /prompt` | 当前 prompt 快照（**不等待**） |
| 4 | `control_wait_prompt` | `since`,`timeout_ms` | `GET /wait_prompt` | 长轮询等下一个 prompt（**主循环原语**） |
| 5 | `control_act` | `seq`,`i`/`hex` | `POST /act` | 底层原始响应（调试/兜底） |
| 6 | `control_ready` | — | `POST /ready` | 点准备 |
| 7 | `control_actions` | — | `GET /actions` | 语义候选（每个 `{id,kind,label}`） |
| 8 | `control_act_id` | `id` | `GET /act_id?id=` | 按候选 id 执行（**首选**） |
| 9 | `control_lobby` | — | `GET /lobby` | 准备界面（座位/ready/人数/卡组数） |
| 10 | `control_deck` | `name`(默认 Blackwing) | `POST /deck?name=` | 预载卡组 |
| 11 | `control_start` | — | `POST /start` | 房主点开始（`CTOS_HS_START`） |
| 12 | `control_surrender` | — | `POST /surrender` | 投降（结束本场，慎用） |
| 13 | `control_chat` | — | `GET /chat` | 最近 50 条聊天（服务器警告在这里） |
| 14 | `control_join` | `ip`,`port`,`pass` | `POST /join` | 进房（连服务器+房间） |
| 15 | `control_msg` | — | `GET /msg` | 最近一条原始服务器消息（调试） |
| 16 | `control_health` | — | `GET /health` | 控制层存活 |
| 17 | `control_side_move` | `code`,`from`,`to`,`n` | `POST /side_swap` | Bo3 换备：移动 N 张卡 |
| 18 | `control_side_done` | — | `/actions`+`/act_id` | Bo3 换备：确认（等价 `side_ok`） |

### 2.1 逐个工具的返回/适用/失败

#### `control_state`
- **返回**（真实精简）：`{valid,inDuel,started,turn,lp:[我,对],lpOrder:"local",phase,phaseName,curMsg,myPlayer,mySeat,turnPlayerLocal,isMyTurn,winPlayer,winPlayerLocal,isWin,isLoss,isDraw,winReason,winReasonName,match:{...},chainMode,seq,awaiting,sidePending,tpPending,counts:{hand,grave,remove,deck,extra},hand,monsters,spells,grave,banished,extraDeck,chainDepth,chainStack,chainingTo,chainCandidates,canDecline,ui,pipeline,net,resume,deckError,side:{...}}`
- **什么时候用**：需要"全局状态"（选卡组数、LP、场面、match 汇总、网络）。
- **不要**：不要每 100ms 轮询它（2–3s 一次足够）；动作决策用 `/actions`，不要从 `/state` 自己拼响应。
- **失败**：HTTP 连不上 → MCP 报错（`fetch failed`）；客户端没起来时先 `control_health`。

#### `control_match`
- **返回**：`{match:{...}, summary:"比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）"}`；旧客户端 `{match:null,fallback:true,summary:"…"}`；离线 `{match:null,fallback:true,error:"fetch failed",summary:"读不到 /state（客户端未连接或控制层无响应）"}`。
- **什么时候用**：任何"结果/比分/是否结束"的问题；每局结束、换备前、`STOC_DUEL_END` 后各调一次。
- **不要**：不要用 `/state.winPlayer` 代替它判断整场。

#### `control_prompt`
- **返回**（真实）：`{seq,curMsg,turn,awaiting,summonable,spsummonable,msetable,ssetable,reposable,activatable,attackable,chains,chainForced,lastChain,selectMin,selectMax,selectCancelable,selectableCount,canBp,canEp,summonableCards:[],...,chains:[],places:[],placesMask,isFirst,placeCoords:"server",sumTarget,sumMode,options:[],chainDepth,chainStack,chainingTo,chainCandidates,canDecline,hint,lastChainEvent}`（`tpPending`/`sidePending` 在换备/先攻阶段出现）。
- **什么时候用**：快速看"现在在问什么"（不阻塞）。
- **不要**：不要用它替代 `control_wait_prompt` 来等下一步（会忙等）。

#### `control_wait_prompt`
- **参数**：`since`=上次处理的 `seq`（首轮传 0），`timeout_ms`（建议 20000–30000）。
- **返回**：同 `control_prompt`；超时返回当前快照（`seq` 不前进 = 没有新 prompt）。
- **判定**：`resp.seq > since && resp.awaiting === true` 才是新决策；`awaiting=false` 时不要动作。
- **失败**：`timeout` 是正常现象（对手回合/等待）；连续超时可查 `control_state.net`。

#### `control_actions`
- **返回**：`{seq,curMsg,awaiting,actions:[{id,kind,label,index?}],sidePending?,tpPending?,reason?}`；典型空动作：`{"actions":[],"awaiting":false,"curMsg":0,"seq":0,"reason":"not awaiting"}`。
- **什么时候用**：每个 prompt 之后**必调**；`kind` 决定怎么选（映射见 §3.7/§5）。
- **不要**：`awaiting=false` 或 `actions=[]` 时不要执行任何动作。

#### `control_act_id`
- **参数**：`id`（整数，来自 `control_actions`）。
- **返回**：`{ok:true,queued:true}`（或 `{ok:false,error:"..."}`）。
- **失败**：`bad id`/`not awaiting`/`stale seq` → 重新取 `/actions`；连续失败查 `retryCount`。

#### `control_act`（底层，少用）
- 参数：`seq` + `i`(int32) 或 `hex`(原始字节)。仅在需要编码特殊响应时使用；一般不用。

#### `control_lobby`
- **返回**（真实）：`{self:0,isHost:true,launchSeat:-1,ready:[0,0],bothReady:false,playerCount:0,players:[],deckMain:0,statuses:[]}`；房间内：`ready:[1,1]`、`bothReady:true`、`players:[{pos,name,ready}]`。
- **判定**：`ready[self]==1` = 我已准备；`playerCount>=2`/`statuses.Count>=2` = 对手进来了。

#### `control_deck`
- **参数**：`name`（对应客户端 `deck/<name>.ydk`，默认 `Blackwing`）。
- **返回**：`{ok:true,queued:true}`；成功后 `/state.deckMain`/`/lobby.deckMain` > 0。
- **失败**：卡组不存在时 `/state.deckError.local` 会置位（`reason/type/code`）。

#### `control_ready`
- **返回**：`{ok:true,queued:true}`；判定 `lobby.ready[mySeat]==1`；重试 1–2s 一次，最多 ~30 次。

#### `control_start`
- **返回**：`{ok:true,queued:true}`；**每 2–3s 重发**直到 `state.started==true`（`STOC_DUEL_START`）。仅房主/launch seat 有效；重复发送是预期行为（latch 修复后安全）。

#### `control_join`
- **参数**：`ip`,`port`,`pass`；返回 `{ok:true,queued:true}`。
- **判定**：`/net.connected==true && /net.joined==true`（重试 4 轮，每轮等 2s×10）。
- **失败**：只弹 LAN 窗口（没真正 join）、密码错（`/chat` 有系统消息）、房已关（`/net.closeReason`）。

#### `control_chat` / `control_msg`
- `chat`：`{chats:["..."]}`（最近 50 条，UTF-8）；**服务器踢人前的警告（AFK/倒计时/非法卡组）就在这里**。
- `msg`：`{id,len,hex}`（最近一条 STOC 原文，调试）。

#### `control_side_move` / `control_side_done`
- 见 §3.9；`side_move` 参数 `code`(卡号)、`from`(side|main|extra)、`to`(main|extra|side)、`n`(默认1)；`side_done` 等价点 `side_ok`。
- `side_move` 返回：`{ok:true,queued:true,main:m,extra:e,side:s}`（预测值）或 `{ok:false,error:"not enough copies in side (have 1, need 2)"}`。
- `side_done` 返回：`{ok:true,queued:true,kind:"side_ok"}` 或 `{ok:false,error:"counts must match",sideError:"counts must match"}`。

---

## 3. 完整生命周期（Bo3 排位 / LAN 都适用）

### 3.1 排队拿房（`get-room.mjs`）

**做什么**：用登录 token 调 `POST https://sapi.moecube.com:444/ygopro/match?arena=athletic&locale=zh-CN`（HTTP Basic: `username:u16Secret`），这是**长轮询**：配到对手才返回房间；没对手就一直挂着。

**判定成功**：stdout 打印 `{"address":"tiramisu.moenext.com","port":8911,"password":"...","name":"...","id":1173810,"stale":false}`（`password` 非空、`id` 匹配 `MC_ACCOUNT_ID`）。

**关键语义**（源码见 `mycard/ygopro-match` 分支 `arena` 的 `main.js`）：

| 现象 | 含义 | 处理 |
|---|---|---|
| 长时间无输出 | 还在排队（正常） | 保持等待；不要频繁 abort |
| `409` | 该账号已在 `playingPlayerPool`（已配到房/未结束）且 `reconnect:"drop"` | 查是否残留；`POST /ygopro/match/finish?usernameA=<name>` 清理（仅确认无进行中对局时） |
| `200` 但 password 与上次相同 | reconnect 模式返回旧房（stale） | `stale:true` → 等 20s 重排（`ranked-loop.ps1` 逻辑） |
| 180s+ 无响应 | athletic 队列无人（深夜常见）或前置故障 | 可换 `arena=entertain` 试一次区分；或等白天 |
| `cancel=1` | **无效参数**（服务端忽略）；取消=客户端 abort 请求 | 不要依赖它 |

**现行 `get-room.mjs` 超时**：首连 20s、leave 重试 240s（旧版本曾用 10 分钟长轮询，日志里会出现 `Error: match long-poll timeout`）。**超时不是故障**，只是"没配到"。

### 3.2 进房

**做什么**：`control_join({ip, port, pass})`（HTTP `POST /join?ip=&port=&pass=`）。

**判定成功**（全部满足）：
- `/net.connected == true`
- `/net.joined == true`
- 日志出现 `NET connected` / `NET joined room`（客户端控制日志）

**重试策略**：4 轮，每轮等 `connected && joined`（每 2s 查，最多 10 次）；仍失败 → `/leave` 后重排。

**常见失败**：
- 只弹出 LAN 窗口、`joined` 仍 false → 密码里 `+`/`/` 没 URL 编码（`encodeURIComponent`）。
- 房已关/密码错 → `/net.closeReason` 变成 `eof`/`error`，`/chat` 可能有系统消息。
- `connected=true, joined=false` → 还在等服务器回包，再等 2–5s。

### 3.3 选卡组

**做什么**：`control_deck({name:"BlackwingHT2S"})`（HTTP `POST /deck?name=`）。

**判定成功**：`/state.deckMain > 0`（如 40/41）且 `/lobby.deckMain >= 40`；客户端日志 `deck: select combo name=... -> confirmed`（或 `deck: load ok`）。

**卡组要求**：
- 主卡组 40–60、额外 ≤15、备牌 ≤15（`/state.side.limits`：`mainMin:40,mainMax:60,extraMax:15,sideMax:15`）。
- 排位要符合当前 lflist（不合规时 `/state.deckError.local.reason` 会给出原因，或进房后服务器发 `STOC_ERROR_MSG{msg:2(DECKERROR), code:DECKERROR_*}`）。
- Bo3 换备卡组必须保证 main/extra/side 张数**不变**（只换卡，不改数量），否则 `side_ok` 报 `counts must match`。

### 3.4 准备（`/ready`）

**做什么**：`control_ready()`，每 1–2s 一次，最多 ~30 次。

**判定成功**：`/lobby.ready[mySeat] == 1`（`mySeat` 来自 `/state.mySeat`，常见 0）。

**注意**：`ready` 是可重复的；不要等"对手也 ready"才发自己的。

### 3.5 开始（`/start`）——双方 ready ≠ 开局

**做什么**：`control_start()`，每 2–3s 一次，最多 ~20 次，**直到 `state.started==true`**。

**判定成功**：`/state.started == true`；客户端日志 `STOC_DUEL_START`；随后 `DUEL_START reset result state (match game N)`。

**为什么反复发**：服务端只在收到 `CTOS_HS_START` 时才推进；`lobby.bothReady=true` 不等于开局（历史坑：ready latch / start latch）。重复发送安全（客户端 latch 已修）。

**失败**：发满 20 次仍 `started=false` → 保存 `/state`、`/lobby`，`/leave` 重排；若日志有 `HS_NOTREADY`/`not host`，说明座位不对（launch seat 不是我们）。

### 3.6 先/后攻（TP）

**判定**：`/prompt.tpPending == true` 或 `/actions` 里有 `kind:"tp"`。

**做什么**：`/actions` 会返回两条：
```json
{"id":0,"kind":"tp","label":"tp first (index=1)","index":1}
{"id":1,"kind":"tp","label":"tp second (index=2)","index":2}
```
调 `control_act_id({id:0})` = 先攻，`{id:1}` = 后攻。

**日志**：客户端 `TP choice res=1 (from control)`；policy 侧 `TP-PICK first (index=1)`。

**LAN 特例**：测试可用环境变量 `YGO_TP=1|2` 让客户端自动应答（不经过 LLM）。

### 3.7 对局决策循环（核心）

```
loop:
  p = control_wait_prompt(since=lastSeq, timeout_ms=25000)   # 阻塞等
  if !p.awaiting: continue
  a = control_actions()
  if a.awaiting==false or a.actions.length==0: continue       # 不要动作
  选 id（按 kind 语义，见下表）
  control_act_id(id)
  lastSeq = a.seq
```

**kind → 选择语义**（完整表见 `MCP-INTERFACE.md` §5；这里给决策要点）：

| kind | 何时出现 | 怎么选 |
|---|---|---|
| `summon`/`spsummon`/`set_monster`/`set_spell` | `MSG_SELECT_IDLECMD` | 按场面/策略选卡（label 含 `code/lv/tuner`） |
| `activate` | 可发动（含手坑/陷阱） | 想发动选它；注意 `CHAIN` 语义 |
| `to_bp`/`to_ep` | 主阶段 | 进战阶/结束回合 |
| `attack` | `MSG_SELECT_BATTLECMD`（直连） | 选攻击/直接攻击 |
| `to_m2`/`end_battle` | 战阶 | 进主2/结束战阶 |
| `chain`/`decline` | `MSG_SELECT_CHAIN` | 接/不接连锁；`canDecline=false` 时必须接 |
| `yes`/`no` | 是否系 | 1/0 |
| `option` | 多效果选择 | 选第 N 个（默认 0 可能不是最优） |
| `position` | 表示形式 | `attack`/`defense` |
| `place` | 放格子 | 选合法格（label 带 bit/mask/ctrl/loc/seq） |
| `select` | 选卡 | 选前 N 张（N=`selectMin`） |
| `sum`/`counter`/`sort`/`announce` | 素材/指示物/排序/宣言 | 安全默认 |
| `auto` | 无 UI 分支的确认类 | 选它（安全默认） |
| `tp`/`side_ok` | 开局前/换备 | 见 §3.6/§3.9 |
| `side_move` | 不通过 actions 暴露 | 用 `control_side_move` |

**铁律**：
- **`seq` 去重**：同一条 prompt 只回一次；`awaiting=false` 不做动作。
- 动作提交后客户端可能立刻置 `awaiting=false`（正常）；下一轮重新 `wait_prompt`。
- 服务器对 `MSG_RETRY` 有计数（`/state.retryCount/retryStreak`）；连续重试说明编码/状态不对，**停下来重新读 `/actions`**，不要连发。
- 非法合成响应（`realMsg != synthMsg`）会触发 RETRY 死循环；发现 `retryStreak` 上涨先 `control_state` 对 `curMsg`。

### 3.8 一局结束

**判定**：`/state.winPlayer >= 0`（raw 座位；我们 seat 0 时 `1`=对手赢）或 `isWin/isLoss`；`winReasonName` 为原因（`LP_ZERO`/`SURRENDER`/`DISCONNECT`/`DECK_OUT`/`TIMEOUT`/`UNKNOWN`）。

**同时**：`/state.match.games` 追加一条 `{game,win,winnerSeat,reason,reasonName}`，`match.gamesWonLocal/gamesWonOpp` 更新。

**日志**：`MSG_WIN player=.. localPlayer=.. isWin=..`。

**接着**：Bo3 会进入换备（§3.9）；单局（非 match）可能直接 `STOC_DUEL_END`。

### 3.9 换备（Bo3，两端都要做）

**触发**：服务器发 `STOC_CHANGE_SIDE`；客户端日志 `SIDE pending: waiting for LLM side_ok`；`/state.side.pending=true`、`/actions` 出现 `{id:0,kind:"side_ok",label:"keep side deck (no changes) and continue"}`。

**读状态**：`/state.side`：
```json
{"available":true,"pending":true,"waiting":false,"waitingSeen":false,"lastWaitMs":0,"elapsedMs":0,
 "main":[{"code":...,"name":"...","count":N}],"extra":[],"side":[],
 "counts":{"main":40,"extra":15,"side":15},"pre":{"main":40,"extra":15,"side":15},
 "limits":{"mainMin":40,"mainMax":60,"extraMax":15,"sideMax":15},"error":null}
```

**换牌（可选）**：`control_side_move({code, from:"side", to:"main", n:1})` → `POST /side_swap?code&from&to&n`
- 成功：`{"ok":true,"queued":true,"main":41,"extra":15,"side":14}`（预测值；再读 `/state.side.counts` 确认）
- 失败：`{"ok":false,"error":"not enough copies in side (have 1, need 2)"}` / `from/to must be main|extra|side` / `side swap pending, retry`
- 允许方向：`side↔main`、`side↔extra`（即 `side→main`、`side→extra`、`main→side`、`extra→side`）
- **必须保持 main/extra/side 张数与 `pre` 一致**（只换不加减），否则 `side_ok` 拒绝。

**确认**：`control_side_done()`（= `/actions` 找 `kind:"side_ok"` → `/act_id?id=0`）
- 成功：`{"ok":true,"queued":true,"kind":"side_ok"}`；日志 `SIDE ok clicked (from control) visible=1`
- 失败：`{"ok":false,"error":"counts must match","sideError":"counts must match"}`（先修回张数）；`side swap pending, retry`/`side prompt not published yet, retry`（等 100–300ms 重试）

**等待对手**：`side.waiting=true`（瞬时，可能只有 0–16ms）+ `waitingSeen=true`（sticky）；**不要重复点 side_ok**。对手掉线/超时用 `/net` 判断。

**关键**：**只有双方都 `side_ok`，服务器才会发下一局 `DUEL_START`**。一端确认后另一端没动，你会一直停在 `waiting`。

**LAN 特例**：`YGO_SIDE_AUTO=1` 可让客户端自动确认（测试用）。

### 3.10 下一局（Game2/3）

**判定**：日志 `DUEL_START reset result state (match game 2) winPlayer=-1 awaiting=0 tp=0 side=0`；`/state.winPlayer` 重置 `-1`；`/state.match.game` 从 1 → 2；`side` 清空。

**然后**：重新 TP（§3.6）→ 决策循环（§3.7）。

### 3.11 整场结束

**判定**（任一）：
- `/state.lastStocName == "STOC_DUEL_END"` 或 `/net.lastStocName == "STOC_DUEL_END"`
- `/state.match.over == true`（Bo3 到 2 胜）

**报告**：`control_match()` → `summary`（例：`比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）`）。

**收尾**：`POST /leave`（`control_*` 无 leave 工具，用 HTTP：`http://127.0.0.1:7788/leave`）→ 杀客户端 → 重新排队（`get-room.mjs`）。

### 3.12 异常与判定（每种都给"依据 + 动作 + 日志关键字"）

| 异常 | 判定依据 | 该做什么 | 日志/字段关键字 |
|---|---|---|---|
| **空房**（进房后没人来） | `lobby.playerCount<2`/`statuses.Count<2` 持续 ≥35s（`ranked-loop -EmptyRoomSec`） | `/leave` → 重排 | `room is empty, waiting up to 35s` |
| **对手静默**（回合不动） | `winPlayer<0 && !awaiting && !sidePending && !tpPending` 且 `lastProgress` >150s（`-SilentAbortSec`） | 存证（state/net/截图）→ `/leave` 重排 | `silent duel for Ns (turn=.. curMsg=.. timeLeft=..)`；`NOPROMPT` |
| **对手挂机但有时间** | `timeLeft<=5` 且 idle >300s | `control_surrender` 结束本场再重排 | `opponent idle for Ns` |
| **连接断开** | `/net.state=="disconnected"`；`/net.closeReason` ∈ `eof/error/stop/exit` | 中止本场、重排；可先试 `/join` 同房重连（有 journal 时） | `connection lost ... closeReason=.. sinceStoc=..`；客户端 `NET disconnected reason=..` |
| **AKF 被踢前兆** | `/chat` 出现 `afk/倒计时/警告/将视为/超时` 等红字（服务端 90s 前警告） | 立刻处理当前 prompt；无动作可做 → surrender 干净结束 | `CHAT-WARN detected` |
| **stale room** | `get-room` 返回的 password 与上次相同（`stale:true`） | 等 20s 重排 | `stale room; wait 20s` |
| **MC API 超时** | 10 分钟+ 长轮询无房 / `match long-poll timeout` / `fetch failed` | 继续等/暂停；夜间队列空属正常；8 次失败可 pause 5–10 分钟 | `MC API unreachable (8 fails) -> pause 300s` |
| **客户端崩溃** | `/health` 无响应、进程消失 | 杀残留 → 重启 → 重排；保留 `control_crash.log`/`error.log` | `client gone (control layer down)`；`Failed to load card database` |
| **replay 阻塞** | 结算后不再前进；日志 `STOC_REPLAY` | 新客户端控制驱动已自动跳过（`replay: dialog skipped`）；旧客户端需 `YGO_SUPPRESS_MODALS` | `replay: dialog skipped (control-driven, no wait)` |
| **非法合成响应** | `retryStreak` 上涨、`MSG_RETRY` 连发 | 停手 → `control_state` 对 `curMsg`，只按 `/actions` 的真实 kind 选 | `retryCount/retryStreak`、`MSG_RETRY` |
| **ready latch** | 发了 ready 但 `lobby.ready[self]!=1` | 反复发（1–2s）；查 `/lobby.launchSeat` | `ready: clicking HP_READY via UI` |
| **start latch** | 双方 ready 但 `started=false` | 反复 `/start`（2–3s，≤20 次） | `start: HS_START #N`；`STOC_DUEL_START` |
| **deadline 从排队算** | 排队耗时吃掉了整场预算 | 每场计时**从 `duel started` 开始**（ranked-loop 已改为 `/state.started` 后开始） | `MATCH N done ... dur=` |
| **ghost room** | 直连 arena 服后 lobby 只有 `{pos:1,ready:true}` 的对手；ready 就退出 | 不要直连清理；`/leave` 重排（或等房间超时） | `players:[{pos:1,ready:true}]` |
| **`cancel=1` 无效** | 以为能取消排队却仍在等 | 取消 = abort 当前请求；不要用 `cancel=1` | —（见 `match-queue-research.md`） |
| **fetch headersTimeout** | Node fetch 报 `UND_ERR_HEADERS_TIMEOUT`/`Headers Timeout` | 长轮询不要用默认 300s？用脚本自带超时；重试即可 | `HeadersTimeoutError` |
| **YGO_TP/side 卡住** | LAN 测试设置 `YGO_TP`/`YGO_SIDE_AUTO` 后仍等 prompt | 确认客户端版本支持；检查 `/prompt.tpPending`/`sidePending` | `TP choice res=`、`SIDE ok clicked` |

---

## 4. 状态字段字典（真实字段名）

### 4.1 `GET /state`（顶层）

| 字段 | 含义 | 典型值（未进房 → 对局中） |
|---|---|---|
| `valid` | 快照是否有效 | `false` → `true` |
| `inDuel` | 是否在对局中 | `false` → `true` |
| `started` | 对局是否已开始（`STOC_DUEL_START` 后） | `false` → `true` |
| `turn` | 当前回合数 | `0` → `1..N` |
| `lp` | `[我方,对手]`（`lpOrder:"local"` 保证顺序） | `[8000,8000]` → `[8000,6500]` |
| `phase`/`phaseName` | 阶段号/名 | `-1/UNKNOWN` → `4/MAIN1` |
| `curMsg` | 当前内核消息 id | `0` → `11`（SELECT_IDLECMD）等 |
| `myPlayer`/`mySeat` | 本地视角（恒 0）/ 实际座位 | `0`/`0`（客机可能是 `1`） |
| `turnPlayerLocal` | 本地视角的回合玩家 | `-1` → `0`（你）/`1`（对手） |
| `isMyTurn` | 是否轮到你 | `false`/`true` |
| `winPlayer` / `winPlayerLocal` | 原始座位号 / 本地视角（0=你赢/1=对手赢/-1=无） | `-1` → `1`（我们 seat0 时=对手赢） |
| `isWin`/`isLoss`/`isDraw` | 本地视角胜负 | `false`/`false`/`false` → 一真 |
| `winReason`/`winReasonName` | 原始原因/名字 | `-1/UNKNOWN` → `1/LP_ZERO` |
| `match` | 整场 Bo3 结果（见 4.2） | 见下 |
| `chainMode` | 连锁模式 | `1`（`avail`） |
| `seq`/`awaiting` | prompt 序号/是否等你响应 | `0/false` → `5/true` |
| `sidePending`/`tpPending` | 换备/先后攻挂起 | `false`/`false` |
| `deckMain`/`deckExtra` | 卡组张数 | `0` → `40/15` |
| `counts` | `{hand,grave,remove,deck,extra}` 各 `[我,对]` | `{"hand":[5,5],...}` |
| `hand`/`monsters`/`spells`/`grave`/`banished` | 卡明细数组 `[我,对]`；卡 `{code,atk,def,pos,faceup,hidden,ty,lv,name,loc,seq}` | `[[],[]]` → 有卡 |
| `chainDepth`/`chainStack`/`chainCandidates`/`canDecline` | 连锁信息 | `0/[]/[]/true` |
| `ui` | UI 状态（弹窗/窗口） | 见 4.7 |
| `pipeline` | 管线诊断 | 见 4.6 |
| `net` | 网络/重连 | 见 4.5 |
| `resume` | 断线恢复信息或 `null` | `null` |
| `deckError` | 卡组错误详情 | `{local:{set:false,...},server:{...}}` |
| `side` | 换备（见 4.3） | `{available:false,...}` |

> 未在上表逐条列出的诊断/次要字段（`selftype`、`playerType`、`timeLeft`、`retryCount`、`lastRetryAfterMsg`、`retryStreak`、`placeVariant`、`lastMsg:{id,len,hex}`、`errorMsg`/`errorCode`、`uiCleanupCount`、`activeEffects`/`continuousEffects`、`hint`/`lastChainEvent`）含义见 `MCP-INTERFACE.md` §4 与 `CONTROL-API.md` §3.2；它们不是决策必需，排障时有用。

### 4.2 `/state.match`（整场；2026-11-13 版起）

```json
{"game":2,"over":true,
 "games":[{"game":1,"win":true,"winnerSeat":0,"reason":1,"reasonName":"LP_ZERO"},
          {"game":2,"win":true,"winnerSeat":0,"reason":4,"reasonName":"DISCONNECT"}],
 "gamesWonLocal":2,"gamesWonOpp":0,
 "lastWinnerLocal":true,"lastReasonName":"DISCONNECT"}
```

| 字段 | 含义 |
|---|---|
| `game` | 当前第几局（开局前 `0`；G1 中 `1`；G2 中 `2`…） |
| `over` | 整场是否结束（Bo3 到 2 胜） |
| `games[]` | 逐局：`win`(bool 本地视角)、`winnerSeat`(raw 座位 0/1)、`reason`(enum)、`reasonName`(原名) |
| `gamesWonLocal`/`gamesWonOpp` | 大比分 |
| `lastWinnerLocal`/`lastReasonName` | 最后一局本地胜负/原因 |

> `lastWinnerLocal` 在没打完一局时可能为 `null`（真实未开局采样：`"lastWinnerLocal":null,"lastReasonName":null`）。

### 4.3 `/state.side`

| 字段 | 含义 |
|---|---|
| `available` | 客户端支持换备接口（`true`） |
| `pending` | 轮到我换备（`/actions` 有 `side_ok`） |
| `waiting` | 我已确认、等对手（瞬时，0–16ms 常见） |
| `waitingSeen`/`lastWaitMs`/`elapsedMs` | sticky 诊断：是否等过/上次等了多久/当前等待毫秒 |
| `main`/`extra`/`side` | 各池卡 `[{code,name,count}]` |
| `counts`/`pre` | 当前张数/换备前张数（必须保持一致） |
| `limits` | `{mainMin:40,mainMax:60,extraMax:15,sideMax:15}` |
| `error` | 最近一次 `side_ok` 校验错误（如 `counts must match`） |

### 4.4 `/prompt`

| 组 | 字段 |
|---|---|
| 基础 | `seq` `curMsg` `turn` `awaiting` |
| 可召唤计数 | `summonable` `spsummonable` `msetable` `ssetable` `reposable` `activatable` `attackable` `chains` `chainForced` `lastChain` |
| 选卡 | `selectMin` `selectMax` `selectCancelable` `selectableCount` `selectableCards` |
| 阶段 | `canBp` `canEp` |
| 候选卡 | `summonableCards` `spsummonableCards` `msetableCards` `ssetableCards` `activatableCards` `attackableCards` |
| 连锁 | `chainDepth` `chainStack` `chainingTo` `chainCandidates` `canDecline` `hint` `lastChainEvent` |
| 放置 | `places` `placesMask` `placeCoords`（`"server"`） |
| 先/后攻/换备 | `tpPending` `tpOptions`（`[1,2]`）/ `sidePending` `sideSummary` `sideChooseBy` `sideError` |

### 4.5 `/net`（重连/存活）

| 字段 | 含义 |
|---|---|
| `connected`/`joined` | TCP 已连 / 已进房 |
| `connectState` | 0=未连，其它=连接阶段 |
| `closeReason` | **`none`（正常/未断）**、`eof`（对端 FIN，服务器主动关）、`error`（连接错误）、`stop`/`exit`（我们主动停/退）、`unknown` |
| `alive` | 存活判定（探活/STOC 综合） |
| `state` | `idle` / `healthy` / `disconnected` / `confirmed_dead` / `disconnected` |
| `inDuel`/`turn` | 对局中/当前回合 |
| `lastStocAt`/`lastStocName`/`sinceLastStoc` | 最近 STOC 时间/名字/距今 ms（`-1`=没有） |
| `uptimeMs` | 连接存活时长 |
| `probe` | `{enabled,unsupported,lastSentAt,lastReplyAt,rttMs,fails,lastReplyPlayerType,lastReplyText}` |
| `lastNetMsg` | `{id,text,ageMs}` 最近一条系统消息（`STOC_CHAT`） |

> 断线排查优先看 `closeReason` + `lastStocName` + `sinceLastStoc`；`eof` 且 `sinceLastStoc` 很大/很小都可能：小=服务器正在推倒计时后关（AFK 踢），大=链路静默后超时（见 `srvpro-disconnect-research.md`）。

### 4.6 `/state.pipeline`

`analyzeCount` `pumpCount` `msgCount` `seq` `awaiting` `lastStoc` `lastStocName` `sinceLastAnalyzeMs` `sinceLastPumpMs` `retryCount` `lastRetryAfterMsg` `lastNonRetryMsg` `retryStreak` `placeVariant` `autoDismiss` `dismissCount` `recentMsgs`（最近消息 id 轨迹）。

### 4.7 `/ui`

`chainMode`/`chainModeName`、`alwaysChain`/`chainWhenAvail`/`ignoreChain`/`desiredChainMode`/`appliedChainMode`/`applyPending`、`uiCleanupCount`、`popupMask`、`popups:{posSelect,options,cardSelect,cmdMenu,message}`、`windows`/`windowsVisible`（可见窗口名）。

### 4.8 `/lobby`、`/chat`、`/msg`、`/actions`

- `/lobby`：`{self,isHost,launchSeat,ready:[我,对],bothReady,playerCount,players,deckMain,statuses}`
- `/chat`：`{chats:[...]}`（最近 50 条；`afk`/`倒计时`/`非法卡组` 等系统消息在此）
- `/msg`：`{id,len,hex}`（最近一条 STOC 原文）
- `/actions`：`{seq,curMsg,awaiting,actions:[{id,kind,label,index?}],sidePending?,tpPending?,reason?}`

## 5. 结果与人话（`control_match` 的 4 种状态 + 原因翻译）

### 5.1 summary 的 4 种状态（真实输出的形态）

| 状态 | summary 示例 |
|---|---|
| 未开局 | `还没有开始对局` |
| 进行中 | `第 2 局进行中；当前大比分 1:0（你领先）` |
| 某局刚结束（局间/换备） | `第 1 局：你赢了，原因 LP_ZERO（对手 LP 归零）；当前大比分 1:0（你领先）` |
| 整场结束（赢） | `比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）` |
| 整场结束（输） | `比赛结束：你输了这场 Bo3（0:2）。最后一局原因：你 LP 归零（LP_ZERO）` |
| 平/未知 | `比赛结束：大比分 1:1` |

对应的 `match` 字段就是 `/state.match` 原样透传（`control_state` 里也能看到）。

### 5.2 原因翻译表（赢/输视角不同）

| 原名 | 你赢时 | 你输时 |
|---|---|---|
| `SURRENDER` | 对手投降 | 你投降 |
| `LP_ZERO` | 对手 LP 归零 | 你 LP 归零 |
| `DECK_OUT` | 对手抽卡耗尽 | 你抽卡耗尽 |
| `TIMEOUT` | 对手超时 | 你超时 |
| `DISCONNECT` | 对手掉线/失联 | 你掉线/失联 |
| 其它 | 原样输出 | 原样输出 |

### 5.3 真实场次示例（供 LLM 学习"人话"）

来自真实排位日志（`ranked/logs/loop-20261113-112706/run.log`）：

- `GAME 1 result raw=1 isWin=False reason=LP_ZERO turn=2 lp=0/8000` → 这一局我们输（`winPlayer=1` 是**原始座位号**，不是"你赢"）。
- `GAME 2 result raw=1 isWin=False reason=LP_ZERO turn=4` → Game2 也输；`STOC_DUEL_END` → 整场 0:2：
  `control_match().summary` = `比赛结束：你输了这场 Bo3（0:2）。最后一局原因：你 LP 归零（LP_ZERO）`。
- 来自 `loop-20261111-101707/run.log`：`GAME 1 result raw=0 isWin=True reason=SURRENDER`、`GAME 2 result raw=0 isWin=True reason=DISCONNECT` → 整场 2:0：
  `比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）`。

> 铁律：**永远不要**用 `winPlayer` 推整场；用 `isWin/winPlayerLocal` 判当前局，用 `control_match` 判整场。

---

## 6. 计时与节奏（照这个做就不会被踢/不会抢动作）

### 6.1 动作节奏表

| 动作 | 建议间隔/超时 | 说明 |
|---|---|---|
| `control_wait_prompt` | `timeout_ms` 20000–30000 | 长轮询；超时正常，重新调用即可（`since` 传上次 seq） |
| `control_actions` → `control_act_id` | **立即**（<1s） | 拿到候选就选、提交；不要 sleep 思考太久 |
| `control_state` 轮询 | 2–3s | 监控用；不要 100ms 级轮询 |
| `/ready` | 每 1–2s，≤30 次 | 直到 `lobby.ready[self]==1` |
| `/start` | 每 2–3s，≤20 次 | 直到 `state.started==true` |
| `/side_swap` 后重试 | 100–300ms | 等 UI 线程落地；读 `/state.side.counts` 确认 |
| `side_ok` 失败重试 | 100–300ms（`retry` 类错误） | `counts must match` 不要重试，先改回张数 |
| `/chat` 轮询 | 1–2s | 抓服务器警告（AFK/倒计时/非法卡组） |
| 整场监控循环 | 3s | `ranked-loop` 的 `Start-Sleep 3` |
| 空房判定 | 35s（可配 `-EmptyRoomSec`） | 进房后 35s 无第二人 → `/leave` |
| 对手静默判定 | 150s（可配 `-SilentAbortSec`） | 无 `awaiting`/无 side/tp 且无进展 → `/leave` |
| stall 判定 | 75s（`-StallSec`） | awaiting 超过 75s 视为卡住，取证 + nudge |
| 单步决策上限 | **<60s（目标 <30s）** | 服务端 AFK ~90s 踢人；踢前有红字警告 |
| 单场预算 | 18 分钟（`-MaxMinutesPerMatch`） | 从 `duel started` 起算（不是排队） |
| 总预算 | 90 分钟（`-MaxTotalMinutes`） | 包含排队时间 |

### 6.2 串行 vs 并行

- **必须串行**：`/actions` → `/act_id`（同一 prompt）；`side_swap` → 读 counts → `side_ok`；`/join` → 等 `connected && joined` → `/deck` → `/ready` → `/start`。
- **可以并行**（只读）：`/state`、`/net`、`/ui`、`/chat` 的轮询互不影响。
- **不要并行**：同时多个 `/act_id`（重复响应 → `MSG_RETRY`）；同时跑 `policy-semantic.mjs` 和 LLM（抢动作）。

### 6.3 LLM 调用预算建议

- 一个 turn 内最多 1 次 `control_wait_prompt` + 1 次 `control_actions` + 1 次 `control_act_id`（≈3 次工具调用）。
- 超过 10 秒还没决定 → 选安全动作（`to_bp`/`to_ep`/`decline`/第一个合法候选），**不要**让客户端空等 > 60s。
- 每局结束/换备/整场结束各调一次 `control_match`，不要每 turn 调。

---

## 7. 完整实战脚本示例

### 7.1 从"拿到房"到"3/3 完成"（伪代码，MCP 工具名）

```text
# 0) 环境检查（可选）
control_health()                       # {"ok":true,"started":true}
control_state()                        # inDuel=false, match.game=0

for n in 1..3:                         # 3 场 Bo3
  # 1) 排队拿房（外部脚本）
  room = GET /room  via bridge/get-room.mjs   # 长轮询；429/409 按 §3.1 处理
  #   → {address, port, password, stale}
  if room.stale: sleep 20s; continue queue
  # 2) 进房
  control_join({ip:room.address, port:room.port, pass:room.password})
  wait_until /net.connected && /net.joined   (4 轮，每 2s)
  # 3) 选卡组
  control_deck({name:"BlackwingHT2S"})
  wait_until /state.deckMain >= 40
  # 4) 准备
  repeat until /lobby.ready[/state.mySeat]==1 (1-2s，≤30 次):
      control_ready()
  # 5) 开始（反复发）
  repeat until /state.started==true (2-3s，≤20 次):
      control_start()
  # 6) 对局主循环
  lastSeq = 0
  loop:
      p = control_wait_prompt({since:lastSeq, timeout_ms:25000})
      if !p.awaiting: continue
      s = control_state()
      if s.match.over: break                      # 整场已结束
      a = control_actions()
      if !a.awaiting || a.actions.empty: continue
      if prompt.tpPending:  id = pick_tp(a)       # 0=先攻 1=后攻
      elif sidePending:     id = 0                # side_ok
      else:                 id = pick_by_kind(a)  # 见 §3.7
      control_act_id({id})
      lastSeq = a.seq
      if s.inDuel == false and s.match.games.length > lastGameCount:
          report control_match()                  # 每局结束报一次
  # 7) 整场结束
  while /state.lastStocName != "STOC_DUEL_END" and !/state.match.over:
      sleep 2s; monitor loop (see §6.1)
  m = control_match()                              # {"match":..., "summary":"比赛结束：..."}
  POST /leave
  kill client; re-queue for next match
```

### 7.2 真实 run 时间线（`ranked/logs/loop-20261113-112706/run.log`）

```
[11:27:07] resume consecutive streak 1/3
[11:27:08] client up after 1s (procs=1) health={"ok":true,"started":true}
[11:37:08] queue attempt 1 failed raw=[... match long-poll timeout ...]   ← 排队 10 分钟没房（长轮询正常超时）
[11:47:54] queue attempt 2 failed raw=[... match long-poll timeout ...]
[11:58:39] queue attempt 3 failed raw=[... match long-poll timeout ...]
[12:05:53] room tiramisu.moenext.com:8911                                  ← 配到房
[12:05:53] join attempt 1 -> {"ok":true,"queued":true}
[12:05:55] join confirmed (connected+joined)                              ← 进房成功
[12:05:57] room is empty, waiting up to 35s for an opponent
[12:06:00] deck -> {"ok":true,"queued":true}                              ← 选卡组
[12:06:06] lobby ready=1,1 self=0 bothReady=True
[12:06:08] start: HS_START #1 (bothReady=True players=2)                 ← 反复 start
[12:06:13] start: HS_START #2
[12:06:17] start: HS_START #3
[12:06:17] lobby ready=1,1 self=0 bothReady=True
[12:06:17] duel started                                                    ← /state.started=true
[12:10:05] GAME 1 result raw=1 isWin=False reason=LP_ZERO turn=2 lp=0/8000
[12:10:08] self answered side_ok id=0 -> {"ok":true,"queued":true,"kind":"side_ok"}
[12:10:37] self answered tp id=0 -> {"ok":true,"queued":true,"kind":"tp","index":1}
[12:17:11] GAME 2 result raw=1 isWin=False reason=LP_ZERO turn=4
[12:17:11] STOC_DUEL_END -> match over                                  ← 整场结束
[12:17:14] MATCH 1 COMPLETE (2/3 consecutive bo3 done, games=2)
...
[12:37:59] MATCH 2 COMPLETE (3/3 consecutive bo3 done, games=2)
```

（这段里 `raw=1` 是原始座位号 → `isWin=False`；要报给人看必须用 `control_match`。）

### 7.3 最简 LAN 自测序列（不用 MC 匹配）

```
# 房主
YGO_CONTROL_PORT=7788 YGO_TP=1 YGO_SIDE_AUTO=1 .\YGOPro.exe -c -h 127.0.0.1 -p 7911 -n HostA -d BlackwingHT2S -k
# 客机
YGO_CONTROL_PORT=7789 YGO_TP=2 YGO_SIDE_AUTO=1 .\YGOPro.exe -h 127.0.0.1 -p 7911 -n GuestB -d BlackwingHT2S -k
# 双方 /ready → 房主 /start（反复）→ 对局 → side → Game2/3 → STOC_DUEL_END
```

---

## 8. 排错表（症状 → 原因 → 检查 → 处理）

| 症状 | 可能原因 | 检查（命令/字段/日志） | 处理 |
|---|---|---|---|
| `control_wait_prompt` 一直超时 | 还没开局/对手回合 | `/state.turn`,`/state.awaiting`,`/lobby.bothReady` | 等到 `awaiting=true`；别硬发动作 |
| `wait_prompt` 立即返回、`seq` 不变 | 唤醒条件含 `!awaiting` | `/state.pipeline.awaiting` | 过滤 `awaiting && seq>lastSeq` |
| 动作后无进展、`retryStreak` 涨 | 非法/重复响应 | `/state.retryCount`,`retryStreak`,`curMsg` | 停手 → 重新 `/actions`，只按真实 kind 选 |
| 整场 `winPlayer` 仍是上局结果 | 旧客户端未重置 | `/state.match.game` 是否递增；日志 `DUEL_START reset` | 升级客户端（14:51:46+）；policy 用 `isWin` |
| ready 发了但 `lobby.ready` 不变 | 卡组未加载/界面未到 | `/state.deckMain`,`/lobby`,日志 `ready: clicking HP_READY` | 先 `/deck`，再重试 ready |
| 双方 ready 但 `started=false` | start latch / 没发 HS_START | `/state.started`,`/lobby.launchSeat`；日志 `STOC_DUEL_START` | 反复 `/start`（≤20 次，2–3s） |
| 进房后立刻被踢 | 密码错/房已关/被顶号 | `/net.closeReason`,`/chat`,`/state.errorMsg` | 重新排队；不要重复 join 同一房 |
| 进房后 lobby 只有 `{pos:1,ready:true}` | ghost room（旧连接残留） | `/lobby.players`、`/net.uptimeMs` | `/leave` 重排；不要直连 arena 服“清理” |
| 结算后卡住不动 | replay 保存对话框 | 日志 `STOC_REPLAY`；`/ui.popups` | 新客户端自动跳过（`replay: dialog skipped`）；旧客户端加 `YGO_SUPPRESS_MODALS` |
| 中途 `eof`、`sinceLastStoc` 很小 | 服务端 AFK 踢（~90s） | `/chat` 是否有 afk/倒计时警告；决策耗时 | 决策压到 <60s；无解则 surrender 干净结束 |
| 中途 `eof`、`sinceLastStoc` 很大 | 链路静默/掉线 | `/net.probe.fails`,`/chat` | 判失联，重排/重连 |
| 排队永远拿不到房 | athletic 无人（深夜）/API 故障 | `authUser` 200、`/ygopro/match/stats/athletic` | 等到白天/换 arena 验证；见 `match-queue-research.md` |
| `cancel=1` 后仍排队 | 服务端不认 cancel | — | 取消 = abort 请求；不要依赖参数 |
| Node fetch 报 `HeadersTimeout` | 长轮询超默认头超时 | 脚本超时配置 | 用脚本自带超时重试；不是服务端错误 |
| 客户端启动即退 | 缺 cards.cdb/工作目录错 | `error.log`、`control_crash.log` | cwd 用 `mycard-bot/game`（有 cards.cdb） |
| 卡组被拒（DECKERROR） | lflist 不符/卡数不对 | `/state.deckError`、`STOC_ERROR_MSG msg=2` | 换合法卡组（BlackwingHT2S） |
| 换备 `counts must match` | 换牌改变了张数 | `/state.side.counts` vs `pre`/`limits` | 只换不增减（换出=换入） |
| 换备卡在 `waiting` | 对手未确认 | `side.waitingSeen`,`/net.alive` | 等；对手失联则重排 |
| TP 没出现但直接开局 | 客户端自动应答（`YGO_TP`） | `/prompt.tpPending` | 正常；LLM 驱动时不要设 `YGO_TP` |
| `NOPROMPT 180s` | 管线卡住/对手静默 | 当时 dump 的 state/net/ui/prompt | 看 `pipeline.recentMsgs`；必要时 `/leave` |
| 连续输但打完 | 策略保守（非流程） | `control_match`、`/state.match.games` | 改策略，不是修链路 |

---

## 9. 已知限制（如实）

1. **排位 LP_ZERO 结算不触发 replay 保存框**：`STOC_REPLAY` 跳过路径已 LAN 实机验证（双方各 2 次 `replay: dialog skipped`、`replay-save=0`、`stoc=23 stall=0`），但排位自然结算暂未遇到该路径（不影响稳定性）。
2. **胜率依赖策略**：管线能完整打完；输局主要是策略保守（大量 `decline`/`to_bp`/`end`），不是卡死。
3. **MC 匹配 API 夜间可能无人/不可用**：`/ygopro/match` 是长轮询，深夜 athletic 队列空时表现为"一直超时"，不是队列卡死（见 `match-queue-research.md`）。
4. **单账号限制**：排位只用 `1173810`（`MC_ACCOUNT_ID` 锁定）；不要多开排队（同 IP >5 会被 `too_much_connection` 踢）。
5. **LAN 不支持中途续局**：仅线上支持受控掉线重连（~13s 回同房）。
6. **深链未实测**：真实对局只验证到 `chainDepth=1`；`depth>=2` 按语义推演。
7. **UI 注入非 100%**：`place`/`attack` 偶发点击失效会直连回退（`UI fallback`，残余 5%~11%）。
8. **策略与 LLM 不可同时跑**：会互相抢动作；二选一。
9. **`/leave` 是 HTTP 端点**（MCP 无对应工具）：`POST http://127.0.0.1:7788/leave`。
10. **指纹/构建**：本文档对应 `2026-11-13 14:51:46 / 6,319,104 B`；旧 exe 缺 `/state.match`/side 等字段，`control_match` 会降级（`fallback:true`）。

---

## 附录 A：文档索引

| 文档 | 用途 |
|---|---|
| **本文件 `PLAYBOOK-FULL.md`** | **权威操作手册（零歧义全流程）** |
| [`MATCH-PLAYBOOK.md`](MATCH-PLAYBOOK.md) | 精简版（agent 快速参考） |
| [`MCP-INTERFACE.md`](MCP-INTERFACE.md) | 字段/工具权威契约 |
| [`RANKED-REPORT.md`](RANKED-REPORT.md) | 排位实战记录与踩坑 |
| [`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md) / [`reconnect-lab.md`](reconnect-lab.md) | 掉线重连设计/实测 |
| [`net-probe.md`](net-probe.md) | `/net` 时间线与探活 |
| `match-queue-research.md`（`ranked/logs/`） | MC 匹配队列/长轮询研究 |
| `srvpro-disconnect-research.md`（`ranked/logs/`） | 服务端断连原因研究 |

## 附录 B：本手册示例的真实采样来源

- `/state` 未进房真实采样：`ranked/logs/playbook-samples/state.json`（含 `match:{game:0,over:false,games:[],...}`、`side.limits`、`net.closeReason:"none"`）
- `/prompt`、`/lobby`、`/net`、`/ui`、`/actions`、`/chat` 采样：`ranked/logs/playbook-samples/*.json`
- 真实排位时间线：`ranked/logs/loop-20261113-112706/run.log`
- LAN `/state.match` 验收：`ranked/logs/match-state-20261113-145150/`、`ranked/logs/lan-match-state-validation.md`
- 断连/队列研究：`ranked/logs/srvpro-disconnect-research.md`、`ranked/logs/match-queue-research.md`

