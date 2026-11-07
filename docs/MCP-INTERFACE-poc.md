# MCP-INTERFACE 补充章节（poc-wasm-duel 提供，供主文档合并）

> 本文是**片段**，交给 `MCP-INTERFACE.md` 的作者合并用；合并时可直接保留章节标题层级，
> 或按主文档的编号重排。所有行号以 2026-11-04 22:00 版 `mycard-client/gframe/control.cpp`
> （exe `22:00:40`，size 6,237,184）为准，之后若代码改动请以符号名搜索更新。

---

## A. UI 动作注入：设计细节（建议并入主文档「动作执行 / UI 注入」章节）

### A.0 为什么要有这一层

控制层（`GET /act_id?kind=...`）拿到的是**语义动作**；为了让客户端界面与"真人操作"完全一致
（弹窗被真正的按钮/点击关掉、动画/高亮/连锁特效正常），动作执行改成：

```
HTTP /act_id  ->  Action{kind=UiSem, semKind, semIndex, ...} 入队
              ->  Pump()（客户端 UI 线程）执行
              ->  ① 优先：注入 UI 事件（点按钮 / 点卡片 / 点格子）
                  ② UI 不可用/点不中：600ms 内自动回退到直连 SetResponseI/B + SendResponse()
```

**原则**：UI 路径是"更真实的执行方式"，直连是**兜底**；任何情况下都不允许把对局卡死。

### A.1 两条注入通道

#### 按钮（GUI 事件）

```cpp
// control.cpp: ClickButton()  ~L697
irr::SEvent ev;
ev.EventType = irr::EET_GUI_EVENT;
ev.GUIEvent.EventType = irr::gui::EGET_BUTTON_CLICKED;
ev.GUIEvent.Caller = btn;                 // IGUIButton* / IGUIElement*
mainGame->device->postEventFromUser(ev);  // 默认通道
// YGO_UI_EVENT_DIRECT=1 时改为：
//   mainGame->device->getEventReceiver()->OnEvent(ev);
```

- 与真实点击走同一条分发路径：`Game::MainLoop` 里 `device->run()` 把事件交给当前 receiver
  （对局中 = `&mainGame->dField`），按钮 ID 在 `ClientField::OnEvent` 的 GUI 分支里分发。
- 日志：`UI inject button id=<id> caller=<ptr> path=postEvent|receiver sentSync=0|1`
  （`sentSync=1` 表示该按钮的 handler 同步发出了 CTOS 响应，例如命令菜单项）。

#### 鼠标（3D 世界 → 屏幕像素 → 三个鼠标事件）

```cpp
// control.cpp: InjectMouse() ~L721
EMIE_MOUSE_MOVED            (ButtonStates=0)
EMIE_LMOUSE_PRESSED_DOWN    (ButtonStates=irr::EMBSM_LEFT)
EMIE_LMOUSE_LEFT_UP         (ButtonStates=0)
// MouseInput.X/Y = 屏幕像素；同样 postEventFromUser（或 YGO_UI_EVENT_DIRECT 时 receiver->OnEvent）
```

### A.2 坐标换算（关键：`curPos` 不是屏幕坐标）

`ClientCard::curPos`、`matManager.vField*` 都是 **3D 世界坐标**（`materials.cpp` 里
`SetS3DVertex` 的 x/y/z）。客户端相机在 `game.cpp:1023` 附近：

```cpp
BuildProjectionMatrix(mProjection, -0.90f, 0.45f, -0.42f, 0.42f, 1.0f, 100.0f);
camera->setProjectionMatrix(mProjection);
mProjection.buildCameraLookAtMatrixLH({4.2f, 8.0f, 7.8f}, {4.2f, 0, 0}, {0, 0, 1});
camera->setViewMatrixAffector(mProjection);
```

因此点击坐标 = **用客户端自己的相机投影**：

```cpp
// control.cpp: WorldToScreenPos()  ~L769
irr::scene::ISceneManager* smgr = mainGame->smgr;
auto* col = smgr->getSceneCollisionManager();
auto* cam = smgr->getActiveCamera();
out = col->getScreenCoordinatesFrom3DPosition(worldPos, cam);   // -> 屏幕像素
```

- **卡片**：`worldPos = card->curPos`
- **格子**（SELECT_PLACE/SELECT_DISFIELD）：世界中心按 `ClientField::GetCardLocation()` 的公式
  （`client_field.cpp:865-905`）：
  - MZONE：`X=(vFieldMzone[board][seq][0].X + [1].X)/2`，`Y=([0].Y + [2].Y)/2`，`Z=0.020f`
  - SZONE：同上（带 `[rule]`，`rule = duel_rule>=4 ? 1 : 0`），`Z=0.01f`
  - `board` 是**本地半区**（0=自己/屏幕下方，1=对手/上方），直接取
    `f.selectable_field` 的 bit 半区（`drawing.cpp` 证实低半→`vFieldMzone[0]`，高半→`[1]`），
    **不要**再做 server ctrl→local 映射。
- 早期错误实现（已修）：把 `curPos` 当虚拟坐标再 `mainGame->Resize(x,y)` → 点击落点全错。

### A.3 语义动作 → 控件映射

| `kind` | 触发方式 | 说明 |
| --- | --- | --- |
| `yes` / `no` | 点 `btnYes` / `btnNo` | 客户端 handler 内 `HideElement(...,true)`，淡出结束后统一 `SendResponse()` |
| `position` | 点 `btnPSAU/PSAD/PSDU/PSDD` | 同上（淡出后发送） |
| `to_bp` / `to_m2` / `to_ep` / `end_battle` | 点 `btnBP` / `btnM2` / `btnEP` | 同步发送 |
| `option` | 点 `btnOption[i]`（0..4） | 多效果选择 |
| `decline`（连锁放弃） | 先点 `btnCancelOrFinish`（弹出"是否放弃连锁"），再点 `btnNo` | 最终发送 -1 |
| `chain` / `activate` | 点卡 → 等 `wCmdMenu` → 点 `BUTTON_CMD_ACTIVATE`（有 `wOptions` 时再点 option0） | 两步 |
| `summon` / `spsummon` / `set_monster` / `set_spell` | 点卡/手牌 → 菜单 → `BUTTON_CMD_SUMMON/SPSUMMON/MSET/SSET` | 两步 |
| `place` | 直接把投影点注入到目标格 | 单步 |

命令菜单的按钮是 **`wCmdMenu` 的固定子按钮**（ID = `BUTTON_CMD_*`，`game.cpp` 里
`env->addButton(..., wCmdMenu, BUTTON_CMD_ACTIVATE, ...)`），用 `FindChildById(wCmdMenu, id)` 找。

### A.4 安全机制（保证「点不中也不会卡死」）

1. **600ms 校验 + 自动回退**（`BeginUiVerify()` ~L807；Pump 内校验块 ~L2896-2925）
   - UI 动作发出时记 baseline：`g_ctosCount`（客户端真正发出的 CTOS 包数）、`g_analyzeCount`；
   - 每帧检查：出现 CTOS 或新 analyze → 记 `UI action kind=.. verified (ctos+.. analyze+..) after ..ms`；
   - 600ms 内两者都没动 → **`UI fallback (no-effect) kind=.. -> direct response`**，用入队时
     预先编码好的 fallback 字节走 `SetResponseI/B + SendResponse()`。
2. **菜单两步**（`UiCardThenMenu()` ~L818；`ActionKind::UiMenu` case ~L1757）
   - 点卡后菜单若未出现（有时候晚 1-2 帧）：记 `UI no-menu ... queued menu`，把"点菜单项"作为
     `UiMenu` 动作排到下一帧；
   - `UiMenu` 里菜单仍不可见/找不到目标按钮：最多 **重试 2 帧**（`UI no-menu retry=N`），
     再失败 `UI fallback (no-menu) ... -> direct response`。
3. **菜单归属校验（防崩溃）**
   - 点卡后必须 `dField.menu_card == 目标卡` 才点菜单项，否则
     `UI skip (menu card mismatch) -> fallback`。
   - 背景：菜单属于别的卡时，客户端 handler 里 `select_options` 可能为空 → `std::out_of_range`
     → 0xE06D7363 崩溃。该防线在 15 回合实测中接住过 3 次。
4. **异常防护**：`TryUiSemantic` / `UiMenu` / `ClickButton` / `InjectMouse` / `Pump` 每动作
   外层全部 `try/catch(std::exception)/catch(...)`，异常记 `UI exec-exception ... -> fallback`。
5. **控件判空**：`TryUiSemantic` 入口检查 `g_uiActions && mainGame && device && smgr`，缺失记
   `UI skip (not ready)`；缺 `wCmdMenu` 记 `UI skip (no widget)`；都返回 false → 直连 fallback。
6. **UI 关闭清理**（`UiCleanup()` ~L595）：每个动作后（以及直连 fallback 后）关闭 prompt 弹窗：
   `wPosSelect / wOptions / wCardSelect / wCmdMenu / wMessage`；task-22 起再扩展关闭
   `wACMessage / wQuery / wCardDisplay / wANNumber / wANCard / wANAttribute / wANRace / wBigCard`
   （`YGO_UI_HIDE_EXTRA=0` 可关；**排除** `wHand / wFTSelect`，这两个是猜拳/先后手窗口）。
7. **空框兜底**（`CloseEmptyFrames()` ~L1009）：仅当 `dInfo.isInDuel && dInfo.isStarted && !awaiting`
   时，把正文为空的 `wMessage/wACMessage/wQuery` 隐藏并记 `UI close empty frame name=..`；
   隐藏 `wMessage` 时强制 `actionSignal.Set()`（否则网络线程会一直等 OK）。

### A.5 开关（环境变量）

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `YGO_UI_ACTIONS` | **1（默认走 UI）** | `0` = 全部走旧直连 `SetResponseI/B+SendResponse`（回退/对照） |
| `YGO_UI_EVENT_DIRECT` | 0 | `1` = 注入改走 `device->getEventReceiver()->OnEvent(ev)`（A/B 用） |
| `YGO_UI_HIDE_EXTRA` | 1 | `0` = 动作后不关 `wACMessage/wQuery/wAN*/wBigCard` 等扩展弹窗 |
| `YGO_UI_TASK22` | 1 | `0` = 一键关闭 task-22 全部新路径（扩展清理 + 空框兜底 + 窗口 debug 日志），二分用 |
| `YGO_UI_CLOSE_EMPTY` | 1 | `0` = 只关空框兜底逻辑 |
| `YGO_CTRL_DEBUG` | 未设 | 设了才输出调试日志（含每 15 帧 `CDBG UI windows visible=[...]`） |

启动日志会打印当前值：
`control: started port=.. hooks=.. ... uiActions=1 uiEventDirect=0 hideExtra=1 task22=1 closeEmpty=1`

### A.6 关键代码位置（control.cpp，22:00:40 版）

| 功能 | 符号 | 行号 |
| --- | --- | --- |
| UI 弹窗清理 | `UiCleanup()` | ~595 |
| 按钮注入 | `ClickButton()` | ~697 |
| 鼠标注入 | `InjectMouse()` / `InjectClick()` | ~721 |
| 世界→屏幕投影 | `WorldToScreenPos()` | ~769 |
| 校验 baseline | `BeginUiVerify()` | ~807 |
| 点卡+菜单两步 | `UiCardThenMenu()` | ~818 |
| 语义→UI 分派 | `TryUiSemantic()` | ~894 |
| 空框兜底 | `CloseEmptyFrames()` | ~1009 |
| 窗口 debug 列表 | `LogVisibleWindows()` | ~1036 |
| `UiMenu` 第二相 | `case ActionKind::UiMenu` | ~1757 |
| 600ms 校验/回退 | `Pump()` 内 `g_uiPending` 块 | ~2896-2925 |

### A.7 日志关键词（排障 grep）

```
UI inject button id=.. caller=.. path=.. sentSync=..
UI inject click x=.. y=.. card=.. world=(x,y,z) hovered=(ctrl,loc,seq) menu=0|1
UI no-menu kind=.. -> queued menu ...
UI no-menu retry=N kind=.. ...
UI skip (menu card mismatch) / UI skip (not ready) / UI skip (no widget)
UI action kind=.. -> ... ok=1
UI action kind=.. verified (ctos+N analyze+M) after ..ms
UI fallback (no-effect) kind=.. / UI fallback (no-menu) kind=..
UI cleanup popups=0x.. extra=0x.. (...) / UI cleanup extra=0x.. after action
UI close empty frame name=wMessage|wACMessage|wQuery
UI exec-exception kind=.. what=..
```

### A.8 已知限制

- `select / card / sum / sort` 这类"选具体卡"的动作仍主要走直连（语义动作里没有卡身份），
  故 `/act_id` 的 `UI fallback` 会占一部分；
- 实测残余 `UI fallback (no-effect)` 约 5%~11%（`place` 边界、`decline`/`yes` 的淡出时序），
  全部自动直连回退，不影响对局；
- 多效果卡默认点第 0 个 option（可能不是最优效果）；
- `wQuery` 的扩展清理目前不判正文（若后续发现"该弹的确认框一闪而过"，可改成仅 `textLen==0` 时关）。

---

## B. 连锁字段与语义（建议并入主文档「/prompt 与 /state 字段」章节）

### B.1 数据来源（客户端）

| 数据 | 来源 | 生命周期 |
| --- | --- | --- |
| `dField.current_chain` | `MSG_CHAINING(70)` 解析 | 每来一次 CHAINING 覆盖：`chain_card/code/desc/controler/location/sequence/solved/target` |
| `dField.chains` | **`MSG_CHAINED(71)`** 时 `push_back(current_chain)` | 已"成立"的连锁环；`MSG_CHAIN_SOLVING(72)` 给对应环打 `solved`；`MSG_CHAIN_END(74)` 时 `chains.clear()` |
| `dField.activatable_cards[]` + `activatable_descs[i]={desc,flag}` | `MSG_SELECT_CHAIN(16)` 解析 | 当前这次可选的连锁项；`flag & 0x100` = 强制发动，`flag & EDESC_OPERATION` = 操作类（不是卡效果） |
| `dField.chain_forced` | 同上（forced 链） | `canDecline = !chain_forced` |
| `dField.select_hint` | 本次选择提示 desc | → `hint` |
| `MSG_HINT(2)` (`type=HINT_SELECTMSG(3)`, `data=desc`) | `OnMessageBegin` 记入原子 | 作为 `hint` 的第二来源 |
| `dataManager.GetName(code)` / `GetDesc(desc)` | 卡名/效果文本 | `name` / `descText` |

> 注意：`MSG_CHAINING` 只填 `current_chain`，**不会**立刻进 `dField.chains`；真正入栈在
> `MSG_CHAINED`。所以"提示你选连锁"的那一刻，`chainStack` 里是**已经成立的环**，
> 当前"正在发动/被连锁"的那一环来自 `current_chain`（我们同时用 `lastChainEvent`/`chainingTo` 体现）。

### B.2 字段表（`/prompt` 与 `/state` 同名字段，由 `AppendChainJson()` ~L404 统一输出）

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `chainDepth` | int | 当前已成立的连锁环数（= `dField.chains.size()`），无连锁为 0 |
| `chainStack[]` | array | 按**成立顺序**（link 1..N）列出每一环：`{link, code, name, desc, descText, ctrl, loc, seq, type:"effect", forced, isMine, solved, summary}` |
| `chainingTo` | object\|null | "当前在回应哪一环"：取 `chainStack` 的最后一环 `{link, code, name, descText, summary}`；无链为 `null` |
| `chainCandidates[]` | array | 本次 `MSG_SELECT_CHAIN` 可选的连锁项：`{index, code, name, desc, descText, forced, isMine, ctrl, loc, seq, summary}`；`index` **就是 `/act_id` 里 `kind=chain&index=N` 的 N** |
| `canDecline` | bool | 是否可以"不连锁"（`!dField.chain_forced`）；`true` 时 `/actions` 里会有 `decline` 动作 |
| `hint` | string | 本 prompt 的可读提示（`select_hint` 或 `HINT_SELECTMSG` 的 desc 文本），可为空串 |
| `lastChainEvent` | string | 最近一次连锁事件的可读文本：`我方/对手发动 [卡名]（效果）→ 连锁`、`连锁成立: [卡名]`、`连锁结算: [卡名]`、`连锁结束（清空）` |
| `/state.activeEffects[]` | array<string> | 当前连锁栈的可读行（每环一条 `summary`），**链结束后由 `MSG_CHAIN_END` 清空** |
| `/state.continuousEffects[]` | array | 旧的"持续效果"列表（`contiList`），与链栈无关 |

兼容字段（旧）：`/prompt.chainCount`、`chainForced`、`chainList[]`（code/seq）仍在，但
**新代码请只读上面的 canonical 字段**；`/prompt` 里另有一个历史遗留的 `chains`（数量）字段，勿与
`chainStack` 混淆。

文本兜底规则（避免空字符串给 LLM 造成误判）：
- `descText` 取 `GetDesc(desc)`；为空时按 `chain_card` 在 `activatable_cards/descs` 回查 → `chain_card->cHint`
  → 兜底 `"<卡名> 的效果"`；
- `name` 取 `GetName(code)`，未知卡兜底 `#<code>`。

### B.3 样例（`curMsg=16`，对手 `神之警告` 发动后轮到我方决定是否连锁）

```json
"chainDepth": 1,
"chainStack": [
  {"link":1,"code":84749824,"name":"神之警告","desc":1141,"descText":"支付2000LP发动……",
   "ctrl":1,"loc":8,"seq":0,"type":"effect","forced":false,"isMine":false,"solved":false,
   "summary":"对手[神之警告]（支付2000LP发动……） 已加入连锁"}
],
"chainingTo": {"link":1,"code":84749824,"name":"神之警告","descText":"支付2000LP发动……",
               "summary":"对手[神之警告]（支付2000LP发动……）"},
"chainCandidates": [
  {"index":0,"code":53582587,"name":"激流葬","desc":1142,"descText":"场上怪兽全部破坏",
   "forced":false,"isMine":true,"ctrl":1,"loc":8,"seq":2,
   "summary":"我方[激流葬]（场上怪兽全部破坏） 可以连锁 对手[神之警告] — 可选"}
],
"canDecline": true,
"hint": "选择要发动的效果",
"lastChainEvent": "对手发动 [神之警告]（支付2000LP发动……）→ 连锁"
```

`/state.activeEffects`（同一时刻）：
```json
"activeEffects": ["对手[神之警告]（支付2000LP发动……） 已加入连锁"]
```

### B.4 多重连锁时字段如何变化（LIFO）

设双方共发动 3 环（A→B→C）：

| 事件 | 客户端状态 | `/prompt` 链字段（对该时点正在选链的一方） |
| --- | --- | --- |
| A 的 `MSG_CHAINING` | `current_chain`=A | （服务器通常先给对手选链）若给到我方：`chainDepth=0`，`chainCandidates=[...]`，`chainingTo=null` |
| A 的 `MSG_CHAINED` | `chains=[A]` | `chainDepth=1`，`chainStack=[A]`，`chainingTo=A` |
| B 的 `MSG_CHAINING`/`CHAINED` | `current_chain`=B，`chains=[A,B]` | `chainDepth=2`，`chainStack=[A,B]`，`chainingTo=B`，`chainCandidates` 为新的可选集合（`index` 从 0 重新编号） |
| C 的 `MSG_CHAINED` | `chains=[A,B,C]` | `chainDepth=3`，`chainStack=[A,B,C]`，`chainingTo=C` |
| `MSG_CHAIN_SOLVING` / `MSG_CHAIN_SOLVED` | 对应环 `solved=true` | `chainStack[i].solved` 逐个变 true；结算顺序 **C→B→A（LIFO）** |
| `MSG_CHAIN_END` | `chains.clear()` | `chainDepth=0`，`chainStack=[]`，`chainingTo=null`，`/state.activeEffects=[]`；`lastChainEvent="连锁结束（清空）"` |

要点：
- **每多一环就多一次 prompt**（`MSG_SELECT_CHAIN`），`chainDepth` 递增；`chainCandidates.index`
  每次都是**当前这次**的候选下标（不是全局链号，链号看 `chainStack[].link`）；
- 连锁结算顺序是 **LIFO**（最后发动的先结算），`solved` 逐个置真；
- 链结束后所有链字段清空，`lastChainEvent` 保留"连锁结束"文本直到下一个事件。

### B.5 给 LLM 的决策规则（可直接写进主文档）

1. `curMsg==16`（`MSG_SELECT_CHAIN`）时优先读 `chainCandidates`：
   - `chainCandidates=[]` 且 `canDecline=true` → **只能不连锁**（发 `decline`）；
   - 想连锁 → `kind=chain&index=<chainCandidates[].index>`；
   - `forced=true` 的候选通常必须发动（`canDecline=false` 时更是如此）；
2. `chainingTo` 用来说明"我在连锁谁"；`chainStack` 说明整条链的历史（谁先发动、结算到哪）；
3. 效果文本：优先 `descText`，其次 `summary`（已含"我方/对手 + 卡名 + 效果 + 可/必发"）；
4. 需要判断"是否值得连锁"时结合 `/state` 的 `lp/turn/phase` 与 `chainCandidates[].descText`；
5. 若 `chainDepth>0` 且 `curMsg` 已经不是 16/11/10，说明链已结算/结束，别再引用旧 `chainCandidates`。

### B.6 与 `/actions` 的关系

- `/prompt.chainCandidates[i].index` ↔ `/actions[]` 里 `kind="chain"` 动作的 `index`（一一对应，
  单效果卡直接回该 index；多效果卡客户端会弹 `wOptions`，直连路径按 `(index<<16)+5` 编码、
  UI 路径默认点第一个 option）。
- `canDecline=true` 时 `/actions` 里会有一个 `kind="decline"`（放弃连锁）。
- 注意 `/actions` 的 index 是**当前 prompt** 的编号，prompt 变了就重新编号。

### B.7 `/prompt` 与 `/actions` 的一致性（prompt 快照）

`awaiting==true` 期间，`/prompt`、`/actions`、`/wait_prompt` 都返回**prompt 发布那一刻冻结的快照**
（`g_promptSnap`），而不是"最新到达的消息"。原因：`MSG_SELECT_CHAIN` 等 prompt 发布后，服务端仍可能
继续发 `MSG_WAITING(3)` 之类消息覆盖实时状态；若用实时快照，`curMsg` 会变成 3 而 `awaiting` 仍为 true，
调用方会看到"在等 prompt 但 `/actions` 只有 auto"的错位（实测导致策略进入 STALL HARD）。
因此：**`awaiting==true` 时 `/actions.curMsg` 一定等于 `/prompt.curMsg`（本次 prompt 的 id）**；
`awaiting==false` 时 `/actions` 返回空数组 + `reason:"not awaiting"`。

另外，**客户端会自己回答的 prompt 不会发布**（日志 `PROMPT skip auto-handled`）。典型例子：
`MSG_SELECT_CHAIN` 的 `count==0`（服务端没有任何可连锁卡，且 `specount!=0x7f`）时客户端 handler
直接 `SetResponseI(-1)+SendResponse()` 自动放弃；若控制层再发布这条 prompt，策略会重复发 `-1`，
把服务端拖进"空候选连锁"循环（实测曾出现 42~94 次空 `CHAIN-DECLINE`）。判定依据：分析前后 CTOS 计数
是否增长（`SendResponse()` 现在也会通知 `OnCtosPacket`），以及 `curMsg==16 && rawCount==0 &&
specount!=0x7f`。所以 `/prompt` 里看到的 `chainCandidates=[]` **只代表"当前无可连锁项、只能不连锁"**，
有候选时（`rawCount>0`）会正常出现，可被 `/act_id?kind=chain` 选中。

### B.8 输赢字段（不要直接读 raw `winPlayer`）

`MSG_WIN.player` 是**服务器座位号（raw seat）**，不一定是"我方"。客户端 `dInfo.lp` 是**本地视角**：
`lp[0]` 是我方 LP、`lp[1]` 是对手 LP。因此 `/state` 提供：

| 字段 | 含义 |
| --- | --- |
| `winPlayer` | raw 赢家座位（0/1；2 = 平局） |
| `winPlayerLocal` | `LocalPlayer(winPlayer)`：0 = 我方赢，1 = 对手赢，-1 = 平局/未知 |
| **`isWin`** / `isLoss` / `isDraw` | **推荐读取**：我们赢 / 我们输 / 平局 |
| `lp` + `lpOrder:"local"` | `lp[0]` = 我方，`lp[1]` = 对手 |

> 实例：raw `winPlayer=0` 对 guest（raw seat 1）而言是**对手赢**，看 `isWin=false/isLoss=true` 才对。

### B.9 已知限制

- `chainStack[].forced` 目前恒为 false（链成立后客户端不再保留 forced 标志）；
- `type` 目前固定 `"effect"`（没有区分 operation/重置类）；
- `descText` 在极少数卡上可能仍只剩兜底文本（`"<卡名> 的效果"`）；
- `lastChainEvent` 来自消息解析的原子量，与 UI 线程快照可能差 ≤1 帧；需要精确时以 `chainStack` 为准。
