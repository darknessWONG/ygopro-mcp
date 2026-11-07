# UI 驱动的动作执行（task-18）

> 只改 `mycard-client/gframe/control.cpp`。目标：控制层不再 `SetResponseI/SendResponse` 直连内核，
> 而是**模拟真人点击**（按钮 GUI 事件 / 鼠标注入），这样弹窗、按钮高亮、命令菜单都与真人一致，
> 不会出现“响应发了但弹窗还挂着”。

## 1. 开关

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `YGO_UI_ACTIONS=0` | **开（默认走 UI）** | 设为 `0` 退回旧直连 `SetResponseI/SendResponse`（A/B/回滚） |
| `YGO_UI_EVENT_DIRECT=1` | 关 | 注入方式改成 `device->getEventReceiver()->OnEvent(ev)`（默认 `postEventFromUser`），用于 A/B |

> 2026-11-04 14:47 版起 **UI 模式已是默认**（用户要求“所有操作经 UI”）：15 回合实跑验证 0 崩溃、
> `UI exec-exception` 0 次、place verified 11/7、菜单归属校验成功挡住过一次会崩的错点
> （`UI skip (menu card mismatch)`）。仍保留 `YGO_UI_ACTIONS=0` 一键回退。

> 历史教训（14:09 版）：UI 点击“看起来成功”但内核没收到响应，控制层又已清掉 `awaiting` → 双端死锁。
> 现在的兜底是 **点击后校验 + 600ms 自动回退**（见 §6），所以即使点不中，对局也会继续。

## 2. 两条注入通道

1. **按钮**：照抄 `gframe.cpp:21` 的 `ClickButton()`：
   ```cpp
   irr::SEvent ev;
   ev.EventType = irr::EET_GUI_EVENT;
   ev.GUIEvent.EventType = irr::gui::EGET_BUTTON_CLICKED;
   ev.GUIEvent.Caller = btn;
   mainGame->device->postEventFromUser(ev);
   ```
   对局中 receiver 是 `&mainGame->dField`，事件进 `ClientField::OnCommonEvent()`，与真人点击同一条路径。
2. **鼠标**：`InjectClick(x,y)` = `EMIE_MOUSE_MOVED` → `EMIE_LMOUSE_PRESSED_DOWN`（ButtonStates=EMBSM_LEFT）
   → `EMIE_LMOUSE_LEFT_UP`（ButtonStates=0），都走 `device->postEventFromUser()`（或 `YGO_UI_EVENT_DIRECT=1` 时 `receiver->OnEvent`）。
   **坐标换算（14:19 版修正）**：`ClientCard::curPos` 和 `matManager.vField*` 都是**3D 世界坐标**
   （`materials.cpp` 里 SetS3DVertex 的 x/y/z；相机在 `game.cpp:1023`：自定义投影 + lookAt(4.2,8,7.8)→(4.2,0,0)）。
   所以用客户端自己的相机投影：
   ```cpp
   auto* col = mainGame->smgr->getSceneCollisionManager();
   out = col->getScreenCoordinatesFrom3DPosition(worldPos, mainGame->smgr->getActiveCamera());
   ```
   （早期版本把 `curPos` 当虚拟屏幕坐标再 `Resize()`，点不中——已修。）

## 3. 语义动作 → UI 映射（当前版本）

| kind | UI 路径 |
| --- | --- |
| `yes` / `no` | `ClickButton(btnYes/btnNo)`（MSG_SELECT_YESNO/EFFECTYN） |
| `position` | `a.i` 0x1/0x2/0x4/0x8 → `btnPSAU/btnPSAD/btnPSDU/btnPSDD` |
| `to_bp` / `to_ep` / `to_m2` / `end_battle` | `btnBP` / `btnEP` / `btnM2` / `btnEP`（按 curMsg 判定 idle/battle） |
| `option` | `btnOption[i]`（i<5；i≥5 需要滚动，暂 fallback） |
| `decline`(chain) | `btnCancelOrFinish`（弹“是否放弃连锁”）→ `btnNo`（发 -1） |
| `chain` | 点 `activatable_cards[index]` 卡 → 命令菜单 `BUTTON_CMD_ACTIVATE`（单效果直接发 index；多效果补点 `btnOption[0]`） |
| `activate` | 点 `activatable_cards[index]` → `BUTTON_CMD_ACTIVATE`（多效果补点 `btnOption[0]`） |
| `summon` / `spsummon` / `set_monster` / `set_spell` | 点对应列表里的卡 → `BUTTON_CMD_SUMMON/SPSUMMON/MSET/SSET` |
| **暂未 UI 化（走 fallback）** | `place`（格子需要棋盘→屏幕投影）、`select/sum/select_tribute/sort/announce/counter/auto`（语义里没有具体卡/值身份，无法还原点击） |

失败/不支持时：日志 `UI fallback kind=<kind> msg=<curMsg> (direct response)`，并用**入队时编码好的字节**
走旧直连路径，保证对局不中断。

## 4. 日志

```
UI action kind=yes msg=13 -> button btnYes (201) ok=1
UI action kind=position msg=19 -> button position (1) ok=1
UI action kind=to_ep msg=11 -> button btnEP(idle) (262) ok=1
UI action kind=chain msg=16 -> card+menu chain (0) ok=1
UI action kind=activate msg=11 -> card+menu activate (3) ok=1
UI fallback kind=select msg=15 (direct response)
UI click point=(640,480)            # /uiclick 校准
```

## 5. `/uiclick` 校准接口

```
GET /uiclick?x=<screen px>&y=<screen px>
→ {"ok":true,"queued":true,"x":..,"y":..}
```
排队一次真实鼠标点击（Pump 里执行），日志 `UI click point=(x,y)`；用于确认 `Resize(curPos)` 的换算。

## 6. 点击后校验 + 自动回退（14:09 死锁后的关键修复）

UI 动作执行后不再“认为成功”，而是进入 `g_uiPending` 待确认状态：

```
baseline:  g_ctosCount（客户端真正发出的 CTOS 数）、g_analyzeCount
每帧 Pump 检查：
  有 CTOS 增加 或 analyzeCount 增加  -> 记 "UI action kind=.. verified" 并结束
  600ms 内两者都没动                -> "UI fallback (no-effect) kind=.. -> direct response"
                                       用入队时编码好的 fallback 字节走直连 SendResponse
```

菜单类动作是**两步**：
1. 点卡片（注入鼠标事件）
2. 下一帧 `ActionKind::UiMenu`：若 `wCmdMenu` 可见且有目标按钮 → 点它；否则
   `UI fallback (no-menu) kind=.. -> direct response`。

所以: **点不中最多损失 600ms，不会死锁**。

## 7. 诊断日志（定位“为什么没点中”）

```
UI inject button id=241 caller=0x... path=postEvent sentSync=0
UI inject click x=812 y=640 card=22835145 cur=(760,637) hovered=(0,1,2) menu=1
UI no-menu kind=summon msg=11 -> queued menu id=241 (next frame)
UI action kind=summon msg=11 -> card+menu summon (0) ok=1
UI action kind=summon verified (ctos+1 analyze+0) after 34ms
UI fallback (no-effect) kind=summon after 600ms -> direct response
```

- `hovered=(ctrl,loc,seq)` 是注入点击后客户端自己的命中结果：如果与目标卡不符 → 坐标/缩放问题；
- `menu=0` → 卡片没点中（菜单没弹出）；
- `path=postEvent|receiver`、`sentSync=0/1` → 哪种注入方式、按钮是否同步发出了响应。

## 8. 与 `UiCleanup` 的配合（重要）

`UiCleanup()` 只在**有直连动作**被执行后才跑（`ExecuteAction` 返回 false 的动作）。
原因：UI 路径的响应是靠 `HideElement(..., set_action=true)` 的淡出动画结束帧调 `SendResponse()`
（`drawing.cpp:989`）；如果紧接着 `UiCleanup()` 再 `HideElement(..., false)`，会把 `signalAction`
覆盖成 false → 响应丢失。所以 UI 动作自己负责关窗，直连动作才需要兜底清理。

## 10. 默认 UI 模式下的实测残余 fallback（2026-11-04 15:00 前后，15 回合整局）

| 指标 | host | guest | 说明 |
| --- | --- | --- | --- |
| UI action 总数 | 110 | 93 | 绝大多数动作都走 UI |
| 其中 `verified` | 多数 | 多数 | `summon/activate/chain` 约 15-16ms；`place` 78-110ms；`position` ~250ms |
| `UI fallback (no-effect)` | 12 (~11%) | 7 (~7.5%) | 600ms 内没响应 → 直连补发；主要是 `place` 边界/`decline`/`yes` 的时序 |
| `place verified` | 11 | 7 | 格子点击已可用 |
| `UI skip (menu card mismatch)` | 1 | 2 | 菜单属于另一张卡时跳过（这正是 14:40 版崩溃的根因，防线接住） |
| `UI exec-exception` | 0 | 0 | 异常防线未触发（前面已挡住） |
| retries | 3 | 0 | 偶发，无死循环 |

**已知风险/限制**：
- `place`/`decline`/`yes` 少量 `no-effect`（~10%）：点击没被消费或淡出帧时序问题，**会自动直连回退**，不影响对局；
- 多效果卡会默认点第 1 个 `btnOption`，可能不是最优效果；
- 菜单归属校验（`menu_card == 目标卡`）宁可 fallback 也不点错菜单；
- 如需完全旧行为：`YGO_UI_ACTIONS=0`。


## 11. 残留窗口清单与自动清理（task-22）

用户反馈对局中屏幕中间会卡一个「没有文字的 UI 框体」。原因：有些窗口由客户端在提示时
`PopupElement()`，但控制层直接发协议响应、没有真人去点按钮，窗口就留着。`UiCleanup()` 原来只关
5 个窗口，**没有** `wANNumber/wANCard/wANAttribute/wANRace`（宣言数字/卡名/属性/种族）和 `wQuery`。

### 11.1 诊断：`/ui.windows` / `/ui.windowsVisible`

`/ui`（以及 `/state.ui`）新增 17 个候选窗口的可见性与矩形：

```json
"windows":[
  {"name":"wMessage","visible":false,"rect":{"l":0,"t":0,"r":0,"b":0},"x":0,"y":0,"w":0,"h":0,"textLen":-1},
  {"name":"wANNumber","visible":true,"rect":{"l":430,"t":260,"r":860,"b":420},"x":430,"y":260,"w":430,"h":160,"textLen":-1}
],
"windowsVisible":["wANNumber"]
```

- 覆盖：`wMessage,wACMessage,wQuery,wSurrender,wOptions,wPosSelect,wCardSelect,wCardDisplay,
  wANNumber,wANCard,wANAttribute,wANRace,wCmdMenu,wHand,wFTSelect,wBigCard,wChat`
- `textLen` 只对 `wMessage`（读 `stMessage`）/`wACMessage`（`stACMessage`）/`wQuery` 有意义，其它 `-1`；
  文本非空时额外带 `text`（截断 120 字）。

### 11.2 扩展 UiCleanup

动作后除原有 5 个窗口，再关闭（`YGO_UI_HIDE_EXTRA`，默认 1；`=0` 关闭）：

```
wACMessage(bit0) wQuery(1) wCardDisplay(2) wANNumber(3) wANCard(4) wANAttribute(5)
wANRace(6) wHand(7) wFTSelect(8) wBigCard(9)
```

日志：`UI cleanup popups=0x.. extra=0x.. (action)`；直连动作后另有 `UI cleanup extra=0x.. after action`。

### 11.3 空框兜底

`Pump()` 每帧调 `CloseEmptyFrames()`：当 `g_awaiting==false`（没有等待中的 prompt）时，若
`wMessage/wACMessage/wQuery` 可见但文本长度为 0，就 `HideElement` 并记
`UI close empty frame name=wMessage|wACMessage|wQuery`。

### 11.4 debug 日志

`YGO_CTRL_DEBUG=1` 时每 15 帧打一条：
`CDBG UI windows visible=[wPosSelect(l=..,t=..,r=..,b=..,t=-1), ...]`

### 11.6 阻塞型确认框自动确认（MSG_CONFIRM_CARDS / HINT_MESSAGE）

客户端有四处 `actionSignal.Reset(); actionSignal.Wait()` 会**阻塞网络线程**（阻塞期间 `OnAnalyzeEnd`
不触发 → analyze 冻结、`curMsg` 停在上一条、连接/`/net` 完全正常）：

| 来源 | 弹窗 | 正常人关闭方式 | 自动化处理 |
| --- | --- | --- | --- |
| `MSG_RETRY` / 解析错误 | `wMessage` + `stMessage` | 点 OK | `ActionKind::MsgOk` 自动关（已有） |
| `MSG_HINT` 的 `HINT_MESSAGE`（type=1） | `wMessage` | 点 OK | **task-28e**：Pump 检测 `inDuel && curMsg==MSG_HINT && wMessage 可见` → `UI auto-confirm kind=hint-message`，复用 2s 反复 `actionSignal.Set()` 窗口 |
| `MSG_CONFIRM_CARDS` 强制面板 | `wCardSelect` + `btnSelectOK`（"确定"） | 点 `btnSelectOK`（`BUTTON_CARD_SEL_OK`） | **task-28d**：`AutoConfirmBlockingUi()` 检测 `curMsg==MSG_CONFIRM_CARDS && wCardSelect 可见 && btnSelectOK 可见` → `ClickButton(btnSelectOK)`，日志 `UI auto-confirm kind=card-select-confirm` |
| 其它错误提示 | `wMessage` | 点 OK | 走 `UiCleanup`/`MsgOk` 兜底 |

注意：`wCardDisplay` 的 `BUTTON_CARD_DISP_OK` 只是 `HideElement(wCardDisplay)`，**不阻塞**，无需自动点。
真正选卡的 `MSG_SELECT_CARD` 等 `wCardSelect` 面板 `curMsg` 不是 `MSG_CONFIRM_CARDS`，仍由 `/actions` 决策。

### 11.7 主菜单叠加（重连路径）

正常手动流程里，用户先点「联机模式」→ 客户端 `HideElement(wMainMenu)` + `ShowElement(wLanWindow)`，
再点 join；而控制层 `ActionKind::Join` 直接 `StartClient`，跳过了这步，重连（新进程刚起来是主菜单）
后 `wMainMenu` 会叠在决斗画面上。修复（只加 hide，不改逻辑）：

- `control_lobby.cpp` `ActionKind::Join`：`StartClient` 成功后若 `wMainMenu/wLanWindow` 可见就隐藏，
  日志 `join: hid wMainMenu|wLanWindow (control-layer join)`；
- `control.cpp` `Pump()`：`dInfo.isStarted && wMainMenu->isVisible()` 兜底隐藏，
  日志 `UI hide wMainMenu (duel started)`（覆盖 `-j`/其它入口）；
- `/ui.windows` 新增 `wMainMenu`、`wLanWindow` 两项 → 决斗中 `windowsVisible` 不应包含它们。

## 12. 已知限制 / 下一步

1. `select/card/sum/sort` 这类“选具体卡”的语义，当前 `BuildSemActions` 只给了一个“选前 N 张”的动作，
   无法表达“点哪张卡” → fallback；要 UI 化需要先扩充 `SemAction`（携带 card 列表/选中下标）；
2. 命令菜单的按钮是 `ShowMenu()` 动态创建的，用 `FindChildById(wCmdMenu, BUTTON_CMD_*)` 找；
   如果某次菜单没弹（例如卡不可用），会 fallback；
3. 多效果卡的链/发动会弹 `wOptions` 选项窗，当前默认点第 0 个效果（**可能不是最优效果**）；
4. `place`/`decline`/`yes` 少量 `no-effect`（~10%）：点击没被消费或淡出帧时序问题，**会自动直连回退**；
5. 残留窗口清单见 §11；若仍有空框，用 `/ui.windows` 的 `visible/rect/textLen` 定位是哪个窗口。
