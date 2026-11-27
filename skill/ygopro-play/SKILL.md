---
name: ygopro-play
description: 用 MCP 控制层真实操作 YGOPro 客户端打牌（MC 线上排位 / 局域网 / 单人测试）。当用户说「帮我打一局游戏王」「用 MCP 打排位」「操控 YGOPro」「陪我在 MC 打一局」「跑 Bo3 测试」「看看我客户端现在什么状态」时使用。覆盖：状态查询、排队进房、选卡组、准备、开局、先后攻、对局决策循环、换备牌、整场结果汇报、异常（空房/对手静默/掉线/卡住）处理与无人值守跑分。细节以同目录 PLAYBOOK-FULL.md 与仓库 docs/MCP-INTERFACE.md 为准。
---

# YGOPro 实操：用 MCP 控制层打一局

**工作区**：`D:\dsh_workspaces\MC_bot_dsh`（下称 `$ROOT`）
**权威细节**：同目录 `PLAYBOOK-FULL.md`（已随 skill 打包，最全）
**接口规范**：`$ROOT\bridge\docs\MCP-INTERFACE.md` ｜ 客户端 HTTP：`$ROOT\mycard-client\docs\CONTROL-API.md`
**不要**：直接调客户端内部接口绕过 MCP/控制层、猜结果、手改客户端状态。

## 0. 最高优先级硬规则（踩过的坑）

1. **TP（先后攻）13 秒铁律**：`STOC_SELECT_TP` 出现后 **13s 内必须答**，否则服务端直接 `eof` 踢人。新 exe 默认 **2 秒自动答**（先/后攻按 `YGO_TP_AUTO_RES`，默认 2=后手）；外部要覆盖只能在 2 秒内 `/act_id kind=tp`。
2. **判死阈值**：旧版（≤2026-11-15 19:05:42）默认 10s，会把"自己回合思考中"误判 `confirmed_dead` → 管线冻结 → 被踢，**仅旧版启动需设 `YGO_NET_DEAD_SILENCE_MS=600000`**；当前版用**默认 60000 即可（最多 120000），别再长期设 600000**（真掉线 10 分钟才发现）。`17:33:31` 版起看门狗修好：`clockRunning = ourTurn && clockFresh(<3s)`，`our-turn-idle` 不再因过期 `g_timeLeft` 永远豁免；`/net` 新增 `ourTurn/oppTurn/timeLeft/clockFresh`，`net.heartbeat` 每 15s。**另一旧版 bug：`/tip` probe 2 次超时即 `NET DEAD reason=probe-fails`+断线**（对手长展开 ~7.5s 被误踢）；`11:31:00` 起 probe 失败只降级 `probe_failed`（`YGO_NET_PROBE_FAIL_MAX=5` 仅日志/降级），判死走被动静默。旧版可用 `YGO_NET_PROBE=0` 规避。
3. **MSG_SORT_CARD（洗牌/排序）响应是裸位序字节、无长度前缀**：两张卡保持原序 = `hex="0001"`；用 `control_act({seq, hex})`，**不要**加计数前缀（会死循环）。
4. **多怪兽攻击目标**：旧版会核心拒绝（`curMsg` 15↔10 反复、攻击消耗但不结算）；新 exe 已修（见 PLAYBOOK-FULL §3.7.2），若仍遇到就降级：直接攻击 / `to_m2` / `end_battle`。
5. **announce 140–143**：旧版 `curMsg=143` 前会 `awaiting=false` 卡住；新 exe（20:11:00+）`/actions` 提供 `announce_race/announce_attrib/announce_card/announce_number`，编码 **race/attrib=掩码、card=卡号、number=数值本身**（候选见 `/prompt.announceNumberValues`）。
6. **`awaiting=false` 不发动作**；同一条 prompt 只回一次（`seq` 去重）；`/act_id` 带 `seq=` 防过期。
7. **整场胜负只信 `control_match`**，不要用 `winPlayer` 推。
8. **EOF guard（10:25:14 版起）**：prompt 空等 ~90s 会被 MC 排位按 AFK `eof` 踢；`YGO_PROMPT_AUTO_DEFAULT_MS`（默认 60000，0=关）45s 打 `PROMPT idle warning`、60s 自动发保守默认（`PROMPT auto-default ... (idle guard, LLM silent)`）。**超 60s 没答会被 guard 顶掉（保守动作），但别依赖它——正常要快**；`/prompt.awaitingSinceMs` 可看等待时长。
9. **座位坐标（11-26 10:26:12 版起）**：`ctrl`/`isMine` 全部是**服务端座位坐标**，恒有 **`isMine == (ctrl == mySeat)`**——判敌我只用 `isMine` 或 `ctrl==mySeat`，**不要用 `ctrl` 猜**。`hand[0]` 是**本地手牌**（本地视角）、`myPlayer` 恒 0 只是索引视角（`hand[1]`=对手）。`places[]` 的 `ctrl` 是服务端座位、`ctrlRaw` 是本地原值，响应仍用 `bit`。旧版（≤11-23 14:53:57）在 **guest（mySeat=1）** 时会把双方阵营整体写反（自己的卡标「对手」、`isMine:false`），升级即可。
   - **`mySeat` 怎么来的（11-27 15:03:45 版起）**：对局/换备期间取 **`dInfo.isFirst`**（`isFirst==true` ⟺ 服务端座位 0，guest 为 1）；大厅才用 `selftype`。原因：**MC 不保证发 `STOC_TYPE_CHANGE`**（guest 的 `selftype` 可能是 0），且 MC launcher 用 `-d/-k` 让 `-c/-j` fallback 失效 → **旧版 guest 的 `mySeat` 会错成 0**。读 `control_state().mySeat`；客户端日志有 `SEAT resolved seat=%d isFirst=%d selftype=%d launch=%d` 可核对。
   - 相关旧 bug（11-27 15:03:45 修复）：guest 自己发动的卡，`/state.lastChainEvent` 文本会写成「**对手**发动 [...]」（同一时刻 `chainStack[0].isMine` 却是 true，因为 isMine 在 `mySeat` 错时恰好仍对）；升级后 guest 看到「我方发动」、host 看到「对手发动」。
10. **时点四态（11-27 11:04:58 版起）**：`chainMode` 取值与**官方语义**——
   - `0 all` = **全部时点**：任何时候都给窗口，不管有没有可用动作
   - `1 avail` = **全部可用时点**：只要有合法动作就询问
   - `2 ignore` = **无视所有时点**：不弹可选窗口、自动放弃；但**不会无视部分诱发效果**（强制/必发仍处理）
   - `3 normal` = **常用时点（进对局默认）**：`avail` 基础上再过滤掉一些非常用的询问（只问 spec/select-trigger 类窗口）

   `YGO_CHAIN_MODE` 默认 `normal`；`/ui?chain=` 支持 4 值；real 字段（`chainMode`/三布尔）**≤1s 刷新**；读当前值用 `control_state().ui.chainMode`（与 `/state.chainMode` 一致）。实现脚注：`duelclient.cpp:1886` 的 auto-decline 门（all 永不；avail 仅 `count==0`；normal `count==0||specount==0`；ignore 无条件，forced 除外）。

## 1. 先确认可用（30 秒）

1. MCP 工具里应能看到 `control_*` 共 **20** 个：`control_state`、`control_match`、`control_prompt`、`control_wait_prompt`、`control_act`、`control_ready`、`control_actions`、`control_act_id`、`control_lobby`、`control_deck`、`control_start`、`control_surrender`、`control_leave`、`control_chat`、`control_join`、`control_msg`、`control_health`、`control_net`、`control_side_move`、`control_side_done`。
2. `control_health` → `{"ok":true,...}` 说明客户端控制层在跑（host 7788，guest 7789）。
3. 没起来：让用户启动，或按第 6 节用脚本起（`ranked-loop.ps1` / `bo3-run.ps1`）。

> 只读安全：`control_state` / `control_prompt` / `control_lobby` / `control_actions` / `control_match` / `control_chat` / `control_msg` / `control_health` / `control_net`。会动 UI：`control_join` / `control_deck` / `control_ready` / `control_start` / `control_act_id` / `control_side_move` / `control_side_done` / `control_surrender` / `control_leave`。
>
> **掉线检查**：长回合/对手长考/等换备时**每 15–30s 调一次 `control_net`**（`alive`/`state`/`closeReason`/`sinceLastStoc`/`probe` + 新字段 `ourTurn/oppTurn/timeLeft/clockFresh`）；只有 `alive=false` 或 `state=confirmed_dead/disconnected` 才处理（`idle-no-packet`=被动静默判死、`disconnected`=socket 断、`probe_failed` 不算断线）。客户端 `net.heartbeat` 只在**空闲（`since>10s`）时每 15s** 打一条，连续操作时不打=正常，不是故障。

## 2. 一局的生命周期（照着走）

| # | 阶段 | 调用 | 判定成功（字段） | 失败/重试 |
|---|---|---|---|---|
| 1 | 排队拿房（仅线上） | `node $ROOT\bridge\get-room.mjs` | 拿到 `{address,port,password}` | 长轮询超时正常；**409 不正常**——见 §5（= 同账号并发）；30–60s 重试，8 次后停 5 分钟 |
| 2 | 进房 | `control_join(address,port,pass)` | `/net.connected && /net.joined` | 2s 重试；3 次失败回第 1 步 |
| 3 | 选卡组 | `control_deck(name)` | `control_lobby.deckMain>0` | 卡组不存在 → 列 `$ROOT\mycard-bot\game\deck\*.ydk` |
| 4 | 准备 | `control_ready()` | `control_lobby.ready[mySeat]==1` | 1–2s 重试 |
| 5 | **开始** | `control_start()` | `control_state.started==true` | 双方 ready ≠ 开局；2–3s 重发最多 30 次 |
| 6 | 先/后攻 | `control_prompt().tpPending` / `control_actions` 的 `kind:"tp"` → `control_act_id` | 日志 `TP choice res=` / `TP auto-answered`；2s 内不答会自动选 | **超过 13s 服务端踢人** |
| 7 | 对局决策 | `control_prompt`/`control_wait_prompt` → `control_actions` → `control_act_id(id, seq)` | `prompt.seq` 增长、`awaiting` 变化 | `awaiting=false` 不动；同 prompt 只回一次 |
| 8 | 一局结束 | 等 `state.match.games` 多一条 | `control_match.match.games[].reasonName` | 立刻 `control_match` 报告 |
| 9 | 换备（Bo3） | `state.side.pending` →（可选 `control_side_move`）→ `control_side_done()` | `/actions` 的 `changed/counts/sideError`；日志 `SIDE ok clicked`；`state.match.game` 递增 | label 三态（见下）；**两侧都要 side_ok**；张数不守恒会被拒 |

> **换备返回怎么读（11-27 17:09:18 版起）**：`/actions` 在 `sidePending` 时返回 `side_ok`，并在**顶格**带 `changed` / `counts{main,extra,side}` / `sideError`：
> - `label` 三态：`keep side deck (no changes) and continue` / `confirm side deck (changed) and continue` / `counts mismatch: fix main/extra/side counts before confirming`；
> - **`counts` 相等 ≠ 没换牌**（换出 A 换入 B 张数不变）——判断"换过没"用 **`changed`**；
> - `changed:true` 就说明已经生效，**别再重复 `side_move`**（会把 40/15/15 换重）；`sideError:"counts must match"` 时先补回守恒再 `side_ok`；
> - 旧版（≤15:03:45）label 写死 "no changes"（task-35/36 遗留），**看到 `no changes` 但 `changed:true` 就是旧版**，升级即可；新换备窗口 `changed` 会复位 false。
| 10 | 下一局 | 等 `DUEL_START reset (match game N)` | `started` 重新 true、`match.game` 递增 | TP 再来（2s 自动） |
| 11 | 整场结束 | 等 `state.match.over==true` | `control_match.summary` 给比分与原因 | 报用户，然后重排 |

## 3. 对局决策循环（核心）

```
while not state.match.over:
  s = control_state()               # 每回合开头读一次完整局面；之后不要反复全量读
  if not s.started: 处理开局/换备（表 1）
  p = control_prompt()              # 非阻塞快照；wait_prompt 只用来"等下一个待答窗口"
  if not p.awaiting: sleep 1–2s; continue
  a = control_actions()             # 新鲜：[{id, kind, label, seq}]；判进度用它
  control_act_id(选中的 id, seq=a.seq)
```

**`control_wait_prompt` 语义（BUG-2，`14:53:57` 已修）**：现版本=**阻塞到新的 `awaiting=true`**（`seq>since && awaiting`），超时返回最新快照；旧版（≤15:34:59）在 `awaiting=false` 时会立刻返回**旧快照**。所以：**判进度用 `control_state`/`control_actions`，轮询用 `control_prompt`，`wait_prompt` 只当"停下来等"**；回动作的 `seq` 用 `actions.seq`。

**选卡字节（BUG-3，`14:53:57` 已修并加 `resp`）**：`/prompt.selectableCards[].i` 是**列表下标**（只给 actions id 用）；**响应 hex 用 `resp`（= `seqNo`）**：`hex="01"+resp hex`（`resp=9` → `"0109"`）。**首选 `control_actions` 的 `kind:"select_card"` id**，别手拼 hex；`ctrl/isMine` 字段也已修正。

**打牌纪律 / 时间预算（必读，实测 TIMEOUT 判负）**：MC 回合时钟约 **240s**。
**⚠️ 单次工具往返实测 10–20s**（不是 3–10s；`control_actions` + `control_act_id` 一对就 20–40s）→ **一回合约 12–14 次调用的硬预算**（按 30 次规划会直接超时钟；2026-11-24 实测两次 TIMEOUT 判负就是这么来的）。

**「MCP 好慢」的真相（2026-11-25 实测）**：MCP 传输本身 **2–4ms**、控制层 HTTP **13–54ms**；慢的是 ①**LLM 每次工具调用的推理往返 10–20s**（占绝大部分）②**`control_wait_prompt` 按设计阻塞**——要等到"新的、`awaiting=true`"的 prompt 才返回（idle 时 `timeout=5000` 就等满 ~5006ms），**这是"等下一次询问"，不是卡死**。所以：等决策点用 `wait_prompt(timeout_ms=10000~30000)`，查现状用 `control_prompt`（2–3ms、~700B），判掉线用 `control_net`（别看 `wait_prompt` 耗时）；`timeout_ms` 别超 MCP 客户端的工具超时（DSH profile `toolCallTimeoutMs: 180000`）。详见 `MCP-INTERFACE.md` §5.11。
1. 开打前按卡组文档想好本回合展开线，**中途不查卡/不查文档**；
2. 只对没见过的卡现查，且**一次批量查完**；
3. 每回合开头读**一次** `control_state`，之后只在 `awaiting` 时「`control_actions` → 动作」，不要反复全量读；
4. 机械步骤（召唤→摆位→表示形式→攻击宣言）**一次连续做完**，别每步停下来思考；
5. 换备（`sidePending`）先想好再**一次性做完**（`side_ok` 一按就定）；**换备前先核对 main 里实际张数**，否则 `side_move` 会被拒
6. 打不完就及时 `to_ep`/结束战阶，**先保证不超时**；
7. **摆位：EMZ 的容量规则** —— 额外怪兽区每家只有 1 个；**非连接（非 Link）怪物只能占用其中 1 个**（Link 怪可以指到对面的 EMZ）。
   → 所以「优先 `seq=5|6`」只在 **EMZ 空着**时成立。第二只额外怪会**只能落主区 `seq=0..4`**。
   具体"哪只怪必须进 EMZ 才有价值"是**卡组策略，不在这里** —— 见卡组文档（本卡组的 `停止下注` 就是典型）。
8. **🔴 连锁窗口模式 `chainMode` —— 这才是 TIMEOUT 的真正机制**（2026-11-25 实测）
   **现象**：`ourTurn:false`（对方回合）期间**我的时钟 `timeLeft` 也在掉**（实测 240 → 37），并两次出现 `STOC_TIME_LIMIT`。
   **原因**：对方**每一个**效果都在我这边弹一次「是否连锁？」窗口，**每次应答都扣我的时钟**（10–20s/次）。
   更糟：**窗口里经常包含你其实接不了的卡** —— 每次误判都要多烧一次 10–20s 往返。
   ⚠️ **但"窗口出现"本身不是 bug**（我一开始误判成"桥接在非法时点弹出"，是错的）：
   YGO 有**自由时点 / 自由连锁（フリーチェーン）**，很多效果本来就能在几乎任何时点发动，窗口频繁是正常现象。
   **判断"能不能接"看两件事**：① 这张卡是几速；② 当前是不是在组建连锁中。
   - **2速以上**（`灰流丽` / `幽鬼兔` / `增殖的G` 这类**诱发即时效果**）→ 能连锁对方效果
   - **1速**（`效果遮蒙者` 是**起动效果**！「对方主要阶段…以对方场上1只表侧怪兽为对象才能发动」）→ **不能连锁**，只能在自由时点发动
   → 完整规则见知识库 `common/01_rules.md` §8.5；**别再把规则问题报成客户端 bug**。
   **处置（实测有效）**：用控制层 `/ui?chain=` 管住可选连锁窗口：
   ```
   GET /ui?chain=ignore    # 对方回合：不再弹可选连锁，止住刷屏、时钟不再被榨干
   GET /ui?chain=avail     # 自己回合：**必须切回来**，否则「抽到时特召」等自家效果接不到
   ```
   **⚠️ 权衡**：`ignore` 会**连合法手坑和自己家的可选诱发效果一起跳过**（灰流丽/遮蒙者/幽鬼兔，以及本家的「抽到时特召」「西艾萝抽卡」）→ **它是止损手段，不是默认**。
   推荐节奏：**开局 `avail` → 对方回合 `timeLeft` 掉得快（<150）或 prompt 刷屏 → `ignore` 止损 → ① 轮到自己第一件事就是切回 `avail`。**
   **🔴 最容易犯的错：切了 `ignore` 忘记切回 `avail`** —— 之后你**自己**的「抽到时→特召」等可选诱发会被客户端自动放弃，白丢展开（2026-11-25 实测吃亏）。
   **把「己方回合开始 → 切 avail」当成一条固定动作**，跟自己回合第一件事绑定。
   **四态定义（11-27 11:04:58 版起，官方口径）**：
   | 值 | 名称 | 行为语义 |
   |---|---|---|
   | 0 | `all`（全部时点） | 任何时候都给窗口，**不管有没有可用动作** |
   | 1 | `avail`（全部可用时点） | **只要有合法动作就询问**（all 之下过滤掉完全无动作的时点） |
   | 2 | `ignore`（无视所有时点） | 不弹可选窗口、自动放弃；**但不会无视部分诱发效果**（强制/必发类仍会处理） |
   | 3 | `normal`（常用时点，**进对局默认**） | **`avail` 的基础上再过滤掉一些非常用的询问**（只问 spec/select-trigger 类窗口） |

   - `/ui?chain=all|avail|ignore|normal` 四值都支持；`desiredChainMode` 立即变，`chainMode/三布尔`（real）**≤1s 刷新**（旧版空闲 guest 不刷新，已修）。
   - 代码实现（脚注）：`duelclient.cpp:1886` auto-decline 门——all 永不放弃；avail 仅 `count==0`；normal 在 `count==0 || specount==0`；ignore 无条件（forced 除外）。`count`=本窗口可发动数，`specount`=spec/常用触发数（`0x7f`=select-trigger 窗口）。
   - 读当前值用 `control_state().ui.chainMode` / `/ui`（`/state.chainMode` 与之一致）。
   **🔴 `normal(3)` 并不能解决"自由时点可选效果反复弹窗"（2026-11-27 实测，单场 **140 次**调用，目标 ≤40）**
   `normal` 只是"`avail` 再过滤**非常用询问**"，**不会**抑制"自由时点可选效果"的窗口。
   本卡组（Raise Moon）有 **16+ 张自由时点可选效果**（`库露雪`/`斯奎兹`/`西艾萝`/`辉煌`/`落胤与圣女`），
   **每给一次优先权就重新弹一次**；碰上速攻魔法多的对手（如 `神碑`/Runick）更被放大 ——
   它的速攻每回合都能发，**每个动作之间都插一个 chain 窗口**，一轮 decline 6–10 次，**连"结束回合"都要先 decline 掉窗口**。
   **实测花费结构：约 65% 是纯 decline 窗口。**
   → **这是结构性的，靠"少思考/少动作"解决不了。** 对策只有三条：
   ① 对方回合临时切 `ignore(2)`（实测省约 1/3 调用），**轮到自己立刻切回 `normal(3)`**；
   ② 同一窗口第 2 次重复就一次性 decline 到底，别反复犹豫；
   ③ 向桥接维护者提：**"同一 turn 内同一 code 只问一次"的记忆抑制**（若实现，调用数可直接砍约 60%）。
   **🔴 `ignore` 的实际表现（2026-11-27 更新）**：
   - **① 它不抑制 `curMsg 16 (SELECT_CHAIN)` 的自由时点重发** —— 即使 `chainModeName=ignore`，自由时点效果（如本家 `斯奎兹`/`落胤与圣女`/`辉煌`）的窗口仍会反复弹。所以 `ignore` **不能**解决"窗口反复"的调用量问题。
   - **② 我方诱发不再被吞（11-27 17:22:16 起）**：auto-decline 会先看本窗口候选里有没有**我方**的卡（`controler==0`）；有就**不自动放弃**，prompt 正常弹出。日志 `CHAIN client auto-decline ... ownCand=1 ignoreDecline=0` 即表示保住了我方窗口；`YGO_CHAIN_IGNORE_KEEP_OWN=0` 可恢复旧行为（会吞）。
   - 旧版（≤11-27 17:09:18）`ignore` 会连「抽到时→特召」「西艾萝抽卡」一起自动放弃（`CHAIN client auto-decline` + `PROMPT skip auto-handled`），白丢回合；升级即可。
   → **纪律**：`ignore` 仍只作**对方回合的止损**，轮到自己第一件事切回 `normal`/`avail` 并确认 `chainModeName`；**不要指望它压调用数**，减调用靠「同窗口第 2 次重复就一次性 decline 到下一事件」「必发效果直接按」「`to_bp` 失败重取一次」。

9. **🔴 自由时点的窗口会"重发"，能把预算打爆**（2026-11-25 实测：单回合 **44 次**调用，预算 12–14）
   典型：**速攻魔法**（如 `落胤与圣女`）在自由时点每给一次优先权就弹一次 → decline→再弹→再 decline，循环烧往返。
   **处置**：
   - **进主阶段前就想好"这个速攻要不要用"**，要就用掉、不用就一次性 decline 到下一事件，别反复犹豫；
   - 一回合内同一个窗口反复出现时，**考虑临时切 `ignore`** 直接止住（记得回合开始切回 `avail`）。
10. **🔴 选卡前必须重新取一次 `control_actions`**（防 id/下标错位）
   实测事故：按 `select_card #3`（对方的关键卡）提交，**结算却炸掉了自己场上的怪** —— 怀疑 prompt 与 actions 之间存在帧差，`selectableCards` 在两次调用间重排。
   **纪律**：① 拿到 `select_card` 列表后**立刻**提交，中间不插任何其它调用；② 若中间隔了别的调用（读局面/查日志），**必须重新 `control_actions` 再选**；③ 优先用 label 里带**卡名**的候选来核对，不要只凭 `code`/下标。

**表示形式（`MSG_SELECT_POSITION`）**：`/prompt.selectablePositions`（+`selectablePositionsHex`）是**合法 POS 掩码**：`0x1` 表侧攻击 / `0x2` 里侧攻击(set) / `0x4` 表侧守备 / `0x8` 里侧守备(set)。`/actions` 只给掩码内项，**按 label 选**（`attack position (face-up ATK)` / `defense position (face-up DEF)` / `defense position (face-down DEF / set)` …），`act_id` 会自动发正确 POS 值。**单 bit 掩码客户端自动应答、不出窗口**。旧版（≤11-27 17:09:18）把 defense 写死成 `0x02`（=里侧攻击，非法）→ 服务器不推进、同一 prompt 连发；升级即可。


**攻击目标（`/prompt.isAttackTarget==true`）必须用 `kind:"select_card"` 按 `atk/def` 选最优者**（`15:18:21` 起每个候选一条，label 带 `atk/def/loc/seq`）；**不要用 `select_auto` 或旧 `id=0`**——单目标时它们永远打第一只（旧版"有对象攻击不结算"的根因）。多选（`selectMin>1`）才用 `select_auto`。

**特殊响应**：`MSG_SORT_CARD` 用裸字节（`hex="0001"` 保持原序、无前缀；20:11:00 已实机验证 `hex=000102` 直连字节）；`MSG_SELECT_PLACE` 用 `(ctrl,loc,seq)` 三字节；`announce_*`（140–143）的 `announce_number` 响应=**数值本身**（不是下标，候选见 `/prompt.announceNumberValues`），`announce_race/attrib`=掩码、`announce_card`=卡号。

## 4. 结果汇报

每局/整场结束调 `control_match`，把 `summary` 告诉用户：

```json
{"match":{"game":2,"over":true,"games":[
  {"game":1,"win":false,"winnerSeat":1,"reason":1,"reasonName":"LP_ZERO"},
  {"game":2,"win":true,"winnerSeat":0,"reason":4,"reasonName":"DISCONNECT"}],
 "gamesWonLocal":1,"gamesWonOpp":1,"lastWinnerLocal":true,"lastReasonName":"DISCONNECT"},
 "summary":"比赛结束：你赢了这场 Bo3（2:1）。最后一局原因：对手掉线/失联（DISCONNECT）"}
```

原因：`SURRENDER`=投降、`LP_ZERO`=LP 归零、`DECK_OUT`=抽卡耗尽、`TIMEOUT`=超时、`DISCONNECT`=掉线；赢时"对手…"、输时"你…"。

## 5. 异常处理表

| 症状 | 判定 | 动作 |
|---|---|---|
| 进房 35s 没人来 | `control_lobby.playerCount<2` | 离开重排 |
| 对手回合长时间无包 | `turnPlayerLocal!=0` 且 `net.sinceLastStoc` 增长、`timeLeft` 冻结 | 180s 后离开重排 |
| `net.closeReason=="eof"` | 服务端主动断 | 本场作废重排；若刚 `tpPending` 过 → 就是 TP 超时 |
| **应答已发出后无任何 STOC + probe 连续超时 + `NET disconnected reason=error`** | **外部断线**（服务端/网络侧；不是自己操作问题）；`match.games` 可能为空 | `control_leave`/杀客户端后重排；第 2 次复现按 `PITFALLS-2026-11.md` 取证 |
| **回合被 `reason=3 TIMEOUT` 判负** | 240s 回合时钟被"查卡/翻文档/反复全量读"耗尽 | 按"打牌纪律"：先规划、机械步骤一次做完、每回合只读一次 `control_state`、快赢不下先保不超时 |
| 怀疑掉线（长回合/对手长考） | 每 15–30s `control_net` | `alive=false` 或 `state=confirmed_dead/disconnected` → 中止重排；`idle-no-packet`=被动静默判死、`disconnected`=socket 断；`probe_failed`/`fails` 增长不算断线 |
| 看起来没动静、但不像掉线 | `/net.stallMs` / `oppClockFresh` / `oppTimeLeft` | `stallMs>120000 && oppClockFresh=false` = **对方客户端/服务端卡住** → **`control_leave` 离桌重排（优先于 surrender）**；`oppClockFresh=true` 是对手长考，继续等（日志 `NET STALL`，`YGO_STALL_WARN_MS` 默认 120000；判读以 `oppClockFresh` 为准） |
| `eof` 前有 `PROMPT publish`、~88s 无 `SEND RESPONSE` | 未答 AFK（MC 排位 ~90s；LAN srvpro 是 180s TIMEOUT） | `10:25:14` 版 guard 60s 自动兜底；`/prompt.awaitingSinceMs` 看等待长度；LLM 60s 内必答 |
| **排队突然连续 `409`**（之前一直是正常长轮询，某刻起全是 409） | **① 先查并发**：起了两个 `queue-loop`，第二个把第一个顶成 409。**不是服务端故障、不是空池** | 查进程只留 1 个；多进程还会让房间 JSON 落在别人 stdout 里拿不到 |
| **确认只有 1 个队列，`409` 仍然不停**（尤其刚离开过"对手没进来的空房"之后） | **② 服务端 `playingPlayerPool` 残留**：我们被记在那个"创建了但从未开始"的房间里，客户端重启**清不掉**服务端状态 | **组合拳（2026-11-26 实测有效）**：① 杀 queue-loop；② `POST /leave`；③ **静置 ≥120 秒**（只等 60 秒不够，实测 409 连续 443 秒不停）；④ 重启客户端；⑤ 重排 → 恢复正常长轮询 |
| **进房后对手迟迟不来**（`playerCount<2`、`bothReady:false`） | 空房：配对成功但对手侧掉了 | **≥45 秒就 `control_leave` 重排**，别空等 60 秒以上（可用 `bridge\empty-room-guard.mjs`：45 秒守门，自动 leave 并以退出码 5 返回，调用方立刻重排）。**⚠️ 它的生命周期要足够长**：实测 804 秒就超时退出，而房间 20 分钟后才配上 → **没赶上，白挂**。要么把生命周期设到 **≥30 分钟**，要么**在房间 JSON 出现的那一刻才启动它** |
| **`control_join` 报 `connect-timeout`（客户端日志 `NETMSG id=1400 "无法连接到主机。"`），但 DNS 解析成功（`join: resolved -> 0x…`）** | **游戏服务器不可达**（TCP 层连不上，服务端侧宕机/维护），**不是房间失效、不是 409、不是我们太慢**（autojoin t+0 就 join 也照样失败） | **立刻停排**（配对服务还会给房间 JSON，但指向的服务器连不上，排了也进不去，还容易再搞出 `playingPlayerPool` 残留）。恢复判断：`Test-NetConnection -ComputerName tiramisu.moenext.com -Port 8911 -InformationLevel Quiet` 返回 `True` 再重排；**别拿排队次数试探服务器** |
| **排队 `/ygopro/match` 稳定 `400`**（body 空、`srv:nginx`、退避 5 分钟后单发仍 400） | **服务端侧拒斥**。已排除：凭证（`authUser` 200）、限流、burst、我们代码（Basic 头 base64 解码回原文一致） | **停排别空烧**，把首次出现时间/次数交给维护者。诊断脚本 `$ROOT\bridge\probe2.mjs` / `probe3.mjs` |
| **`control_join` 连上 ~80ms 就 `STOC_ERROR_MSG code=0x00090000`（`errorCode:589824`）、`joined:false`** | **房间已失效/被回收**（MC 房间是一次性的，配对后几十秒内不进就死）。不是密码错、不是超时 | **立刻重排，别反复 join 同一个房**；根因多半是"配对→进房"之间有人/B 的往返延迟 → 见 §7.5 |
| **`/state.errorMsg:1` + `errorCode:589824` 在整场健康对局里一直挂着**（`net.state:"healthy"`、prompt 正常） | `errorCode/errorMsg` **粘滞**（进房失败后不清），**不代表当前有错误** | 判当前是否出错看 `awaiting`/`prompt`/`net.state`，**别看 `errorCode`**；只有它**刚变化**时才有诊断意义 |
| **`awaiting:false` 时 `control_actions` 仍返回上一轮的 `chainCandidates`** | 动作列表残留（如"XX可以连锁"），此时发动作无效 | **只在 `awaiting:true` 时发动作**；`awaiting:false` 一律等 |
| 卡 `STOC_SELECT_TP` | `prompt.tpPending` | 立刻 `control_act_id`（13s 内） |
| 卡 `STOC_CHANGE_SIDE` | `state.side.pending` | 两侧 `control_side_done` |
| `side_ok` 报 `counts must match` | 换备不守恒 | 换回等量再 done |
| 攻击目标提交无效（旧版） | `curMsg` 15↔10 反复 | 升级 exe；否则降级直接攻击/to_m2/end_battle |
| 目标窗总是打第一只/选完不结算 | 旧版 `/actions` 只有一条 `select`（≤11:31:00） | 升级 `15:18:21+`；用 `kind:"select_card"` 显式选（`isAttackTarget=true` 时） |
| **guest（mySeat=1）时阵营反了**（自己手牌/候选/chain 卡 `isMine:false`、label 写成「对手[...]」、对方卡 `isMine:true`） | 旧版（≤11-23 14:53:57）把 `controler`（本地视角 0=我）直接和 `mySeat`（服务端座位）比较；host 时两者都 0 所以测不出 | 升级 `11-26 10:26:12+`（输出统一服务端座位，`isMine==(ctrl==mySeat)`）；判敌我只用 `isMine`/`ctrl==mySeat` |
| 排序 prompt 死循环 | `curMsg==25` 反复 | `control_act({seq, hex:"0001"})` 裸字节重发；20:11:00 已改直连字节 |
| 卡在 `curMsg==143`、`awaiting=false` | 旧版 announce prompt 未发布 | 升级 20:11:00+；用 `/actions` 的 `announce_number`（数值本身）/`announce_race/attrib/card` |
| `stale action id` | `/act_id` 的 seq 旧了 | 重新 `control_actions` 再发 |
| `confirmed_dead` 误判 | 我方回合思考>10s | 旧版设 `YGO_NET_DEAD_SILENCE_MS=600000`；当前版用默认 60000（最多 120000），别 600000 |
| 一直 `NET ALIVE reason=our-turn-idle timeLeft=240`、无 NET DEAD | 旧版 `clockRunning` 用过期 `g_timeLeft`（看门狗 bug） | 升级 `17:33:31+`（`clockFresh` 3s 内刷新才算）；用 `control_net` 主动查 `alive/sinceLastStoc/closeReason` |
| `NET DEAD reason=probe-fails` → `disconnected error` | 旧版 probe 独立 2 次阈值误判（对手长展开 ~7.5s 静默） | 升级 `11:31:00+`（probe 失败只降级）；旧版 `YGO_NET_PROBE=0` 规避或 `YGO_NET_PROBE_FAIL_MAX` 调大 |
| `/net.state=="probe_failed"` 但 `alive=true` | 新版正常（probe 让位守卫，logs `NET probe deferred ...`） | 不用处理，继续对局 |
| MC API 连续超时 8 次 | 排队失败 | 停 5 分钟再试 |
| `state.started==false` 但 ready=1/1 | 没人发 HS_START | 继续 2–3s `control_start()` |

## 6. 无人值守跑分

```powershell
cd $ROOT
$env:YGO_NET_DEAD_SILENCE_MS = '60000'       # 当前版默认 60000（最多 120000，不要 600000；旧 exe 才 600000）
$env:YGO_NET_PROBE_FAIL_MAX = '5'            # probe 失败仅降级/日志（11:31:00 版默认 5；旧版可用 YGO_NET_PROBE=0 关探活）
$env:YGO_PROMPT_AUTO_DEFAULT_MS = '60000'   # EOF guard（10:25:14 版默认即 60000；0=关，不建议）
$env:YGO_PROMPT_IDLE_WARN_MS = '45000'      # 空闲告警（默认 45000）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\ranked-loop.ps1 `
  -Runs 3 -MaxMinutesPerMatch 25 -MaxTotalMinutes 240 -Deck <卡组> `
  -ShotEverySec 10 -StallSec 120 -SilentAbortSec 180 -EmptyRoomSec 35
```

- 连击持久化：`ranked\logs\streak.json`；证据：`ranked\logs\loop-<stamp>\`（`run.log`/`summary.json`/`shots/`）
- LAN 验证：`bridge\bo3-run.ps1`、`bridge\verify-match-state.ps1`；测试专用 env：`YGO_TP=1`、`YGO_SIDE_AUTO=1`（排位不要设）

## 7. 报告风格

说清楚：第几局、谁赢、原因（翻译）、大比分、是否结束；有截图就配图；输赢如实说；失败给判定依据（字段/日志行）。

## 7.5 ★★★ 多 agent / subagent 打排位（实测有效，但有铁律）

> 背景：主会话上下文一大，每次工具往返就慢（实测 **10–20s/次**），一回合 12–14 次调用就把 240s 时钟吃光 → 必然 TIMEOUT。
> **解法：用上下文干净的子 agent（subagent/teammate）去打。** 实测同一个模型，新会话从开工到开打只要几分钟，而且没超时。

### 铁律 1：**配对和进房必须是同一个执行者**
实测：主会话排到房（17:31:25）→ 把房间 JSON 转给子 agent → 40–50 秒后才 join →
**两次都被 `STOC_ERROR_MSG code=0x00090000`（`errorCode:589824`）拒**，同时 server chat 显示「主机密码不正确 (Unauthorized)」。
**MC 的房间是一次性的，配对后几十秒内不进去就死。**
→ **A 排队 B 进房必然失败**。要么让同一个 agent 全包，要么用下面的 autojoin。

### 铁律 2：**账号任何时刻只能有 1 个队列进程**
两个 `queue-loop` 并发 → 服务端返回 **`status=409`**（不是故障、不是空池）。
而且多进程时房间 JSON 会落在**别人的** stdout 里，你拿不到。
→ 交接前先查：`Get-Process node`，只留 1 条 `bridge\queue-loop.mjs`。

### 推荐架构：`autojoin` 一条龙（实测一次成功）
子 agent 写一个 watchdog（如 `bridge\autojoin.mjs`）：
1. **盯队列日志文件**（把 `queue-loop` 的 stdout 重定向到 `ranked\queue-*.out.log`）
2. 一旦出现房间 JSON，**在同一次轮询里**完成 `control_join → control_deck → control_ready → control_start`
3. 实测：`ROOM FOUND → JOINED → deck → ready` 全在 **2 秒内**，**无人工往返**

**配套要点**：
- 续跑队列时**复用同一个 out 日志文件**，这样 watchdog 不用重启（少一个环节少一个出错点）
- `queue-loop` 写 stderr、房间 JSON 写 stdout —— 分别重定向到 `.out.log` / `.err.log`，别搞混
- 读房间 JSON 用 `JSON.parse`，**不要肉眼看** `name` 字段（可能是 GBK 乱码；`address/port/password` 是 ASCII 没问题）

### 分工建议
| 角色 | 干什么 |
|---|---|
| 子 agent（干净上下文） | **排队 + autojoin + 打完整场 + 汇报**（一回合 ≤12–14 次调用） |
| 主 agent | 不做任何客户端动作（出手慢会超时），只做转述/决策把关/改 skill |

### 汇报要求（子 agent 交给主 agent）
比分（`control_match` 原文）/ 每局原因 / 对手卡组 / **有没有超时** / **每回合调用次数** / 新 BUG（带字段或日志行）/ **自己的失误（如实，别美化）**

---

## 8. 更多细节

- **同目录 `PLAYBOOK-FULL.md`**：20 个工具逐个、每阶段返回示例、字段字典、计时表、真实 run、21 行排错表
- `$ROOT\bridge\docs\MCP-INTERFACE.md`、`$ROOT\mycard-client\docs\CONTROL-API.md`、`$ROOT\bridge\docs\RANKED-REPORT.md`
