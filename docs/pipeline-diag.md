# 客机 prompt 管线中断：诊断 + MSG_RETRY 自动恢复（task-12）

> 只改 `mycard-client/gframe/control.cpp`（`single_duel.cpp` 未动）。
> 构建：`mycard-client/build` → `msbuild YGOPro.vcxproj /p:Configuration=Release /p:Platform=x64 /m:1` ✅ 成功、无警告；
> 输出 `mycard-client/bin/release/x64/YGOPro.exe`（22:32:33 与 22:33:55 两次构建同一份源码，后者只是抓警告的重编译）。

## 1. 现象与失效链（已由 lan-harness 现场日志证实）

```
bot 提交了非法响应
  → 服务端回 STOC_GAME_MSG(MSG_RETRY)
  → DuelClient::ClientAnalyze(MSG_RETRY)   // duelclient.cpp:1064
       gMutex.lock(); PopupElement(wMessage); gMutex.unlock();
       actionSignal.Reset();
       actionSignal.Wait();               // ← 网络线程在这里永久阻塞
  → 没人点“确定” → 网络线程不再收任何包
  → 服务端超时判负（MSG_WIN reason=3 / STOC_DUEL_END）
```

lan-harness 的失败局 guest 日志：`ExecuteAction kind=1`（提交回包）之后紧跟
`OnMessageBegin len=1 id=1`（MSG_RETRY），然后 `control-<pid>.log` 再无游戏消息 —— 与上面的链路一致。

## 2. 本次改动（全部在 control.cpp）

| # | 内容 | 位置（control.cpp 行号） |
| --- | --- | --- |
| 1 | pipeline 计数器（atomic）：analyze / pump / msg / lastStoc / lastAnalyzeTick / retry 等 | 205 起 |
| 2 | `StocName()` —— STOC id 可读名 | 220 |
| 3 | `WinReasonName()` —— win_reason → 可读名（全表见 §4） | 247 |
| 4 | `LogPipeline(why)` —— 单行统一格式；`MaybePeriodicPipelineLog()` —— **每 5s 或每 200 条**打一次 | 290 / 307 |
| 5 | `AutoDismissPump()` —— 在 UI 线程续命 `actionSignal`（见 §3 竞态说明） | 321 |
| 6 | `/state.winReasonName` + `/state.pipeline{...}`（见 §5） | 529 起（SnapshotJson） |
| 7 | `ActionKind::MsgOk` 执行体：HideElement(wMessage) + actionSignal.Set() | 829 |
| 8 | `EnsureStarted()`：读 `YGO_AUTO_DISMISS`（默认开，`0` 关）+ 启动日志 | 1545 |
| 9 | `OnStocPacket()`：无论 hooks 开关都记 `lastStoc` | 1580 |
| 10 | `OnMessageBegin()`：MSG_WIN 解码 + MSG_RETRY 诊断/入队自动关框 | 1688 |
| 11 | `OnAnalyzeEnd()` 计数 + 周期日志；`Pump()` 计数 + stall 检测 + AutoDismissPump | 1743 / 1755 |
| 12 | **`chainList` 改为按消息顺序取 `activatable_cards/activatable_descs`**（修 MSG_SELECT_CHAIN 非法 index） | SnapshotFromClient 内 |
| 13 | 每条响应留痕 `response: prompt=… hex=…`；`RETRY after msg=<提示 id>`、`streak=`、`RETRY loop detected` | ExecuteAction / OnMessageBegin |
| 14 | `/state` 顶层 `retryCount/lastRetryAfterMsg/retryStreak`；`pipeline.lastNonRetryMsg/retryStreak` | SnapshotJson |

### 2.2 为什么 Set() 要"重复 2 秒"（关键实现细节）

`Pump()` 由 `Game::MainLoop()` 调用，**调用时 `gMutex` 已经持有**（game.cpp），而 `gMutex` 是普通
`std::mutex`（非递归）。所以 `ActionKind::MsgOk` 里**不能**再 `gMutex.lock()`（会死锁），
直接 `HideElement(wMessage)` + `actionSignal.Set()` 即可。

另一个坑：网络线程是 `PopupElement → Reset() → Wait()`，我们队列里的动作在 **下一帧** 才执行，
`Set()` 可能早于 `Reset()` 而丢失（`Signal` 的 `_state` 被 Reset 清掉）→ 仍然卡死。
因此 MsgOk 会把 `g_dismissUntilTick = now + 2000ms`，之后 2 秒内 **每帧** 都
`HideElement + Set()`：即使前面丢一次，`Reset()` 之后的下一帧 `Set()` 一定能唤醒 `Wait()`。

### 2.3 RETRY 死循环的根因：MSG_SELECT_CHAIN 的索引用错数组（已修）

现场（22:34 那局 host `control-23720.log`）：

```text
[897526234] PIPE periodic ... seq=3 awaiting=1 ... retry=0
[897526250] CDBG ExecuteAction kind=1            <-- 提交 4 字节响应
[897526250] RETRY after msg=16 retry=1 ...       <-- MSG_SELECT_CHAIN 的响应被拒
[897526250] CDBG OnMessageBegin len=1 id=1
...（之后 replay msg16 + 同一个非法响应）...
[897558796] RETRY after msg=1 retry=35 ...       <-- 关框生效（dismiss=34）但响应仍非法
```

- 客户端 `duelclient.cpp` 的 `case MSG_SELECT_CHAIN` 把候选按**消息顺序**压进
  `dField.activatable_cards` / `activatable_descs`；客户端自己的自动连锁就是
  `SetResponseI((int)i)`，`i` 是这两个数组的下标。
- control.cpp 原 `SnapshotFromClient()` 拿 `f.chains`（**链路显示列表**，还含之前的链）
  建 `s.chainList` → bot 选出的 index 与服务端消息里的链下标不一致 → 服务端回 `MSG_RETRY`；
  RETRY 后 replay 同一条 msg + 同一个非法 index → 死循环。
- 修复：`chainList` 改为从 `f.activatable_cards` + `f.activatable_descs` 构建：
  `cs.seq = i`（消息下标）、`desc = activatable_descs[i].first`、
  `forced = (activatable_descs[i].second & 0x100)`（flag 里 forced 在第 8 位）；
  `chainCount = chainList.size()`；`chainForced` 仍取 `f.chain_forced`。
  语义动作编码不变（`outI = a.index`，现在 a.index == 消息下标）。
- 另外：`activatableList` 的 desc 原来误取了 `activatable_descs[i].second`（flag），
  已改成 `.first`（真正的 desc）。

### 2.4 诊断增强（配合上面的修复）

- 每条响应留痕：`response: prompt=<id> streak=<n> kind=int|bytes ... hex=<bytes>`，
  紧挨着 `RETRY after msg=<id>` 就能看出"给哪个提示回了什么字节"。
- `RETRY after msg=%d retry=%llu streak=%llu`：`after` 是**上一个非 RETRY 消息**
  （即被判非法的提示，不会被 RETRY 自己覆盖）；`streak` 是连续 RETRY 次数（非 RETRY 清零）。
- 连续第 3 次时打 `RETRY loop detected for msg=<id>`，直接点出卡在哪个提示。
- `/state` 顶层新增 `retryCount/lastRetryAfterMsg/retryStreak`；`pipeline` 里新增
  `lastNonRetryMsg`、`retryStreak`。

### 2.5 SELECT_PLACE(18) 诊断（第二处卡点）

现场（22:42 局 host `control-38024.log`）：`RETRY after msg=18` 27 次，每次响应都 `hex=000400`，
而 bot 侧 `[sem] escalate msg=18 count=27 -> place(...)` 明明在轮换。两个问题：

1. **只暴露 1 个候选**：`BuildSemActions` 的 place 分支原来 `if (s.curMsg == MSG_SELECT_PLACE && i >= 1) break;`
   → 永远只有 id=0 一个 place 动作，bot 的轮换等于没换。**已去掉 break**，现在列出所有合法格子。
2. **格子坐标需要自证 + 自动试错**：新增
   - `/state.prompt.places[]` 每项带 `bit`（它来自 `selectable_field` 的第几位），并新增 `placesMask`
     （= `f.selectable_field`，**已取反的"允许位"**，不是 wire flag）与 `placeCoords`/`isFirst`；
   - 响应时打 `PLACE resp variant=%d mask=0x%08x bit=%d -> (p,l,s) count=%d first=%d hex=...`；
   - `YGO_PLACE_COORDS=local` 可强制基础变体用原始半区（默认用 seat 映射）；
   - 环境变量/文件不再需要"猜对"：`g_placeVariant` 0..3 枚举 `(p, 1-p) × (loc, swap MZONE/SZONE)`，
     `OnMessageBegin` 每收到一条 `MSG_RETRY` 且 `lastNonRetryMsg == MSG_SELECT_PLACE(18)` 就
     `variant=(variant+1)&3`，日志打 `PLACE retry -> variant=%d next`；之后收到非 place 提示时重置 0
     （日志 `PLACE variant reset (0) after msg=…`）。一次对局内最多 4 次试错即收敛。
3. **为什么 guest 之前两种固定映射都挂**（22:47/22:49 两局对照）：guest 的 `dInfo.isFirst` 两局不同，
   需要的 `p` 分别是 1 和 0；局 E（isFirst=0）发 0、局 F（isFirst=1）发 1，各错一次 → 都 RETRY。
   与其在 seat/isFirst/半区之间猜，不如用 RETRY 反馈枚举（上面的 variant 方案）。
   `/state` 顶层与 `pipeline` 都有 `placeVariant`，可实时看当前枚举到哪。

### 2.6 开关（A/B 对照）

`YGO_AUTO_DISMISS=0` 关闭自动关框（其余诊断照常），用于复现"不修"的行为作对照。
`YGO_PLACE_COORDS=local` 把 SELECT_PLACE 恢复成旧的原始半区坐标（默认 `server` = 客户端的 LocalPlayer 映射）。

## 3. 日志格式（写进 `control-<pid>.log`）

```
control: started port=7788 hooks=7 autoDismiss=1 (pipeline diagnostics)
PIPE periodic analyze=73 pump=1799 msgs=73 seq=3 awaiting=1 stoc=1(STOC_GAME_MSG) retry=0 lastRetryAfter=-1 streak=0 sinceAnalyze=1344ms sincePump=0ms autoDismiss=1 dismiss=0
response: prompt=16 streak=0 kind=int val=0 hex=00000000
PLACE resp mask=0x00000001 bit=0 ctrl=0 loc=4 seq=0 coords=local hex=000400
RETRY after msg=18 retry=1 streak=1 (auto-dismiss queued)
PIPE msg-retry ...  (连续 RETRY 时每 10 次打一行，避免刷屏)
retry: auto-dismissed wMessage and signalled actionSignal (#1)
PIPE periodic analyze=40 pump=2400 msgs=41 seq=12 awaiting=1 stoc=1(STOC_GAME_MSG) retry=1 lastRetryAfter=16 streak=1 sinceAnalyze=120ms sincePump=16ms autoDismiss=1 dismiss=1
RETRY loop detected for msg=16: same prompt keeps being rejected; see the preceding "response: prompt=16 ..." line for the exact bytes
PIPE stall analyze=40 pump=3900 msgs=41 seq=12 awaiting=1 stoc=1(STOC_GAME_MSG) retry=1 lastRetryAfter=16 streak=1 sinceAnalyze=1500ms ...
MSG_WIN player=1 reason=2(DECK_OUT)
PIPE msg-win analyze=88 pump=5200 msgs=89 seq=0 awaiting=0 stoc=22(STOC_DUEL_END) retry=0 ...
```

字段含义：
- `analyze` = `Control::OnAnalyzeEnd` 次数（每条 STOC_GAME_MSG 处理完 +1，**重放** last_successful_msg 不会加）；
- `pump` = `Control::Pump` 次数（UI 帧级）；
- `msgs` = `OnMessageBegin` 次数（收到的游戏消息数）；
- `sinceAnalyze/sincePump` = 距上次 analyze/pump 的毫秒数（`PIPE stall` 阈值：analyze ≥ 3000ms 且 5s 内只报一次）；
- `retry/lastRetryAfter` = MSG_RETRY 次数与**被判非法的提示 id**（"哪个提示的编码错了"的直接线索）；
- `streak` = 连续 RETRY 次数（收到任何非 RETRY 消息清零）；
- `dismiss` = 自动关框执行次数（正常恢复应 ≥1）。
- `response: prompt=… kind=… hex=…` = 服务端即将收到的响应原文（int32 或字节串）。

## 4. win_reason 解码依据

1. `ocgcore/processor.cpp` `field::adjust_step()`：**rea=1** = 对方 LP 归零；**rea=2** = 对方抽卡时牌组耗尽（overdraw）；
   写 MSG_WIN 时 `write_buffer8(winp); write_buffer8(rea);`
2. `ocgcore/libduel.cpp` `scriptlib::duel_win()`：Lua `Duel.Win(player, reason)` 把 `reason` 原样写进
   `core.win_reason`。
3. `reason` 的命名来自卡脚本 `CardScripts/constant.lua` 的 `WIN_REASON_*`（0x10 起）。
4. 客户端 `strings.conf` 的 `!victory <id> <文本>` 就是这些 id 的显示文案（0x1 基本分变成0 / 0x2 没有卡可抽 …）。

映射表（`WinReasonName()`，完整实现见 control.cpp:247）：

| reason | 名称 | 含义 |
| --- | --- | --- |
| 0x00 | SURRENDER | 投降（strings 0x0） |
| 0x01 | LP_ZERO | LP 归零（core rea=1、strings 0x1） |
| 0x02 | DECK_OUT | 无卡可抽（core rea=2、strings 0x2） |
| 0x03 | TIMEOUT | 超时（strings 0x3） |
| 0x04 | DISCONNECT | 失去连接（strings 0x4） |
| 0x10–0x1F | EXODIA / FINAL_COUNTDOWN / VENNOMINAGA / CREATORGOD / EXODIUS / DESTINY_BOARD / LAST_TURN / PUPPET_LEO / DISASTER_LEO / JACKPOT7 / RELAY_SOUL / GHOSTRICK_MISCHIEF / PHANTASM_SPIRAL / FA_WINNERS / FLYING_ELEPHANT / EXODIA_DEFENDER | 特殊胜利（constant.lua 同名） |
| 0x21/0x22/0x30/0x52–0x59 | TRUE_EXODIA / FINAL_DRAW / CREATOR_MIRACLE / NUMBER_iC1000 / ZERO_GATE / DEUCE / DECK_MASTER / DRAW_OF_FATE / MUSICAL_SUMO / SUMMER_SCHOOLWORK | 其余特殊胜利 |
| 其它 | UNKNOWN | 未收录（会原样打出数字，便于继续补表） |

> 注意：reason=3（超时）/4（失去连接）是服务端/对局框架给的，不是 ocgcore 自己的 `rea`；
> 但客户端 `strings.conf` 把它们和 1/2 放在同一张 `!victory` 表里，所以一起映射。

## 5. `/state` 新增字段

```json
{
  "winPlayer": 1,
  "winReason": 2,
  "winReasonName": "DECK_OUT",
  "retryCount": 0,
  "lastRetryAfterMsg": -1,
  "retryStreak": 0,
  "pipeline": {
    "analyzeCount": 88,
    "pumpCount": 5200,
    "msgCount": 89,
    "seq": 0,
    "awaiting": false,
    "lastStoc": 22,
    "lastStocName": "STOC_DUEL_END",
    "sinceLastAnalyzeMs": 4200,
    "sinceLastPumpMs": 16,
    "retryCount": 0,
    "lastRetryAfterMsg": -1,
    "lastNonRetryMsg": 40,
    "retryStreak": 0,
    "autoDismiss": true,
    "dismissCount": 0
  }
}
```

其余字段（`seq/awaiting/...`）保持不变，向后兼容；bot 侧可只加读 `pipeline`（或顶层 `retryCount`）。

## 6. 构建（在 lead 允许的窗口里执行；编译前必须按路径杀 exe，否则 LNK1104）

```powershell
# 只杀本仓库的客户端，别用 Stop-Process -Name ygopro
Get-Process YGOPro | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force
cd mycard-client\build
cmd /c "`"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat`" >nul && msbuild YGOPro.vcxproj /p:Configuration=Release /p:Platform=x64 /m:1 /nologo /v:m"
```

自检（不运行客户端也能确认代码进了 exe）：

```powershell
$b=[IO.File]::ReadAllBytes('mycard-client/bin/release/x64/YGOPro.exe')
$s=[Text.Encoding]::ASCII.GetString($b)
foreach($n in @('RETRY after msg=%d','retry: auto-dismissed','PIPE %s analyze','winReasonName','sinceLastAnalyzeMs','autoDismiss=')){ "$n -> " + $s.Contains($n) }
# 全部 True
```

## 7. 运行时验证步骤（由 lan-harness / bot-scout 跑对局，本任务不启动 LAN 对局）

### 7.1 已验证（2026-11-03 22:55 局，新 exe LastWriteTime=22:54:58）

`ranked/logs/lan-run-20261103-225521.log`（deck=Blackwing，9 回合，279s，deadline 结束）：

```text
retries: host=0 guest=0 total=0 (source=none, estimated=False) stateRetry host=0 guest=0
turns=9  win=-1 reason=-1 (未判定)  natural=False  duration=279s
PLACE resp variant=0 mask=0x0000001f bit=0 -> (p=0,l=4,s=0) count=1 first=1 hex=000400   # host 被接受
PLACE resp variant=0 mask=0x0000001f bit=0 -> (p=1,l=4,s=0) count=1 first=0 hex=010400   # guest 被接受
PIPE periodic analyze=853 pump=11097 ... retry=0 streak=0 sinceAnalyze=906ms              # 管线健康
```

- chain(16)/place(18) 两类此前的 RETRY 全部消失（`retry=0`），`placeVariant` 全程 0（基础映射即正确，变体枚举备用）；
- `/state`（`lan-state-20261103-225521-g1.json`）实测：`retryCount=0/retryStreak=0/placeVariant=0/
  winPlayer=-1/winReasonName="UNKNOWN"`，`pipeline.{analyzeCount,pumpCount,lastStocName,placeVariant,...}` 齐全；
- 该局没产生 `MSG_WIN`（bot 策略不攻击，LP 8000/8000，deadline 收场）。

### 7.2 已验证（2026-11-03 23:21 局，策略 v3 会攻击 → 自然胜负）

`ranked/logs/lan-run-20261103-232109.log`（deck=Blackwing，8 回合，299s，`end cause: win`）：

```text
[900565578] MSG_WIN player=1 reason=1(LP_ZERO)                  # 两端 control-<pid>.log 逐字一致
[900565578] PIPE msg-win analyze=1304 pump=16958 msgs=1305 seq=127 awaiting=0 stoc=1(STOC_GAME_MSG) retry=0 ...
retries: host=0 guest=0 total=0  turns=8 winPlayer=1 winReason=1 (LP_ZERO) natural=True
host : turn=8 lp=0/5700    winPlayer=1 winReason=1 winReasonName=LP_ZERO
guest: turn=8 lp=5700/0    winPlayer=1 winReason=1 winReasonName=LP_ZERO
```

→ `win_reason` 的运行时解码闭环：`reason=1` 正是 §4 映射的 `LP_ZERO`（`processor.cpp adjust_step` 的
rea=1 + `strings.conf !victory 0x1 基本分变成0`）；`/state.winReasonName` 与日志一致。该局 retries=0、
dismiss=0，chain/place/变体兜底在真实对局里稳定。

### 7.3 复跑清单

1. 用 `bridge/lan-host.cmd` / `bridge/lan-guest.cmd` 起 host(`-c`, `YGO_HOOKS=msganalyze`) + guest(`-j`, `YGO_HOOKS=all`)；
2. **链 prompt 修复验证**：应该看不到 `RETRY after msg=16`（MSG_SELECT_CHAIN）；若还出现，看紧邻的
   `response: prompt=16 ... hex=...` 是否 index 超出 `chainList` 长度；
3. **place 修复验证**：`RETRY after msg=18` 应消失；若出现，看 `PLACE resp variant=` 是否递增
   （0→1→2→3），收敛后 `RETRY after msg=18` 停止；
4. 万一仍触发 RETRY：`control-<pid>.log` 应有 `RETRY after msg=<提示 id> retry=1 streak=1 (auto-dismiss queued)`
   紧跟 `retry: auto-dismissed wMessage and signalled actionSignal (#1)`，`streak` 到 3 会打 `RETRY loop detected`；
5. `curl 127.0.0.1:<control端口>/state` 看 `pipeline.dismissCount>=1`（若触发过 RETRY）、
   之后 `analyzeCount/pumpCount` 继续增长、`awaiting` 能再次变 true（新 prompt 到达）；
6. 对局应能继续到正常 `MSG_WIN`（而不是 reason=3 超时）；`MSG_WIN player=… reason=…(…)` 与 /state 的
   `winReasonName` 应一致；
7. A/B 对照：`YGO_AUTO_DISMISS=0` 起 guest，应复现"RETRY 后网络线程静默、最后 reason=3"。
8. 如果仍然卡：看 `PIPE stall` 行里 `sinceAnalyze` 是否持续增大、`retry` 是否在涨 —— 那说明
   消息在 `Reset/Wait` 之外别的地方被挡住了（如 `STOC_DUEL_END` 的另一个 wMessage 等待），把该段日志发我。

## 8. 已知限制

- 自动关框是"救场"：非法响应仍然会丢一次（客户端会重放上一条消息重新问），bot 需要能重新作答；
  日志里的 `lastRetryAfter` + `response: prompt=… hex=…` 才是修复编码的入口
  （本轮的 chain 非法 index 已由 §2.3 的 chainList 修复彻底解决）。
- `dismiss` 窗口 2s 内如果恰好另有合法 `wMessage` 弹出，可能被一起关掉（仅在 RETRY 恢复窗口内，可接受；
  需要更精细可改成只关"重试文案"的 wMessage）。
- `PIPE stall` 阈值 3s 是为人类可读性定的；正常对局里 `sinceAnalyze` 也会随思考/动画变大，注意区分
  "agent 正在想" 与 "网络线程死了"（后者 `pump` 仍涨、`analyze` 冻住、`retry` 不再变化）。
- win_reason 仅 `MSG_WIN` 携带；`STOC_DUEL_END` 后的 reason 由服务端另给，客户端侧只有 `winReason`。
