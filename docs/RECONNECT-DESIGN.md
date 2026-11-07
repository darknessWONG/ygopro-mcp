# 重连设计（RECONNECT DESIGN）

> 状态：**设计稿（未实现代码）**。依据 2026-11-06 的本地 LAN 掉线实验（[`reconnect-lab.md`](reconnect-lab.md)）+ 用户对线上排位的实际观察。
> 目标读者：后续实现客户端 prober / `supervisor.mjs` / 策略侧改造的工程师或 AI。
> 涉及文件：`mycard-client/gframe/control.cpp`（扩展现有控制层）、`bridge/supervisor.mjs`（新增）、`bridge/policy-semantic.mjs`（小改）、`bridge/docs/*`。

---

## 1. 目标与边界

### 1.1 目标

1. **线上排位**：客户端掉线（关窗/网络断/进程崩）后，自动把对局**重进同一房间并续上**（用户手动验证过：关客户端 → 重开 → 同房号+密码 → 点准备，即可回到对局）。
2. **自动检测**：客户端能自动探测"连接是否已死"（不依赖人去看窗口），supervisor 自动完成重启与重连，策略无需感知细节。
3. **上下文不丢**：服务端不重发连锁历史，因此**连锁上下文必须本地 journal 落盘 + 重连后恢复**。

### 1.2 边界（不做什么）

| 边界 | 说明 |
|---|---|
| **本地 LAN 服务端不支持中途重进** | 实验证明：kill 客机瞬间对局以 `MSG_WIN reason=4 (DISCONNECT)` 结束；重进客户端 TCP 能连、能发 `HS_READY`，但**收到 0 条 STOC**（`OnMessageBegin=0`），turn/LP/场面全为零。LAN 端只能验证**客户端收尾 + supervisor 状态机 + journal**，不能验证"续局成功"。 |
| **协议不重发连锁历史** | 即便线上支持 resume，`chainStack/chainingTo/chainCandidates` 也不会被服务端补发 → 必须靠本地 journal（§5）。 |
| **不改 ygopro 协议、不伪造包** | 重连只用现有 join/ready 流程（`CTOS_JOIN_GAME` / `CTOS_UPDATE_DECK` / `CTOS_HS_READY`）；不构造自定义包。 |
| **策略不做重连决策** | 重连是 supervisor 的职责；LLM/策略只消费"已断开/已恢复"的语义事件（§6）。 |
| **不碰排位以外的自动化** | 本设计只服务"掉线恢复"，不做挂机/刷分；登录与会话仍由用户手动完成。 |

### 1.3 关键事实（来自实验，作为设计输入）

- 掉线瞬间：存活方立即收到 `MSG_WIN player=N reason=4(DISCONNECT)`，停在「You Win/失去连接」结算层。
- 重进（LAN）：客户端日志 `join: host=... port=... → StartClient create=0 → ready: enter (connected=1) → UpdateDeck → HS_READY`，**单边握手成功**；但 `OnMessageBegin=0`、真实 `STOC_*=0`、`/state.pipeline.msgCount=0`。
- host 侧（服务端）日志：`MSG_WIN` 之后 **0×`CTOS type=`（含 0x12 JoinGame）、0×`HS_PLAYER_ENTER/CHANGE`、0×`join/DuelPlayer`**；`/lobby` 旧座位冻结（`ready=[1,1] statuses=[9,25]`）→ **服务端根本没把重进当 join 处理**。
- 客户端卡模态框：重进失败会弹 irrlicht 原生 `addMessageBox`（`无法连接到主机`，strings id **1400**），等人工点 OK；但 `/health`、`/state` 仍响应（不是 API 死锁）。
- 客户端可复用：重新起房后能干净开新局（实验 B）。

---

## 2. 三层职责表

> 原则：**探测自动、接口只读、LLM 不触发**。LLM 永远不需要（也不允许）主动调 `/reconnect`。

| 层 | 进程/文件 | 职责 | 明确不做 |
|---|---|---|---|
| **客户端** | `YGOPro.exe` + `control.cpp` 扩展 | ① 自动 prober（`/tip` 探活 + 被动 `sinceLastStoc`）<br>② `/net` 只读状态<br>③ 断线收尾（关原生模态框、保存 `lastRoom`、置 `disconnected`）<br>④ `/reconnect` / `/leave` 供 supervisor 调用<br>⑤ journal 落盘（§5） | 不做重试编排、不重启自身、不决定"要不要重连" |
| **supervisor** | `bridge/supervisor.mjs`（新增，常驻；**`--profile lan\|ranked`**） | **`--profile ranked`（默认，线上）**：1s 循环读 `/net`，`confirmed_dead` → 重启客户端 → 同房号/密码 join → `/ready` → VERIFY（turn/LP/seat）→ 拉起 policy；退避与失败记账。<br>**`--profile lan`**：**只检测 + 记账 + 收尾清理**，`confirmed_dead` 后直接 `RESULT(reason=lan-no-resume)`，**不重启、不 join、不重连**（LAN 续局必失败）。<br>可选 **`--lan-restart-game`**：仅 `--profile lan` 下用于本地长稳测试——掉线后以**新局**重启（日志明确标注 `new-game (NOT resume)`）。 | 不直接读内存、不改客户端逻辑；不替 LLM 打牌；`--profile lan` 下不含任何重连尝试 |
| **策略** | `bridge/policy-semantic.mjs` | 收到 `disconnected` 打印 stats 退出（不做重连决策）；恢复后被 supervisor 重新拉起，读 `/state.resume` 从当前 prompt 继续 | 不轮询 `/net`、不调 `/reconnect`、不自行重启客户端 |

### 2.1 客户端新增接口（设计契约）

| 接口 | 方法 | 返回（只读） |
|---|---|---|
| `/net` | GET | `{state, role, room:{addr,port,passHash,joinedAt}, lastStocName, sinceLastStocMs, probe:{enabled,intervalMs,lastAtMs,rttMs,failStreak,lastReplyText,lastError}, pipeline:{analyzeCount,msgCount,sinceLastAnalyzeMs,sinceLastPumpMs}, uptimeMs, version}` |
| `/reconnect` | POST | `{ok, attempt, state, error?, elapsedMs}`（用 `lastRoom` 重新 StartClient+join+ready；幂等、有 attempt 去重） |
| `/leave` | POST | `{ok}`（清理当前房间/连接，供 supervisor 重启前调用） |
| `/tip` | GET（内部/调试） | `{ok, sent, rttMs?, replyText?}`（手动触发一次探活；prober 自身也会自动调用同样逻辑） |
| `/state` 扩展 | GET | 新增 `resume:{stale,seqReset,preTurn,nowTurn,gapMs,chainContextLost}`、`net:{state,sinceLastStocMs}` |
| `/wait_prompt` 扩展 | GET | 断线时不阻塞：返回 `{disconnected:true, reconnect:{state,attempt,etaMs}}` |

`/net.state` 取值：`healthy | idle | probing | probe_failed | confirmed_dead`（§3.1）。

---

## 3. 状态机

### 3.1 客户端检测状态（`/net.state`）

```
                 (有 STOC / prompt 活动)
        ┌──────────────────────────────┐
        │                              ▼
   ┌─────────┐  idle>3s   ┌──────┐  探测窗口到   ┌─────────┐
   │ healthy │ ─────────▶ │ idle │ ───────────▶ │ probing │
   └─────────┘            └──────┘              └────┬────┘
        ▲                        ▲                   │ STOC_CHAT(type=8) 收到
        │                        │                   ▼
        │                        │              ┌─────────┐
        │                        └──────────────│ 成功    │
        │                                       └─────────┘
        │ 下次探测成功
   ┌──────────────┐  失败1次   ┌─────────┐  连续2次失败 / DUELING 中 sinceLastStoc>15s
   │ probe_failed │ ─────────▶ │ 判死候选 │ ─────────────────────▶ ┌───────────────┐
   └──────────────┘            └─────────┘                        │ confirmed_dead│
                                                                  └───────┬───────┘
                                       客户端重启并 /reconnect 成功 ◀──────┘
```

**转换条件表**

| 从 | 到 | 条件 |
|---|---|---|
| healthy | idle | 无 STOC/prompt 活动且空闲 > 3s |
| idle | probing | 到达探测窗口（间隔 ≥5s）且 `probe.enabled` |
| probing | healthy | 收到 `STOC_CHAT(player_type==8)`（或任何 STOC）且在窗口内 |
| probing | probe_failed | 探测超时（3s）/发送失败 / 收到网络错误 |
| probe_failed | healthy | 下一轮探测成功 |
| probe_failed | confirmed_dead | 连续 2 次失败，或（DUELING 中）`sinceLastStocMs > 15000` |
| healthy/idle | probe_failed | （DUELING 中）`sinceLastStocMs > 15000` 触发被动判死候选 |
| confirmed_dead | healthy | 客户端重启 + `/reconnect` 成功 + 收到首个 STOC |

### 3.2 supervisor 状态机

> **LAN 与 ranked 的差异由 `--profile` 决定**：`--profile ranked`（默认）走完整 RECONNECTING/VERIFY 流程；
> `--profile lan` 在 `confirmed_dead` 后**直接进 `RESULT(reason=lan-no-resume)`**（不经过 RECONNECTING、不重启、不 join）。
> `--lan-restart-game` 只影响 lan profile 下 RESULT 之后的动作（可选：以新局重启，而非续局）。

**`--profile ranked`（默认，线上）**

```
      ┌──────┐  net=healthy && room
      │ IDLE │ ─────────────────────────────────▶ ┌───────┐
      └──────┘                                     │ READY │
           ▲                                       └───┬───┘
           │                                           │ policy 启动 / 首个 prompt
           │                                           ▼
           │                                       ┌─────────┐
           │  net=probe_failed                     │ DUELING │
           │  ┌────────────────────────────────────┴────┬────┘
           │  ▼                                         │ net=confirmed_dead
           │ ┌────────┐   退避计时到                      ▼
           │ │ QUEUED │ ─────────────┐            ┌──────────────┐
           │ └────────┘              │            │ RECONNECTING │
           │      ▲                  ▼            └───────┬──────┘
           │      │            ┌──────────┐  重启客户端+reconnect+ready
           │      └────────────│ VERIFY   │◀──────────────┘
           │   retry<max       └────┬─────┘
           │                        │ turn>=preTurn && LP 合法
           │                        ▼
           │                    ┌─────────┐  拉起 policy
           └────────────────────│ DUELING │◀──────────────┐
                                └─────────┘
                        retry>=max / 不可恢复
                                ▼
                           ┌────────┐
                           │ RESULT │（写失败记账并退出）
                           └────────┘
```

**`--profile lan`（本地测试 / LAN）**

```
      ┌──────┐  net=healthy && room
      │ IDLE │ ─────────────────────────────────▶ ┌───────┐
      └──────┘                                     │ READY │
           ▲                                       └───┬───┘
           │                                           │ policy 启动
           │                                           ▼
           │                                       ┌─────────┐
           │                                       │ DUELING │
           │                                       └────┬────┘
           │  net=probe_failed                         │ net=confirmed_dead
           │  （只记录，不动作）                        ▼
           │                                    ┌────────────────────────┐
           └────────────────────────────────────│ RESULT                 │
                                                │ reason=lan-no-resume   │
                                                │ （不重启/不 join）      │
                                                └───────────┬────────────┘
                                                            │ --lan-restart-game（可选）
                                                            ▼
                                                ┌──────────────────────────┐
                                                │ 重启客户端 → 开新局       │
                                                │ 日志: new-game (NOT resume)│
                                                └──────────────────────────┘
```

**转换条件表**

| 从 | 到 | 条件（profile 无关项已标注） |
|---|---|---|
| IDLE | READY | `/net.state=healthy` 且 `room.joinedAt` 存在 |
| READY | DUELING | policy 已启动（`/state.started=true` 或首个 `/wait_prompt` 有 prompt） |
| DUELING | QUEUED | **仅 ranked**：`/net.state=probe_failed`（软失败，先等确认） |
| DUELING | RECONNECTING | **仅 ranked**：`/net.state=confirmed_dead` |
| DUELING | RESULT | **仅 lan**：`/net.state=confirmed_dead` → `reason=lan-no-resume` |
| QUEUED | RECONNECTING | 退避时间到 或 `state=confirmed_dead` |
| QUEUED | IDLE | 退避期间 `state` 回到 `healthy`（误报恢复） |
| RECONNECTING | VERIFY | 客户端重启完成 + `/reconnect` 返回 ok + `/ready` 成功 |
| VERIFY | DUELING | `turn >= preTurn`（正常对局 turn 单调）且 `lp/counts` 合法；拉起 policy |
| VERIFY | QUEUED | 超时（≤20s）或校验失败；`retry++` |
| QUEUED/RECONNECTING | RESULT | `retry >= max`（默认 3）或不可恢复错误（如账号被顶掉） |
| RESULT | (新局) | **仅 lan 且带 `--lan-restart-game`**：重启客户端并以新局方式拉起 policy，日志标注 `new-game (NOT resume)` |

**退避**：`1s, 2s, 4s, 8s, 15s`（上限 30s），每次尝试写 `attempt`；失败原因分类：`client-restart-fail / join-fail / ready-fail / verify-fail / lan-no-resume`（lan profile 直接终态，不重试）。

---

## 4. 探活细节

### 4.1 `/tip` 探活（线上）

- **发送**：`CTOS_CHAT`（参考客户端现有发送点 `mycard-client/gframe/event_handler.cpp:1977`：`SendBufferToServer(CTOS_CHAT, msgbuf, (len+1)*sizeof(uint16_t))`），文本为 `/tip`（UTF-16）。
- **判定**：服务端回 `STOC_CHAT`，其中 `chat_player_type == 8` 表示"system custom message"（`duelclient.cpp:861` 起解析，`player_type==8` 分支），客户端会把它显示为系统消息。
- **现状缺口**：`Control::OnChat(const uint16_t* msg, size_t len)`（`control.cpp:886`）**没有接收 `player_type`** → 需要改成 `OnChat(uint16_t player_type, const uint16_t* msg, size_t len)`，在 `duelclient.cpp` 的 `STOC_CHAT` 分支（已读出 `chat_player_type`）把该值传进来，并记录 `probe.lastReplyText`。
- **频控**：
  - `idle > 3s` 才允许探测；
  - 同一客户端**探测间隔 ≥ 5s**；
  - 探测响应窗口 3s；
  - 连续 2 次失败 → `probe_failed`；`DUELING` 中 `sinceLastStocMs > 15000` 直接 `confirmed_dead`。
- **被动探活**：任何 `STOC_*` 到达时更新 `lastStocTick`（新增，与现有 `g_lastStocId` 同处记录：`control.cpp:139/806`），`/net.sinceLastStocMs` 由它算。
- **误报规避**：
  - 自己刚提交动作、`awaiting=true` 或 UI 600ms 校验期间**不计**超时；
  - 只在 `DUELING`（`/state.started && inDuel`）阶段允许"被动判死"；
  - 客户端刚启动/刚恢复的 5s 内不判死。

### 4.2 LAN / 无 `/tip` 场景退化

| 场景 | 退化规则 |
|---|---|
| LAN 服务端不回应 `/tip`（本实验未验证有回应） | 连续 2 次探测失败后 **关闭 prober**（`probe.enabled=false`），记录 `probe.unsupported=true`，改用"被动 STOC 超时"判定 |
| 完全无网络活动（大厅/准备阶段） | 只判 `idle`，不判死（`/net.state` 最高到 `probe_failed`） |
| LAN 重连 | **不重连**（`--profile lan`）：`confirmed_dead` → 直接 `RESULT(reason=lan-no-resume)`，不重启客户端、不 join；
  需要本地长稳测试时用可选 `--lan-restart-game`：以**新局**重启（日志 `new-game (NOT resume)`），绝不假装续局 |

---

## 5. 连锁上下文 journal

### 5.1 文件与格式

- 路径：`mycard-bot/game/resume-context.json`（客户端写；supervisor/policy 只读，重连成功后由 supervisor 归档为 `resume-context.used-<ts>.json`）。
- 原子写：先写 `.tmp` 再 `rename`（Windows 用 `MoveFileEx(REPLACE_EXISTING)`）。
- 结构：

```json
{
  "savedAt": "2026-11-06T18:01:02.345Z",
  "clientBuild": "2026-11-06 02:56:20",
  "room": { "addr": "127.0.0.1", "port": 7911, "passHash": "sha256:…" },
  "turn": 7,
  "mySeat": 1,
  "phase": 4,
  "lp": [7300, 6100],
  "chainDepth": 1,
  "chainStack": [ { "link":1,"code":84749824,"name":"神之警告","ctrl":0,"loc":8,"seq":0,
                    "type":"effect","forced":false,"isMine":true,"solved":false,
                    "summary":"我方[神之警告] 已加入连锁" } ],
  "chainingTo": { "link":1,"code":84749824,"name":"神之警告","summary":"我方[神之警告]" },
  "canDecline": true,
  "pendingPrompt": {
    "seq": 123, "curMsg": 16, "awaiting": true,
    "chainCandidates": [ { "index":0,"code":53582587,"name":"激流葬","forced":false,"isMine":true } ]
  }
}
```

### 5.2 写入时机

| 触发 | 说明 |
|---|---|
| `chainStack` / `activeEffects` 变化 | 链成立/结算/清空时立即写 |
| `lastChainEvent` 变化 | 同上（可读事件） |
| `pendingPrompt.curMsg/seq` 变化 | 保证"掉线瞬间在等什么"可恢复 |
| `turn` 变化 | 粗粒度快照（低频） |
| 定时兜底 | 每 5s 写一次；**写盘限速 ≤ 1 次/秒**（合并写） |

### 5.3 读取条件与 `/state.resume`

- 读取条件（全部满足才用）：重启后 **< 60s**、`nowTurn >= saved.turn`（turn 不回退）、`mySeat` 一致、`clientBuild` 一致。
- 满足 → `/state.resume = {stale:false, seqReset:true, preTurn, nowTurn, gapMs, chainDepth, chainStack, chainingTo, canDecline, source:"journal"}`；
  不满足 → `{stale:true, reason:"expired|turn-regressed|seat-mismatch|build-mismatch"}`，并丢弃 journal。
- `/state.seq` 在新进程里从 0 开始 → **`resume.seqReset` 必须为 true**，策略据此丢弃旧 seq。

### 5.4 `chainContextLost` 兜底策略

当 journal 不可用或与当前 prompt 对不上（`curMsg != pendingPrompt.curMsg`、候选对不上）时：

1. 若当前 `curMsg==16` 且 `chainCandidates=[]` 且 `canDecline=true` → **回 `decline`**；
2. 若 `chainCandidates[].forced=true` → 选**第一个 forced** 候选；
3. 否则 **保守 decline**（不主动加环）；
4. 日志：`RESUME chain-lost fallback=decline|forced-first reason=...`，并在 `/state.resume.chainContextLost=true` 暴露给策略。

> 原则：宁可少打一环，也不要因为候选错位打错牌（错位的 `index` 会触发 `MSG_RETRY` 风暴）。

---

## 6. 断线时的 LLM 语义

### 6.1 `/wait_prompt` 断线返回

客户端检测到 `confirmed_dead` 后，`/wait_prompt` **不再长时间阻塞**，而是返回：

```json
{ "disconnected": true,
  "reconnect": { "state": "reconnecting", "attempt": 1, "etaMs": 4000 } }
```

- HTTP 仍 200；`awaiting=false`、无 `seq` 变化。
- 策略收到后**打印 stats 并退出**（不重试、不算失败）：`[sem] stats reason=disconnected uptime=… acted=…`
- supervisor 在检测到 dead 时会先把 policy 进程停掉（避免它对着死客户端打请求），恢复后重新拉起。

### 6.2 恢复后

`/state` 与 `/wait_prompt` 返回正常 prompt，并附加：

```json
"resume": { "stale": false, "seqReset": true,
            "preTurn": 7, "nowTurn": 9, "gapMs": 18342,
            "chainContextLost": false }
```

- 策略处理规则：
  1. 见 `seqReset=true` → 丢弃所有旧 `seq`/候选缓存，重新 `wait_prompt`；
  2. 见 `chainContextLost=true` → 按 §5.4 兜底；
  3. `nowTurn - preTurn` 可能 >1（掉线期间对手/回合推进），**不要**假设 turn 连续；
  4. 不主动触发重连、不等额外确认，从当前 prompt 继续打。

---

## 7. 自动关闭模态框

### 7.1 客户端会弹的原生框（已核实的调用点）

全部走 `mainGame->env->addMessageBox(L"", dataManager.GetSysString(id))`：

| 文案 id（`mycard-bot/game/strings.conf`） | 文案 | 触发场景 | 调用点（当前代码） |
|---|---|---|---|
| **1400** | 无法连接到主机。 | 连接失败/超时 | `duelclient.cpp:122,224` |
| **1401** | 连接已断开。 | 对局中断线 | `duelclient.cpp:244` |
| **1402** | 网络传输发生错误。 | 传输错误/断线通用 | `duelclient.cpp:226,245`、`menu_handler.cpp:107,113,318,347` |
| **1502** | 连接已断开。 | 决斗模式掉线 | `duelclient.cpp:250` |
| 1403 / 1404 / 1405 | 无法加入主机 / 密码错误 / 主机拒绝 | join 失败 | `duelclient.cpp:318,320,322` |
| 1406 / 1408 / 1410 | 无效卡组 / 换副卡组失败 / 卡组数量不符 | 备牌阶段 | `menu_handler.cpp:155,583`、`deck_con.cpp:696` 等 |
| 1439 / 1365 / 1412 | 其他网络/环境错误 | 杂项 | `duelclient.cpp:676`、`menu_handler.cpp:70,442` |

### 7.2 方案

1. **自动化模式拦截**（`YGO_AUTO_DISMISS=1` 已存在，扩展语义）：
   新增 helper `Control::NotifyUser(const wchar_t* text, int sysId)`，把上述调用点改为调它：
   - 自动化模式：**不弹框**，写日志 `NETMSG auto-closed sysId=1401 text=连接已断开。`，并记录 `/net.lastNetMsg{id,text,at,ageMs}`；
   - 非自动化模式：保持原行为 `addMessageBox`。
2. **弹了立即关（兜底）**：`UiCleanup`/Pump 增加扫描：遍历 `mainGame->env->getRootGUIElement()` 的顶层子元素，识别 irrlicht message box（`IGUIWindow` 且非已知窗口名 / 文本命中 1400/1401/1402/1403/1404/1405/1502 文案），调用 `remove()`/`close()`，日志 `UI cleanup modal=auto-closed text=...`。
3. **区分合法结算框**：`1500 决斗结束` 与 `MSG_WIN` 结算层**不自动关**（那是正常结果展示）；只关"断线/连接失败/传输错误"类。
4. **断线与终局的判定顺序**：先看 `/state.winReason`，**输赢必须用 `isWin/isLoss`（或 `winPlayerLocal`）判断，不能看 raw `winPlayer`**：
   - `/state.winPlayer` 是 **raw 座位号**（本机是 raw seat 1 → `winPlayer=0` 表示**对手赢**）；
   - `winPlayerLocal`（0=我方赢 / 1=对手赢 / -1=平局）、`isWin/isLoss/isDraw` 是客户端换算后的**本机视角**字段；
   - `winReason==4 (DISCONNECT)` 且 `isWin !== true` → 真实掉线，进入 `confirmed_dead` 流程；
   - `winReason` 正常（0..3,0x10+）→ 正常终局，不做重连；
   - 旧 exe 没有 `isWin/winPlayerLocal` 时：`winPlayerLocal===0` 兜底，仍未知则按"未知"处理（不猜赢/输）。

---

## 8. 测试计划与验收指标

### 8.1 本地可做（LAN，不碰排位）

| # | 测试 | 方法 | 期望 |
|---|---|---|---|
| L1 | 检测延迟 | kill 客机，记录 `/net.state` 变 `confirmed_dead` 的时间 | ≤10s（P95） |
| L2 | 误报 | 正常对局 10 分钟（有 bot 活动） | `confirmed_dead` 次数 = 0 |
| L3 | 客户端收尾 | kill 后检查 host 窗口/日志 | host 无"阻塞式断线框"；`/health`、`/state` 持续可用 |
| L4 | 模态框自动关 | 人为制造 join 失败（连错端口） | 出现 `NETMSG auto-closed sysId=1400`，画面无待点 OK 的框 |
| L5 | supervisor 状态机（**lan profile**） | `supervisor.mjs --profile lan` + kill 客机 | 日志出现 `IDLE→READY→DUELING→RESULT(reason=lan-no-resume)`；**不出现** `RECONNECTING`；无重启/无 join 尝试 |
| L6 | 失败记账（**lan profile**） | `--profile lan` + 关闭 7911 | `RESULT` 带 `reason=lan-no-resume`、检测耗时；无重试 |
| L12 | `--lan-restart-game`（可选路径） | `--profile lan --lan-restart-game` + kill 客机 | 记录 `RESULT(reason=lan-no-resume)` 后重启客户端并以**新局**拉起 policy，日志含 `new-game (NOT resume)`；`/state.resume.stale=true` |
| L7 | journal 写入 | 对局中制造连锁（神之警告/激流葬） | `resume-context.json` 有 `chainStack/chainingTo/pendingPrompt`，限速 ≤1/s |
| L8 | journal 读取 | 重启客户端 + 手工放 journal | `/state.resume={stale:false,seqReset:true,...}`；过期/turn 回退 → `stale:true` |
| L9 | chain 兜底 | 放一个"候选对不上"的 journal | `resume.chainContextLost=true`，动作=decline，不产生 `MSG_RETRY` |
| L10 | `/wait_prompt` 断线语义 | kill 后继续 wait | 返回 `{disconnected:true,reconnect:{...}}`，无长阻塞 |
| L11 | 客户端可重用 | 断线后重启客户端+新 host | 新局 `started=true`（实验已验证） |

### 8.2 线上必须做（1 局）

1) 重连后服务端**重发了哪些 STOC/消息 id 序列**；2) `/tip` 回包文本与 RTT；3) 认人方式（昵称 / 会话 / token）；
4) 断线到判负的宽限时间（多久内重连允许续局）。记录方式：客户端 `OnMessageBegin id=...` 序列 + `/state` 前后快照 + 计时。

### 8.3 验收指标

> 指标按 profile 区分：**ranked**（默认）看完整重连指标；**lan** 只验收检测与收尾（不要求重连成功）。

| 指标 | 适用 profile | 目标 |
|---|---|---|
| 检测延迟（kill → `confirmed_dead`） | ranked / lan | P95 ≤ 10s |
| 误报（正常对局 30min 内 `confirmed_dead` 次数） | ranked / lan | 0 |
| 重连成功率（线上，模拟掉线） | **ranked** | ≥ 90%（≥10 次样本） |
| 重连耗时（dead → 恢复可打） | **ranked** | 中位 < 15s，P95 < 30s |
| `RESULT(reason=lan-no-resume)` 判定正确率 | **lan** | 100%（无 `RECONNECTING`、无重启/join 尝试） |
| `--lan-restart-game` 新局拉起成功率 | lan（可选开关） | ≥ 90%，日志含 `new-game (NOT resume)` |
| journal 读取成功率（本机） | ranked / lan | 100%（不含过期场景） |
| 断线期间误动作 / `MSG_RETRY` 风暴 | ranked / lan | 0 |

---

## 9. 待验证清单（线上 1 局，做完再定稿参数）

| # | 待验证 | 影响的设计参数 |
|---|---|---|
| V1 | 排位服重连后重发什么（是否有状态快照/增量消息；`OnMessageBegin` 序列） | journal 是否还需要/需要到多细；§5 读取条件 |
| V2 | `/tip` 是否有回包、文本格式、RTT | prober 间隔与超时（§4.1）；LAN 退化开关 |
| V3 | 认人方式（昵称 / 会话 token / uid；同名是否冲突） | supervisor join 参数与 `lastRoom` 字段 |
| V4 | 断线到判负的宽限时间 | 退避上限与总重试次数（§3.2） |
| V5 | 重连后 `seq`/turn 语义（是否回退、`seq` 是否重置） | `resume.seqReset` 判定与策略兼容 |

---

## 附录 A：本设计涉及的现有代码位置（已核实）

| 位置 | 内容 |
|---|---|
| `control.cpp:139` / `:806` | `g_lastStocId`（STOC 诊断）；需新增 `lastStocTick` 供 `sinceLastStocMs` |
| `control.cpp:886` | `Control::OnChat(msg,len)`（**需加 `player_type`**） |
| `control.cpp:595` | `UiCleanup()`（扩展：自动关模态框） |
| `control.cpp:1009` | `CloseEmptyFrames()`（空框兜底，参考其模式） |
| `duelclient.cpp:861` | `STOC_CHAT` 解析（`chat_player_type` 在这里已读出，`player_type==8` 为 system custom message） |
| `event_handler.cpp:1977` | 客户端 `CTOS_CHAT` 发送点（`/tip` 复用） |
| `netserver.cpp:264` | 服务端 `CTOS_CHAT` → `duel_mode->Chat()` |
| `strings.conf` | `!system 1400/1401/1402/1502` 等文案 |

## 附录 B：本设计产出/改动的文件（计划）

| 文件 | 动作 |
|---|---|
| `mycard-client/gframe/control.cpp` | 新增 prober/`/net`/`/reconnect`/`/leave`/journal/`/state.resume`/`/wait_prompt` 断线返回/模态框自动关 |
| `mycard-client/gframe/duelclient.cpp` | `STOC_CHAT` 把 `player_type` 传给 `Control::OnChat` |
| `bridge/supervisor.mjs` | 新增：常驻状态机 + `--profile lan\|ranked`（默认 ranked）+ `--lan-restart-game`（可选）+ 退避 + 记账 |
| `bridge/policy-semantic.mjs` | 小改：`disconnected` 退出语义、`resume.seqReset` 处理 |
| `bridge/docs/reconnect-lab.md` | 实验记录（已完成） |
| `bridge/docs/RECONNECT-DESIGN.md` | 本文 |

### 附录 B.1 supervisor 命令行约定（设计）

```powershell
# 线上（默认）：完整重连
node bridge/supervisor.mjs --profile ranked --url http://127.0.0.1:7789 --policy "node bridge/policy-semantic.mjs"

# 本地 LAN：只检测 + 记账 + 收尾清理（不重连）
node bridge/supervisor.mjs --profile lan --url http://127.0.0.1:7789

# 本地 LAN 长稳测试（可选）：掉线后以新局重启（明确不是续局）
node bridge/supervisor.mjs --profile lan --lan-restart-game --url http://127.0.0.1:7789 --policy "node bridge/policy-semantic.mjs"
```

- `--profile`：`ranked`（默认）| `lan`
- `--lan-restart-game`：仅在 `--profile lan` 下有效；行为 = 检测到 `confirmed_dead` → 写 `RESULT(reason=lan-no-resume)` → 重启客户端 → 以**新局**拉起 policy（日志 `new-game (NOT resume)`）
- 记账字段：`{ts, profile, state, reason, attempt, elapsedMs, lastNet:{state,sinceLastStocMs,probe:{...}}}`，写 `ranked/logs/supervisor-<stamp>.jsonl` + 滚动日志

---

## 10. 实现备注（2026-11-06，task-28 客户端侧）

客户端侧已落地（exe 2026-11-06 20:57:32，size 6,270,976），**详细字段/规则/日志/env 见 [`net-probe.md`](net-probe.md)**。与本文设计的差异/落地状态：

| 设计项 | 落地状态 |
| --- | --- |
| `GET /net` | ✅ 已实现（字段见 `net-probe.md` §2；`closeReason` 为字符串 `none/stop/exit/eof/error/...`，另有 `state`、`lastNetMsg`、`probe.unsupported`） |
| `/tip` 自动探活 | ✅ Pump 内自动（3s idle / 5s 间隔 / 2.5s 窗口 / 连续 2 次或 dueling `sinceLastStoc>15s` 判死）；`YGO_NET_PROBE=0` 可关；参数为**设计值，待 task-30 实测校准** |
| `POST /net/probe` | ✅ 手动探一次（最多等 3s，返回 rtt/fails/lastReplyPlayerType） |
| `POST /leave` | ✅ 入队 `ActionKind::Leave`：`StopClient(EXIT)` + 隐藏对局弹窗 + 清 dInfo + 回主菜单 |
| 模态框抑制 | ✅ `Control::NotifyUser(id,tag)` 替换 1400/1401/1402/1403/1404/1405/1502；`YGO_SUPPRESS_MODALS`（默认 1）只记 `NETMSG suppressed ...`；正常结算 1500 未动 |
| journal | ✅ cwd **`resume-context-<控制端口>.json`** 原子写（按端口隔离，见 `net-probe.md` §6；链/prompt/turn 变化 + ≤1/s + 5s 兜底）；启动 <60s 且 turn>0 载入 → `/state.resume`；密码仅存 `fnv1a:` 哈希；`YGO_RESUME_JOURNAL=0` 可关 |
| `/state` 扩展 | ✅ 末尾新增 `net` + `resume` |
| `/reconnect` | ⏳ 未实现（按本设计由 supervisor 用 `/leave`+重启+`/join` 完成；客户端不提供 `/reconnect`） |
| `/wait_prompt` 断线返回（§6.1） | ⏳ **待办**：当前 `/wait_prompt` 仍会正常阻塞；先验证 supervisor 仅靠 `/net.alive` 是否足够，不够再补 `{disconnected:true,...}` |
| 探活参数 | ⏳ 待 task-30 的 `detectMs` 实测后调（idle 3s→2s、判死 15s→10s、窗口 2.5s 等） |
