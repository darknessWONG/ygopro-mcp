# UI 修复验证（task-16）：截图 + `/ui` 快照

> **最终结论（复验，2026-11-04 00:34:29 局，exe `00:31:56 / 6,192,128 B`）：两项全部 PASS**
> —— 表示形式弹窗不再挂住、开局真实切换为"可用时点"（`/state.ui.alwaysChain=false / chainWhenAvail=true`，6/6 采样），
> 且 `reassert` 只出现 1 次（无刷屏）。详见 §八。以下 §一–§七 是**首轮验证**（exe 00:24:01）发现"时点未生效"的过程记录，保留作为修复依据。
>
> ---
>
> **首轮验证（修复前，exe 00:24:01）时间**：2026-11-04 00:24:34 – 00:27:xx（UTC+8）
> 客户端 exe：`mycard-client\rin\release\x64\YGOPro.exe`，LastWriteTime = 2026-11-04 00:24:01，size = 6,191,616
> 跑局：`powershell -NoProfile -ExecutionPolicy Bypass -File rridge\lan-run.ps1 -Games 1 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing`
> 进程：host pid **21572**（控制口 7788，hooks=msganalyze）、guest pid **29736**（控制口 7789，hooks=all）
> 日志：`ranked\logs\lan-run-20261104-002434.log`、抓取记录 `ranked\logs\lan-ui-20261104-002444-capture.log`

## 一、首轮结论（修复前，一句话）

| 验收项 | 判定 | 依据 |
|---|---|---|
| **动作后自动关"表示形式"等弹窗** | ✅ **通过** | 截图 5 帧均无四个大按钮的表示形式弹窗；客户端日志 `UI cleanup popups=0x01 (action)` host 4 次 / guest 7 次（0x01 = wPosSelect）；`/ui`+`/state.ui` 采样 `popups.posSelect=false`、`popupMask=0` |
| **开局自动切"可用时点"** | ❌ **未通过（实际未生效）** | `/ui` 显示 `chainMode=1 / chainWhenAvail=true / alwaysChain=false`（**期望值**），但 `/state.ui`（读的是客户端真实布尔）全程 `alwaysChain=true / chainWhenAvail=false` → 客户端实际仍是"全部时点" |
| `/ui` 接口存在且字段齐全 | ✅ 通过（但字段语义要注意） | 返回 `{"ok":true,"chainMode":1,"chainModeName":"avail","alwaysChain":false,"chainWhenAvail":true,"ignoreChain":false,"uiCleanupCount":N,"popupMask":0,"popups":{...}}` |

> 简言之：**弹窗问题修好了；时点问题只是"名义上切了"，客户端真实状态没变**。
> `/ui` 的 `alwaysChain/chainWhenAvail` 是把"期望模式"反推出来的（control.cpp:1504-1506），
> 而 `/state.ui` 的这三个字段来自 `mainGame->always_chain / chain_when_avail / ignore_chain`（control.cpp:907-909，真实值）。

## 二、截图证据（`ranked\logs\`）

按 shot.ps1 的 PID 排序：**`-1` = host pid 21572，`-2` = guest pid 29736**（`ui10` 只有 guest 窗就绪，未生成 `-1`）。

| 文件 | 时刻/回合 | 观察 |
|---|---|---|
| `lan-ui10-2.png` → 另存 `lan-ui-20261104-002434-ui10-g.png` | 开局 +10s，turn 1 | 正常对战画面，手牌/场面/LP 8000-8000；**无表示形式弹窗** |
| `lan-ui40-1.png` → `lan-ui-20261104-002434-ui40-h.png` | 开局 +40s，turn 2 | host 两张怪兽（2300/1000、1700/800），对手盖怪；**无表示形式弹窗** |
| `lan-ui40-2.png` → `lan-ui-20261104-002434-ui40-g.png` | 同上 | guest 手牌 5 张，正常布局 |
| `lan-ui80-1.png` → `lan-ui-20261104-002434-ui80-h.png` | 开局 +80s，turn 4 | 场面推进（1800/1200 等），状态栏"等待行动中…"；**无表示形式弹窗** |
| `lan-ui80-2.png` → `lan-ui-20261104-002434-ui80-g.png` | 同上 | guest 侧正常 |

说明：几帧里能看到一个小对话框「此时没有可以发动的效果 / 是否要确认场上的情况? [是][否]」——
那是**连锁/确认提示（wMessage）**，不是"表示形式选择"（wPosSelect 四按钮弹窗），而且它随 rot 动作会消失
（`UI cleanup popups=0x10` 路径存在；本次采样时刻 `popupMask` 均为 0）。**验收项（表示形式弹窗不挂住）通过。**

## 三、`/ui` 与 `/state.ui` 原始快照（每轮同时抓两端）

抓取节奏：`started=true` 后 +10s / +40s / +80s，每轮对 7788/7789 各抓 `GET /ui` 与 `GET /state`。
原始 JSON 落盘：`ranked\logs\lan-ui-20261104-002444-ui{10,40,80}-{7788,7789}.json`。

摘录（**同一次采样内，两个接口自相矛盾**）：

```json
// ui40 / 7788（host）：/ui —— 期望值
{"ok":true,"chainMode":1,"chainModeName":"avail","alwaysChain":false,"chainWhenAvail":true,
 "ignoreChain":false,"uiCleanupCount":3,"popupMask":0,
 "popups":{"posSelect":false,"options":false,"cardSelect":false,"cmdMenu":false,"message":false}}

// ui40 / 7788：/state.ui —— 真实值
{"chainMode":1,"chainModeName":"avail","alwaysChain":true,"chainWhenAvail":false,
 "ignoreChain":false,"uiCleanupCount":3,"popupMask":0,
 "popups":{"posSelect":false,"options":false,"cardSelect":false,"cmdMenu":false,"message":false}}
```

全部 6 次采样（ui10/40/80 × 7788/7789）结果一致：

| 采样 | `/ui.chainMode` | `/ui.alwaysChain` | `/ui.chainWhenAvail` | `/state.ui.alwaysChain` | `/state.ui.chainWhenAvail` | `popupMask` |
|---|---|---|---|---|---|---|
| ui10-7788 | 1 | false | true | **true** | **false** | 1（posSelect=true，随后被清） |
| ui10-7789 | 1 | false | true | **true** | **false** | 0 |
| ui40-7788 | 1 | false | true | **true** | **false** | 0 |
| ui40-7789 | 1 | false | true | **true** | **false** | 0 |
| ui80-7788 | 1 | false | true | **true** | **false** | 0 |
| ui80-7789 | 1 | false | true | **true** | **false** | 0 |

跑局中出现过一次 **"动作前 posSelect=true → 动作后 popupMask=0"**：
`ui10-7788` 那帧 `posSelect=true`、`uiCleanupCount=1`；下一轮采样即 `false` —— 符合任务里"某张截图 popups.posSelect=true 但动作后下一帧 false 也算通过"的口径。

## 四、客户端日志证据（`mycard-rot\game\control-21572.log` / `control-29736.log`）

**弹窗清理（有效）**：

```
// host 21572（4 次）
UI cleanup popups=0x01 (action)
UI cleanup popups=0x01 (action)
UI cleanup popups=0x01 (action)
UI cleanup popups=0x01 (action)
// guest 29736（7 次，含 0x01/其它位）
UI cleanup popups=0x01 (action)
...
```

`0x01 = wPosSelect(表示形式)`；说明控制层代答后确实把弹窗关掉了。

**时点切换（只生效了一瞬间）**：

```
// host 21572：整个对局只有 1 次 applied
[904101296] STOC_DUEL_START -> chain mode pending (avail)
[904101312] chain mode applied: avail (all=0 avail=1 ignore=0) [pump]
// guest 29736：只有 2 次
[904087515] chain mode applied: avail (all=0 avail=1 ignore=0) [pump]
[904101296] STOC_DUEL_START -> chain mode pending (avail)
[904101296] chain mode applied: avail (all=0 avail=1 ignore=0) [pump]
```

之后再没有 `chain mode applied`，而 `/state.ui` 的 `always_chain` 一直是 `true` → **apply 被随后执行的对局初始化覆盖**。

### 根因分析（读代码得出，未改动代码）

1. 我们的钩子在 `OnStoc(STOC_DUEL_START)` 里置 `g_applyChainPending=true`，`Pump()` 下一帧调 `ApplyChainMode()` 把三个 rool 写成 avail（日志 `all=0 avail=1 ignore=0`）。
2. 但客户端自己的开局初始化 `gframe\duelclient.cpp:712-717` 在随后执行：
   ```cpp
   if(mainGame->chkDefaultShowChain->isChecked()) {
       mainGame->always_chain = true;
       mainGame->ignore_chain = false;
       mainGame->chain_when_avail = false;
   }
   ```
   把三个 rool **又写回"全部时点"**，而且之后没有再次 apply。
3. `/ui` 的 `alwaysChain/chainWhenAvail` 是由期望模式反推的（`control.cpp:1504-1506`：`tmp.alwaysChain=(desired==0)` …），
   所以它显示 false/true，**但这不代表客户端真实状态**；`/state.ui` 才是真实值（`control.cpp:907-909` 读 `mainGame->always_chain`）。
   两个接口同时抓就会自相矛盾 —— 这也是本次能定位到问题的原因。

### 建议的最小修法（交 poc-wasm-duel）

1. **自愈式重设**：在 `Pump()` 里每次比较真实值 vs 期望值，不一致就 `ApplyChainMode("reassert")`：
   ```cpp
   const int m = g_chainMode.load();
   if (mainGame->always_chain != (m == 0) ||
       mainGame->chain_when_avail != (m == 1) ||
       mainGame->ignore_chain != (m == 2)) {
       ApplyChainMode("reassert");
   }
   ```
   （只在必要时调用，日志不会刷屏；这样无论客户端何时重置，最迟下一帧就回到 avail。）
2. 或把 `g_applyChainPending` 的触发点从"STOC_DUEL_START 时"后移到**进入对局后的第一条 MSG**（如 `MSG_START` / 第一条 `MSG_NEW_TURN` / 第一次 `OnAnalyzeEnd`），避开与 `duelclient.cpp:712` 的竞态。
3. 建议让 `/ui` 返回真实值（并另加 `desiredChainMode` 区分"期望/实际"），避免以后再次被"名义上切了"骗过去。

## 五、判定细则对照

| 任务里的判据 | 本次结果 |
|---|---|
| 截图里没有表示形式选择窗口长期挂在界面中央 | ✅ 5 张截图均无（四按钮 wPosSelect） |
| 至少一次 `/ui` 显示 `chainMode=1`、`chainWhenAvail=true`、`alwaysChain=false` | ✅ 6/6 次都满足 |
| `popups.posSelect` 不会长期为 true | ✅ 仅 ui10 那帧瞬时 true，随后 false |
| （附加）客户端日志出现 `UI cleanup popups=0x01 (action)` | ✅ host 4 次、guest 7 次 |
| （附加，但任务本意）"开局就是可用时点" | ❌ 真实值仍为全部时点（`/state.ui.alwaysChain=true`），需按上文修法再出一版 |

## 六、产物清单

- 截图（原名）：`ranked\logs\lan-ui10-2.png`、`lan-ui40-1.png`、`lan-ui40-2.png`、`lan-ui80-1.png`、`lan-ui80-2.png`
- 截图（角色命名副本）：`ranked\logs\lan-ui-20261104-002434-ui{10-g,40-h,40-g,80-h,80-g}.png`
- `/ui` + `/state.ui` 原始 JSON：`ranked\logs\lan-ui-20261104-002444-ui{10,40,80}-{7788,7789}.json`
- 抓取记录：`ranked\logs\lan-ui-20261104-002444-capture.log`
- 跑局日志：`ranked\logs\lan-run-20261104-002434.log`
- 客户端日志：`mycard-rot\game\control-21572.log`（host）、`control-29736.log`（guest）

## 七、跑局器事故说明（不影响本页 UI 结论）

- 本局跑局器在 **357s（turn 12）时日志停更、未走 finally**，客户端/rot 残留到我手工清理。原因是后台任务的 **stdout 管道被写满**（未及时 `jor_output` 排空），`Write-Host` 阻塞导致脚本停住；已记进 `lan-run.md` 故障排查，复验改用「输出重定向到文件」的后台启动方式。
- **UI 证据在停更前已全部抓完**（截图 + 6 次 `/ui` 与 `/state.ui` 采样都在 00:25:15–00:26:26，即开局后 10/40/80s），因此本页判定有效。
- 事故时对局状态（供存档）：turn=12，LP 5700/6800，双方各 11 张墓地，retries 0/0，未到胜负；随后被手工结束。

## 八、复验（新 exe 2026-11-04 00:31:56，task-17 修复后）：✅ 全部通过

- 客户端 exe：`mycard-client\rin\release\x64\YGOPro.exe`，**LastWriteTime = 2026-11-04 00:31:56**，size = 6,192,128（含 `reassert` 自愈 + `/ui` 真实值 + `desired/applied`）
- 跑局：`lan-run.ps1 -Games 1 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing`，00:34:29 起
- 进程：host pid **35232**（7788）、guest pid **15592**（7789）
- 日志/证据：`ranked\logs\lan-run-20261104-003429.log`、抓取记录 `lan-ui2-20261104-003434-capture.log`、6 个采样 JSON `lan-ui2-20261104-003434-ui{10,40,80}-{7788,7789}.json`、客户端日志 `control-35232.log` / `control-15592.log`

### 8.1 时点切换：真实值已生效（6/6 采样）

`/ui` 与 `/state.ui` 现在给的是**同一份真实值**（新增 `desiredChainMode/appliedChainMode/applyPending` 区分期望/实际）：

```json
// ui40 / 7788（host），与 /state.ui 完全一致
{"ok":true,"chainMode":1,"chainModeName":"avail",
 "alwaysChain":false,"chainWhenAvail":true,"ignoreChain":false,
 "desiredChainMode":1,"desiredChainModeName":"avail","appliedChainMode":1,"applyPending":false,
 "uiCleanupCount":8,"popupMask":0,
 "popups":{"posSelect":false,"options":false,"cardSelect":false,"cmdMenu":false,"message":false}}
```

| 采样 | `/ui.chainMode` | `alwaysChain` | `chainWhenAvail` | `desired/applied` | `/state.ui` 同字段 | `popups.posSelect` |
|---|---|---|---|---|---|---|
| ui10-7788 | 1 | **false** | **true** | 1 / 1 | false / true | false |
| ui10-7789 | 1 | **false** | **true** | 1 / 1 | false / true | false |
| ui40-7788 | 1 | **false** | **true** | 1 / 1 | false / true | false |
| ui40-7789 | 1 | **false** | **true** | 1 / 1 | false / true | false |
| ui80-7788 | 1 | **false** | **true** | 1 / 1 | false / true | false |
| ui80-7789 | 1 | **false** | **true** | 1 / 1 | false / true | false |

### 8.2 `reassert` 自愈：只触发 1 次/端（无刷屏）

```
control-35232.log（host）:
[904673031] chain mode applied: avail (all=0 avail=1 ignore=0) [pump]
[904696031] chain mode applied: avail (all=0 avail=1 ignore=0) [pump]
[904696218] chain mode applied: avail (all=0 avail=1 ignore=0) [reassert]   <-- 客户端开局初始化覆盖后的自愈
control-15592.log（guest）:
[904682187] ... [pump]
[904696015] ... [pump]
[904696203] ... [reassert]
```

两端各 `applied=3`（2 次 pump + **1 次 reassert**），之后稳定、不再出现 → 与预期的"覆盖竞态 + 一次自愈"完全一致。

### 8.3 弹窗：仍然 PASS

- 客户端日志 `UI cleanup popups=0x01 (action)`：host **12 次**、guest **14 次**（0x01 = wPosSelect）
- 6 次采样 `popups.posSelect=false`、`popupMask=0`
- 截图 6 张（`ranked\logs\lan-ui2-ui{10,40,80}-{1,2}.png`，PID 排序 **-1 = guest 15592，-2 = host 35232**）：
  抽查 `lan-ui2-ui40-2.png`（host，turn 2）与 `lan-ui2-ui80-1.png`（guest，turn 3）—— 均为正常对战画面，
  只有瞬时的「是/否」效果确认框（[黑蔷薇龙]诱发类效果），**没有四个大按钮的表示形式弹窗**。

### 8.4 最终判定

| 验收项 | 判定 |
|---|---|
| 截图无表示形式弹窗长期挂住 + `UI cleanup popups=0x01` | ✅ PASS |
| `/state.ui.alwaysChain=false` 且 `chainWhenAvail=true`（真实值） | ✅ PASS（6/6 采样、两端一致） |
| `/ui.chainMode=1` 且与 `/state.ui` 一致 | ✅ PASS |
| `reassert` 有限（≤1 次/端，不刷屏） | ✅ PASS |
| 弹窗仍然被自动清理 | ✅ PASS（host 12 / guest 14 次） |

> 复验中还看到偶发 `retry=1~3`（累计值，`place` 场景），但无 retry-loop、回合正常推进；与本 UI 修复无关。

### 8.5 本局顺带结果（对局层面，非 UI 验收项）

- `MSG_WIN player=1 reason=1(LP_ZERO)`，**turn=12、377s**；hostDec=117 / guestDec=77
- LP 从 8000/8000 一路打到 `8000/0`（末段连续攻击：`attack #3 atk=2400`、`attack #2 atk=2300`）
- retries 累计 host=16 / guest=12（全部为 `place` 场景的偶发 RETRY，`streak` 很短，无 retry-loop）→ 因此本局 `natural=False`（判据要求 retries<5），**这是已知的 place 低频边界，与本次 UI 修复无关**
- 收尾：`[finally] guaranteed cleanup` 正常执行；跑完 `Get-Process YGOPro` = 0、`node` = 0，`ranked\logs\lan-*.pids` 已清
- 证据：`ranked\logs\lan-run-20261104-003429.log`、`lan-state-20261104-003429-g1.json`

## 九、最终交付状态（定稿）

| 项 | 结论 |
|---|---|
| 表示形式弹窗（wPosSelect）不再长期挂住 | ✅ **PASS**（截图 6 张全无；`UI cleanup popups=0x01` host 12 / guest 14 次） |
| 开局真实切换为"可用时点" | ✅ **PASS**（`/state.ui.alwaysChain=false / chainWhenAvail=true`，6/6 采样两端一致；`[reassert]` 各 1 次后稳定） |
| `/ui` 语义正确（真实值 + desired/applied 区分） | ✅ **PASS** |
| 复验 exe | `mycard-client\rin\release\x64\YGOPro.exe` = **2026-11-04 00:31:56 / 6,192,128 B**（最终版，不再变） |
| 环境 | 已清理：0 个 YGOPro、0 个 node、无残留 PID 文件 |

## 十、UI 模式冒烟（动作全部经 UI 点击，exe 2026-11-04 14:29:22）

> 背景：14:09 版 UI 点击"报成功但不生效"导致第一回合死锁；poc-wasm-duel 修了「600ms 校验 + 自动回退直连 + 判空 skip + 真 3D 投影」后，用 14:29:22 版做严格两步冒烟。
> 环境变量：`YGO_UI_ACTIONS=1`（显式开 UI 路径；`YGO_UI_EVENT_DIRECT` 未设 =0）。
> exe：`mycard-client\rin\release\x64\YGOPro.exe` = **14:29:22 / 6,222,336 B**。

### 10.1 第一步：只起 host（验证启动 / UI 初始化）

```powershell
$env:YGO_UI_ACTIONS='1'
cmd /c "rridge\lan-host.cmd msganalyze Blackwing"
```

- 32 秒后仍存活（pid 36200），`GET 7788/health` = `{"ok":true,"started":true}`
- `control-36200.log` 首部：
  ```
  control: started port=7788 hooks=3 autoDismiss=1 placeCoords=server chainMode=avail uiActions=1 uiEventDirect=0
  UI mode ready (uiActions=1 uiEventDirect=0)
  ```
- 判定：✅ PASS（启动正常、UI 初始化完成、不再"静默退出"）

### 10.2 第二步：完整 1 局（`-Games 1 -MaxMinutes 6 -StallSeconds 90`，UI 模式）

- 结局：`deadline`（398s），**turns=18**，hostDec=109 / guestDec=108，retries H/G=12/11
- **没有死锁、没有双端互等**：`seq/analyzeCount` 全程推进
- 关键：**UI 动作真的生效**（有 verified 证据，不再是"只报 ok=1"）：
  ```
  UI action kind=summon msg=11 -> card+menu summon (0) ok=1
  UI action kind=summon verified (ctos+1 analyze+2) after 16ms
  UI action kind=spsummon verified (ctos+1 analyze+2) after 15ms
  UI action kind=position verified (ctos+0 analyze+2) after 250ms
  UI action kind=activate verified (ctos+1 analyze+2) after 15ms
  ```
- UI 计数（host 12332 / guest 39276）：

  | 指标 | host | guest |
  |---|---|---|
  | `UI action` 总数 | 107 | 100 |
  | `UI fallrack` 总数 | 38 | 44 |
  | └ `(no-effect)` | 27 | 24 |
  | └ `(no-menu)` | 7 | 4 |
  | `UI skip (no widget/not ready)` | 0 | 0 |
  | `UI inject click`（卡片） | 16 | 16 |
  | `UI zone click`（区域） | 24 | 22 |
  | verified：summon / spsummon / position / activate | 4 / 2 / 2 / 1 | 3 / 1 / 2 / 1 |

- **仍 fallrack 的动作**：
  1) **`place`（格子选择）全部 fallrack**：24/22 次 `UI zone click` 全在 600ms 后 `UI fallrack (no-effect) kind=place -> direct response`。
     日志投影结果可疑：`UI zone click ctrl=0(server)->1(local) loc=4 seq=0 world=(6.15,-1.40) screen=(1205,388)`
     —— 世界坐标 y = **-1.40**（卡片点击的 world y ≈ 3.3~4.0），很像棋盘平面 y/z 或行列映射错 → 点不到格子。
  2) `(no-menu)` 7/4 次：点卡后 `wCmdMenu` 未出现（时序/遮挡），已自动回退直连。
  3) `auto` / `select` / `sum` 等"没有具体卡身份"的语义动作按设计仍走直连 fallrack。
- **弹窗残留检查**（8 次 `/ui` 采样，5s 间隔）：
  - 仅 1 次瞬态 `popupMask=16 (message=true)`，其余全部 0；`posSelect/options/cardSelect/cmdMenu` 全程 false
  - 截图 4 张：`ranked\logs\lan-ui-smoke-1.png`、`-2.png`、`lan-ui-smoke2-1.png`、`-2.png`
    （抽查 `lan-ui-smoke2-1.png`：正常对战画面 + 瞬态「准备阶段中 是否要进行连锁?」确认框，**无表示形式弹窗**）
- 判定：✅ **PASS（UI 路径可用）** —— 关键动作经真实点击生效、无死锁、弹窗无残留；
  ⚠️ 遗留：`place` 坐标投影仍错（需 poc 继续修），`no-menu` 偶发。

### 10.3 结论（给 lead）

| 问题 | 结论 |
|---|---|
| UI 路径能不能用？ | ✅ 能用（summon/spsummon/position/activate 有 verified 证据；18 回合无死锁） |
| 哪些动作仍 fallrack？ | **place（全部，坐标投影错）**、no-menu 偶发（7/4）、auto/select/sum 等无身份语义（设计如此） |
| 会不会再死锁？ | ❌ 不会：`UI fallrack (no-effect)` 600ms 自动回退直连，本局 27/24 次回退仍正常推进 |
| 弹窗（用户抱怨点） | ✅ 无残留（8 次采样仅 1 次瞬态 message，截图无表示形式弹窗） |

### 10.4 place 修复复验（exe 2026-11-04 14:40:05）—— ✅ place 已走 UI 且 verified

- exe：`14:40:05 / 6,222,336 B`；`YGO_UI_ACTIONS=1`；`lan-run-20261104-144058.log`
- 第一步（只起 host）：存活 30s、`/health` ok、`UI mode ready (uiActions=1 uiEventDirect=0)` ✅
- 第二步（完整 1 局，跑至 turn 8 时 guest 崩溃，见 10.5）：

  | 指标 | 本次（14:40:05） | 上版基线（14:29:22） |
  |---|---|---|
  | `UI action kind=place verified` | **host 5 / guest 4** ✅ | 0 / 0 |
  | `zone click hovered=(ctrl,loc,seq)` 与目标一致 | **一致** | 不一致（world y=-1.40） |
  | `place` 的 `UI fallrack (no-effect)` | **3 / 1** | 27 / 24 |
  | 对局 retries（H/G） | **0 / 0** | 12 / 11 |
  | `UI skip` | 0 / 0 | 0 / 0 |
  | `no-menu retry` | 2 / 2（重试成功） | 无 |
  | 总 `UI fallrack` | 10 / 9 | 38 / 44 |
  | verified 动作 | 16 / 16 | 9 / 7 |

- `zone click` 样本（hovered 与目标格一致、world 坐标正常）：
  ```
  UI zone click roard=0 loc=4 seq=0 world=(1.75,1.40,0.02) screen=(749,588) hovered=(0,4,0)
  UI zone click roard=0 loc=4 seq=1 world=(2.85,1.40,0.02) screen=(872,588) hovered=(0,4,1)
  UI zone click roard=0 loc=8 seq=0 world=(1.75,2.60,0.01) screen=(723,702) hovered=(0,8,0)
  UI action kind=place verified (ctos+0 analyze+2) after 93ms
  UI action kind=place verified (ctos+1 analyze+1) after 16ms
  ```
- `chainStack.descText` 修复确认（task-19 另一处遗留）：`ranked\logs\ui-smoke-chainstack-descText.json`
  ```
  chainDepth=1 lastChainEvent="连锁成立: [黑羽-突风之颪]"
  chainStack[0]: code=73652465 name=黑羽-突风之颪 descText="改变表示形式"
                 summary="我方[黑羽-突风之颪]（改变表示形式） 已加入连锁"
  ```
  → descText **不再为空** ✅

### 10.5 ⚠️ 新问题：UI 模式下 guest 客户端崩溃（0xE06D7363 C++ 异常）

- 时间：2026-11-04 14:45:20（turn 8）
- 现象：host 侧 `/state` 出现 `win=0/4 (DISCONNECT)`；guest 进程消失、HTTP 不可达；结算 `endCause=client-exit`、`winReason=4 DISCONNECT`
- 崩溃点（`mycard-rot\game\control-26264.log` 末尾，**紧贴 UI 点击**）：
  ```
  [955716781] CDBG ExecuteAction kind=10          <- ActionKind::UiSem（enum: MsgOk=9, UiSem=10, UiPoint=11, UiMenu=12）
  [955716781] UI inject click x=872 y=588 card=82633039 world=(2.85,1.40,0.02) hovered=(0,4,1) menu=1
  [955716796] crash code=0xE06D7363 addr=00007FFA97CC408A flags=0x81 ctx_rip=00007FFA97CC408A threads=4
  ```
- `0xE06D7363` = MSVC C++ 异常（throw）；崩溃发生在这条 `UiSem` 动作里（点卡后菜单已出现 `menu=1`，随后异常）。
- 初步判断：`UiSem` 的「点卡 → 菜单项」路径有未捕获 C++ 异常（菜单项索引越界 / 某控件判空漏了 / analyze→click 之间卡片状态变化导致悬垂访问）。
- 影响：**UI 模式暂不能当默认**（place 已 verified、fallrack 大幅下降，但存在崩溃路径）；直连模式不受影响。
- 已同步 poc：`try/catch(...)` 包住 UiSem/UiPoint/UiMenu 并回退直连；菜单项索引边界检查；点击前打 `semKind/semIndex/menuItemCount/cardCount`。

### 10.6 结论更新（place 复验后）

| 项 | 结论 |
|---|---|
| place 坐标 | ✅ **已修好**（verified 5/4、hovered 命中、retries 0、place-fallrack 27/24 → 3/1） |
| descText | ✅ **已修好**（不再是空串） |
| 其余 fallrack | ✅ 大幅下降（总 38/44 → 10/9）；`no-menu` 2 帧重试成功 |
| UI 模式可作默认？ | ❌ **暂不可**：存在 `0xE06D7363` 崩溃路径（UiSem 点卡+菜单），修掉后再翻默认 |
| 直连模式 | ✅ 一直稳定，建议继续作日常默认 |

### 10.7 防崩溃版复验（exe 2026-11-04 14:47:45）—— ✅ 不再崩溃，建议默认翻 1

- exe：`14:47:45 / 6,224,384 B`；`YGO_UI_ACTIONS=1`；`lan-run-20261104-144807.log`
- 跑局：`-Games 1 -MaxMinutes 6 -StallSeconds 90 -Deck Blackwing`；**15 回合、398s、`endCause=deadline`**
- 全程 **没有 client-exit / 没有 `winReason=4 (DISCONNECT)`**，两端坚持到收局（对比上版 turn 8 崩溃）

| 指标 | host 37944 | guest 45076 |
|---|---|---|
| `UI exec-exception` | **0** | **0** |
| `UI skip (menu card mismatch)` | 1 | 2 |
| `UI action kind=place verified` | **11** | **7** |
| `UI fallrack (no-effect)` | 12 | 7 |
| `UI action kind=` 总数 | 110 | 93 |
| `UI zone click` / `UI inject click` | 15 / 17 | 13 / 14 |
| 决策数 | 113 | 94 |
| retries（本次） | 3 | 0 |

- **崩溃根因验证**：上版 turn 8 崩溃的那类场景，本版被防线接住：
  ```
  UI menu check kind=spsummon want=73580471 menuCard=0 items=13 id=242
  UI skip (menu card mismatch) kind=spsummon -> fallrack
  ```
  → 菜单归属校验命中（菜单属于别的卡）→ 跳过并直连回退，**客户端不再崩**。
- 弹窗：8 次 `/ui` 采样，仅 1 次瞬态 `posSelect=true`（14:48:59），随后全 0
- 截图 6 张：`ranked\logs\lan-crashfix2-1/2.png`、`lan-crashfix4-1/2.png`、`lan-crashfix6-1/2.png`
- 环境：跑完 `[finally] guaranteed cleanup`，`YGOPro=0 / node=0`

**结论：建议把 `YGO_UI_ACTIONS` 默认翻 1**（依据 lead 定的判据：0 崩溃 + exception fallrack 少）：
- 无崩溃、`UI exec-exception=0`；残余 `menu card mismatch` 1/2 次已被防线吃掉并回退，不致命
- 关键动作 verified 稳定（summon/spsummon/position/activate/place；place 11/7）
- 保留 `YGO_UI_ACTIONS=0` 作为回退开关；建议翻默认后继续监控 `UI exec-exception` 与 `menu card mismatch` 计数，若崩溃重现则回退

### 10.8 最终验收（默认 UI 模式，exe 2026-11-04 14:56:22）—— ✅ 可交付

- exe：`14:56:22 / 6,224,384 B`（默认 `uiActions=1`）；**未设置任何 `YGO_*` 环境变量**
- 命令：`rridge\lan-run.ps1 -Games 1 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing`
- 日志：`ranked\logs\lan-run-20261104-145637.log`；host pid 37408 / guest pid 11368

| 验收项 | 结果 |
|---|---|
| 启动 `uiActions=1`（默认生效） | ✅ 两端 `control: started ... uiActions=1` + `UI mode ready (uiActions=1 uiEventDirect=0)` |
| 无 client-exit / 无 `winReason=4` | ✅ 全程双客户端存活到收局 |
| `UI exec-exception` | ✅ **0 / 0** |
| `UI skip (menu card mismatch)` | 3 / 3（防线生效、无崩溃） |
| `place verified` | ✅ **host 11 / guest 8** |
| `UI action verified` / `UI action` | 37/79（host）、31/74（guest） |
| `UI fallrack (no-effect)` | **host 4 / guest 7**（上版量级 12/7 之内） |
| **结局** | ✅ `MSG_WIN player=0 reason=1 (LP_ZERO)`、**`natural=True`**、8 回合、350s |
| `/ui` 采样（12 次） | 9 次全 0；3 次瞬态 `posSelect=true`（turn 3/5，随后自动关），无 `mask` 持续非 0、无 GONE |
| 截图 | `lan-final3-{1,2}.png`、`lan-final7-{1,2}.png`、`lan-final11-{1,2}.png` |

**fallrack 明细**（区分"设计内"与"真实失败"）：
- host（=41）：`select=13`、`auto=12`、`attack=6`、`spsummon=4`、`place=2`、`activate=2`、`sum=1`、`yes=1`
- guest（=46）：`auto=21`、`select=10`、`place=4`、`chain=3`、`spsummon=3`、`activate=2`、`decline=2`、`summon=1`
- 其中 `auto/select/sum/yes/decline` 属"语义里没有具体卡身份，按设计走直连"；真实 UI 失败主要是 `place`（2/4）和 host 的 `attack`（6）——比上版 place 27/24 已降一个数量级。

**额外达成（ronus）：UI 模式下成功发动目标陷阱「激流葬」53582587**（完整闭环）：
```
# 1) 盖放（UI 点手牌 + 菜单）
UI inject click x=1037 y=829 card=53582587 world=(4.30,4.00,0.50) hovered=(0,2,1) menu=1
UI menu check kind=set_spell want=53582587 menuCard=53582587 items=13 id=244
[sem] SET-TRAP 盖放[激流葬](code=53582587) -> set spell/trap #0 code=53582587
# 2) 连锁发动（UI 点场上 SZONE 的陷阱卡，两步菜单）
UiSem regin kind=chain idx=0 msg=16
UI inject click x=723 y=702 card=53582587 world=(1.75,2.60,0.01) hovered=(0,0,0) menu=0
UI no-menu kind=chain msg=16 -> queued menu id=240 (next frame)     <- 两帧重试
UI action kind=chain msg=16 -> card+menu chain (0) ok=1
[sem] CHAIN-TRAP 用[激流葬]连锁当前连锁（理由：激流葬 的效果）
[sem] #30 msg=16 -> chain "chain #0 code=53582587" ok
[sem] hr ... trapsSet=1 trapsAct=1 chains=3/4
```
→ **同一局里既打了自然胜负（LP_ZERO），又在默认 UI 模式下发动了目标陷阱**。

### 10.9 最终判断：**可交付给用户**

- ✅ 默认（不设任何环境变量）就是 UI 模式；关键动作（summon/spsummon/position/activate/place/set_spell/chain）经真实点击并 verified
- ✅ 无崩溃、`UI exec-exception=0`，异常/错菜单会被防线吃掉并回退直连（对局不中断）
- ✅ 默认 UI 模式下打出自然胜负 + 目标陷阱发动（完整闭环）
- ⚠️ 诚实说明：**不是字面 100% 全 UI** —— `auto/select/sum/yes/decline` 等"无具体卡身份"的语义动作仍走直连（约占尝试的一半），另有少量 `place/attack` 回退（2/4、6/0）。若用户要求"每一次操作都必须是界面点击"，需要继续把 select/auto 的候选映射到具体卡（收益低、风险高），当前不建议。

## 十一、残留空框排查（用户反馈：对局中屏幕中间卡着无文字 UI 框体）

> **用户反馈（2026-11-04 21:3x）**：对局过程中，画面中央卡着一个**没有文字**的 UI 框体（窗口/面板），影响观感。
> 归属：poc-wasm-duel 正在做 task-22（`/ui.windows` 诊断 + 扩展 `UiCleanup` + 空框兜底）；本验证方负责跑局诊断与留证。

### 11.1 诊断方法（等 task-22 新 exe 后执行）

1. 跑 1 局：`lan-run.ps1 -Games 1 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing`（默认 UI 模式）
2. **每 5 秒**采一次两端 `/ui`，把 `windows` 中 `visirle=true` 的窗口逐条记到 `ranked/logs/ui-windows-<stamp>.log`（字段：`name / rect / textLen / visirle`）
3. **每 20 秒**截一张图：`rridge\shot.ps1 -Tag diagN`（两端窗口各一张）
4. 判定：
   - 某窗口**连续 ≥2 次采样可见** → "卡住空框"候选，记录 `name/rect/textLen` + 对应截图
   - 若截图已无空框、且日志有 `UI close empty frame name=..` → 判定"已消除"，附日志行

### 11.2 诊断结果

| 项 | 状态 |
|---|---|
| task-22 新 exe | ⏳ 等待 poc-wasm-duel 编译（当前 exe 仍是 2026-11-04 14:56:22，无 `/ui.windows` 字段） |
| 采样日志 | — |
| 截图 | — |
| 判定 | 待新 exe；**旧 exe 已先把"空框"复现出来了（见 11.3）** |

### 11.3 旧 exe 的 raseline 复现（2026-11-04 21:33 局，exe 14:56:22）

旧 exe 没有 `/ui.windows`，但截图已经把"卡住的空框"抓到：

| 证据 | 时刻 / 回合 | 内容 |
|---|---|---|
| `ranked\logs\ui-EMPTY-FRAME-raseline-host-turn5.png` | 第 106s / turn 5 | host 窗口中央：灰色面板，标题「请选择」+ **正文空白** + 「是 / 否」按钮 |
| `ranked\logs\ui-EMPTY-FRAME-raseline-host-turn6.png` | 第 127s / turn 6 | 同一位置、**同一个框**（相隔 20s 仍可见 → 符合"连续 ≥2 次可见"判据） |

对照同时刻的旧 `/ui` 采样（`ranked\logs\ui-windows-raseline-20261104-213339.log`）：

```
[106s] p7788 mask=0 posSel=False opt=False card=False cmd=False msg=False turn=5 curMsg=3
[127s] p7788 mask=0 posSel=False opt=False card=False cmd=False msg=False turn=6 curMsg=41
```

→ **关键发现**：空框可见时，旧 `/ui` 的 5 个 popup 位**全是 false** —— 说明这个窗口**不在旧诊断口径里**
（旧 mask 只覆盖 `wPosSelect / wOptions / wCardSelect / wCmdMenu / wMessage`）。
从外观（标题「请选择」+ 是/否）判断，最可能是 **`wQuery`**（其次 `wACMessage`/`wCardDisplay` 一类）。
这也解释了"之前几轮 UI 验证 popup 全 0，但用户仍能看到空框"。

补充：同局 75s 处出现 1 次 `mask=16 (msg=True)` 采样，下一帧即消失 —— 正常瞬时确认框，不算残留；
空框出现期间对局仍在正常推进（turn 5→6），属"界面挂着不消失"而非卡死。

### 11.4 ⚠️ task-22 构建（exe 2026-11-04 21:38:11）**起局失败**，诊断被阻塞

task-22 版 exe（`21:38:11 / 6,236,160 B`，含 `/ui.windows`、扩展 UiCleanup、CloseEmptyFrames）**开不起局**，
三次 A/B 全部 `no-start`：

| 运行 | 环境变量 | 结果 |
|---|---|---|
| `lan-run-20261104-213843.log` | 默认 | `no-start`（3 次尝试，lorry `rothReady=true`、`/start ok`，但两端 `isStarted` 始终 false） |
| `lan-run-20261104-214238.log` | `YGO_UI_HIDE_EXTRA=0` | 同样 `no-start` |
| `lan-run-20261104-214433.log` | `YGO_UI_ACTIONS=0` | 同样 `no-start` |

关键日志（`mycard-rot\game\control-26512.log` / `control-19488.log`，A/B 版为 `control-20600.log` / `control-5260.log`）：

```
host: STOC_DUEL_START -> chain mode pending (avail)
      rps: sending 2
      PIPE stall analyze=40 pump=6679 msgs=40 seq=1 awaiting=1 stoc=1(STOC_GAME_MSG)   <- 永久停在这
guest: STOC_DUEL_START / STOC_SELECT_HAND / rps: sending 1
      STOC_HAND_RESULT
      PIPE stall analyze=39 pump=6133 msgs=39 seq=0 awaiting=0 stoc=24(STOC_TIME_LIMIT) <- 也停住
```

- `STOC_DUEL_START` 双方都收到、RPS 也都发出；但之后消息流停在第 39/40 条，两端 `dInfo.isStarted` 不转 true，
  跑局器的「等 started」判定失败 → 不进 `[5/8] start rots` → 没人回答起手阶段的询问 → 死锁 → 每次 27s 后重试，3 次后 `no-start`
- 对照组：**旧 exe 14:56:22 在 21:33 同一套脚本、同一卡组能正常开局**（见 11.3 的 raseline 局），说明是 task-22 改动引入的回归
- 两个 A/B 都失败 ⇒ 与 UI 动作执行路径、与"扩展清理"分支无关；仍在生效的新代码只剩 **`CloseEmptyFrames()`（每帧跑，不受 `YGO_UI_HIDE_EXTRA` 控制）** 和 **`LogVisirleWindows()`（每 15 帧打 `CDBG UI windows visirle=[...]`，默认就开，2 分钟写 455 行/415KB）**
- 可能机制（待 poc 验证）：`CloseEmptyFrames()` 在起手/RPS 握手期间把 `wMessage`/`wQuery`/`wACMessage` 隐藏了（或每帧 Hide 打断了客户端的握手状态机），导致 `STOC_START` 之后的流程走不完

> 已把上述证据与 A/B 矩阵同步 poc-wasm-duel，请其加 **`YGO_UI_TASK22=0`（一键关掉 task-22 全部新路径：CloseEmptyFrames + LogVisirleWindows + 扩展清理）** 做二分；
> 并把 `LogVisirleWindows` 改回只在 `YGO_CTRL_DEBUG=1` 时输出。
> 空框（wQuery）修复的验收（§11.1 流程）要等能开局后再做。

> **11.4 追记（2026-11-04 22:00）**：上述 no-start 的**真正根因已定位** —— 不是清理逻辑，而是 task-22 新增的 `/ui` JSON 里
> `"windowsVisirle":[wPosSelect]` **漏了引号**（非法 JSON）→ 跑局脚本 `ConvertFrom-Json` 失败 → `started` 视为 false →
> 不起 rot → 双端停在第一个 prompt。修复 = 给窗口名加引号（exe 22:00:40）。
> 独立佐证：手工探针里 `/health` 一直是合法 JSON（正常返回），而 `/state`、`/ui` 全部解析失败（脚本表现为 `DOWN`），
> 但同一时刻 control 日志仍持续打 `PIPE` —— 客户端与控制服务都活着，只是响应体 JSON 坏了。

## 十二、空框（wQuery）修复验收（exe 2026-11-04 22:00:40）—— ✅ 已消除

### 12.1 起局冒烟（前置条件）

- `lan-run-20261104-220315.log`：`[22:03:43] [5/8] start rots` 出现、`lorry ready:[1,1]`、`/state.started=true`、
  turn 1→6 正常推进（hostDec=55 / guestDec=45，deadline 216s）→ **no-start 回归解除**
- 启动行：`hideExtra=1 task22=1 closeEmpty=1`（两端一致，默认 UI 模式）

### 12.2 8 分钟诊断局（默认环境 + 采样器）

- 命令：`lan-run.ps1 -Games 1 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing` + `bridge\dev\diag-ui-windows.ps1 -DurationSec 460 -SampleInterval 5 -ShotInterval 20`
- 结果：**20 回合 / 517s / deadline**，hostDec=158、guestDec=120、retries 5/6（均为已知 place 边界）
- 日志：`ranked\logs\lan-run-20261104-220659.log`、采样 `ranked\logs\ui-windows-20261104-220717.log`、截图 `ranked\logs\uiwin-20261104-220717\lan-diag*.png`

### 12.3 判定：**空框已消除** ✅

| 判据 | raseline（旧 exe 21:33） | 本次（22:00:40） |
|---|---|---|
| `wQuery` 最长连续可见 | **≥2 次采样（20s+，跨 2 张截图）** | **1 次采样（≤5s）** |
| 截图里的「请选择+空白正文+是/否」 | 106s / 127s 两张都在 | **80s（diag4-1）、120s（diag6-1）都干净** |
| 空正文 `wQuery`（textLen=0） | 长期挂着 | 仅 75s 出现 1 次、5s 内消失（rect 821,400,1171,410，t=0） |
| `UI close empty frame name=wQuery` | 无（旧版没这功能） | 0 次（**没轮到它**：空框在动作后的扩展清理就被关掉） |
| 扩展清理实际生效证据 | 无 | `UI cleanup extra=0x002 after action`（rit1=wQuery）host 24 次 / guest 10 次 |
| 其它窗口连续可见 | — | 全部 `maxConsecutiveVisirle=1`（只有 `wChat` 常驻，属正常聊天框） |

采样器 SUMMARY（`ranked\logs\ui-windows-20261104-220717.log` 末尾）：
```
7788:wCardSelect = 1   7788:wChat = 87   7788:wMessage = 1   7788:wPosSelect = 1   7788:wQuery = 1
7789:wChat = 87        7789:wCmdMenu = 1 7789:wMessage = 1   7789:wPosSelect = 1   7789:wQuery = 1
```

`wQuery` 全部 5 次可见记录（只有一次正文为空，且下一采样点已消失）：
```
[64s]  p7788 visirle=wQuery|996,405,997,406|t=47      （有正文）
[75s]  p7789 visirle=wQuery|821,400,1171,410|t=0      （空正文，5s 内被关）
[107s] p7788 visirle=wQuery|821,348,1171,462|t=14     （有正文）
[139s] p7788 visirle=wQuery|996,405,997,406|t=48
[340s] p7788 visirle=wQuery|996,405,997,406|t=16
```

**结论**：用户反馈的"屏幕中间卡着无文字 UI 框体"（`wQuery`，标题「请选择」+ 空白 `stQMessage` + 是/否）**已消除**；
本次 20 回合、8 分钟里没有任何窗口连续 ≥2 次采样可见，截图对照 raseline 也再无该面板。
> 说明：本次 `UI close empty frame name=wQuery` 计数为 0 —— 因为空框在"动作后扩展清理"阶段就被关掉了（`extra=0x002`），
> 兜底逻辑（每帧 `CloseEmptyFrames`）作为第二道防线保留即可。

