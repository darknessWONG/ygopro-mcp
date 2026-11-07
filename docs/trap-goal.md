# 目标验证：成功发动 激流葬 / 神之警告 / 三角乌鸦阵 之一

> 任务：task-20（验证方 = bot-scout，独占客户端/端口）
> 目标卡（都在 Blackwing 主卡组里）：
> - 激流葬 `53582587`
> - 神之警告 `84749824`
> - 三角乌鸦阵-反埋伏 `59839761`
> 达标：**任意一张、任意一局，内核真的发动成功一次**。

## 一、判定标准（硬，不看策略日志）

必须满足下面任一"内核级"证据；**策略日志（`ACTIVATE-TRAP`/`CHAIN-TRAP`）只能当线索，不能当结论**：

| 证据 | 来源 | 具体形式 |
|---|---|---|
| A. 内核 CHAINING 消息 | 客户端 `control-<pid>.log` | 出现 `MSG_CHAINING` / `CHAINING` / `chain` 相关行，且其 `code` ∈ {53582587, 84749824, 59839761}，并伴随 `MSG_CHAINED`/`CHAIN_SOLVED` 或后续效果日志 |
| B. 结构化链快照 | `/state.chainStack` / `/prompt.chainStack` / `/prompt.chainCandidates` | 出现目标卡 `code` + 卡名（`激流葬` / `神之警告` / `三角乌鸦阵`），且 `type=effect`（不是 operation）、`isMine=true` |
| C. bot 动作 + 结算 | bot 日志 | `-> activate ... code=53582587|84749824|59839761` **且**随后该局出现对应的 `MSG_CHAIN_SOLVED`（或目标卡进入墓地 + 效果生效的日志/状态变化） |
| D. 截图 | `bridge\shot.ps1` | 陷阱翻开发动瞬间（卡图/效果处理条），作为辅助证据 |

补充要求：
- **不是"盖下去"**：必须是 `activate`/`chaining` 动作真的被内核接受（无 `RETRY`、后续有结算）。
- 若同局出现 `RETRY after msg=...` 与目标卡相关，需确认最终是否仍发动成功；无法确认则不算。

## 二、证据提取命令（每局跑完执行）

```powershell
# 1) 客户端日志里的链/目标卡
Get-ChildItem mycard-bot\game\control-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
  ForEach-Object { Select-String -Path $_.FullName -Pattern 'CHAIN|chaining|chained|53582587|84749824|59839761' }
# 2) bot 日志里的动作/策略线索
Select-String -Path ranked\logs\lan-bot-*-<stamp>-g1.log -Pattern 'ACTIVATE-TRAP|CHAIN-TRAP|-> activate|-> chain' 
# 3) /state 快照（跑局中/结束时）
#    /state.chainStack、/state.activeEffects、/state.lastChainEvent（task-19 新增字段）
Invoke-WebRequest 'http://127.0.0.1:7788/state' -UseBasicParsing | Select-Object -Expand Content
# 4) 截图（跑局中，看到陷阱翻开的瞬间）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\shot.ps1 -Tag trap<N>
```

## 三、卡组准备

- 基线：`mycard-bot\game\deck\Blackwing.ydk`（40 主 / 15 额外），三张目标陷阱各 ×1 → **实际跑局用这个**。
- `mycard-bot\game\deck\trap-test.ydk`：**已改回 lflist 合规副本**（三张目标陷阱各 ×1，其余同 Blackwing）。
  - ⚠️ 教训（第 1 轮）：曾把三张各放到 ×3 提高上手率，但 `lflist.conf` 里
    激流葬 `53582587` = 1~2、神之警告 `84749824` = **限1** → `PlayerReady: deckerror type=1 code=0x150d2e00`，
    RS_READY 被服务端拒绝，房间永远 `ready:[0,0]`、开不了局。**不能靠堆同名卡提高上手率**。
  - 合规前提下想提高上手率只能：换卡池（仍受 lflist 约束）或靠多局累积概率。

## 四、轮次记录

| 轮 | 时间 | 卡组 | 结局 | 回合 | 目标陷阱是否发动 | 证据路径 | 失败原因 / 反馈对象 |
|---|---|---|---|---|---|---|---|
| 1 | 2026-11-04 14:05:56 | trap-test（×3，违规） | `no-start`（117s） | 0 | 否 | `ranked\logs\lan-run-20261104-140556.log`、`control-27532.log` / `control-27116.log` | **卡组违规**：`deckerror type=1 code=0x150d2e00`（神之警告限1/激流葬1~2 却放 ×3）→ CheckDeck 失败、RS_READY 被拒；与 UI/策略无关。已改回合规。 |
| 2 | 2026-11-04 14:12:28 | Blackwing | 手动停在 turn 8 | 8 | 否 | `lan-run-20261104-141228.log` | **策略旧镜像**：`choose()` 无 `set_spell` 分支 → bot 45/111 决策中 `set_spell=0`（guest 手里摸到过 激流葬 53582587 但从未盖下）。已由 task-21 (14:16) 修复。 |
| **3** | **2026-11-04 14:21:12** | **Blackwing** | **✅ 目标达成（turn 4 命中，手动停在 turn 4）** | **4** | **是：神之警告 84749824（双方各发动 1 次）** | 见下方 §4.1 | **成功**：`SET-TRAP → CHAIN-TRAP → 内核 chainStack 命中 + 支付 2000 LP` |

### 4.1 第 3 轮成功证据（内核级）

**运行**：`lan-run.ps1 -Games 3 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing`，`YGO_UI_ACTIONS=0`（直连，避开 UI bug）
**环境**：exe `2026-11-04 14:19:13 / 6,220,800 B`；策略 `14:16:07`（含 SET-TRAP）；host pid 44424（7788）/ guest pid 18016（7789）

1) **策略层（bot 日志，线索）**：
```
[guest] SET-TRAP 盖放[神之警告](code=84749824) -> set spell/trap #3 code=84749824
[guest] #4 seq=4->4 msg=11 -> set_spell "set spell/trap #3 code=84749824" ok
[guest] CHAIN-TRAP 用[神之警告]连锁当前连锁（理由：无效特殊召唤/效果并破坏） (no desc)
[guest] #29 seq=29->29 msg=16 -> chain "chain #0 code=84749824" ok
[host]  SET-TRAP 盖放[神之警告](code=84749824) -> set spell/trap #0 code=84749824
[host]  CHAIN-TRAP 用[神之警告]连锁当前连锁（理由：无效特殊召唤/效果并破坏） (no desc)
[host]  #23 seq=23->23 msg=16 -> chain "chain #0 code=84749824" ok
```

2) **内核级证据（`/prompt` 快照，`chainStack` 来自 CHAINING 消息）**：
文件：`ranked\logs\trap-20261104-142112\chain-p7789-seq35-d1-c0.json`
（归档副本：`ranked\logs\trap-EVIDENCE-84749824-chainStack.json`）
```json
"turn": 4, "lp": [6000, 6000],
"chainDepth": 1,
"chainStack": [{"link":1,"code":84749824,"name":"神之警告","desc":0,"descText":"",
  "ctrl":1,"loc":8,"seq":0,"type":"effect","forced":false,"isMine":true,"solved":false,
  "summary":"我方[神之警告] 已加入连锁"}],
"chainingTo": {"link":1,"code":84749824,"name":"神之警告","descText":"","summary":"我方[神之警告]"},
"lastChainEvent": "连锁成立: [神之警告]",
"activeEffects": "我方[神之警告] 已加入连锁"
```
→ `type=effect`、`code/name` 命中、`ctrl/loc/seq` 齐全 = 内核已经把这张陷阱放进连锁。

3) **效果实际生效（LP 代价）**：神之警告发动需支付 2000 LP。LP 轨迹：
```
8000/8000 -> 8000/6000（guest 支付）-> 6000/6000（host 支付）-> 6000/4600 -> 6000/4200
```
对应 run log：`[14:22:58] lp=8000/6000`（guest 已付）→ `[14:23:17] lp=6000/6000`（host 也付）。
即**双方各成功发动过一次** 神之警告（不是"选中但被 invalid"，否则不会扣 LP/不会进连锁栈）。

4) **截图（发动瞬间）**：
- `ranked\logs\lan-traphit2-1.png` → 归档 `ranked\logs\trap-EVIDENCE-84749824-hit1.png`
- `ranked\logs\lan-traphit3-1.png` → 归档 `ranked\logs\trap-EVIDENCE-84749824-hit2.png`
- 另有 `lan-traphit1-*.png`（3 组共 6 张）
画面：turn 4、双方 LP 6000/6000，中央连锁窗口「[黑羽-月影之卡鲁特]召唤中 是否要进行连锁?」= 神之警告的发动时点。

5) **旁证**：`/state.chainStack` 在链结束后清空（`lastChainEvent="连锁结束（清空）"`），符合 task-19 的设计。

> 结论：**task-20 目标达成** —— 三张目标陷阱中的「神之警告 84749824」已被内核成功发动（双方各一次），证据链 = bot 决策日志 → `/prompt.chainStack`（内核级）→ LP 支付 2000 → 截图。

### 4.2 补充：默认 UI 模式下也发动了目标陷阱「激流葬 53582587」（2026-11-04 15:02，exe 14:56:22）

`lan-run-20261104-145637.log`（默认 `uiActions=1`、未设任何环境变量，同一局还打出了 `MSG_WIN player=0 reason=1 (LP_ZERO)` 自然胜负）：

```
# 盖放：UI 点手牌 → 菜单 → set_spell（menu check 命中）
UI inject click x=1037 y=829 card=53582587 world=(4.30,4.00,0.50) hovered=(0,2,1) menu=1
UI menu check kind=set_spell want=53582587 menuCard=53582587 items=13 id=244
[sem] SET-TRAP 盖放[激流葬](code=53582587) -> set spell/trap #0 code=53582587
# 连锁发动：UI 点场上 SZONE 的陷阱卡（两帧菜单重试生效）
UiSem begin kind=chain idx=0 msg=16
UI inject click x=723 y=702 card=53582587 world=(1.75,2.60,0.01) hovered=(0,0,0) menu=0
UI no-menu kind=chain msg=16 -> queued menu id=240 (next frame)
UI action kind=chain msg=16 -> card+menu chain (0) ok=1
[sem] CHAIN-TRAP 用[激流葬]连锁当前连锁（理由：激流葬 的效果）
[sem] #30 msg=16 -> chain "chain #0 code=53582587" ok
[sem] hb ... trapsSet=1 trapsAct=1 chains=3/4
```

→ 证明"动作全部经 UI 点击"的链路和"目标陷阱发动"可以同时成立（**UI 模式下也能发动陷阱**）。

## 五、失败原因分类与反馈对象

| 现象 | 判定 | 反馈给 |
|---|---|---|
| 手牌/盖放里根本没有目标陷阱（抽不到） | 上手率问题 | 自己：换 `trap-test`（浓度 ×3） |
| 有 `activate` 候选（含目标陷阱）但 bot 选了别的 | 策略问题 | **proxy-poc-builder（task-21）**，附 `/prompt` 原始候选 + bot 决策日志 |
| 有 `chainCandidates` 含目标陷阱但 bot 连锁选了别的 / 直接 decline | 策略问题 | **proxy-poc-builder（task-21）**，附 `chainStack/chainingTo/chainCandidates` |
| bot 选了目标陷阱但 UI 点击失败 / 回退 / `RETRY` | UI 执行问题 | **poc-wasm-duel（task-18）**，附 control 日志 `UI action`/`RETRY` 行 |
| 陷阱成功发动但内核没给 `CHAINING`/`chainStack` 记录 | 语义暴露缺失 | **poc-wasm-duel（task-19）**，附 `/state`、`/prompt` 原始 JSON |

## 六、环境与协作

- 同一时间只能跑一对客户端（7911/7788/7789）：**只有本验证方起停 YGOPro**；其他 agent 只改代码/编译（编译前需我确认窗口）。
- 跑局命令：
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 10 -StallSeconds 150 -Deck Blackwing
  # 或高浓度陷阱卡组：
  powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 10 -StallSeconds 150 -Deck trap-test
  ```
- 产物：`ranked\logs\lan-run-<stamp>.log`、`lan-bot-*`、`lan-state-*`、`lan-ctl-*`、截图 `lan-trap<N>-*.png`

## 七、待办 / 已知小问题（不阻塞验收）

| # | 问题 | 证据 | 归属 |
|---|---|---|---|
| 1 | ~~`chainStack[].descText` / `chainingTo.descText` 为**空串**~~ → ✅ **已结案（2026-11-04 14:40:05 版验证通过）** | 修复后实测：`ranked\logs\ui-smoke-chainstack-descText.json` → `chainStack[0] = {code:73652465, name:"黑羽-突风之颪", descText:"改变表示形式", summary:"我方[黑羽-突风之颪]（改变表示形式） 已加入连锁"}`；`lastChainEvent="连锁成立: [黑羽-突风之颪]"`。策略日志不再出现 `(no desc)` 后缀 | poc-wasm-duel（task-19）—— 已修复并验证 |
| 2 | 策略日志中文在 PS 控制台显示为乱码（GBK 解码显示问题），文件内容 UTF-8 正常 | `Get-Content` 直接输出时可见；用 `Select-String -Encoding UTF8` 正常 | 显示问题，无需修 |
| 3 | 完整跑完一局时 `stats ... trapsSet=/trapsActivated=` 才会打在收尾；被 kill 会丢 | 第 3 轮 turn 4 命中后手动停局 | proxy-poc-builder 已改为每 30s 心跳也打 `trapsSet=/trapsAct=`，下次可直接 grep 心跳行 |
| 4 | 另外两张目标陷阱（激流葬 53582587 / 三角乌鸦阵 59839761）未单独验证 | 第 3 轮只出现 神之警告 84749824 | 两者走同一 `SET-TRAP → CHAIN-TRAP` 路径；如需再证，重跑等抽到即可 |
