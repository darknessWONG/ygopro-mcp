# bot 自诊断（policy-semantic.mjs v2）

针对的症状：**客机 bot 打到一半不再出牌，进程还活着，日志停在最后一条动作** —— 也就是"静默停摆"。
自诊断部分只动了一个文件：[`bridge/policy-semantic.mjs`](../policy-semantic.mjs)。

> **状态备注**：`choose()` 的 **AGGRO / "会攻击"改动由 bot-scout 接手（lead 授权）**，
> 与本文档的自诊断逻辑无关；`choose()` 的最终优先级以文件里的实际代码为准，本文档不重复描述。

## 1. 为什么以前看不出病

控制层只有三种"不动"的可能，但旧版 bot 全都表现为"没有新日志"：

| # | 本质 | 旧版日志 | 现在 |
|---|---|---|---|
| A | 客户端不再产生 prompt（管线死了） | 无输出 | `STALL` 块：`curMsg` / `awaiting` / `lastMsg.id` 冻结 + verdict 指明"没有新提示" |
| B | 有 prompt 但 bot 没答（`/actions` 空、或动作被拒） | 无输出 | `EMPTY` 块 / `act rejected` + `act-retry` 行 |
| C | 答了但内核拒了 / prompt 被别人抢先答掉 | 偶尔一行 skip | `act-retry` 行 + `seq advanced but awaiting=false` + `skip stale prompt` |

关键事实（读 `mycard-client/gframe/control.cpp` 确认）：`g_seq` **只在 Control::Pump 发现"新 prompt 且需要回应"时才 +1**，
`/wait_prompt` 在 `seq > since` 或 `!awaiting` 时返回。所以"seq 不涨"和"没有提示"是同一件事，
而"seq 涨了但 awaiting=false"意味着这个 prompt 已经被消费掉了（别的 bot / 人手点了客户端）。

## 2. 改动清单（对着 task-13 的四条）

| 要求 | 实现 |
|---|---|
| ① 卡住检测：20s 无新 seq，或 `/actions` 空 5 次 → 打印诊断后继续等 | `STALL_MS`(默认 20000) + `EMPTY_ACTIONS_LIMIT`(默认 5)；`diagnose()` 打印 `curMsg/awaiting/seq`、`/state` 摘要（turn/phase/lp/手牌/卡组/墓地/场面/turnPlayer/myTurn/timeLeft/lastMsg/err）、当前 prompt 计数、**最近 3 条自己的动作**、以及一句 `verdict` 直接给结论；**不退出** |
| ② 每 30 秒心跳 | `HEARTBEAT_MS`(默认 30000)，格式 `[sem] hb acted=N seq=S curMsg=M awaiting=... stale=... actErr=... stalls=... hb=... up=..s turn=.. phase=..`；长轮询按"到下次心跳还有多久"动态缩短（`hbBudget`），保证 15s 的 `/wait_prompt` 不会把心跳饿死 |
| ③ 行动前后记录 seq；`/act_id` ok:false 打印并重试一次 | 每次动作打印 `#N seq=<before>-><after> msg=.. -> kind "label" ok awaitingNow=..`；拒绝时打印完整 `{ok:false,error:...}`，然后**重读 /actions**、校验 seq 未变、再提交一次（`ACT_RETRIES`，默认 1，不是无限重试），重试成功记 `act-retry#1 ok` |
| ④ 结束统计 | `stats reason=.. uptime=.. acted=.. skippedStale=.. escalations=.. heartbeats=.. stalls=.. emptyBursts=.. actErrors=.. actRetries=.. httpErrors=.. loops=.. lastSeq=.. lastCurMsg=.. lastAwaiting=..` + 最近 3 条动作 |
| ⑤ `choose()` | **AGGRO/"会攻击"改动由 bot-scout 接手（lead 授权）**；本文档不再固定描述其优先级，以文件里的实际代码为准。自诊断逻辑不改动 `choose()` 内部的分支结构。 |
| ⑥ 重复提示升级（补充） | 同一 `curMsg` 连续出现 ≥`ESCALATE_AFTER`(默认 3) 次 → 换一个**不同但合法**的候选，见 §2.1 |

额外加的两条（都是为了"别再静默"）：
- **HTTP 层失败**：连续 5 次 `/state` 或 `/wait_prompt` 失败 → `http-err consecutive=5` + `HTTP` 诊断块，
  verdict 会写 `control API unreachable (HTTP thread dead or client closed)` —— 这是"进程活着但控制线程死了"的形态。
- **单次循环异常不再杀死 bot**：整个循环体包在 try/catch 里，异常只记 `loop-error` 并继续。

## 2.1 重复提示升级（anti RETRY-loop）

**病因**：我们提交了非法响应 → 服务端回 `MSG_RETRY` → 客户端把**同一个提示**重新发出来（同一个 `curMsg`，新 `seq`）。
而 `choose()` 是确定性的，于是会一直给同一个答案 → 死循环（表现就是"静默停摆"）。

**对策**：用 `ESC.lastCurMsg` / `ESC.sameMsgCount` 数"连续同一个 curMsg"，到 `ESCALATE_AFTER`(默认 3) 次就换答案：

| 候选里有什么 | 升级时怎么选 |
|---|---|
| `chain` | 选 chain（第一次是 i=0），不再 decline |
| `place` | 轮换到下一个格子 |
| `select` / `sum` / `card` | 选择索引 +1（在合法候选里循环） |
| `position` | attack ⇄ defense 来回切 |
| 其它 | 先选**最后一个**候选（`choose()` 选第一个）；再被拒就继续往前轮换，直到把所有候选都试一遍 |

- 每次升级打印：`[sem] escalate msg=<curMsg> count=<n> -> <kind>("<label>") [why]`
- 计数进 `stats` 的 `escalations=` 和每 30s 心跳的 `esc=`，事后能看出"这一局到底重试了多少次"。
- **`curMsg` 一变即重置**（计数器、轮换游标、position 开关全部清空），所以正常对局里 `curMsg` 交替
  （11→10→11）**永远不会触发升级** —— 有实测为证，见 §4.4。

## 2.2 目标陷阱 + 连锁语义（task-21）

用户验收标准是"成功发动 **激流葬 53582587 / 神之警告 84749824 / 三角乌鸦阵-反埋伏 59839761** 之一"，
所以 `choose()` 里加了一条最高优先级（`TRAP_GOAL=0` 可关闭）：

| 时机 | 行为 | 日志 |
|---|---|---|
| `set_spell` 候选里有目标陷阱（**能不能发动的前提**） | 先盖到场上；优先级在召唤/特召之后、攻击之前 | `SET-TRAP 盖放[激流葬](code=53582587) -> set spell/trap #0 code=53582587` |
| `set_spell` 里 code 未知（缺失或 0） | 每回合最多盖 1 张（避免把手牌全盖光） | `SET-TRAP 盖放[未知陷阱](code=?) -> set spell/trap #0` |
| `set_monster` 且没有更好的召唤 | 盖 1 张当墙（不盖 tuner，保留同调素材） | `SET-MONSTER 盖放 set monster #0 code=2345（当墙；本回合没有更好的召唤）` |
| 同回合重复出现同一张 set 候选 | 不重复盖（`turn` 变化才重置） | —（`trapsSet` 不增长） |
| `activate` 候选里出现目标陷阱（场上已盖的） | 立刻发动 | `ACTIVATE-TRAP 神之警告(84749824) -> activate #0 code=84749824` |
| `chain` 候选里出现目标陷阱 | 优先连锁，压过 mission 的"留素材/结束战阶" | `CHAIN-TRAP 用[激流葬]连锁[对手的效果]（理由：破坏全场怪兽；depth=1）` |
| `canDecline=false`（必发） | 必须连锁，绝不 decline（decline 会被内核判非法→RETRY） | `CHAIN-FORCED 必须连锁[...] -> chain #0 code=...（canDecline=false）` |
| 可选、有看起来能干扰对手的效果 | 连锁 | `CHAIN-INTERFERE 用[...]连锁[...]（理由：...）` |
| 可选、没有目标陷阱也没有干扰价值 | 不连锁 | `CHAIN-DECLINE 不连锁[...]（canDecline=true，无目标陷阱）` |
| MISSION 未完成但当前是陷阱窗口（可盖/可发动/可连锁/被迫连锁） | MISSION 让位 | `MISSION yields -> trap window (set=true activate=false chain=false forced=false) synchro=TODO xyz=TODO` |

**为什么之前从来没发动过**：`choose()` 原来**完全没有处理 `set_spell` / `set_monster`**，三张陷阱永远留在手里；
而陷阱必须先盖到场上才能发动（`activate`）—— 所以无论连锁逻辑多聪明都不可能成功发动。补上 SET 分支后，
整条链路才是：`SET-TRAP`（盖放）→ 之后的连锁/战阶窗口出现 `activate` → `ACTIVATE-TRAP`（发动）→ `CHAIN-TRAP`（连锁）。

**数据来源**：优先用控制层的新字段（`/prompt` 的 `chainCandidates[] / chainStack / chainDepth / chainingTo /
canDecline / hint`）；**没有这些字段时**自动退回旧信息：`chains`（PromptJson 里重复键，实际是 CandSnap 数组，
带 `code`）+ `chainForced` + 动作 label（`chain #0 code=53582587`）。所以**即使 C++ 侧还没编译出新 exe，
陷阱连锁也照样能被选中**。

**统计**：`stats` 末尾多了 `trapsActivated=N trapsSet=N chainsTaken=N chainsDeclined=N`，
这四项也**重复打在每 30s 的心跳行里**（`hb ... trapsSet=1 trapsAct=1 chains=1/0`）——因为 Windows 上
被 `Stop-Process` 杀掉的 bot 打不出收尾 `stats`，最后一行心跳就是唯一能留存的证据。

## 2.3 实测结果（2026-11-04，task-20，bot-scout 执行）

用户验收目标**已达成**：**神之警告 84749824** 在真实 LAN 对局里被双方各发动一次。

```
[guest] SET-TRAP 盖放[神之警告](code=84749824) -> set spell/trap #3 code=84749824
[guest] CHAIN-TRAP 用[神之警告]连锁当前连锁（理由：无效特殊召唤/效果并破坏）(no desc)
[guest] #29 msg=16 -> chain "chain #0 code=84749824" ok
[host]  SET-TRAP 盖放[神之警告](code=84749824) -> set spell/trap #0 code=84749824
[host]  CHAIN-TRAP 用[神之警告]连锁当前连锁（理由：无效特殊召唤/效果并破坏）(no desc)
[host]  #23 msg=16 -> chain "chain #0 code=84749824" ok
```

内核级证据：`chainStack=[{code:84749824, name:"神之警告", type:"effect", ctrl:1, loc:8, isMine:true}]`、
`lastChainEvent="连锁成立: [神之警告]"`（`ranked/logs/trap-EVIDENCE-84749824-chainStack.json`），
效果真的结算：双方 LP 各 8000 → 6000（神之警告 2000 LP 代价），截图
`ranked/logs/trap-EVIDENCE-84749824-hit1.png` / `hit2.png`。

`(no desc)` 的含义：`/prompt.chainStack[0]` 的 `descText` 为空（C++ 侧 `MSG_CHAINING` 的 desc 还没映射，task-19
范围），我们仍用内置卡名/理由兜底，所以不影响发动。

## 3. 环境变量

```
CONTROL_URL          默认 http://127.0.0.1:7788   （主机 7788 / 客机 7789）
MAX_MINUTES          默认 20
STALL_MS             默认 20000   多久没有新 seq 就诊断一次
EMPTY_ACTIONS_LIMIT  默认 5       连续几次 /actions 为空就诊断
HEARTBEAT_MS         默认 30000
WAIT_TIMEOUT_MS      默认 15000
ACT_RETRIES          默认 1       /act_id 被拒后额外重试次数
DIAG_EVERY_MS        默认 30000   STALL 块的最小间隔（防止刷屏）
ESCALATE_AFTER       默认 3       同一个 curMsg 连续出现几次后开始换答案（最小 2）
```

## 4. 实测输出（**未启动客户端**：用假控制台 API 在 7791/7792/7793/7797/7798/7799 端口模拟各种病态）

> 真实的 LAN 对局证据由 task-14（`bridge/lan-run.ps1`）负责跑；这里验证的是诊断逻辑本身。
> `node --check bridge/policy-semantic.mjs` → OK。

### 4.1 正常推进 + 心跳 + 动作被拒后重试（STALL_MS=1500 加速）

```
[sem] start base=http://127.0.0.1:7799 maxMin=1 stall=1500ms hb=2000ms wait=800ms emptyLimit=5 actRetries=1
[fake] act #1 id=0 kind=summon accepted
[sem] #1 seq=1->1 msg=11 -> summon "Blackwing - Gale the Whirlwind" ok awaitingNow=false acted=1
[fake] act #2 id=0 kind=summon accepted
[sem] #2 seq=2->2 msg=11 -> summon "Blackwing - Gale the Whirlwind" ok awaitingNow=false acted=2
[sem] hb acted=2 seq=2 curMsg=11 awaiting=true stale=0 actErr=0 stalls=0 hb=1 up=2s turn=1 phase=MAIN1 lp=8000/6200 hand=3/2 win=-1/-1
[fake] act_id=0 -> FORCED REJECT (retry test)
[sem] act rejected seq=3 summon "Blackwing - Gale the Whirlwind" -> {"ok":false,"error":"kernel rejected action (forced by test)"} [actions=3 curMsg=11 awaiting=true]
[fake] act #3 id=0 kind=summon accepted
[sem] act-retry#1 ok
[sem] #3 seq=3->3 msg=11 -> summon "Blackwing - Gale the Whirlwind" ok awaitingNow=false acted=3
[sem] STALL stuck? uptime=4s frozenSeq=2s seq=3 curMsg=11 awaiting=false | turn=1 phase=BATTLE_START lp=8000/6200 hand=3/2 deck=33/34 grave=1/0 mon=0/0 myTurn=true turnPlayer=0 timeLeft=240 win=-1/-1 lastMsg=11(len 32) err=0 | actions=[]
[sem] STALL prompt: seq=3 curMsg=11 awaiting=false summonable=0 spsummonable=0 activatable=0 attackable=0 chains=0 canBp=true canEp=true
[sem] STALL recent actions: #1 seq=1 summon "..." | #2 seq=2 summon "..." | #3 seq=3 summon "..."
[sem] STALL extra: {"waitedMs":1873,"emptyStreak":0}
[sem] STALL verdict: prompt was consumed; waiting for the next one (client may be stuck before it)
[sem] duel finished turn=1 winPlayer=0 reason=3 winReasonName=(n/a) acted=3 up=7s
[sem] stats reason=duel-finished uptime=7s acted=3 skippedStale=0 heartbeats=3 stalls=2 emptyBursts=0 actErrors=1 actRetries=1 httpErrors=0 loops=13 lastSeq=3 lastCurMsg=5 lastAwaiting=false finished=true
```

要点：`act rejected` 打印了完整错误、`act-retry#1 ok` 证明重试生效、`#3` 行的 `seq=3->3` 说明这次动作没能推进 seq
（正常：答案是下一轮才产生新 prompt），`STALL` 给的是证据 + 一句话结论，**bot 没有退出**。

### 4.2 有 prompt 但 `/actions` 永远为空（EMPTY_ACTIONS_LIMIT=3 加速）

```
[sem] empty actions seq=1 curMsg=11 awaiting=true streak=1/3 (client says awaiting but built no actions)
[sem] empty actions seq=3 curMsg=11 awaiting=true streak=3/3 (client says awaiting but built no actions)
[sem] EMPTY stuck? uptime=5s frozenSeq=1s seq=3 curMsg=11 awaiting=true | turn=3 phase=MAIN1 lp=6500/7000 hand=5/3 deck=30/32 grave=2/1 mon=0/0 myTurn=true turnPlayer=0 timeLeft=150 win=-1/-1 lastMsg=11(len 64) err=0 | actions=[]
[sem] EMPTY prompt: seq=3 curMsg=11 awaiting=true summonable=2 spsummonable=1 activatable=1 attackable=0 chains=0 canBp=true canEp=true
[sem] EMPTY recent actions: (none yet)
[sem] EMPTY extra: {"seq":3,"curMsg":11,"streak":3}
[sem] EMPTY verdict: prompt EXISTS but we did not answer it (our loop/action path is the problem)
```

判定：`awaiting=true` + `summonable=2` 但 `actions=[]` → **客户端说有提示、却没把它翻译成语义动作**（客户端侧问题，不是 bot 的决策问题）。

### 4.3 控制 API 挂掉（模拟"进程活着但 HTTP 线程没了"）

```
[sem] hb acted=0 seq=1 curMsg=11 awaiting=true stale=0 actErr=0 stalls=0 hb=2 up=6s
[sem] http-err consecutive=5 /state unreachable (control API dead? client closed?)
[sem] HTTP stuck? uptime=9s frozenSeq=8s seq=1 curMsg=11 awaiting=true | state=(unavailable) | actions=[]
[sem] HTTP extra: {"stage":"/state","streak":5}
[sem] HTTP verdict: control API unreachable (HTTP thread dead or client closed)
```

### 4.4 重复提示升级（`ESCALATE_AFTER=3`；假服务端把同一个 curMsg 反复发回来）

候选只有 `summon / to_bp / to_ep`，所以升级走"其它"分支：先选最后一个，再往前轮换。

```
[fake] accepted #1 id=0 kind=summon label="Blackwing - Gale" (seq=1 curMsg=11)
[sem] #1 seq=1->1 msg=11 -> summon "Blackwing - Gale" ok awaitingNow=false acted=1
[fake] accepted #2 id=0 kind=summon label="Blackwing - Gale" (seq=2 curMsg=11)
[sem] #2 seq=2->2 msg=11 -> summon "Blackwing - Gale" ok awaitingNow=false acted=2
[sem] same prompt again msg=11 count=3 -> enabling escalation
[sem] escalate msg=11 count=3 -> to_ep("end phase") [last-candidate]
[fake] accepted #3 id=2 kind=to_ep label="end phase" (seq=3 curMsg=11)
[sem] #3 seq=3->3 msg=11 -> to_ep "end phase" ok awaitingNow=false acted=3
[sem] escalate msg=11 count=4 -> to_bp("to battle phase") [candidate#1]
[fake] accepted #4 id=1 kind=to_bp label="to battle phase" (seq=4 curMsg=11)
[sem] #4 seq=4->4 msg=11 -> to_bp "to battle phase" ok awaitingNow=false acted=4
```

`place` 轮换（同一个 curMsg=18，3 个格子）——第一次仍是 0 号，之后依次 1 号、2 号：

```
[sem] same prompt again msg=18 count=3 -> enabling escalation
[sem] escalate msg=18 count=3 -> place("mzone 0") [place-rotate]
[sem] escalate msg=18 count=4 -> place("mzone 1") [place-rotate]
```

**对照组（正常对局形状，curMsg 交替 11→10→11→10）——一条 escalate 都没有**：

```
[fake] accepted #1 id=0 kind=summon label="..." (seq=1 curMsg=11)
[sem] #1 seq=1->1 msg=11 -> summon "..." ok awaitingNow=false acted=1
[fake] accepted #2 id=0 kind=summon label="..." (seq=2 curMsg=10)
[sem] #2 seq=2->2 msg=10 -> summon "..." ok awaitingNow=false acted=2
[fake] accepted #3 id=0 kind=summon label="..." (seq=3 curMsg=11)
[sem] #3 seq=3->3 msg=11 -> summon "..." ok awaitingNow=false acted=3
（无 escalate 行；choose() 行为完全不变）
```

## 5. 拿到真实 LAN 对局后怎么用（判读顺序）

1. **先看最后一行 `hb`**：`acted` 还在涨 = bot 活着；`seq` 不涨 = 没有新提示。
2. **看有没有 `STALL`**：有 → 读它的 `curMsg` / `awaiting` / `lastMsg.id`：
   - `awaiting=false` 且 `curMsg` 非 0 → prompt 被消费了，卡在"下一个 prompt 之前"（**这就是客机那个症状的形状**）；
   - `awaiting=true` 且 `curMsg=11/10`（IDLECMD/BATTLECMD）→ 有提示没答，问题在本 bot 的决策/提交路径；
   - `curMsg=0` → 内核没在等任何人，看 `winPlayer`、`errorMsg`、`timeLeft`。
3. **对照 `mycard-client/gframe/control.cpp` 的 `pipeline` 计数**（task-12 在加）：如果 `STALL` 里
   `lastMsg.id` 长时间不变且 `analyzeCount/pumpCount` 也不涨 → 客机根本没收到新 STOC（网络/服务端侧）；
   若 `pumpCount` 在涨但 `seq` 不涨 → prompt 判定逻辑（`IsPromptMsg` / `g_promptWanted`）没命中。
4. **跨机对比**：主机跑一份、客机跑一份，同一局里比较 `hb` 的 `seq`/`acted` 曲线；客机先停 → 看它停在哪条 MSG。
5. **看 `escalate`**：出现 `escalate msg=11 count=3` 就是"同一个提示被反复发回来"的硬证据 ——
   配合 `MSG_RETRY` 日志/客户端的自动关框行为，可以直接判定"客机静默 = 我们给了非法响应"这条因果。
   若 `esc=` 一直涨同一个 curMsg，说明升级选的答案也被拒，需要看该 MSG 的响应编码（C++ 侧 `EncodeSemAction`）。

## 6. 已知限制

- **Windows 上被 `Stop-Process` / `taskkill` 杀掉时不会打印 `stats`**（Windows 没有真正的 SIGINT 投递）。
  所以关键计数（acted / stale / actErr / stalls / hb）都**同时写进每 30s 的 `hb` 行**，事后从最后一行心跳就能读到。
- `STALL` 只说明"20 秒没有新 seq"，**不代表一定是故障**：对手长考、`timeLeft` 倒计时、
  或者自己的回合结束等对手，都会出现"没有新提示很正常"。所以诊断块里给了 `myTurn` 和 `verdict`：
  看到 `verdict: not our turn: waiting for the opponent (normal)` 就可以忽略。
- 诊断块本身会额外打 2 个 HTTP 请求（`/state`、`/actions`），`DIAG_EVERY_MS` 限流到 30s 一次，对控制层压力可忽略。
- **升级是有代价的**：它只按"同一个 curMsg 连续出现"触发，而**正常对局里同一类提示偶尔也会连续出现**
  （例如 MAIN1 里召唤→再 idle→再 idle）。所以阈值默认 3 且只在连续时生效；如果发现它对正常局有干扰，
  把 `ESCALATE_AFTER` 调大（4~5）。真正能精准区分"RETRY 重发"和"正常同类提示"的信号需要客户端暴露
  `MSG_RETRY`（C++ 侧 task-12 的 `pipeline`），届时可以把触发条件改成"最近一次 STOC 是 MSG_RETRY"。
- 这只解决"**看见**问题"，不解决"客机为什么不出牌"本身；根因要靠 task-12 的 `pipeline` 计数 + 本日志对照，
  以及 task-14 的一键跑局产出可复现证据。
