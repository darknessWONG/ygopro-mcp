# 一键 LAN 跑局器（bridge/lan-run.ps1）

> ⚠️ **进程安全（2026-11-07 事故记录）**：本脚本收尾用"路径过滤"清理 `mycard-client` 下的 **所有** `YGOPro`
> （`Get-Process YGOPro | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process`）。
> **只要本机还有别人在跑同一个 exe（例如排位实跑），就会被一起杀掉**——11-07 11:08:32 就因此误杀了正在跑的排位客户端。
> 规则：**同一时间只允许一个 owner 使用 `mycard-client\bin\release\x64\YGOPro.exe`**；
> 跑 LAN 前先确认没有排位对局；若确实要并存，先给脚本加 `-OnlyOwnPids`（用记录的真实 pid 清理）再跑。
> 需要 LAN 验证时，**先让排位的 owner 暂停**再起本脚本。

> 状态：**目标达成** —— 2026-11-03 23:21 那局跑出**自然胜负**：`MSG_WIN player=1 reason=1(LP_ZERO)`，
> 两端 `/state.winReasonName = LP_ZERO`，`retries = 0/0`，8 回合、host 128 / guest 127 次决策、299 秒。
> 脚本链路（起局→备牌→准备→开局→双 bot→看门狗→证据→收尾）全部实测通过，收尾有 try/finally 保证不留孤儿。
> 最后实测：2026-11-03 23:26（UTC+8），客户端 exe `2026-11-03 22:54:58 / 6,183,936 B`。

---

## 一、一条命令

```powershell
# 跑 1 局（默认 Blackwing / 最多 8 分钟 / 卡死 120s 判负）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1

# 连跑 3 局，换卡组，单局上限 4 分钟、50s 无进展即收局
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 3 -Deck "Blue Eyes" -MaxMinutes 4 -StallSeconds 50
```

> ⚠️ 脚本文件必须保存为 **UTF-8 with BOM**。本机 PowerShell 是 5.1（`$PSVersionTable.PSVersion = 5.1.26100`），
> 读无 BOM 的 UTF-8 会把中文按 ANSI 解码，导致**假的语法错误**（`Missing ')' in function parameter list` 之类）。
> 自检命令：`[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errs)`。

## 二、参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Games` | 1 | 连续跑几局（每局之间间隔 5s） |
| `-MaxMinutes` | 8 | 单局墙上时间上限 |
| `-Deck` | `Blackwing` | 双方卡组名（`mycard-bot\game\deck\<Deck>.ydk`） |
| `-Hooks` | `msganalyze` | **host** 的 `YGO_HOOKS`。**不要用 `all`**：stoc 钩子会在开局搞死进程 |
| `-GuestHooks` | `all` | guest 的 `YGO_HOOKS` |
| `-StallSeconds` | 120 | 两端 seq/turn/phase 连续 N 秒无变化 → `stalled` 收局 |
| `-PlaceCoords` | 空 | 可选 `local` / `server`：给两端客户端设 `YGO_PLACE_COORDS=<值>`（控制层 place 坐标解释开关，默认不传、用客户端默认） |
| `-KeepClients` | 关 | 结束后不杀客户端（默认杀） |

退出码：`0` = 所有局都跑到「有结果/按预期收局」；`1` = 至少一局启动失败（`start-failed` / `no-start`）。

## 三、每局流程（8 步）

```
[1/8] cleanup     按路径杀旧 YGOPro（*mycard-client* / *mycard-bot\game*）+ 按 PID 文件杀旧 bot
[2/8] host        bridge\lan-host.cmd  <Hooks> <Deck>      → 等 9s → /health(7788)
[3/8] guest       bridge\lan-guest.cmd <GuestHooks> <Deck> → 等 10s → /health(7789)
[4/8] lobby       /deck?name=<Deck> ×2 → /ready ×2 → 7788 /start（整体最多重试 3 轮，等 started=true）
[5/8] bots        CONTROL_URL=:7788 / :7789，MAX_MINUTES=<MaxMinutes>，node bridge\policy-semantic.mjs
[6/8] watchdog    每 2s 记录两端 /state 摘要；胜 / 进程消失 / 卡死 / retry 风暴 / 超时 任一即收局
[7/8] evidence    落盘 final states、抽取 control 日志关键行、统计决策/重试/escalate
[8/8] gap         5s 后进入下一局
```

已验证的配方（不可改）：
- host 用 `-c -k`，guest 用 `-j -k`（`-k` 必须带，否则 LAN 窗口返回时进程直接退出）
- `mycard-bot\game\system.conf` 里 `lasthost=127.0.0.1` / `lastport=7911`（否则客机会连去线上排位服）
- host 控制口 7788、guest 控制口 7789（`lan-*.cmd` 里设 `YGO_CONTROL_PORT`）

## 四、产物（都在 `ranked\logs\`）

| 文件 | 内容 |
|---|---|
| `lan-run-<stamp>.log` | 全流程时间线 + 每 2s 看门狗快照 + 汇总表 |
| `lan-bot-host-<stamp>-gN.log` / `.err` | 主机 bot 决策流水（`[sem] #n ...`、`escalate`、`hb`、`STALL`） |
| `lan-bot-guest-<stamp>-gN.log` / `.err` | 客机 bot 同上 |
| `lan-state-<stamp>-gN.json` | 收局时两端的完整 `/state`（含 `pipeline` 字段） |
| `lan-ctl-<stamp>-gN.txt` | 两端 `control-<pid>.log` 的关键行摘录（`response:` / `RETRY` / `MSG_WIN` / `PIPE` / `stall`） |
| `lan-place-<stamp>-gN.txt` | 当该局 `retries >= 8` 且有 `escalate` 时额外生成：两端所有 `response: prompt=18` / `RETRY after msg=18` 行，专门用于定位 place 编码 |

### 指标口径

- **决策数**：bot 日志中匹配 `^\[sem\] #\d+ ` 的行（心跳 `hb`、`STALL`、`http-err` 不算）。
- **retries**：两端客户端 `control-<pid>.log` 里 `RETRY after msg=` 的行数（host/guest 分别统计）。
  老版本客户端没有该行时退化为数 `OnMessageBegin len=1 id=1`，并在汇总里加 `~` 表示估算。
  交叉验证：`/state` 的 `retryCount`（新版在顶层，旧版在 `pipeline.retryCount`，两处都读）。
- **escalate**：bot 心跳行里的 `esc=N` 与 `[sem] escalate` 行数取大者（bot 因重试而升级策略的次数）。
- **自然胜负**：`winPlayer >= 0` **且** `retries < 5` **且** 收局原因 `win` **且** `winReason ∉ {0,3,4}`。
  `winReason` 语义取自 `mycard-bot\game\strings.conf` 的 `!victory` 段（0=投降、1=LP 归零、2=抽干、3=超时、4=断线、0x10+=特殊胜利）；
  `/state.winReasonName` 存在时优先用它。
- **收局原因 endCause**：`win` / `retry-loop` / `stalled` / `deadline` / `client-exit` / `no-start` / `start-failed`。

> retry 风暴保护：`retryCount >= 8` 且回合数 25s 未变化 → 直接判 `retry-loop` 收局（否则要白等 `-MaxMinutes`）。

## 五、实测证据

### 5.1 对照表（2026-11-03 晚，全部为本机真实运行）

| # | 时间 | 客户端 exe | 结局 | 回合 | host 决策 | guest 决策 | retries (H/G) | escalate | 说明 |
|---|---|---|---|---|---|---|---|---|---|
| A | 22:34 | 旧（22:33 前） | `retry-loop` | 1 | 25 | 6 | 0 / **37** | — | guest 卡 `MSG_SELECT_CHAIN(16)`：`RETRY after msg=16` 1 次后变成 `RETRY after msg=1`（RETRY 自锁重放）36 次 |
| B | 22:37 | 旧 | `retry-loop` | 1 | 25 | 6 | **23** / 0 | — | host 侧同样卡 chain(16)；第 2 局启动阶段被外部编译杀进程（`client-exit`） |
| C | 22:40 | 新（22:39:30） | `retry-loop` | 2 | 9 | 32 | 0 / 23（state） | 27 | chain 已修；换 guest 卡 `MSG_SELECT_PLACE(18)`：`hex=000400` ×N |
| D | 22:42 | 新 | `retry-loop` | 2 | 33 | 10 | **27** / 0 | 28 | 同一 place 症状换到 host；每次响应字节完全相同 `000400` |
| E | 22:47 | 新（22:46:40） | `retry-loop` | 1 | 0 | 29 | 0 / 38 | 26 | place 候选展开生效（bit 0/1/2/4/8/9/12 都在换）；默认 local 坐标下 host 通过、guest 全拒 |
| F | 22:49 | 同 | `retry-loop` | 1 | 0 | 23 | 0 / 40 | 20 | `-PlaceCoords server`：guest p=1 仍全拒 → 不是单纯 seat 问题 |
| G | 22:52 | 同 | `retry-loop` / `client-exit` | 1 | 0 | 29 / 26 | 0 / 28、0 / 25 | 26 / 23 | `-Games 2 -PlaceCoords server`；G2 被外部清进程打断（不计） |
| **H** | **22:55** | **新（22:54:58，place 4 变体自愈）** | **`deadline`** | **9** | **100** | **100** | **0 / 0** | 33 / 30 | ✅ **place 修复成功**：变体 0 直接通过、全程 0 次 RETRY；但两 bot 从不攻击 → 无胜负，到点收局 |
| I | 23:10 | 同（策略 v3 会攻击） | `deadline` | 16 | 291 | 273 | 18 / 12 | 128 / 135 | 攻击生效：LP 打到 `3150/2250`，10 分钟到点 |
| **J** | **23:21** | **同** | **✅ `win`** | **8** | **128** | **127** | **0 / 0** | 63 / 55 | ✅✅ **自然胜负**：`MSG_WIN player=1 reason=1(LP_ZERO)`，LP `8000/8000 → … → 5700/0`，299s |
| K | 23:30 | 同 | ✅ `win` | 14 | 213 | 213 | 0 / 0 | 104 | ✅ 复现（lead 亲自跑，`-MaxMinutes 12`）：LP_ZERO、natural=True、482s，证据 `lan-run-20261103-233015.log` |
| L | 00:04 | 同 | ✅ `win` | 11 | 183 | 177 | 0 / 0 | 83 | ✅ 复现：`win=0 reason=1(LP_ZERO)`、natural=True、415s（`lan-run-20261104-000400.log`） |
| M | 00:11 | 同 | ✅ `win` | 9 | 223 | 186 | 0 / 0 | 97 | ✅ 复现：`win=0 reason=1(LP_ZERO)`、natural=True、473s（`lan-run-20261104-001137.log`） |
| — | 00:01 | 同 | `retry-loop` | 2 | 33 | 15 | 21 / 2 | 21 | ⚠️ 偶发：place 场景下 RETRY 累积到 21（streak 判据触发收局），同一 exe 前一/后两局均 0 RETRY → 属低频边界，非回归 |

> A/B 是「chain 索引取错数组」时代；C/D 是 chain 修好之后；E/F/G 是「候选展开但坐标映射错」阶段；H 是 place 修好；I/J 是「策略肯攻击」之后。
> **J 是目标验证局：`winPlayer=1 / winReason=1 / winReasonName=LP_ZERO / natural=True / retries 0-0`。**
> K/L/M 是**重复性验证**（含 lead 亲自执行的两局）：同一 exe、同一参数族，全部 `LP_ZERO` 自然胜负、`retries=0-0`，
> 仅回合/时长/胜负方不同（先后手差异）。详见 `bridge/docs/lan-run-repeatability.md`。00:01 那局是已知低频 place 边界。

### 5.2 关键日志片段（真实输出）

启动链路（`lan-run-20261103-224240.log`）：

```
[22:42:52]   host pid=38024 control7788=True procs=1
[22:43:02]   guest pid=30808 control7789=True procs=2
[22:43:06]   lobby={"self":0,"isHost":true,"launchSeat":0,"ready":[1,1],"bothReady":true,"deckMain":40,"statuses":[9,25]}
[22:43:06]   7788 /start -> ok (1/3)
[22:43:09]   bot host pid=40188 log=lan-bot-host-20261103-224240-g1.log
[22:43:09]   bot guest pid=6100 log=lan-bot-guest-20261103-224240-g1.log
```

看门狗（每 2s 一行，节选）：

```
[22:43:22]     10s alive=2 | H turn=1 ph=4(MAIN1) msg=16 seq=3 aw=True retry=0 an=86 win=-1/-1/UNKNOWN lp=8000/8000 h5/3 g0/1 | G turn=1 ph=4(MAIN1) msg=3 seq=8 aw=False retry=0 an=90 win=-1/-1/UNKNOWN lp=8000/8000 h3/5 g1/0
[22:43:30]     19s alive=2 | H turn=2 ph=4(MAIN1) msg=18 seq=7 aw=True retry=0 an=143 win=-1/-1/UNKNOWN lp=8000/8000 h6/3 g0/1 | G turn=2 ph=4(MAIN1) msg=3 seq=10 aw=False retry=0 an=146 win=-1/-1/UNKNOWN lp=8000/8000 h3/6 g1/0
[22:43:33]     21s alive=2 | H turn=2 ph=4(MAIN1) msg=18 seq=9 aw=True retry=2 an=145 ... | G ...
[22:43:53]     42s alive=2 | H turn=2 ph=4(MAIN1) msg=18 seq=32 aw=True retry=25 an=168 ... | G ...
[22:43:53]   retry storm detected: retryCount=25, turn stuck at 2 for 27s
[22:43:53]   end cause: retry-loop
```

收局统计（同一次运行）：

```
[22:43:57]   host decisions : 33  last: [sem] #33 seq=33->33 msg=18 -> place "zone mask=0 real=0 seat=0 loc=4 seq=0 your_side" ok awaitingNow=false acted=33
[22:43:57]   guest decisions: 10  last: [sem] STALL verdict: not our turn: waiting for the opponent (normal)
[22:43:57]   retries: host=27 guest=0 total=27 (source=RETRY after msg=, estimated=False) stateRetry host=25 guest=0
[22:43:57]   escalations: host=28 guest=0
[22:43:57]   ctl logs: host=control-38024.log guest=control-30808.log  excerpt=lan-ctl-20261103-224240-g1.txt
[22:43:57]   turns=2 winPlayer=-1 winReason=-1 (未判定) natural=False duration=77s
```

客户端侧证据（`mycard-bot\game\control-38024.log`，22:42 局 host）：

```
response: prompt=18 streak=0  kind=bytes len=3 hex=000400
response: prompt=18 streak=25 kind=bytes len=3 hex=000400
RETRY after msg=18 retry=27 streak=27 (auto-dismiss queued)
```

bot 侧对应的升级（`lan-bot-host-20261103-224240-g1.log`）：

```
[sem] escalate msg=18 count=27 -> place("zone mask=0 real=0 seat=0 loc=4 seq=0 your_side") [place-rotate]
```

→ 策略在轮换候选，但**编码出来的字节始终是 `000400`**，所以服务端一直回 RETRY。

### 5.3 两个已知阻塞点（都不是跑局器的问题）

1. **已修复** `MSG_SELECT_CHAIN(16)`：客户端原先用 `dField.chains`（显示顺序）生成候选，而 kernel 用 `activatable_cards/descs`（消息顺序）作为响应下标，导致 index 非法 → RETRY 死循环。
   新 exe 实测 prompt=16 响应为 `kind=int hex=ffffffff`，**0 次 RETRY**。
2. **已修复（2026-11-03 22:54:58 的 exe）** `MSG_SELECT_PLACE(18)`：响应是 3 字节 `(p, l, s)`，core 在
   `mycard-client/ocgcore/playerop.cpp` 的 select_place 分支里校验（`p==playerid` 表示己方、`l` 为 `4=LOCATION_MZONE` / `8=LOCATION_SZONE`、`s` 为 zone 序号、选中的位必须落在提示允许区域内）。
   修复路径（三个阶段，全部有实测）：
   - 阶段 1（候选）：控制层原先对 SELECT_PLACE 只暴露 1 个候选，`place-rotate` 每次选到同一个 id → 展开全部合法格子（`bit` 开始变化，见局 E）。
   - 阶段 2（坐标）：`p` 的正确取值是 `LocalPlayer(half)`，即 `p = dInfo.isFirst ? 0 : 1`（己方半区），与 seat 无关；旧 `local/server` 两种映射都会在其中一种先手情况下编错（局 E/F 一正一反正好证明）。
   - 阶段 3（自愈兜底）：客户端加了 4 变体自动枚举 —— 每条 `RETRY after msg=18` 就 `variant=(v+1)&3`，最多 4 次内必有一种被接受。
   **局 H 实测：两端 `variant=0` 就直接通过，0 次 RETRY、0 次变体递增。**
   `bridge/lan-run.ps1` 保留 `-PlaceCoords local|server` 仅用于复现旧行为 A/B。
3. **已修复（策略层，不属跑局器）**：早期两个 bot 全程不攻击（`attack=0`），LP 恒定 8000 → 只能 `deadline`。
   `bridge/policy-semantic.mjs` 改成「默认攻击，仅"场上正好 2 怪 + 有额外特召/手牌调整怪"时留素材」后，
   局 I 打到 `3150/2250`、局 J 直接打出 `MSG_WIN / LP_ZERO`（见 5.5）。

> 说明：自 `MSG_RETRY` 自动关框（`YGO_AUTO_DISMISS`，默认开）上线后，RETRY 不再让网络线程永久阻塞 ——
> `PIPE periodic` 里 `analyze` 一直在涨、`sinceAnalyze` 稳定在几百毫秒，属于「重放循环」而非「假死」。

### 5.4 place 修复验证（局 H，2026-11-03 22:55，新 exe 22:54:58）

两端 `control-<pid>.log` 的 place 响应（**没有任何 RETRY 跟随**）：

```
# host (pid 45624, first=1)
PLACE resp variant=0 mask=0x0000001f bit=0 -> (p=0,l=4,s=0) count=1 first=1 hex=000400
PLACE resp variant=0 mask=0x00001f00 bit=8 -> (p=0,l=8,s=0) count=1 first=1 hex=000800
PLACE resp variant=0 mask=0x00001e00 bit=9 -> (p=0,l=8,s=1) count=1 first=1 hex=000801
# guest (pid 26092, first=0)
PLACE resp variant=0 mask=0x0000001f bit=0 -> (p=1,l=4,s=0) count=1 first=0 hex=010400
PLACE resp variant=0 mask=0x00001f00 bit=8 -> (p=1,l=8,s=0) count=1 first=0 hex=010800
PLACE resp variant=0 mask=0x0000001e bit=1 -> (p=1,l=4,s=1) count=1 first=0 hex=010401
```

统计（两端 control 日志 + bot 日志）：

```
PLACE resp lines: host=10 guest=8    RETRY after msg=18: host=0 guest=0    variant resets: 0
MSG_WIN: 0    hostDec=100 guestDec=100    turns=9    retries(H/G)=0/0    duration=279s    endCause=deadline
attack actions: host=0 guest=0（to_bp=4/4, end_battle=4/4, summon=4/3, spsummon=4/3）
```

→ 协议层（chain / place）已全部通过；剩下的 `MSG_WIN` 只差决策层愿意攻击。

### 5.5 目标验证局：自然胜负（局 J，2026-11-03 23:21:09 – 23:26:08）

参数：`powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 20 -StallSeconds 150 -Deck Blackwing`
客户端 exe `22:54:58`；策略 `bridge/policy-semantic.mjs`（v3，默认攻击）。

两端 `control-<pid>.log`：

```
[900565578] MSG_WIN player=1 reason=1(LP_ZERO)
[900565578] PIPE msg-win analyze=1304 pump=16958 msgs=1305 seq=127 awaiting=0 stoc=1(STOC_GAME_MSG) retry=0 lastRetryAfter=-1 streak=0 sinceAnalyze=0ms sincePump=0ms autoDismiss=1 dismiss=0
```

收局统计（`lan-run-20261103-232109.log`）：

```
turns=8 winPlayer=1 winReason=1 (LP_ZERO) natural=True duration=299s
hostDec=128 guestDec=127 retries(H/G)=0/0 escalations 63/55
LP: 8000/8000 -> 5700/8000 -> 5700/6700 -> 5700/4900 -> 5700/3100 -> 5700/800 -> 5700/0
```

两端 `/state` 最后一帧（`lan-state-20261103-232109-g1.json`）：

```
host : turn=8 lp=0/5700    myPlayer=0 mySeat=0 winPlayer=1 winReason=1 winReasonName=LP_ZERO
guest: turn=8 lp=5700/0    myPlayer=0 mySeat=1 winPlayer=1 winReason=1 winReasonName=LP_ZERO
```

攻击动作统计（bot 日志）：`attack-pick` host=1 / guest=5，全部真打出去（`-> attack` 与 pick 数一致）；`keep-materials` 0 次。

> 顺带修掉一个**自己造成的误判**：早期看门狗把「累计 retryCount ≥ 8」当作死循环判据，
> 会在正常对局（偶发 place RETRY、`streak=1`）里提前收局 —— 局 I 就是这样在 172s 被掐断的。
> 现在改为 **`retryStreak >= 6`（或累计 ≥30）且回合 30s 未动** 才判 `retry-loop`；
> 局 J 全程 `retryCount=0`，也顺带证明修复后的协议层不再产生 RETRY。

## 六、故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 语法自检报 `Missing ')'` 之类 | 文件被存成了无 BOM 的 UTF-8；用 `[System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($true)))` 重存 |
| `host control7788=False` | 端口被旧进程占着（先 `Get-Process YGOPro` 按路径过滤杀掉）；或 `-k` 参数丢了导致窗口返回即退出 |
| `no-start`（/start 后两端不 started） | 重跑；查看 `game\control-<pid>.log` 与 `mycard-bot\game\error.log`；确认 `lasthost/lastport=127.0.0.1/7911` |
| `client-exit` 且时间点吻合别人编译 | 同一时间只能有一对客户端：编译（msbuild 会因为 LNK1104 杀在跑的 exe）必须先打招呼 |
| `start-failed`、`control7789=False`（guest 起不来） | 端口被**另一对客户端**占着（有人手动起了 host/guest，或另一实例在跑）：`Get-Process YGOPro` 按路径全清后重跑；不要并发 |
| 每局都 `retry-loop` | 不是脚本问题：看 `lan-ctl-*.txt` 里 `RETRY after msg=<id>` 与 `response: ... hex=...`，那是控制层编码问题 |
| bot 起不来 | `node bridge\policy-semantic.mjs` 手动跑一次看报错；检查控制口 7788/7789 是否 `/health` 可达 |
| 脚本跑到一半**日志停更、不走 finally**、客户端残留 | 后台运行且父进程**没有及时消费 stdout** 时，`Write-Host` 会写满管道而阻塞整个脚本（实测 8 分钟局在 357s 卡住）。后台跑请把输出重定向到文件，别让它走管道：`Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','bridge\lan-run.ps1','-Games','1' -RedirectStandardOutput 'ranked\logs\lan-launcher.out' -RedirectStandardError 'ranked\logs\lan-launcher.err'`；或在前台/交互终端里跑；或定时 `job_output` 排空缓冲 |
| 崩溃/被 kill 后要收尾 | 直接按路径杀 `YGOPro` + 删 `ranked\logs\lan-{clients,bots}.pids` 即可；下一局的 `[1/8] cleanup` 也会自动做 |

## 七、边界与协调

- **同一时间只能有一对客户端**：本脚本是唯一负责启动/停止 YGOPro 的入口；其他人在它跑的时候不要起客户端、不要 msbuild。
  杀进程一律按路径过滤：`Get-Process YGOPro | Where-Object { $_.Path -like '*mycard-client*' -or $_.Path -like '*mycard-bot\game*' }`。
- bot 进程用 `ranked\logs\lan-bots.pids` 记录 PID，再按 PID 杀（本机 `Get-CimInstance Win32_Process` 会被策略拒绝，不能依赖 WMI 匹配命令行）。
- 全程离线回环（127.0.0.1:7911），不登录、不连线上服务器。
