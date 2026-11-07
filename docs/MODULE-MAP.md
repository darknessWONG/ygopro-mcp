# MODULE-MAP — 进程内控制层（control 层）模块图

> 适用版本：`mycard-client/gframe/` 控制层重构后（git `d7f38d1` 及之后）
> 重构前基线：`6a9189d`（单个 `control.cpp`，3008 行）
> 回归判定清单见本文 §8 + `bridge/docs/`（bot-scout 的 `refactor-*`）

---

## 1. 为什么拆，以及拆的硬前提

重构前 `control.cpp` 是**一个 3008 行的 translation unit**，并且文件主体整体被包在
`namespace ygo { namespace { ... } }` —— 匿名 namespace 里。

拆成多个 `.cpp` 时这会带来一个**不会报错但一定出错**的陷阱：

- 匿名 namespace 给其中每个实体 **internal linkage**；
- 于是每个新 `.cpp` 都会得到自己**私有的一份**全局变量和 helper 拷贝；
- 代码照样编译、照样链接，但 HTTP 线程读的 `g_seq` 和 UI 线程写的 `g_seq`
  是**两个不同的变量** → `/wait_prompt` 永远等不到新 seq，对局卡死。

所以拆分前必须先做三件事（第 1 件是本重构的核心）：

1. **`control_internal.h`**：把所有跨模块共享的**类型定义**、**全局变量的 `extern` 声明**、
   跨 TU 函数的声明集中到这里；把匿名 namespace 改成**具名** `namespace ygo { namespace ctl {`。
2. **全局变量只允许有一个定义点**（本重构选在 `control.cpp`，见 §4）。
3. `Control::` 那些成员函数定义在 `ctl` 闭包之外，需要 `using namespace ctl;`（见 §5）。

---

## 2. 模块总表

| 文件 | 行数 | 职责 | 主要公共函数 |
|---|---:|---|---|
| `control.h` | 57 | **对外**接口（上游 6 个文件只 include 这个） | `Control::EnsureStarted / OnMessageBegin / OnAnalyzeEnd / Pump / OnStocPacket / AutoHandResult / AutoTpResult / OnCtosPacket / OnChat / OnHsChange / Log` |
| `control_internal.h` | 367 | 控制层**内部**共享：Snap 结构、`extern` 全局、跨 TU 声明 | （类型 + 声明，无实现） |
| `control.cpp` | 1133 | 生命周期、HTTP 服务与路由、`Pump()` 主循环、上游钩子、日志、异常处理、全局定义 | `CtlDbg` `StocName` `WinReasonName` `SinceTickMs` `UrlDecode` `QueryParam` `RouteRequest` `HandleClient` `ServerLoop` + 全部 `Control::*` |
| `control_state.cpp` | 727 | 快照采集 + 全部 JSON 序列化 | `WideToUtf8` `PromptJson` `UiJson` `SnapshotJson` `SnapshotFromClient` `SelfSeat` `LaunchSeat` |
| `control_ui.cpp` | 652 | UI 注入（按钮/鼠标）、窗口清理与诊断、连锁时点模式、UI 动作执行 | `PopupBits` `CollectWindows` `ChainModeName` `ApplyChainMode` `UiCleanup` `CloseEmptyFrames` `LogVisibleWindows` `ExecUiAction` |
| `control_lobby.cpp` | 274 | 大厅/卡组：选卡组、准备、开始、加入、投降 | `ExecLobbyAction`（+ 文件内 `LoadDeckBySections` `FixupDeckSections`） |
| `control_actions.cpp` | 140 | 动作分发与原始响应端点 | `ExecuteAction` `Unhex`（+ 文件内 `HexBytes`） |
| `control_sem.cpp` | 306 | 语义动作列表与编码（`/actions` 的返回体） | `BuildSemActions` `EncodeSemAction` `SemActionsJson` |

合计 8 个文件；原 `control.cpp` 3008 行 → 现 1133 + 7 个新文件。

### 依赖方向（单向，无环）

```
control.h  (对外)
   └── control_internal.h  (内部共享)
          ├── control.cpp          主干：定义全部全局 + Pump + HTTP
          ├── control_state.cpp    被 control.cpp / control_ui.cpp 调用
          ├── control_ui.cpp       被 control.cpp(Pump) 调用
          ├── control_lobby.cpp    被 control_actions.cpp 调用
          ├── control_actions.cpp  被 control.cpp(Pump) 调用
          └── control_sem.cpp      被 control.cpp(/actions,/act_id) 调用
```

`control_actions.cpp` → `ExecUiAction`(ui) / `ExecLobbyAction`(lobby)；
ui 与 lobby 之间不互相依赖。

---

## 3. `ExecuteAction` 是怎么拆的（关键，别改坏）

原来是一个 268 行的巨型 `switch`，混合了三类语义。现在：

```
ExecuteAction(a)                    [control_actions.cpp]  分发器
├── MsgOk / UiSem / UiMenu / UiPoint   → return ExecUiAction(a)     [control_ui.cpp]
├── Ready/Deck/Surrender/Start/NotReady/Join → return ExecLobbyAction(a) [control_lobby.cpp]
└── Int32 / Bytes                       → 就地处理（日志 + SetResponseI/B + SendResponse）
```

**返回值语义必须保持**：原函数返回 `uiHandled`，`Pump()` 用它决定是否调用 `UiCleanup()`
（`anyDirect` 判定）。拆分后：UI 分支返回 `ExecUiAction` 的结果；UI 分支以外的两条路径
原本 `uiHandled` 恒为 `false`，故直接 `return false` / 落到 `return false`。

各 `case` 体是**逐字节搬移**，`break` 跳出的是新的 switch，语义与原 switch 相同。

---

## 4. 全局变量归属表（**单一定义点**）

设计选择：**全部全局变量只在 `control.cpp` 定义一次**，其余模块只看到
`control_internal.h` 里的 `extern`。这与"谁写谁定义"的直觉方案不同，是有意的：

> 拆成多个定义点时，只要漏搬一个变量就会得到两份状态，而这种 bug **编译期完全不报错**。
> 单一定义点从结构上消灭了这类 bug，代价只是 `control.cpp` 多承担十几行定义。

| 分组 | 变量 | 定义位置 | 主要写入者 |
|---|---|---|---|
| 线程/队列 | `g_mutex` `g_cv` `g_shared` `g_seq` `g_awaiting` `g_actions` | control.cpp | `Pump()` |
| 环形缓冲 | `g_stocRing` `g_ctosRing` `g_chats` `g_hsStatuses` | control.cpp | `OnStocPacket` / `OnCtosPacket` / `OnChat` / `OnHsChange` |
| 原始消息 | `g_lastMsgId` `g_lastRaw` `g_lastRawLen` | control.cpp | `OnMessageBegin` |
| 对局快照标量 | `g_phase` `g_winPlayer` `g_winReason` `g_timeLeft` `g_turnPlayer` `g_errMsg` `g_errCode` `g_lastHintData` `g_lastHintType` | control.cpp | `OnMessageBegin` / `OnStocPacket` |
| 卡组/大厅 | `g_deckMain` `g_deckExtra` `g_selectedDeck` `g_readySent` `g_sentMain` `g_sentExtra` | control.cpp | `ExecLobbyAction` |
| 管道诊断 | `g_analyzeCount` `g_pumpCount` `g_gameMsgCount` `g_lastStocId` `g_lastAnalyzeTick` `g_lastPumpTick` `g_retryCount` `g_lastRetryAfterMsg` `g_autoDismiss` `g_dismissUntilTick` `g_dismissCount` `g_periodicLogTick` `g_periodicAnalyze` `g_stallLogTick` `g_lastNonRetryMsgId` `g_retryStreak` | control.cpp | 多处钩子 |
| PLACE 编码 | `g_placeCoordsServer` `g_placeVariant` | control.cpp | `OnMessageBegin` |
| 连锁时点 | `g_chainMode` `g_appliedChainMode` `g_applyChainPending` `g_realAlways` `g_realAvail` `g_realIgnore` `g_realChainMode` `g_reassertLogTick` `g_uiCleanupCount` `g_popupBits` | control.cpp | `Pump()` / `ApplyChainMode()` |
| 连锁语义 | `g_chainEventSeq` `g_chainEventMsg` `g_chainEventCode` `g_chainEventDesc` `g_chainEventCtrl` | control.cpp | `OnMessageBegin` |
| UI 动作 | `g_uiActions` `g_uiPending` `g_uiEventDirect` `g_uiActionCount` `g_uiFallbackCount` `g_hideExtra` `g_task22` `g_closeEmpty` | control.cpp | `Pump()` / `ExecUiAction()` |
| CTOS 计数 | `g_ctosCount` | control.cpp | `Control::OnCtosPacket`（由 `duelclient.h` 内联调用） |
| 生命周期 | `g_started` `g_hookMask` `g_snapshotWanted` `g_promptWanted` | control.cpp | `EnsureStarted` / `OnAnalyzeEnd` / `SampleLoop` |

新增跨模块全局时：**在 `control_internal.h` 加 `extern`，在 `control.cpp` 加唯一一份定义**，不要在新文件里定义。

---

## 5. ⚠️ 匿名 namespace 的隐式可见性（本次最大的坑，务必记住）

C++ 规则：**匿名 namespace 的成员在它的外层 namespace 里可以被无限定名查找找到**。

```cpp
namespace ygo {
namespace {                    // 匿名
    int g_seq;                 // ygo::(anon)::g_seq
    void Pump();               // 可被 ygo 内代码直接写 Pump()
}
void Control::Foo() { Pump(); }  // OK：无限定名可见
}
```

改成**具名** namespace 后这条"透明性"消失：

```cpp
namespace ygo {
namespace ctl { int g_seq; void Pump(); }
void Control::Foo() { Pump(); }  // ✗ 找不到 ctl::Pump
}
```

`Control::*` 的成员函数（`EnsureStarted`/`Pump`/`OnMessageBegin`/…）是定义在 `ctl` 闭包
**之后**、`ygo` 之内的，因此全部失去对 `ctl` 符号的无限定访问 —— 第一轮编译报了 60+ 个
"未声明的标识符"。

**解决办法（`control.cpp` 中，`} // namespace ctl` 之后）：**

```cpp
using namespace ctl;   // 恢复"像匿名 namespace 一样"的无限定可见性
void Control::EnsureStarted() { ... }
```

**新增任何"定义在 ctl 闭包之外、却要用 ctl 符号"的代码时，这段 `using namespace ctl;` 必须在它之前。**

---

## 6. 原行号来源

每个函数搬自原 `control.cpp`（基线 `6a9189d`，3008 行）的哪一行，见**附录 A**（逐函数）。

按模块的粗略汇总：

- `control_state.cpp` ← 原 `352–447`、`1088–1120`、`1137–1666`
  （`WideToUtf8`…`AppendChainJson`、`FillCard`/`Hex`、`AppendCand*`…`SnapshotFromClient`）
- `control_ui.cpp` ← 原 `565–690`、`696–1002`、`1009–1048`、`1715–1816`
  （连锁模式/清理/窗口诊断、注入器全家、`CloseEmptyFrames`/`LogVisibleWindows`、`ExecuteAction` 的 UI 分支）
- `control_lobby.cpp` ← 原 `1671–1708`、`2266–2280`、`1833–1972`
  （`LoadDeckBySections`、`FixupDeckSections`、`ExecuteAction` 的大厅分支）
- `control_actions.cpp` ← 原 `340–351`（`HexBytes`）、`1121–1136`（`Unhex`）、`1711–1978` 中的分发部分
- `control_sem.cpp` ← 原 `2015–2265`（`SemAction`/`AddSem`/`BuildSemActions`/`EncodeSemAction`/`SemActionsJson`）
- `control.cpp` ← 其余全部（生命周期、HTTP、`Pump`、钩子、日志、全局定义）

> 注：`SemAction` 类型定义搬到了 `control_internal.h`（`/act_id` 需要它）。

---

## 7. 死代码 / 重复 / 有意保留项

| 项 | 处理 | 说明 |
|---|---|---|
| `gframe/control_sem.inc` | **已删除** | 全仓 0 引用、从未被 include；内容与 `control.cpp` 内联版重复。现由 `control_sem.cpp` 承担 |
| 重复 `LoadDeckBySections` | **已修** | 拆分过程中它一度同时留在 `control.cpp` 和 `control_lobby.cpp`；两处都是 `static`，**编译器不报错**，属于典型的静默重复。现仅 `control_lobby.cpp` 一份 |
| `HexBytes`(原 340) vs `Hex`(原 1110) | **保留双份** | 两个 hex dump 实现。`HexBytes` 服务于 `response: ... hex=` 日志行，`Hex` 服务于 `/msg` 的 `lastMsgHex`。合并会改动日志/JSON 输出 → 违反"逐字一致"，故不动 |
| `CtlDbg`(原 994, 前缀 `CDBG`) vs `DbgLog`(原 2652, 前缀 `DBG`) | **保留双份** | 两者都由 `YGO_CTRL_DEBUG` 门控但前缀不同，日志前缀是回归基线，不能合并 |
| `g_uiActionCount` | **保留（只写不读）** | 原 904/1813 两处 `fetch_add`，全仓无读取、无输出。属死变量，但删除会改变 diff 面且无收益，留待后续清理 |
| `g_sentMain` | **保留（只写不读）** | 与上一行同理：`ExecLobbyAction` 里填充，无人读取 |
| `VexHandler` 前置声明 | **保留** | 定义前多一行声明，冗余但不影响行为；顺手删会打乱原顺序，不在本次范围 |
| `ExecuteAction` 的 `MsgOk` 分支 | **保留在 UI 模块** | 它本质是"替用户点 MSG_RETRY 的 OK 按钮"，属 UI 语义 |

---

## 8. 回归判定（给 bot-scout）

**必须逐字一致的清单**（重构只有 move + namespace + goto 改造，没有任何逻辑重写）：

1. **HTTP 端点 16 个**：`/health /state /prompt /wait_prompt /actions /act_id /act /ui /uiclick
   /deck /ready /start /join /chat /surrender /lobby /hs /stoc /ctos /msg`
   - `/state` 中 `retryCount` **故意出现两次**（不同位置），是既有行为，不要"修"；
   - `/act`、`/act_id` 的错误仍返回 **HTTP 200 + `{"ok":false,...}`**，只有未知路径才 404。
2. **连锁语义字段 7 个**：`chainStack` `chainDepth` `chainingTo` `chainCandidates` `canDecline` `hint` `lastChainEvent`。
3. **环境变量 11 个**：`YGO_UI_ACTIONS` `YGO_UI_EVENT_DIRECT` `YGO_UI_HIDE_EXTRA` `YGO_UI_TASK22`
   `YGO_UI_CLOSE_EMPTY` `YGO_CHAIN_MODE` `YGO_AUTO_DISMISS` `YGO_CTRL_DEBUG` `YGO_PLACE_COORDS`
   `YGO_HOOKS` `YGO_CONTROL_PORT`。
4. **日志关键字**：`UI action` `UI fallback` `UI skip` `UI inject` `UI cleanup` `UI close empty frame`
   `UI no-menu` `UI exec-exception` `PIPE` `RETRY after msg` `chain mode applied` `rps:` `ready:`
   `start:` `join:` `surrender:` `deck:` `response: prompt=`。
5. **行为细节**：600ms UI 校验回退；菜单两帧重试（`retries<2`）；菜单归属校验
   （`UI menu check ... menuCard` 不匹配 → `UI skip`）。

### 本轮唯一有语义风险的改动（重点验证）

`HandleClient` 里两处**跨作用域 `goto`** 改成了 `return body;`：

| 端点 | 原 `goto` | 触发条件 |
|---|---|---|
| `/act_id` | `goto send_body;` ×2 | `not awaiting`、`bad action id` |
| `/act` | `goto respond;` ×2 | `stale seq`、`not awaiting` |

语义应等价（都是"跳过后续分支、直接回响应"）；锁由 `lock_guard` 析构释放。
**请专门打这两个端点的错误路径**，确认返回体与基线一致且**不死锁**。

---

## 9. 构建说明（重要，给 fork 用户）

- `gframe/premake5.lua` 用 `files { "*.cpp", "*.h" }` —— **前提是重新生成工程**。
  premake 的 glob 在**生成工程时**求值；已经生成好的 `build/YGOPro.vcxproj` 里是
  **显式文件列表**，新增 `.cpp` 不会自动加入。
- 本次为了不动整套 `premake/` 依赖脚本，直接把这 6 个 `.cpp` 与 `control_internal.h`
  补进了 `build/YGOPro.vcxproj`（该文件被 `.gitignore` 忽略，不会提交）。
- **重跑 premake 后自动自愈**（glob 会重新包含新文件），因此 fork 用户按下面的标准流程
  生成工程即可，无需手工维护文件列表：

```
cd mycard-client
.\premake5.exe vs2022          # 重新生成 build/*.vcxproj
cd build
msbuild YGOPro.vcxproj /p:Configuration=Release /p:Platform=x64 /m:1
```

- **基线二进制可复现**：从基线提交 `6a9189d` 重建出的 `YGOPro.exe` 为 **6,237,184 B**，
  与重构前线上基线**逐字节同尺寸**；重构后（`d7f38d1`）为 **6,242,304 B**。
  留档：`_backups/YGOPro-baseline-6a9189d-20261106-0308.exe`、`_backups/YGOPro-refactor-20261106-0256.exe`。
  需要做新旧同场 A/B 时可直接用这两个 exe。
- 构建目录 `build/ bin/ obj/ buildtmp_out/` 均已加入 `.gitignore`。

---

## 附录 A：函数 → 原 `control.cpp` 行号（基线 `6a9189d`）

| 函数 | 原行号 | 现位置 |
|---|---|---|
| `IsPromptMsg` | 69 | control.cpp:88 |
| `stoc` | 258 | —（已删除/合并） |
| `Pump` | 271 | control.cpp:1034 |
| `invocations` | 272 | —（已删除/合并） |
| `identifier` | 273 | —（已删除/合并） |
| `GetTickCount64` | 274 | —（已删除/合并） |
| `YGO_AUTO_DISMISS` | 278 | —（已删除/合并） |
| `Set` | 279 | —（已删除/合并） |
| `MSG_RETRY` | 285 | —（已删除/合并） |
| `local` | 286 | —（已删除/合并） |
| `mode` | 293 | —（已删除/合并） |
| `path` | 323 | —（已删除/合并） |
| `HexBytes` | 340 | control_actions.cpp:65 |
| `WideToUtf8` | 352 | control_state.cpp:64 |
| `CardNameOf` | 378 | control_state.cpp:90 |
| `DescTextOf` | 379 | control_state.cpp:91 |
| `JsonEscape` | 382 | control_state.cpp:94 |
| `CardLabel` | 399 | control_state.cpp:111 |
| `AppendChainJson` | 404 | control_state.cpp:116 |
| `StocName` | 448 | control.cpp:195 |
| `WinReasonName` | 475 | control.cpp:222 |
| `SinceTickMs` | 512 | control.cpp:259 |
| `LogPipeline` | 518 | control.cpp:265 |
| `MaybePeriodicPipelineLog` | 536 | control.cpp:283 |
| `AutoDismissPump` | 550 | control.cpp:297 |
| `ChainModeName` | 565 | control_ui.cpp:65 |
| `ApplyChainMode` | 573 | control_ui.cpp:73 |
| `UiCleanup` | 595 | control_ui.cpp:95 |
| `PopupBits` | 630 | control_ui.cpp:130 |
| `TextOfWidget` | 644 | control_ui.cpp:144 |
| `CollectWindows` | 649 | control_ui.cpp:149 |
| `directly` | 696 | —（已删除/合并） |
| `ClickButton` | 697 | control_ui.cpp:191 |
| `InjectMouse` | 721 | control_ui.cpp:215 |
| `InjectClick` | 747 | control_ui.cpp:241 |
| `FindChildById` | 754 | control_ui.cpp:248 |
| `WorldToScreenPos` | 769 | control_ui.cpp:263 |
| `UiClickCard` | 780 | control_ui.cpp:274 |
| `QueueUiMenu` | 794 | control_ui.cpp:288 |
| `BeginUiVerify` | 807 | control_ui.cpp:301 |
| `UiCardThenMenu` | 818 | control_ui.cpp:312 |
| `UiClickFieldZone` | 860 | control_ui.cpp:354 |
| `TryUiSemantic` | 894 | control_ui.cpp:388 |
| `CtlDbg` | 994 | control.cpp:319 |
| `CloseEmptyFrames` | 1009 | control_ui.cpp:494 |
| `LogVisibleWindows` | 1036 | control_ui.cpp:521 |
| `VexHandler` | 1051 | control.cpp:331 |
| `CrashHandler` | 1063 | control.cpp:343 |
| `FillCard` | 1088 | control_state.cpp:161 |
| `Hex` | 1110 | control_state.cpp:183 |
| `Unhex` | 1121 | control_actions.cpp:79 |
| `AppendCard` | 1137 | control_state.cpp:195 |
| `AppendCards` | 1147 | control_state.cpp:205 |
| `AppendCands` | 1156 | control_state.cpp:214 |
| `PromptJson` | 1168 | control_state.cpp:226 |
| `PhaseName` | 1222 | control_state.cpp:280 |
| `UiJson` | 1239 | control_state.cpp:297 |
| `SnapshotJson` | 1285 | control_state.cpp:343 |
| `LaunchSeat` | 1385 | control_state.cpp:443 |
| `SelfSeat` | 1401 | control_state.cpp:459 |
| `SnapshotFromClient` | 1407 | control_state.cpp:465 |
| `LoadDeckBySections` | 1671 | control_lobby.cpp:82 |
| `ExecuteAction` | 1711 | control_actions.cpp:101 |
| `UrlDecode` | 1979 | control.cpp:369 |
| `QueryParam` | 2000 | control.cpp:390 |
| `AddSem` | 2027 | control_sem.cpp:65 |
| `BuildSemActions` | 2039 | control_sem.cpp:77 |
| `EncodeSemAction` | 2133 | control_sem.cpp:171 |
| `SemActionsJson` | 2248 | control_sem.cpp:286 |
| `FixupDeckSections` | 2266 | control_lobby.cpp:65 |
| `HandleClient` | 2282 | control.cpp:409 |
| `ServerLoop` | 2571 | control.cpp:710 |
| `EnsureStarted` | 2599 | control.cpp:744 |
| `DbgLog` | 2652 | control.cpp:797 |
| `OnStocPacket` | 2660 | control.cpp:805 |
| `AutoHandResult` | 2689 | control.cpp:834 |
| `AutoTpResult` | 2709 | control.cpp:854 |
| `Log` | 2722 | control.cpp:269 |
| `OnHsChange` | 2735 | control.cpp:880 |
| `OnChat` | 2741 | control.cpp:886 |
| `OnCtosPacket` | 2769 | control.cpp:914 |
| `OnMessageBegin` | 2776 | control.cpp:921 |
| `OnAnalyzeEnd` | 2877 | control.cpp:1022 |
