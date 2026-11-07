# 直连动作清单：哪些动作还没走 UI、为什么、对 LLM 有什么影响

> **一句话**：客户端的控制层对**一部分**语义动作会「注入真实 UI 点击」，对另一部分直接回退成
> **直接发协议响应（直连）**。这不是 bug，而是**设计上的兜底**：UI 点不中时也不能让对局死锁。
> 对 LLM 来说两种路径**行为上完全等价**（同一个内核入口、同样的结算），差别只在「UI 自己会不会收尾」。
>
> 本文是 **kind 级**的清单与代码依据；概括性描述见 [`MCP-INTERFACE.md`](MCP-INTERFACE.md) §9「已知限制」。
> 本文实测数据来自 **`YGOPro.exe` 6,237,184 B / 2026-11-04 22:00:40** 构建的一局完整客户端日志
> （`control-7616.log`，68,592 行；这类日志是运行产物，不随仓库分发，数字只用于判断量级）。
> 字段名/日志关键词均可在源码 grep 到。

---

## 1. 判定口径（代码级，先说清"怎么算直连"）

`/act_id?id=N` 在客户端进程内的执行链：

```
HTTP /act_id  ──►  Action{ kind = ActionKind::UiSem, semKind, semIndex, i, bytes }
                    │
        Pump()（UI 线程）──► ExecuteAction(a)            // control_actions.cpp
                    │
                    └─► case ActionKind::UiSem: ExecUiAction(a)     // control_ui.cpp
                              │
                              ├─ handled = TryUiSemantic(a)
                              │     true  →  ok(): g_uiActionCount++,
                              │              日志 "UI action kind=.. msg=.. -> <目标> (..) ok=1"
                              │              并 BeginUiVerify(a)（600ms 内要有 CTOS/analyze 变化）
                              │     false →  g_uiFallbackCount++,
                              │              日志 "UI fallback kind=.. msg=.. (direct response)"
                              │              → DuelClient::SetResponseB/I(...); DuelClient::SendResponse();
                              └─ 之后 Pump() 校验：600ms 内没有 CTOS/analyze 变化 →
                                    g_uiFallbackCount++, 日志
                                    "UI fallback (no-effect) kind=.. after <ms>ms -> direct response"
                                    → 同样走 SetResponseB/I + SendResponse
```

因此**"直连"有两种成因**，日志里都能区分：

| 成因 | 日志 | 含义 |
|---|---|---|
| 语义动作**没有 UI 分支** | `UI fallback kind=<kind> msg=<curMsg> (direct response)` | `TryUiSemantic()` 直接 `return false` |
| **有** UI 分支但没生效 | `UI fallback (no-effect) kind=<kind> after <ms>ms -> direct response` | 点了，但 600ms 内内核没动（坐标/时序/遮罩） |
| 卡片→菜单 两段式的第二段失败 | `UI fallback (<reason>) kind=<kind> menuId=<id> -> direct response`；`<reason>` 运行期是 `no-menu`（实测：`UI fallback (no-menu) kind=chain menuId=240 -> direct response`） | 命令菜单没等到/菜单项不对 |
| 点之前就判定不能点 | `UI skip (no widget) kind=` / `UI skip (not ready) kind=` / `UI skip (menu card mismatch) kind=` / `UI skip (place not in snapshot) index=` | 直接进 fallback |

`TryUiSemantic()` 里**有** UI 分支的 `kind`（源码里逐条 `a.semKind ==` 比较，共 **16** 个）：

`yes` `no` `position` `option` `to_bp` `to_ep` `to_m2` `end_battle` `decline` `chain`
`activate` `summon` `spsummon` `set_monster` `set_spell` `place`

`TryUiSemantic()` **末尾 `return false`** → 其余一切 `kind`（含未来新增的）都直接走直连。

---

## 2. 现状清单（kind 级，含一局实测）

### 2.1 纯直连（代码里没有 UI 分支）

| `kind` | 出现场景（`curMsg`） | 为什么没有 UI 分支 |
|---|---|---|
| `auto` | 其它所有 MSG 的安全默认（`MSG_HINT`、`MSG_CONFIRM_*`…） | 它不是一个"具体动作"，而是"没有语义时的安全回 0/空"，**没有可点的控件** |
| `attack` | `MSG_SELECT_BATTLECMD`(10) | UI 上是"点我方攻击怪 → 再点目标/直攻按钮"的两段交互，`TryUiSemantic()` 里**没有** `"attack"` 分支 |
| `select` | `MSG_SELECT_CARD`(15) / `SELECT_TRIBUTE`(20) / `SELECT_UNSELECT_CARD`(26) | 候选只是"下标集合"，UI 要把它映射到 `wCardSelect` 列表里的具体卡片/坐标；`/actions` 的 index 与弹窗列表顺序**不保证一致** |
| `sum` | `MSG_SELECT_SUM`(23) | 既要定位多张卡，还要按"合计值"决定选几张（顺序/组合影响合法性） |
| `sort` | `MSG_SORT_CARD`(25) | 需要拖拽排序（`wCardSelect` 内部顺序），失败=非法排列 |
| `counter` | `MSG_SELECT_COUNTER`(22) | 需要逐卡填指示物数量（`wQuery` 类计数对话） |
| `announce` | `MSG_ANNOUNCE_RACE/ATTRIB/NUMBER/CARD` | 需要操作 `wANRace`、`wANAttribute`、`wANNumber`、`wANCard` 四套不同控件 |

### 2.2 部分 UI（有分支，但会按失败回退）

| `kind` | 为什么"部分" |
|---|---|
| `decline` | 需要 `btnCancelOrFinish` + `btnNo` 两连击；若弹窗层级不对，点了也不生效 → `no-effect` 回退 |
| `activate` / `chain` / `spsummon` | 走"点卡 → 等命令菜单 → 点菜单项"两段式；菜单没在下一帧出现就 `no-menu` 回退 |
| `yes` | `btnYes` 是最稳的按钮，但若点之前已被自动关闭/模态框遮挡，仍会 `no-effect` 回退 |

### 2.3 稳定 UI（代码有分支，实测 0 fallback；标 * 的是本局没出现、仅代码确认）

`place`（点格子 `UiClickFieldZone`）、`summon`、`to_bp`、`to_ep`、`to_m2`*、`end_battle`、`position`、
`option`*、`set_spell`、`set_monster`*、`no`*

### 2.4 同一局实测（`control-7616.log`，141 次 `UiSem begin`）

| `kind` | 尝试 | UI 成功 | 回退 |
|---|---|---|---|
| `auto` | 36 | 0 | 36 |
| `place` | 21 | 21 | 0 |
| `select` | 19 | 0 | 19 |
| `decline` | 13 | 10 | 4 |
| `activate` | 9 | 8 | 3 |
| `to_bp` | 8 | 8 | 0 |
| `summon` | 8 | 8 | 0 |
| `end_battle` | 7 | 7 | 0 |
| `position` | 6 | 6 | 0 |
| `spsummon` | 5 | 2 | 3 |
| `set_spell` | 2 | 2 | 0 |
| `attack` | 2 | 0 | 2 |
| `chain` | 2 | 2 | 2 |
| `to_ep` | 1 | 1 | 0 |
| `sum` | 1 | 0 | 1 |
| `yes` | 1 | 1 | 1 |
| **合计** | **141** | **76** | **71** |

- UI 占比 ≈ **52%**（76 / 141），直连 ≈ 48%。
- **回退数可以大于尝试数**：一次动作可能"菜单段失败 + 校验段再失败"，各自计一次（上表 `decline` 13→10+4、
  `chain` 2→2+2 就是这种）。
- 回退原因分布（同目录全部 `control-*.log` 汇总）：`(no-effect)` **87** 次、`(no-menu)` **34** 次。

> 这与 [`MCP-INTERFACE.md`](MCP-INTERFACE.md) §9 第 1 条的"UI action 79/74、verified 37/31"是同一量级；
> 数字会随牌组/对局/点击时序波动，**不要当基准值**，只用来判断"是不是明显退化了"。

---

## 3. 为什么这样设计（而不是全部走 UI）

1. **没有具体卡/目标身份**：`select` / `sum` / `sort` / `counter` 的候选只是"下标/数量"，
   要变成"点哪里"必须额外维护「候选 → 卡对象 → 屏幕坐标」的映射，并由 UI 侧反向确认"点中的是不是同一张"。
   一旦映射错位，得到的是**非法响应**（内核 `MSG_RETRY`），比直连更糟。
2. **多步交互的时序**：`attack` / `sort` / `counter` / `announce` 都是多段交互（点卡→点目标、拖拽、填数），
   每段都可能被动画/弹窗/遮罩打断；600ms 校验只覆盖"点了之后有没有效果"，覆盖不了多段中间态。
3. **兜底优先于纯度**：工程目标写死在代码注释里——**"a missed click can never deadlock the duel"**。
   UI 失败必须能退出到直连；反过来"为了 100% UI 而冒险"没有收益（内核看到的是同一份响应）。
4. **收益极低**：`sort/counter/announce` 一局通常 0–2 次；`auto` 是兜底语义，本来就没有"正确 UI 动作"。

---

## 4. 对 LLM 的影响（重点：几乎为零）

| 维度 | 有影响吗 | 说明 |
|---|---|---|
| 内核行为/结算 | **无差别** | 两条路径最终都是 `DuelClient::SetResponseI/B(...) + SendResponse()`，产生同一条 `CTOS_RESPONSE` |
| `/state` 可见状态 | **无差别** | 不回写额外字段；`uiCleanupCount` 会涨（直连后需要清理弹窗） |
| 日志 | 有差别 | UI 路径多一行 `UI action ... ok=1`；直连路径是 `UI fallback ... (direct response)` |
| **UI 收尾** | **有差别** | UI 点击会顺手关闭自己的弹窗；直连不会 → 控制层用 `UiCleanup("action")`（关 `wPosSelect/wOptions/wCardSelect/wCmdMenu/wMessage` + 扩展弹窗）和 `CloseEmptyFrames()`（关正文为空的 `wMessage/wACMessage/wQuery`）兜底 |
| 失败可见性 | 有差别 | UI 路径"假成功"会记 `UI fallback (no-effect)`；直连若响应非法，内核回 `MSG_RETRY` → `/state.retryCount`、`/state.retryStreak` 上升 |

**给 LLM 的建议**

- **只选 `id`，不要关心它走 UI 还是直连**；`UI fallback` 是**正常噪声**，不要重试、不要切换到别的动作。
- 真正需要盯的自检只有两个：`/state.retryStreak`（响应被内核拒收）和 `/ui.popupMask`（是否有残留弹窗）。
- 想看"这次动作到底点了没"：`UI action ... ok=1` 是点了且已生效（`verified`）；只有 `UI fallback` 才是直连。

---

## 5. 可选改进（想做「100% 全 UI」时的路线与代价）

> 目标不是"好看"，而是**减少 `UI fallback` 与残留弹窗**。任何一档都必须保留现有直连兜底
> （`YGO_UI_ACTIONS=0` 可一键全局对照），否则风险大于收益。

| 档 | 内容 | 做法 | 工作量（相对） | 风险 |
|---|---|---|---|---|
| **A** | `select` / `sum` | 在 `TryUiSemantic()` 里给这两类加分支：拿候选卡 → `ClientCard::curPos` → `WorldToScreenPos()` → 注入点击；点击后校验 `wCardSelect` 高亮集合是否与预期一致；`sum` 逐个点直到合计值达标 | 中（映射+校验+多选循环） | **点错卡=非法响应 → RETRY**；多选顺序/数量错会直接被内核拒。建议先只做 `select`（单选、cancelable 之外） |
| **B** | `attack` | 两段交互：点我方攻击怪（`mzone` 卡）→ 等可攻击目标高亮 → 点目标（或直攻按钮） | 中高 | 目标高亮窗口的时序；`attackableList` 里的目标必须与 `/actions` 的 `attack #i atk=N` 一一对上（label 里**没有**直攻标记，得从客户端 `attackable_cards` 反查）；错了会打错目标 |
| **C** | `announce` / `sort` / `counter` | `wANRace/wANAttribute/wANNumber/wANCard` 选择；`wCardSelect` 拖拽排序；`wQuery` 计数 | 高 | 控件交互密集、每类都要单独校验；一局 0–2 次，收益最低 |
| **D** | `auto` | 不建议改：它不是"一个动作"，是"其它 MSG 的安全默认"，没有对应控件 | — | 改了反而会引入"点错框"的新问题 |

**验收标准（建议写进 PR）**

1. 同牌组连跑 3 局：`UI fallback` 降到 **< 2%** 且 `retryStreak == 0`；
2. 新增分支的 `kind` 在日志里不再出现 `UI fallback (no-effect)` 或 `UI fallback (no-menu)`（允许极少首次校准）；
3. 任何一档都必须能通过 `YGO_UI_ACTIONS=0` 回到直连并正常打完一局（A/B 对照）；
4. 一局结束没有残留弹窗：`/ui.popupMask == 0` 且 `/ui.windowsVisible` 里没有 `wQuery`、`wMessage`、`wAN` 系列窗口。

---

## 6. 如何量化"这次运行直连占多少"

**日志在哪**：`Control::Log()` 写到**客户端进程当前工作目录**下的 `control-<pid>.log`
（LAN 跑局时客户端 cwd = `mycard-bot\game`，即 `mycard-bot\game\control-<pid>.log`）。
`bridge/lan-run.ps1` 会把对应两端的日志**摘录**成 `ranked\logs\lan-ctl-<stamp>-g<N>.txt`（片段，非全量）；
要统计比例请直接用**全量** `control-<pid>.log`。

**最小命令（PowerShell，粘到仓库根目录就能跑）**

```powershell
$logs = Get-ChildItem mycard-bot\game\control-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$t = Get-Content $logs.FullName
$ui = @($t | Select-String 'UI action kind=.*ok=1').Count        # 真正点成功（含 phase2）
$fb = @($t | Select-String 'UI fallback').Count                  # 所有回退（含 no-effect/no-menu）
$sem = @($t | Select-String 'UiSem begin kind=').Count           # 总尝试次数
"{0}: sem={1} ui={2} fallback={3} uiRatio={4}%" -f $logs.Name, $sem, $ui, $fb, [math]::Round(100*$ui/[math]::Max(1,$sem),1)
```

**完整脚本（按 kind 分布 + 回退原因）**

```powershell
$file = (Get-ChildItem mycard-bot\game\control-*.log | Sort-Object LastWriteTime -Descending)[0].FullName
$t = Get-Content $file

"== file: $file  lines=$($t.Count) =="

"`n== 每个 kind：尝试 / UI 成功 / 回退 =="
$kinds = $t | Select-String 'UiSem begin kind=(\w+)' | ForEach-Object { [regex]::Match($_.Line,'kind=(\w+)').Groups[1].Value } | Sort-Object -Unique
foreach ($k in $kinds) {
  $begin = @($t | Select-String ("UiSem begin kind=" + $k + "\b")).Count
  $ok    = @($t | Select-String ("UI action kind=" + $k + "\b.*ok=1")).Count
  $fb    = @($t | Select-String ("UI fallback.*kind=" + $k + "\b")).Count
  "{0,-12} begin={1,-4} uiOk={2,-4} fallback={3}" -f $k, $begin, $ok, $fb
}

"`n== 回退原因分布 =="
$t | Select-String 'UI fallback' | ForEach-Object {
  $m = [regex]::Match($_.Line,'UI fallback \(([^)]+)\)'); if ($m.Success) { $m.Groups[1].Value } else { 'no-ui-branch' }
} | Group-Object | Sort-Object Count -Descending | ForEach-Object { "{0,-14} {1}" -f $_.Name, $_.Count }

"`n== UI 生效校验 / 清理 / 残留 =="
"verified   : " + @($t | Select-String 'verified \(ctos\+').Count
"cleanup    : " + @($t | Select-String 'UI cleanup popups=').Count
"closeEmpty : " + @($t | Select-String 'UI close empty frame').Count
"retry      : " + @($t | Select-String 'RETRY after msg=').Count
```

**配套的 HTTP 侧自检**（不需要日志，随时可读）：

| 字段 | 用途 |
|---|---|
| `/ui.popupMask`、`/ui.popups` | 是否有残留弹窗（直连后靠 `UiCleanup` 兜底） |
| `/ui.uiCleanupCount` | 清理次数（直连频次越高，这个越大） |
| `/ui.windowsVisible` | 当前可见窗口名（`wQuery`、`wMessage`、`wAN*` 残留会在这里出现） |
| `/state.retryCount`、`/state.retryStreak`、`/state.placeVariant` | 响应被内核拒收的累计/连续次数 |
| `/state.uiCleanupCount` | 与 `/ui.uiCleanupCount` 同源（顶层别名） |

---

## 7. 结论：这不是 bug，是设计上的兜底

- **默认路径是 UI**（`YGO_UI_ACTIONS=1`，可在启动日志 `control: started ... uiActions=1` 里确认；
  `YGO_UI_ACTIONS=0` 可一键全部直连做对照）。
- **直连是兜底**：语义动作没有 UI 分支、或点了 600ms 内没生效时，回退到直连，保证"点不中也绝不死锁"。
  相关实现：`ExecuteAction()`（分派）、`ExecUiAction()`（UI 优先 + 回退）、`TryUiSemantic()`（16 个分支 + 末尾 `return false`）、
  `UiCleanup()` / `CloseEmptyFrames()`（直连后的弹窗收尾）。
- 相关概括描述见 [`MCP-INTERFACE.md`](MCP-INTERFACE.md) **§9「已知限制」**（第 1、2、5 条）；
  **注意**：§9 第 1 条的措辞（"`auto / select / sum / yes / decline` 等仍走直连"）偏粗——按当前代码，
  `yes` / `decline` / `option` / `position` **已经走 UI**；真正没有 UI 分支的是
  `auto / attack / select / sum / sort / counter / announce`。以本文 §2.1 为准。
- 如果你在写策略/接入层：**把 `UI fallback` 当噪声**，按 §4 的两个自检项（`retryStreak`、`popupMask`）把关即可。
