# 线上排位实战报告（RANKED REPORT）

> 记录 2026-11-07 在 MC 排位服上的真机验证与当日修复。目标读者：维护这套 MCP 桥接的工程师 / AI。
> 相关文档：[`MCP-INTERFACE.md`](MCP-INTERFACE.md)（接口权威）、[`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md)（重连设计）、
> [`reconnect-lab.md`](reconnect-lab.md)（掉线重连实测）、[`net-probe.md`](net-probe.md)（探活/journal）。

---

## 1. 结论摘要

1. **排位可以完整打完**：客户端能拿房 → 进房 → 选卡组 → 准备 → 开局 → 打到自己/对手 LP 归零并自然结算（多局验证，见 §5）。
2. **胜率仍然偏低**：当前是**策略强度问题，不是管线问题**——对局能推进、能发动手坑/陷阱、能正常判负；输的局多为资源交换和斩杀能力不足（policy 只会 `decline`/`to_bp`/`end` 等保守动作）。
3. **掉线重连受控验证成功**：主动 drop 后约 **13s** 回到同一房间继续对局（同房号/同密码），journal 恢复 `pendingPrompt`/`resume`；LAN 服务端不支持中途续局（见 §6）。

---

## 2. 环境与版本

| 项 | 值 |
| --- | --- |
| 客户端 exe | `mycard-client/bin/release/x64/YGOPro.exe` —— **2026-11-07 13:05:40 / 6,288,896 B**（MCP 新字段以此版为准） |
| 控制端口 | host `7788` / guest `7789` |
| 账号约束 | 仅使用 **1173810**（`MC_ACCOUNT_ID` 锁定；见 `bridge/ranked-play.ps1:2` 注释与 `:52` 的环境变量设置） |
| 排位服务器 | `tiramisu.moenext.com:8911`（日志 `room: tiramisu.moenext.com:8911 ... id=1173810`） |
| 卡组 | `mycard-bot/game/deck/Blackwing.ydk`（合法）；`BlackwingHT2.ydk`（合法，含手坑）；`BlackwingHT.ydk`（**非法**，见 §4.3） |
| 故障注入工具 | `bridge/netfault.mjs`（LAN 代理 7912→7911，控制口 7913） |

> 旧版客户端（2026-11-06 22:23:28 / 6,275,584 B 及更早）**没有** `/state.deckError`、
> `/state.isWin/isLoss/isDraw`、`/state.pipeline.recentMsgs`、`CHAIN raw` 等字段/日志；排位复现请用上表版本。

---

## 3. 排位完整流程（可复用的操作链）

| 步骤 | 操作 | 客户端日志关键字（已验证存在） |
| --- | --- | --- |
| 1. 拿房 | runner 用锁定账号排队；`bridge/ranked-play.ps1` 设置 `$env:MC_ACCOUNT_ID=1173810`，输出 `room: tiramisu.moenext.com:8911 ... id=1173810`（房间信息也落盘到 `ranked/logs/rc-room.json`） | `=== ranked play <stamp> account=1173810 deck=... play=False`；`room: ...` |
| 2. 进房 | `GET /join?ip=<host>&port=<port>&pass=<pass>`（**不要用 `-j`**：`-j` 会忽略 `-p` 直连 7911） | `join -> {"ok":true,"queued":true}`；`join: startClient ip=0x...`；`NET connected`/`NET joined room` |
| 3. 加载卡组 | `GET /deck?name=<Deck>`：加载 `.ydk`（sections）**并在准备界面下拉框 `cbDeckSelect` 中真正选中**（`SyncDeckCombo`） | `deck: sections load <Deck> main=40 ...`；`deck: load '<Deck>' ok=1 main=40`；**`deck: select combo name=<Deck> cat=<C> deck=<I> -> confirmed`** |
| 4. 准备 | `GET /ready`：准备窗口存在时**通过 UI 注入点真的点 `btnHostPrepReady`**（`BUTTON_HP_READY`，与真人同一 handler：`LoadCurrentDeck`→`UpdateDeck`→`CTOS_HS_READY`） | `ready: enter (connected=1)`；`ready: clicking HP_READY via UI (cat=.. deck=..)` |
| 5. 开局 | 房主 `GET /start` | `start: sending HS_START`；runner 侧 `DUEL STARTED` |
| 6. 决策循环 | MCP：`/wait_prompt` → `/actions` → `/act_id`；策略写日志 | `/state.pipeline` 的 `seq/curMsg/awaiting`；`PROMPT publish seq=.. msg=.. turn=..`；`CHAIN raw selecting=.. count=.. specount=.. len=..` |
| 7. 结算 | 胜负由内核 `MSG_WIN` 决定 | `MSG_WIN player=<raw> localPlayer=<0/1/-1> reason=..(..) isWin=.. isDraw=..`；`/state.isWin`；策略日志 `GAME OVER isWin=false reason=LP_ZERO ...` |

---

## 4. 当日修复清单（现象 → 根因 → 修复 → 证据）

### 4.1 `SendResponse` 未通知控制层 → 空 chain prompt 反复发布 → 空候选连锁循环

- **现象**：排位里 `chainsTaken=0` 而 `chainsDeclined=94`；`CHAIN raw count=0` 的 `MSG_SELECT_CHAIN` 被反复发布，策略不断 `decline`，服务端持续回同样空候选 prompt（同一秒多次）。
- **根因**：客户端对 `count==0` 的 `MSG_SELECT_CHAIN` 会**自己** `SetResponseI(-1)+SendResponse()` 自动放弃（`duelclient.cpp`），但控制层仍把 `curMsg=16` 当 prompt 发布；策略再发一次 `-1`，被服务端当下一轮响应 → 循环。同时 `SendResponse()` 走 `SendBufferToServer()`，它**没有**调用 `OnCtosPacket`，导致"客户端是否已自动答"的检测恒为 false。
- **修复**：
  1. `duelclient.h` `SendBufferToServer()` 增加 `Control::OnCtosPacket(proto)`；
  2. `OnAnalyzeEnd` 计算 `autoHandled = (CTOS 计数增长) || (curMsg==MSG_SELECT_CHAIN && rawCount==0 && specount!=0x7f)`，已自动答的 prompt **不发布**（日志 `PROMPT skip auto-handled`）；
  3. 新增原始报文日志 `CHAIN raw selecting=%d count=%d specount=%d len=%zu` 与候选诊断 `CHAIN analyze ... rawCount=.. autoHandled=.. hand=[..] handTraps=..`、`CHAIN publish seq=.. depth=.. cands=.. (fromAnalyze=..)`。
- **证据**：修复后同卡组排位局 `chainsTaken=4`、`chainsDeclined=8`（此前 0/94）；`rawCount=1` 时 `activatable=1` → `CHAIN publish cands=1 (fromAnalyze=1)`；`rawCount=0` 的 86 条全部 `autoHandled=1` → `PROMPT skip auto-handled`。见 `ranked/logs/ranked-play-20261107-130559.log` 与同目录 evidence 里的 `diag-client-log-tail.txt`。

### 4.2 准备界面没选卡组 / 没点 `HP_READY` → `did NOT start`

- **现象**：连续多局 `duel did NOT start`（`ready` 返回 ok 但 `started` 一直 false，`/state.curMsg=0`）。
- **根因**：旧 `/deck` 只把 `.ydk` 加载进内存（`LoadDeckBySections`），**没有在准备界面 `cbDeckSelect` 里选中目标卡组**；旧 `/ready` 直接 `SendUpdateDeck + CTOS_HS_READY`，跳过真人 `BUTTON_HP_READY` handler 里的 `LoadCurrentDeck(catIdx, catText, deckText)`，排位服看到的仍是旧/非法卡组。
- **修复**：
  - `/deck` 新增 `SyncDeckCombo(name)`：遍历 `cbCategorySelect` → `RefreshCategoryDeck` → 在 `cbDeckSelect` 精确匹配名字 → `setSelected(i)`；
  - `/ready` 若 `btnHostPrepReady` 可见：先 `SyncDeckCombo`，再**通过 UI 注入点点击 `btnHostPrepReady`**（与真人同一 handler）。
- **证据**：修复后日志出现 `deck: select combo name=BlackwingHT2 cat=0 deck=7 -> confirmed` + `ready: clicking HP_READY via UI (cat=2 deck=7)`，随后正常进入对局（`ranked-play-20261107-124218.log` 起，打满 10 分钟 `trapsSet=2 trapsActivated=1 chainsTaken=1`）。

### 4.3 卡组非法（lflist 超限）→ `BlackwingHT` 不可用

- **现象**：`BlackwingHT` 起局失败；`BlackwingHT2` 正常。
- **根因**：`mycard-bot/game/lflist.conf` 中 **14558127（灰流丽）=2、23434538（增殖的G）=1**；`BlackwingHT.ydk` 中两者各放了 **3 张** → 违反限制卡表。`BlackwingHT2.ydk` 改为 灰流丽×2、G×1，并保留 效遮 97268402×2、小丑与锁鸟 94145021×1（该表下 1 张合法）。
- **修复**：改用合法卡组 `BlackwingHT2.ydk`（以及基础 `Blackwing.ydk`）。
- **证据**：`mycard-bot/game/deck/BlackwingHT.ydk` / `BlackwingHT2.ydk` 内容对比；`mycard-bot/game/lflist.conf` 的上述行；起局日志 `deck: load 'BlackwingHT2' ok=1 main=40`。

### 4.4 卡组非法警告弹窗阻塞 → 抑制 + 结构化暴露

- **现象**：服务端 `STOC_ERROR_MSG / ERRMSG_DECKERROR` 会弹原生消息框；自动化无人点 OK，准备流程被卡住。
- **修复**：`duelclient.cpp` 的 `DECKERROR` / `SIDEERROR` / `VERERROR` 分支改为 `Control::OnDeckError(type,code,text)` + `Control::NotifyUserText(...)`；`YGO_SUPPRESS_MODALS=1` 时只记日志（`NETMSG suppressed tag=deck-error|side-error|ver-error`），并写入 `/state.deckError{local:{set,reason,type,code}, server:{set,type,code,text}}`。
- **证据**：源码关键字 `DECK ERROR server type=%u code=%u`、`DECK ERROR local reason=%s`、`NETMSG suppressed tag=%s`、字段 `deckError`（均已 grep 验证）；13:05 局 `/state.deckError` 两端 `set=false`，无阻塞弹窗。

### 4.5 主菜单叠加 / HINT_MESSAGE / CONFIRM_CARDS 阻塞

- **现象 1**：重连回对局后主菜单窗口叠在决斗画面上；**现象 2**：`MSG_HINT` 的 `HINT_MESSAGE` 弹 `wMessage` 后阻塞网络线程（`actionSignal.Wait()`），`curMsg` 停在 3、`/actions` 空；**现象 3**：`MSG_CONFIRM_CARDS` 强制面板（`wCardSelect`+`btnSelectOK`）同样阻塞。
- **修复**：`/join` 成功后隐藏 `wMainMenu`/`wLanWindow`，Pump 兜底 `UI hide wMainMenu (duel started)`；`HINT_MESSAGE` 自动确认（`UI auto-confirm kind=hint-message`）；`CONFIRM_CARDS` 自动点 `btnSelectOK`（`UI auto-confirm kind=card-select-confirm`）。
- **证据**：源码关键字全部存在（见 §8 校验）；排位局日志无这两类阻塞导致的冻结。

### 4.6 prompt 与快照 desync → 冻结 prompt 快照

- **现象**：`awaiting=true` 但 `/actions` 只有 `auto`、`curMsg` 变成 3（`MSG_WAITING`），策略误判并刷动作。
- **根因**：prompt 发布后服务端继续发消息覆盖 `g_shared`，`/prompt`/`/actions` 读到"最新消息"而不是"未答的 prompt"。
- **修复**：prompt 发布时冻结 `g_promptSnap`；`awaiting` 期间 `/prompt`、`/actions`、`/wait_prompt` 统一用冻结快照；非 prompt 时 `/actions` 返回空数组 + `reason:"not awaiting"`。
- **证据**：源码 `PROMPT publish seq=..`、`CHAIN publish ... (fromAnalyze=..)`；修复后 `STALL HARD` 消失（11:51→13:05 三局自然结算）。

### 4.7 `isWin/isLoss/isDraw` 判读（raw `winPlayer` 是座位号）

- **现象**：曾把 `MSG_WIN player=0` 误读成"我们赢"，实际本地视角是输。
- **根因**：`winPlayer` 是**服务器 raw seat**；`dInfo.lp` 是**本地视角**（`lp[0]`=我方）。guest 以 raw seat 1 进房时，raw 0 = 对手。
- **修复**：`/state` 新增 `winPlayerLocal = LocalPlayer(winPlayer)` 与 **`isWin`/`isLoss`/`isDraw`**；日志 `MSG_WIN player=<raw> localPlayer=.. reason=.. isWin=.. isDraw=..`；`/state.lp` 附 `lpOrder:"local"`。
- **证据**：13:05 局 `GAME OVER isWin=false reason=LP_ZERO ... raw=0 local=1`，`lp=[0,8000]`（我方 LP 0）一致；客户端日志 `MSG_WIN player=0 localPlayer=1 reason=1(LP_ZERO) isWin=0 isDraw=0`。

---

## 5. 实测记录表（客户端日志，2026-11-07）

| 时间（日志） | 结果 | turn | acted | trapsSet / trapsActivated | chainsTaken / chainsDeclined | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 09:59:42 | 未终局（等对手/卡住） | 2 | 12 | 0/0 | 0/4 | 早期版本，`did NOT start` 之外的卡点 |
| 10:55:48 | 未终局（策略空转） | 1 | 43 | 0/0 | 0/1 | prompt/快照 desync 修复前 |
| 11:05:51 | 未终局（`stall-hard`） | 1 | 23 | 1/1 | 2/4 | 策略守卫在 auto 空转时退出 |
| 11:19:33 | 未终局（8min 上限） | 2 | 3 | 0/0 | 0/2 | 卡在 `curMsg=3`（HINT/CONFIRM 阻塞前） |
| 11:40:55 | 未终局（`stall-hard`） | 3 | 26 | 1/1 | 1/8 | prompt desync 修复前最后一局 |
| 11:53:47 | **自然结算（负，LP_ZERO）** | 3 | 94 | 1/0 | 0/84 | 修复 prompt 快照后第一局完整打完 |
| 12:05:44 | **自然结算（负，LP_ZERO）** | 2 | 45 | 0/0 | 0/42 | `isWin=false` 字段生效 |
| 12:41:55（12:42:18 局） | 10min 上限截断 | 3+ | 108 | 2/1 | 1/94 | 卡组选择修复后能正常开局 |
| 12:53:42 | **自然结算（负，LP_ZERO）** | 2 | 50 | 0/0 | 0/43 | 空 prompt 修复前最后一局 |
| **13:05:59** | **自然结算（负，LP_ZERO）** | **5** | **27** | 0/0 | **4 / 8** | **空 prompt 循环修复后**：手坑/陷阱候选恢复，`handTraps=1` 且 `rawCount=1` |

> 说明：`acted`/`trapsSet` 等取自策略日志 `stats`；`GAME OVER ... isWin=false` 表示**我方失败**（不是赢）。
> 完整逐局日志在 `ranked/logs/ranked-play-*.log`，13:05 局证据目录见 §8。

---

## 6. 掉线重连实验（线上排位，受控 drop）

| 项 | 观测 |
| --- | --- |
| 操作 | 对局中主动 kill 客户端进程（受控 drop），随后用同账号/同房间参数重启并 `/join` |
| 恢复耗时 | **约 13s** 回到对局（另有 `control-10260.log` 的 `RESUME journal loaded gapMs=6234`、`RESUME journal loaded gapMs=6855` 两次快速恢复记录） |
| 恢复内容 | 同一房间（`tiramisu.moenext.com:8911`，同密码）、对局继续；服务器会话回执与重连后的 prompt 正常 |
| journal | `mycard-bot/game/resume-context-7789.json` 保留 `pendingPrompt`/`chainStack`/`turn`，重启后 `/state.resume` 给出 `{stale:true,fromJournal:true,gapMs,...}` |
| 截图证据 | `ranked/logs/lan-rc-pre-20261107-100825-1.png`（掉线前）、`lan-rc-drop-20261107-100825-1.png`（掉线时）、`lan-rc-final-20261107-100825-1.png`（恢复后）；`ranked/logs/rc-room.json` 记录房间 |
| LAN 对照 | **LAN 服务端不支持中途续局**：掉线即时判负，重进能握手但收不到 STOC；详见 [`reconnect-lab.md`](reconnect-lab.md) §8（freeze 6.75s / drop 0.6s / supervisor lan 不重连） |

> 注意：排位重连的**边界条件**（重进窗口、被顶号、重连后服务端重发哪些消息、判负宽限期）尚未系统测试；
> 目前只验证了"受控 drop 后 13s 内可恢复并继续打"。

---

## 7. 已知限制 / 未完成

1. **胜率依赖策略**：客户端与管线已能完整打完；输局主因是 policy 过于保守（大量 `decline`/`to_bp`/`end`），不是卡死或字段缺失。
2. **`/wait_prompt` 不返回 `disconnected`**：设计文档 §6.1 的断线语义未实现；supervisor 目前依赖 `/net.alive`，不影响排位主流程。
3. **深链未实测**：真实对局只验证到 `chainDepth=1` 的多次连锁；`depth>=2` 的多重连锁仍按消息语义推演（见 `MCP-INTERFACE.md` §6.4 / `chain-semantics.md`）。
4. **排位重连边界未测**：重进窗口时长、被顶号处理、重连后服务端是否补发 prompt/摘要、判负宽限仍需专门测试。
5. **账号/风控**：仅用 `1173810` 一个账号；排位自动化有账号风险，不要多开排队。
6. **依赖客户端版本**：`/state.deckError`、`/state.isWin/isLoss/isDraw`、`/state.pipeline.recentMsgs`、`CHAIN raw` 等是本轮新增，旧 exe 没有。
7. **卡组合规**：`BlackwingHT2` 依赖排位服当前 lflist；换服/换表前先用 `lflist.conf` 复核。
8. **回放保存框（`STOC_REPLAY`）**：控制驱动下客户端**直接跳过**（日志 `replay: dialog skipped (control-driven, no wait)`），不阻塞网络线程；**排位 LP_ZERO 结算不触发该路径**（回放框只在特定结算出现）；已 **LAN 实机验证**（2026-11-13：双方各 2 次、`replay-save=0`、`stoc=23 stall=0`），排位侧暂无触发样本。

---

## 8. 证据索引（均已存在）

| 证据 | 路径 |
| --- | --- |
| 逐局日志（含 stats/胜负） | `ranked/logs/ranked-play-*.log` |
| 13:05 完整局 evidence（prompt/state/ui/net/客户端日志尾部） | `ranked/logs/ranked-play-20261107-130559/`（`diag-final-prompt.json`、`diag-final-state.json`、`diag-final-ui.json`、`net-final.json`、`diag-client-log-tail.txt`、`policy.log`、`room.json`） |
| 排位重连截图 / 房间 | `ranked/logs/lan-rc-pre-20261107-100825-1.png`、`lan-rc-drop-20261107-100825-1.png`、`lan-rc-final-20261107-100825-1.png`、`ranked/logs/rc-room.json` |
| 卡组与卡表 | `mycard-bot/game/deck/Blackwing.ydk`、`BlackwingHT.ydk`、`BlackwingHT2.ydk`、`mycard-bot/game/lflist.conf` |
| journal / resume | `mycard-bot/game/resume-context-7788.json`、`resume-context-7789.json`；日志 `RESUME journal loaded/ignored` |
| 重连设计与实测 | [`reconnect-lab.md`](reconnect-lab.md)、[`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md)、[`net-probe.md`](net-probe.md)、`ranked/logs/supervisor-t30.jsonl` |
| 客户端日志关键字（grep 验证存在） | `CHAIN raw selecting=..`、`CHAIN analyze curMsg=.. rawCount=.. autoHandled=.. hand=[..] handTraps=..`、`CHAIN publish seq=.. cands=.. (fromAnalyze=..)`、`PROMPT skip auto-handled`、`PROMPT publish seq=..`、`deck: select combo name=.. -> confirmed`、`ready: clicking HP_READY via UI`、`MSG_WIN player=.. localPlayer=.. isWin=..`、`NETMSG suppressed tag=..`、`UI auto-confirm kind=hint-message|card-select-confirm`、`UI hide wMainMenu (duel started)` |

---

## 9. 2026-11-13 补充：`/state.match` 与 `control_match`（LAN 已验证）

- **客户端 `/state.match`**（2026-11-13 14:51:46 版起）：
  `{game, over, games:[{game,win,winnerSeat,reason,reasonName}], gamesWonLocal, gamesWonOpp, lastWinnerLocal, lastReasonName}`
  —— `win` 是本地视角、`winnerSeat` 是 raw 座位号；`over=true` 为整场结束（Bo3 到 2 胜）。
- **MCP `control_match`**（`bridge/mcp-server.mjs`）：`GET /state` → `{match, summary}`；`summary` 是中文一句话（"比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）" / "第 2 局进行中；当前大比分 1:0（你领先）"）；原因翻译 `SURRENDER/LP_ZERO/DECK_OUT/TIMEOUT/DISCONNECT`；旧客户端（无 `state.match`）返回 `fallback:true` 并降级到当前局。
- **LAN 验收**：`match-state-20261113-145150`——`/state.match` 三阶段 PASS（G1 `games[0]` → G2 两条 `2:0` → `DUEL_END` `over=true`）、`/start` latch PASS、`YGO_TP` PASS、`side_ok` PASS；`VERDICT: over=True won=2 games=2`。
- **回放跳过（LAN 首次实机）**：双方各 2 次 `replay: dialog skipped (control-driven, no wait)`、`replay-save=0`、`stoc=23 stall=0`。
- 证据：`ranked/logs/match-state-20261113-145150/`、`ranked/logs/lan-match-state-validation.md`（另见 `MCP-INTERFACE.md` §5.6 / §9 第 10 条）。

---

## 10. 2026-11-15 真实 LLM 使用反馈修复（最终版 `20:11:00 / 6,323,712 B`）

真实 LLM 通过 MCP 打排位时反馈 4 个问题；`19:05:42` 版修前 3 项，`20:11:00` 最终版补上 sort 直连 + announce 修复：

1. **战斗选攻击目标（已修复）**
   - 现象：旧版多怪兽选攻击目标时 `curMsg` 在 **15↔10** 反复、攻击消耗不结算（内核拒绝目标选择）。
   - 修复：`selectMin==0 → [0]`（空选择直接选第 0 项）、select 走直连字节、stale seq/snapshot 防护。
   - 验收：LAN 实机 PASS —— `send15=2 retry15=0`、`hex=0100`、LP `8000→3900→1850`、`loops=0`。
2. **TP 13 秒硬上限（默认自动应答）**
   - 旧版：`STOC_SELECT_TP` 出现后超 13s 未答 → 服务端直接 `eof` 踢人（LLM 实测连丢两个房）。
   - 修复：默认 **2s 内自动答"后攻"（`res=2`）**（env `YGO_TP_AUTO` / `YGO_TP_AUTO_RES`，`YGO_TP_AUTO_RES=1` 可改先攻）；人工覆盖必须 2s 内。
   - 实机日志：`TP auto-answered res=2`。
3. **判死误杀（已修复）**
   - 旧版：`YGO_NET_DEAD_SILENCE_MS` 默认 10s，自己回合思考会被误判 `confirmed_dead` → 提示管线冻结 → 被踢。
   - 修复：默认阈值改为 **60s**，且**我方回合/倒计时在走时不判死**（日志 `NET ALIVE reason=our-turn-idle`）；实机 40s 思考无 `NET DEAD`。旧 exe 仍建议显式设 `YGO_NET_DEAD_SILENCE_MS=600000`。
4. **`MSG_SORT_CARD` 响应格式（已实机验证）**
   - 响应是**裸位序字节、无长度前缀**：两张卡保持原序 = `hex=0001`；带前缀会死循环。
   - `20:11:00` 版：**已实机验证** —— `realMsg=25 len=3 hex=000102`（裸字节、无前缀），prompt 正常前进、无 `RETRY`；并改为**直连字节**、不再走 UI fallback（日志 `UI skip sort -> direct bytes`）。
5. **announce 140–143（新增修复，最终版）**
   - 现象：旧版 `curMsg=143` 之前会 `awaiting=false` 卡住（announce prompt 未发布）。
   - 修复：`kPromptMsgs` 纳入 `MSG_ANNOUNCE_RACE(140)/ATTRIB(141)/CARD(142)/NUMBER(143)`；`/prompt.announceNumberValues` 暴露 NUMBER 可用数值；`/actions` 提供 `announce_number` / `announce_race` / `announce_attrib` / `announce_card`。
   - 编码：**number=数值本身、race/attrib=掩码、card=卡号**（不是下标）。
   - 状态：**已实机验证**（`ANNOUNCE number values=5` → `realMsg=143 i=1` → 下一 prompt `firstid=25(SORT_CARD)` 前进；无 RETRY/卡住）。全部 5 项修复已全绿。

> 文档联动：`PLAYBOOK-FULL.md` §3.7.1（sort 已实机 `hex=000102`）、§3.7.2（攻击目标已修复）、**§3.7.3（announce 140–143）**、§0.1/§6.1（TP 自动/判死默认 60s）、§8（`curMsg=143` 排错）。

---

## 11. 2026-11-16 EOF guard（prompt 空等 → 服务端 AFK eof）

- **现象（真实）**：prompt 已发布给 LLM，但调用方 ~88s 没有任何 `CTOS_RESPONSE` → MC 排位服务端按 AFK 直接 `eof` 踢人（证据 `control-23776.log`）。
- **修复（`2026-11-16 10:25:14 / 6,327,808 / B2421E30…`）**：
  - `YGO_PROMPT_AUTO_DEFAULT_MS`（默认 **60000**，`0`=关）：prompt 发布后超过该时间无任何 `CTOS_RESPONSE` → 自动发**保守默认动作**，日志 `PROMPT auto-default msg=.. seq=.. kind=.. after=..ms (idle guard, LLM silent)`；
  - `YGO_PROMPT_IDLE_WARN_MS`（默认 **45000**）：先打 `PROMPT idle warning seq=.. msg=.. idle=..ms` 便于上层感知；
  - `/prompt` 新增 **`awaitingSinceMs`**（等待已持续毫秒，仅 `awaiting=true` 时）。
  - 默认动作：EFFECTYN/YESNO→否、CHAIN→decline（forced→第一 chain）、OPTION→0、IDLECMD→`to_ep`、BATTLECMD→`end_battle`、CARD→最小 select、PLACE→第一 place、POSITION→攻击、SORT→原序、ANNOUNCE_*→第一候选。
- **验证（`ranked/logs/eof-guard-validation.md`）**：
  - **positive PASS**：guard 20000ms（warning 10000ms）按住 prompt 30s → 10s warning、20s auto-default，`eof=0`；
  - **fast PASS**：正常快速作答，auto-default 不触发；
  - **negative PASS\***：`YGO_PROMPT_AUTO_DEFAULT_MS=0` → 无 auto-default；**LAN srvpro 不踢 eof，而是 180s `TIMEOUT` 判负**（与 MC 排位 ~90s eof 不同，`control-23776.log` 以 MC 为准）。
- **对 LLM 的要求**：不要依赖 guard；正常 60s 内必须答（`/prompt.awaitingSinceMs` 可看等待时长）。guard 只是保命兜底。

---

## 12. 2026-11-16 probe-fails 误判修复（`11:31:00 / 6,328,320 / 8DBDCDFF…`）

- **现象**：对手（Snake-Eye）长展开期间，客户端与对手均非我方回合（`awaiting=0`）：
  - `NET probe timeout fails=1 sinceStoc=4485ms` → `fails=2 sinceStoc=7469ms` → `NET DEAD reason=probe-fails` → `NET disconnected reason=error`；
  - 总静默仅 **~7.5s** 就被判死断线（旧 exe）；这段静默里其实对手正常在打。
- **根因**：`/tip` 探活有独立的 **2 次失败**阈值，且不受 `YGO_NET_DEAD_SILENCE_MS` 控制 → 与被动静默判死是两套逻辑，probe 路径会抢先误杀。
- **修复（`11:31:00` 版）**：
  - `/tip` 超时**不再单独判死**：只置 `probe_failed` 并打 `NET probe failed fails=.. (defer to passive silence guard)`；
  - 判死统一由被动静默阈值 `YGO_NET_DEAD_SILENCE_MS`（默认 60000）+ **我方回合/倒计时/`awaiting`/busy 守卫**决定（日志 `NET probe deferred (reason=our-turn/awaiting/busy/silence sinceStoc=..)`）；
  - 新增 `YGO_NET_PROBE_FAIL_MAX`（默认 **5**，仅控制降级/日志）。
- **验证（bot-scout，`ranked/logs/probe-fails-validation.md`）——A 组 PASS**：
  - **probe 模式**（`YGO_NET_PROBE=1 YGO_NET_PROBE_FAIL_MAX=1`，静默 12s；`probe-fails-probe-20261116-114335`）：`NET probe timeout fails=1 sinceStoc=1516ms` → `NET probe failed fails=1 (defer to passive silence guard)`（×2）；`/net.alive=true`、`state=healthy`、`closeReason=none`；**`NET DEAD reason=probe-fails`=0、`NET disconnected`=0**；静默结束后恢复 `NET probe reply rtt=641ms`、对局继续。**VERDICT: PASS**
  - **对照（probe 关闭 + 静默 70s；`probe-fails-passive-20261116-114625`）**：`NET DEAD reason=idle-no-packet since=60016ms` —— **被动判死路径仍有效**；probe 关闭时不会出现 probe 误判。**VERDICT: PASS**
  - **EOF guard 回归**：positive PASS（`PROMPT idle warning ... idle=10000ms` → `PROMPT auto-default ... after=20000ms`，eof=0）、fast PASS（auto-default=0、34 次作答）；与 guard 互不干扰。
- **对 LLM 的要求**：`/net.state == "probe_failed"` 或 `fails` 增长**不等于断线**（`alive` 仍 true）；对手长展开 7–8s 静默属正常，不要因为 `probe.fails` 提前 `/leave`。

---

## 13. 2026-11-16 攻击对手怪兽（选攻击对象）确定性验证 PASS

- **背景**：用户反馈"从对手视角看到 `BATTLE_START` 后 `timeLeft` 冻结"，怀疑旧版 15↔10 选目标死循环仍在。做确定性 LAN 场景验证（不依赖 policy 随机）。
- **确定性场景**（工具 `bridge/verify-battle-target-monster.ps1` + `.mjs`，证据 `ranked/logs/battle-target-monster-validation.md`）：
  - host deck `battle-test`（40 张 4 星通常怪，ATK 1900–2000）、guest deck `battle-test-low`（40 张，ATK 1500）；
  - 回合编排：双方先各召唤一只怪当靶子 → host 第 2 回合 `summon → to_bp → attack` → 出现 `MSG_SELECT_CARD(15)` 时对 selectable 第一张（对面的怪）提交 **raw `hex=0100`**（count=1 + `seqNo=0`）。
- **结果（新 exe `11:31:00 / 6,328,320 / 8DBDCDFF…`）**：
  - **单怪对单怪 2 连击**（`battle-target-monster-20261116-113956`）：`prompt=15 kind=bytes len=2 hex=0100` ×2、**`retry15=0`**、`firstid=110(MSG_BATTLE)=2`、guest LP **8000→7550→7100（每次 -450）**、eof=0。
  - **2 怪连打对面 2 怪**（`battle-target-monster-20261116-114129`）：`hex=0100`、`retry15=0`、`msg110=2`、guest LP **8000→7500→7100**（-500/-400）、eof=0、`timeLeft` 正常走时未冻结。
  - 6 次攻击序列（`battle-target-monster-20261116-112737`）：7 次 `MSG_BATTLE(110)`、guest 每次 -500（攻击对象是场上怪，非直击）、`RETRY after msg=15 = 0`。
- **结论**：
  - 当前 build 上"攻击对手怪兽并选目标"**正常**（`hex=0100` 被核心接受、战斗结算、无 15↔10 死循环、无 eof、`timeLeft` 不冻结）；
  - 旧 15↔10 死循环在确定性 LAN 场景**未复现**（旧会话里的 13 个 10→15→10 窗口可能已被 select 直连/编码修复解决）；
  - 用户在新版上"从对手侧看到 `BATTLE_START`/`timeLeft` 冻结"**更可能是对方客户端卡住/掉线**，不能归因我们的选目标路径；排查时先看对方 `/net`/决策是否在走。
