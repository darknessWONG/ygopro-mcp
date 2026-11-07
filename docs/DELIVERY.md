# 交付说明：YGOPro「画面可见、AI 代打」控制层

> 写给使用者/评审看的一页说明。技术细节见文末「延伸阅读」。
> **完整接口规范（面向 LLM 接入）见 [`MCP-INTERFACE.md`](MCP-INTERFACE.md)。**

## 一、这是什么

一套跑在**本机/局域网**的 YGOPro 对局的 **AI 控制层**：真实客户端窗口照常渲染（可看、可直播），AI 通过 HTTP/MCP 读取局面并**像人一样点鼠标**打牌。
默认 **所有操作都经由客户端 UI 点击执行**（召唤/盖放/选格/选卡/攻击/连锁都点真实按钮和卡片），点击不生效时自动回退为直连协议，**不会卡死、不会崩客户端**。

- 控制接口：每端一个 HTTP 端口（房主 `7788`、客人 `7789`）
- MCP 工具：`control_state` / `control_wait_prompt` / `control_actions` / `control_act_id` / `control_act` / `control_ready` / `control_deck` / `control_lobby` …
- 对局引擎：MyCard 客户端自带 ygopro 内核，走标准 LAN（`127.0.0.1:7911`）；**不登录、不连线上服务器**（合规边界见 `SAFETY.md`）

## 二、能做什么（均有实测证据）

**1) 开局链路**：起房 / 加入 / 备牌 / 准备 / 开始，一条命令完成（见第五节）。

**2) 对局决策**：AI 每回合读 `/state` + `/actions`（语义化候选：`summon / spsummon / set_spell / activate / attack / chain / decline / position / place / select …`），选一个后 `POST /act_id`。
默认该动作会被**翻译成真实 UI 操作**：点卡片 → 点命令菜单 → 点格子/按钮，并在 600ms 内用"是否产生新响应"验证；无效果则自动改用直连协议补发。

**3) 连锁语义**（给 LLM/策略判断"谁在连锁谁"用）：
`chainStack[]`（每一环的 `link/code/name/descText/ctrl/loc/seq/forced/isMine/summary`）、`chainingTo`、`chainCandidates[]`、`canDecline`、`hint`、`lastChainEvent`、`activeEffects`。

**4) 实测结果**
- **自然胜负**：多局 `MSG_WIN reason=1 (LP_ZERO)`，其中最终验收局 8 回合、AI 双方决策各 ~78 次、`natural=True`（`ranked/logs/lan-run-20261104-145637.log`）
- **目标陷阱发动**：
  - 「神之警告」双方各发动一次（支付 2000 LP，`chainStack` 内核级证据，`ranked/logs/trap-EVIDENCE-84749824-chainStack.json`）
  - 「激流葬」在**默认 UI 模式**下完成 盖放 → 连锁 → 发动（`lan-run-20261104-145637.log`、`trap-goal.md` §4.2）
- **UI 化程度**（默认模式、一局样本）：`place verified` 11/8 次；关键动作 verified 37/31 次；`UI exec-exception=0`、无客户端崩溃

## 三、开关（环境变量）

| 变量 | 默认 | 作用 |
|---|---|---|
| `YGO_UI_ACTIONS` | `1` | `1`=动作经 UI 点击（默认）；`0`=直连协议（回退/对照） |
| `YGO_CHAIN_MODE` | `avail` | 时点：`avail` 可用时点 / `all` 全部时点 / `ignore` 忽略；开局自动应用 |
| `YGO_AUTO_DISMISS` | `1` | 自动关掉 `MSG_RETRY`/提示弹窗；`0`=关闭（调试用） |
| `YGO_PLACE_COORDS` | 内置 | 选格坐标规则 `local`/`server`，仅用于 A/B 复现旧行为 |
| `YGO_CTRL_DEBUG` | 关 | `1`=控制层详细日志（含每条 UI 注入） |
| `YGO_HOOKS` | 房主 `msganalyze` / 客人 `all` | 客户端钩子；**房主不能用 `all`**（会在开局搞死进程） |
| `YGO_UI_EVENT_DIRECT` | `0` | 实验项：换一种事件注入方式（`1`=receiver->OnEvent） |
| `TRAP_GOAL` / `MAX_MINUTES` / `CONTROL_URL` | `1` / 20 / `:7788` | 策略侧：优先目标陷阱 / 单局上限 / 控制端地址 |

回退方式：跑局前 `set YGO_UI_ACTIONS=0`（或 PowerShell `$env:YGO_UI_ACTIONS='0'`）即可回到纯直连模式。

## 四、已知限制（如实说明）

1. **不是字面 100% 全 UI**：`auto / select / sum / yes / decline` 这类"语义里没有具体卡身份"的提示仍走直连（约占尝试的一半）；`place`、`attack` 偶发点击失效会回退（样本次数 2/4、6/0）。
2. **会有 600ms 校验延迟**：UI 动作需等一帧确认是否生效，个别回合节奏略慢。
3. **menu card mismatch**：点卡后若弹出的是别的卡的菜单（约每局 3 次），会被防线拦下并回退，不会崩，但该次动作不走 UI。
4. 仅支持**本机/局域网**对局（LAN 7911 + 两个客户端进程）；不支持登录线上账号/排位（`ranked/` 下脚本有硬闸门）。
5. 同一时间只能跑**一对**客户端（固定端口 7911/7788/7789）。

## 五、一键跑局

```powershell
# 默认（UI 模式），跑 1 局，最多 8 分钟
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 8 -Deck Blackwing

# 连跑 3 局 + 换卡组
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 3 -Deck trap-test
```

流程自动完成：清场 → 起房主 → 起客人 → 备牌 → 准备 → 开始 → 双 AI → 每 2s 看门狗 → 收证据 → 收尾清进程。
产物都在 `ranked/logs/`：
- `lan-run-<stamp>.log`（时间线/看门狗/汇总）、`lan-bot-*.log`（AI 决策流水）
- `lan-state-*.json`（终局状态）、`lan-ctl-*.txt`（内核/UI 关键行摘录）
- 截图 `lan-*.png`（`bridge\shot.ps1 -Tag xx` 可随时抓客户端窗口）

## 六、证据与延伸阅读

| 文档 | 内容 |
|---|---|
| `bridge/docs/ui-verify.md` | UI 修复与**最终验收**（默认 UI 模式、place verified、无崩溃、可交付判断） |
| `bridge/docs/trap-goal.md` | 目标陷阱发动验证（神之警告 / 激流葬，含内核级 `chainStack`、LP 证据） |
| `bridge/docs/chain-semantics.md` | 连锁语义字段定义与"要不要连锁"判断方法 |
| `bridge/docs/ui-actions.md` | UI 点击实现：坐标投影、600ms 校验回退、两帧菜单重试、已知风险 |
| `bridge/docs/lan-run.md` | 一键跑局器用法 + 12 局实测对照 + 故障排查 |
| `bridge/docs/pipeline-diag.md` / `bot-diag.md` | 管线/协议层排障记录（MSG_RETRY、place 索引、descText 等） |
| `bridge/docs/MODULE-MAP.md` | **控制层源码地图**（7 模块职责 / 公共函数 / 全局归属 / 原行号来源 / 构建与 namespace 坑） |
| `bridge/docs/RECONNECT-DESIGN.md` | **重连设计**：三层职责（客户端 prober / supervisor / 策略）、双状态机、探活、chain journal、LLM 语义、自动关模态框、测试与验收 |
| `bridge/docs/reconnect-lab.md` | **重连实测**：LAN 掉线重进（服务端不支持续局）+ task-30 客户端检测/supervisor/journal 实测（freeze 6.75s、drop 0.6s） |
| `bridge/docs/net-probe.md` | netfault 故障注入 + net-probe 采样工具用法（`-j` 忽略 `-p` 的坑、流量断言） |
| `bridge/docs/supervisor.md` | supervisor 用法（`--profile lan|ranked`、JSONL 记账、`--mock` 自测、与 netfault 配合） |
| `bridge/docs/RANKED-REPORT.md` | **线上排位实战报告**：完整流程（拿房→选卡组→`HP_READY`）、当日修复清单（空 chain prompt 循环 / 准备界面未选卡组 / 卡组非法 / deckError / 阻塞弹窗 / prompt 快照 / isWin）、实测记录表、掉线重连 13s、已知限制与证据索引 |

关键证据文件：
- 自然胜负（UI 模式）：`ranked/logs/lan-run-20261104-145637.log`、`ranked/logs/lan-final7-1.png`
- 神之警告：`ranked/logs/trap-EVIDENCE-84749824-chainStack.json`、`trap-EVIDENCE-84749824-hit1.png`
- 激流葬（UI 模式）：`ranked/logs/lan-run-20261104-145637.log` 内 `SET-TRAP / CHAIN-TRAP` 行
- UI 采样：`ranked/logs/ui-final-samples.log`（12 次 `/ui`，无弹窗残留）

---

## 七、源码结构（重构后）

> 详细地图见 [`MODULE-MAP.md`](MODULE-MAP.md)。这里只给"该从哪读起"。

控制层原本是**一个 3008 行的 `mycard-client/gframe/control.cpp`**，现已拆成 7 个模块：

| 文件（`mycard-client/gframe/`） | 行数 | 职责 |
|---|---:|---|
| `control.h` | 57 | **对外**接口；上游 6 个文件（duelclient / game / netserver / single_duel）只 include 它 |
| `control_internal.h` | 367 | 控制层**内部**共享：Snap 结构、`extern` 全局、跨 TU 函数声明 |
| `control.cpp` | 1133 | 生命周期、HTTP 服务与 `RouteRequest` 路由、`Pump()` 主循环、上游钩子、日志、**全局变量的唯一定义处** |
| `control_state.cpp` | 727 | 快照采集 `SnapshotFromClient` + 全部 JSON 序列化（`/state` `/prompt` `/ui`） |
| `control_ui.cpp` | 652 | UI 注入（按钮/鼠标）、窗口清理与诊断、连锁时点模式、`ExecUiAction` |
| `control_lobby.cpp` | 274 | 卡组/准备/开始/加入/投降（`ExecLobbyAction`） |
| `control_actions.cpp` | 140 | `ExecuteAction` 分发 + 原始响应（Int32/Bytes） |
| `control_sem.cpp` | 306 | 语义动作列表与编码（`/actions` 的返回体） |

### 建议阅读顺序

1. `control.h` —— 先看对外 10 个入口（`EnsureStarted` / `OnMessageBegin` / `OnAnalyzeEnd` / `Pump` / `OnStocPacket` / …）；
2. `control.cpp` 的 `Pump()` —— 整个控制层的心跳：UI 校验 → 快照发布 → 执行动作队列 → 清理；
3. `control.cpp` 的 `RouteRequest()` —— 16 个 HTTP 端点的全部返回体都从这里出去；
4. 按需下钻：`control_state.cpp`（字段怎么算）→ `control_ui.cpp`（怎么点）→ `control_sem.cpp`（动作怎么枚举/编码）。

### 重构约束（改代码前必读）

- **全局变量只在 `control.cpp` 定义一次**，其它模块只能通过 `control_internal.h` 的 `extern` 使用。
  历史上这些变量都在**匿名 namespace** 里，拆分后若各文件各定义一份，编译不报错但会出现两份状态（典型症状：`/wait_prompt` 永不返回）。
- 匿名 namespace 的成员在 `ygo` 命名空间内**隐式可见**，而具名 `namespace ctl` **不是**；因此 `control.cpp` 在 `ctl` 闭包之后有一行 `using namespace ctl;`，不要删。
- `gframe/premake5.lua` 用 `files { "*.cpp", "*.h" }`，但 glob 只在**生成工程时**求值：新增 `.cpp` 后需要重跑 premake 生成 `build/YGOPro.vcxproj`（或像本次一样手工补进 vcxproj）。
- 新增文件请带 GPLv2 版权头（本项目为 GPLv2 fork，见仓库根 `LICENSE`）。

### 行为兼容性

重构**只做搬移 + namespace 调整 + 两处 `goto` 改 `return`**，没有任何逻辑重写；
HTTP 端点、返回字段（含 `/state` 里故意重复的 `retryCount`）、连锁语义字段、环境变量、日志关键字均保持不变，
由 `bridge/refactor-compare.mjs` 对照基线指标回归验证。
