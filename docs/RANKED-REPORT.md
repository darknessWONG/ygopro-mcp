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
