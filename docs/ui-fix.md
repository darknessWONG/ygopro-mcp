# UI 修复：表示形式弹窗不消失 + 开局切「可用时点」

> task-15。只改 `mycard-client/gframe/control.cpp`（`duelclient.cpp` / `single_duel.cpp` 未动）。
> exe：`mycard-client\bin\release\x64\YGOPro.exe`（构建见 §5）。

## 1. 问题与根因

### 1.1 表示形式弹窗（wPosSelect）一直挂着
- 客户端收到 `MSG_SELECT_POSITION` 且可选位置 >1 时，`duelclient.cpp` 的 case 会
  `PopupElement(mainGame->wPosSelect)`（并把 4 个表示形式按钮设为可见），然后等用户点按钮；
- 人类点击时 `event_handler` 会先 `HideElement(mainGame->wPosSelect)` 再发响应；
- 我们的控制层是直接 `SetResponseI(pos); SendResponse();`，**从不关窗口** → 弹窗留在界面中央。

### 1.2 开局默认「全部时点」
- `duelclient.cpp:713-717`，若配置勾了「默认显示时点」，开局会把
  `always_chain=true / ignore_chain=false / chain_when_avail=false`（= 全部时点）；
- 三个开关：`always_chain`=全部时点、`chain_when_avail`=可用时点、`ignore_chain`=忽略；
- UI 同步函数是 `mainGame->dField.UpdateChainButtons()`（`ClientField` 成员）。

## 2. 实现（control.cpp）

### 2.1 动作后清理弹窗 `UiCleanup()`

```cpp
// Pump() 已持 gMutex，所以这里不再加锁（复用了 task-12 的 MsgOk 思路）
static void UiCleanup(const char* why) {
	unsigned bits = 0;
	if (wPosSelect->isVisible())  { HideElement(wPosSelect);  bits |= 0x01; }
	if (wOptions->isVisible())    { HideElement(wOptions);    bits |= 0x02; }
	if (wCardSelect->isVisible()) { HideElement(wCardSelect); bits |= 0x04; }
	if (wCmdMenu->isVisible())    { HideElement(wCmdMenu);    bits |= 0x08; }
	if (wMessage->isVisible())    { HideElement(wMessage); actionSignal.Set(); bits |= 0x10; }
	if (bits) { ++g_uiCleanupCount; Control::Log("UI cleanup popups=0x%02x (%s)", bits, why); }
}
```

`Pump()` 里每执行完队列里的一个 action 就调一次：

```cpp
for (const auto& a : pending) { ExecuteAction(a); }
if (!pending.empty()) UiCleanup("action");
g_popupBits.store(PopupBits());   // 缓存给 /ui（HTTP 线程不碰控件）
```

- `PopupBits()` 只读不关，返回同一套 bit；`g_popupBits` 是 atomic，HTTP 线程只读缓存。
- `wMessage` 那支同时 `actionSignal.Set()`，兼容 `MSG_RETRY`/提示框会阻塞网络线程的情况。

### 2.2 时点模式 `g_chainMode` + `ApplyChainMode()`

```cpp
std::atomic<int> g_chainMode{ 1 };            // 0=all,1=avail,2=ignore；env YGO_CHAIN_MODE，默认 avail
std::atomic<int> g_appliedChainMode{ 1 };     // 真正写进客户端的模式
std::atomic<bool> g_applyChainPending{ true };// Pump 里消费

static void ApplyChainMode(const char* why) {
	mainGame->always_chain      = (mode == 0);
	mainGame->chain_when_avail  = (mode == 1);
	mainGame->ignore_chain      = (mode == 2);
	mainGame->dField.UpdateChainButtons();
	...
	Control::Log("chain mode applied: %s (all=%d avail=%d ignore=%d) [%s]", ...);
}
```

- `Pump()` 中 `if (g_applyChainPending.exchange(false)) ApplyChainMode("pump");`
- **开局自动应用**：`OnStocPacket()` 里 **不依赖 hook 开关** 地对 `STOC_DUEL_START` 置
  `g_applyChainPending = true;`（host 用 `YGO_HOOKS=msganalyze` 没有 stoc hook，也能生效），
  日志 `STOC_DUEL_START -> chain mode pending (avail)`。
- 启动时 `g_applyChainPending` 初值 true，第一帧就会把模式写成 avail。

### 2.3 HTTP `/ui`

- `GET /ui` →
  ```json
  {"ok":true,"chainMode":1,"chainModeName":"avail","alwaysChain":false,
   "chainWhenAvail":true,"ignoreChain":false,"uiCleanupCount":0,"popupMask":0,
   "popups":{"posSelect":false,"options":false,"cardSelect":false,"cmdMenu":false,"message":false}}
  ```
- `GET /ui?chain=all|avail|ignore` → 设 `g_chainMode` + `g_applyChainPending=true`（下一帧 Pump 应用），
  日志 `"/ui chain=... -> mode=N (pending Pump apply)"`。
- **字段语义（task-17 修正）**：
  - `chainMode / alwaysChain / chainWhenAvail / ignoreChain` = **客户端真实值**（Pump 每帧从控件缓存，
    HTTP 只读缓存，不跨线程碰控件）；
  - `desiredChainMode`（0/1/2）+ `desiredChainModeName` = 我们期望的模式（`g_chainMode`）；
  - `appliedChainMode` = 最近一次真正写进客户端的模式（`g_appliedChainMode`）；
  - `applyPending` = 是否还有一次 pending apply。
  这样 `/ui` 不会被"期望值反推"骗到：真实值被客户端覆盖时会如实显示 `alwaysChain=true`。
- popup 状态来自 `g_popupBits`（Pump 缓存）。

### 2.4 `/state` 增加

顶层 `chainMode`、`uiCleanupCount`，以及 `ui` 对象（字段同 `/ui`，无 `ok`）：

```json
{"chainMode":1,"uiCleanupCount":0,
 "ui":{"chainMode":1,"chainModeName":"avail","alwaysChain":false,"chainWhenAvail":true,
       "ignoreChain":false,"desiredChainMode":1,"appliedChainMode":1,"applyPending":false,
       "uiCleanupCount":0,"popupMask":0,
       "popups":{"posSelect":false,"options":false,"cardSelect":false,"cmdMenu":false,"message":false}}}
```

`Snapshot` 里对应字段在 `SnapshotFromClient()`（UI 线程）采集：`chainMode` 由**真实布尔**推导
（`always_chain?0:(ignore_chain?2:1)`）、三个 bool 读 `mainGame->*`、`popupMask=PopupBits()`、
`uiCleanupCount=g_uiCleanupCount`。

### 2.4b 开局初始化覆盖竞态与自愈（task-17）

**现象**：`ApplyChainMode()` 在 `STOC_DUEL_START` 后第一帧就执行了，但客户端自己的
`duelclient.cpp:712-717`（`if(chkDefaultShowChain->isChecked()) { always_chain=true; ... }`）
在**之后**执行，把三个 bool 又写回"全部时点"；之后不再 apply，于是实际一直是全部时点。
而且旧 `/ui` 用期望值反推 bool，导致 `/ui` 说 avail、`/state.ui` 说 all 自相矛盾。

**自愈**：`Pump()` 每帧比对真实 bool 与 `g_chainMode`，不一致就 `ApplyChainMode("reassert")`；
`ApplyChainMode()` 对 `reassert` 的日志限流 **1 秒最多 1 条**，不会刷屏：

```cpp
const int m = g_chainMode.load();
const bool mismatch = mainGame->always_chain != (m == 0) ||
                      mainGame->chain_when_avail != (m == 1) ||
                      mainGame->ignore_chain != (m == 2);
if (mismatch) ApplyChainMode("reassert");
```

启动竞态通常只触发 1~2 次 reassert，之后 bool 稳定；日志形如
`chain mode applied: avail (all=0 avail=1 ignore=0) [reassert]`（限流后不会连续出现）。

### 2.5 环境变量

| 变量 | 值 | 默认 | 作用 |
| --- | --- | --- | --- |
| `YGO_CHAIN_MODE` | `all` / `avail` / `ignore` | `avail` | 启动时的时点模式（`/ui?chain=` 可运行中切换） |

启动日志会带 `chainMode=avail`。

## 3. 日志标记（取证用）

```
control: started port=7788 hooks=7 autoDismiss=1 placeCoords=server chainMode=avail (pipeline diagnostics)
STOC_DUEL_START -> chain mode pending (avail)
chain mode applied: avail (all=0 avail=1 ignore=0) [pump]
UI cleanup popups=0x01 (action)          # 0x01=wPosSelect(表示形式)；0x02=wOptions；0x04=wCardSelect；0x08=wCmdMenu；0x10=wMessage
/ui chain=all -> mode=0 (pending Pump apply)
```

## 4. 验证方法（由 task-16 / bot-scout 执行）

1. 跑一局（`bridge\lan-run.ps1 -Games 1 ...`），期间抓 `/ui` 与 `/state.ui`：
   - 期望 `chainMode=1 / chainWhenAvail=true / alwaysChain=false / ignoreChain=false`；
2. 每 ~20s `PrintWindow` 截两个客户端窗口，看是否还有「表示形式」4 按钮弹窗长期挂着；
   - 若截图 `popups.posSelect=true`、而下一帧 `/ui` 变 false，也算通过（说明动作后自动关了）；
3. 证据：`ranked/logs/lan-ui-*.png`、`/ui` 快照、`control-<pid>.log` 里的 `UI cleanup` / `chain mode applied` 行。

## 5. 构建

```powershell
# 只杀本仓库客户端（不要 Stop-Process -Name ygopro）
Get-Process YGOPro | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force
cd mycard-client\build
cmd /c "`"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat`" >nul && msbuild YGOPro.vcxproj /p:Configuration=Release /p:Platform=x64 /m:1 /nologo /v:m"
```

自检：`[IO.File]::ReadAllBytes('...\YGOPro.exe')` → ASCII → 应含
`chainMode`、`chainModeName`、`ApplyChainMode`（日志串里有 `chain mode applied`）、`UI cleanup`、`/ui`。

## 6. 已知限制

- `UiCleanup` 只在控制层**执行 action 之后**触发；如果 bot 迟迟不响应，弹窗会一直显示（这与人类等待手感一致）。
- `wMessage` 也被 `UiCleanup` 关闭并 `actionSignal.Set()`：正常提示框会被跳过（机器人场景想要的就是这个）。
- 时点模式切换在 `/ui` 响应里先回显目标值，真正写进客户端在下一帧 Pump（≤16ms）；`/state.chainMode` 是已应用值。
