---
name: ygopro-play
description: 用 MCP 控制层真实操作 YGOPro 客户端打牌（MC 线上排位 / 局域网 / 单人测试）。当用户说「帮我打一局游戏王」「用 MCP 打排位」「操控 YGOPro」「陪我在 MC 打一局」「跑 Bo3 测试」「看看我客户端现在什么状态」时使用。覆盖：状态查询、排队进房、选卡组、准备、开局、先后攻、对局决策循环、换备牌、整场结果汇报、异常（空房/对手静默/掉线/卡住）处理与无人值守跑分。细节以同目录 PLAYBOOK-FULL.md 与仓库 docs/MCP-INTERFACE.md 为准。
---

# YGOPro 实操：用 MCP 控制层打一局

**工作区**：`D:\dsh_workspaces\MC_bot_dsh`（下称 `$ROOT`）
**权威细节**：`$ROOT\bridge\docs\PLAYBOOK-FULL.md`（全流程逐步 + 每步返回字段 + 排错）
**接口规范**：`$ROOT\bridge\docs\MCP-INTERFACE.md` ｜ 客户端 HTTP：`$ROOT\mycard-client\docs\CONTROL-API.md`
**不要**：直接调客户端内部接口绕过 MCP/控制层、猜结果、手改客户端状态。

## 0. 先确认可用（30 秒）

1. MCP 工具里应能看到 `control_*` 共 **18** 个：`control_state`、`control_match`、`control_prompt`、`control_wait_prompt`、`control_act`、`control_ready`、`control_actions`、`control_act_id`、`control_lobby`、`control_deck`、`control_start`、`control_surrender`、`control_chat`、`control_join`、`control_msg`、`control_health`、`control_side_move`、`control_side_done`。
2. `control_health` → `{"ok":true,...}` 说明客户端控制层在跑（host 端口 7788，guest 7789）。
3. 没起来：让用户启动，或按第 6.1 用脚本起客户端（`$ROOT\bridge\ranked-loop.ps1` / `bo3-run.ps1`）。

> 只读查询永远安全：`control_state` / `control_prompt` / `control_lobby` / `control_actions` / `control_match` / `control_chat` / `control_msg` / `control_health`。阻塞等待下一条 prompt 用 `control_wait_prompt(since=上一个 seq)`。会动 UI 的：`control_join` / `control_deck` / `control_ready` / `control_start` / `control_act_id` / `control_side_move` / `control_side_done` / `control_surrender`。

## 1. 一局的生命周期（照着走）

| # | 阶段 | 调用 | 判定成功（字段） | 失败/重试 |
|---|---|---|---|---|
| 1 | 排队拿房（仅线上） | 跑 `node $ROOT\bridge\get-room.mjs` | stdout 拿到 `{address,port,password}` | 超时/409 属正常长轮询；每 30–60s 重试，最多 8 次后停 5 分钟 |
| 2 | 进房 | `control_join(address, port, pass)` | `control_state` 里 `inDuel` 前先看 `/net`：`connected=true && joined=true` | 等 2s 重试；3 次失败 → 房间已关，回第 1 步 |
| 3 | 选卡组 | `control_deck(name)` | `control_lobby.deckMain>0` 或日志 `deck: load ... ok=1` | 卡组名不存在 → 列出 `$ROOT\mycard-bot\game\deck\*.ydk` 让用户选 |
| 4 | 准备 | `control_ready()` | `control_lobby.ready[mySeat]==1` | 1–2s 一次、可无限重试（准备窗未建好会吞点击） |
| 5 | **开始** | `control_start()` | `control_state.started==true` | **双方 ready 不会自动开局**；2–3s 一次直到 started，最多 30 次 |
| 6 | 先/后攻 | `control_state().prompt.tpPending` 或 `control_actions` 里 `kind:"tp"` → `control_act_id(id)` | 日志 `TP choice res=1/2`、随后 `state.started=true` | 不选会卡在 `STOC_SELECT_TP` |
| 7 | 对局决策 | 见第 2 节循环（`control_prompt`/`control_wait_prompt` → `control_actions` → `control_act_id`） | 每次动作后 `prompt.seq` 增长、`awaiting` 变化 | `awaiting=false` 时**不要**发动作；同一条 prompt 只回一次（`seq` 去重） |
| 8 | 一局结束 | 等 `state.winPlayer>=0` 或 `state.match.games` 多一条 | `control_match.match.games[].reasonName` | 立刻调 `control_match` 向用户报告本局结果 |
| 9 | 换备（Bo3） | `control_state.side.pending==true` → （可选 `control_side_move`）→ `control_side_done()` | 日志 `SIDE ok clicked`；之后 `state.match.game` 变 2 | 两侧都必须 side_ok；张数不一致会被拒（`counts must match`），换回等量 |
| 10 | 下一局 | 等 `DUEL_START reset (match game N)` | `state.started` 重新变 true、`state.match.game` 递增 | TP 会再次出现 |
| 11 | 整场结束 | 等 `state.match.over==true`（`STOC_DUEL_END`） | `control_match` 的 `summary` 给出比分与最后一局原因 | 然后 `control_state` 确认 `over`，通知用户，`/leave` 后再排下一场 |

### 阶段 1 补充：线上排队语义
`/ygopro/match` 是**长轮询**（服务端挂住请求直到配对成功）。我们的 `get-room.mjs` 已经用原生 https 等 10 分钟；**不要**用 20s 超时反复重排、也不要用 `cancel=1`（服务端不认）。拿到房后房间密码有时效，尽快 join。

## 2. 对局决策循环（核心）

```
while 对局没结束:
  s = control_state()
  if s.match.over: break                 # 整场结束
  if s.started == false: 处理开局/换备/TP（第 1 节）
  p = control_prompt()             # 或 control_wait_prompt(since=上次seq, timeout_ms=15000) 阻塞等到新 prompt
  if not p.awaiting: 等 1–2s 后 continue   # 对手回合/连锁在对方，不要动作
  a = control_actions()                   # [{id, kind, label, ...}]
  选择 id = 决策(a, s)                     # 见下
  control_act_id(id)
```

**怎么选动作**（`control_actions` 返回的每个 action 都有 `id` 和 `kind`）：
- `kind:"yesno"`：只有 2 个（是/否），按卡牌效果收益选；不确定时选"是"通常更安全（无效效果/放弃连锁时才选否）。
- `kind:"option"`：多选一（效果/卡牌选项），label 里是效果文本，按效果强度选。
- `kind:"card"` / `kind:"place"`：需要 `control_prompt` 的 `selectableCards`/`selectableCount` / `placeOptions`；也可用 `control_act(kind, hints)` 让桥接层按提示挑。
- `kind:"chain"`：是否连锁；有可用的反制/收益就链，没有就 `i=-1` 的选项（不连锁）。
- `kind:"position"`：攻/守/里侧；按场面选。
- `kind:"idlecmd"`：主阶段行动（召唤/发效果/进战阶/结束）；优先做能赢的展开。
- `kind:"side_ok"`：换备完成，见第 1 节第 9 步。
- `kind:"tp"`：先后攻，`index=1` 先攻 / `index=2` 后攻（按 `id` 传）。

**不要做**：
- 不要凭 `winPlayer` 猜整场结果 → 用 `control_match`。
- 不要在 `awaiting=false` 时发 `control_act_id`。
- 不要自己拼 `/act_id` 的 id（必须来自最近一次 `control_actions`）。

## 3. 结果汇报（给用户的话）

每局结束、整场结束都调 `control_match`，把 `summary` 原样或稍作润色告诉用户：

```json
{"match":{"game":2,"over":true,"games":[
  {"game":1,"win":false,"winnerSeat":1,"reason":1,"reasonName":"LP_ZERO"},
  {"game":2,"win":true,"winnerSeat":0,"reason":4,"reasonName":"DISCONNECT"}],
 "gamesWonLocal":1,"gamesWonOpp":1,
 "lastWinnerLocal":true,"lastReasonName":"DISCONNECT"},
 "summary":"比赛结束：你赢了这场 Bo3（2:1）。最后一局原因：对手掉线/失联（DISCONNECT）"}
```

原因翻译：`SURRENDER`=投降、`LP_ZERO`=LP 归零、`DECK_OUT`=抽卡耗尽、`TIMEOUT`=超时、`DISCONNECT`=掉线/失联；赢的时候是"对手…"，输的时候是"你…"。

## 4. 异常处理表

| 症状 | 判定 | 动作 |
|---|---|---|
| 进房后 35s 没人来 | `control_lobby.playerCount<2` | 离开重排（线上）；规则：**35 秒没人进房就退出重排** |
| 对手回合长时间无包 | `state.turnPlayerLocal!=0` 且 `net.sinceLastStoc` 持续增长、`timeLeft` 冻结 | 180s 后离开重排；不要一直等 |
| `net.closeReason=="eof"` | 服务端主动断开 | 本场作废（外部原因），重排；连续 eof 检查是否我们发了非法动作（看客户端日志 `SEND RESPONSE realMsg=`） |
| 卡在 `STOC_SELECT_TP` | `state.prompt.tpPending` | 调 `control_act_id` 选先后攻 |
| 卡在 `STOC_CHANGE_SIDE` | `state.side.pending` | 两侧 `control_side_done` |
| `side_ok` 返回 `counts must match` | 换备张数不守恒 | 换回等量（`control_side_move` 反向）再 done |
| 动作没生效 / `seq` 不涨 | `/prompt` 仍是同一 prompt | 等 300ms 重发一次；两次无效则查 `/ui.windowsVisible` 是否被弹窗挡住 |
| `stale room` | 拿到的是上一场的旧密码 | 等 20s 重排（线上） |
| MC API 连续超时 8 次 | 排队失败 | 暂停 5 分钟再试（凌晨/早间常见） |
| `state.started==false` 但双方 ready=1/1 | 没人发 HS_START | 继续每 2–3s `control_start()`，直到 `started==true` |

## 5. 无人值守跑分（用户要"连续打 N 场"时）

直接用现成脚本，不要手搓循环：

```powershell
cd $ROOT
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\ranked-loop.ps1 `
  -Runs 3 -MaxMinutesPerMatch 25 -MaxTotalMinutes 240 -Deck <卡组> `
  -ShotEverySec 10 -StallSec 120 -SilentAbortSec 180 -EmptyRoomSec 35
```

- 连击进度持久化在 `$ROOT\ranked\logs\streak.json`，重启会 `resume consecutive streak N/M`
- 证据/截图：`$ROOT\ranked\logs\loop-<stamp>\`（`run.log`、`summary.json`、`shots/`、每场 `match.json`）
- 局域网验证用 `bridge\bo3-run.ps1`；`/state.match` 端到端自检用 `bridge\verify-match-state.ps1`（LAN 下建议两个客户端都设 `YGO_TP=1`、`YGO_SIDE_AUTO=1`，这是测试专用 env，排位不要设）

## 6. 报告风格（给用户）

- 说清楚：**第几局、谁赢、为什么（原因翻译）、大比分、整场是否结束**。
- 有截图就配图（`ranked/logs/loop-*/shots/*.png`）。
- 输赢如实说；不要因为"打完了"就说赢。
- 失败时给出判定依据（字段/日志行），不要猜。

## 7. 更多细节

- 完整逐字段说明、18 个 MCP 工具的参数/返回示例、真实 run 时间线、21 行排错表：**同目录 `PLAYBOOK-FULL.md`**（本 skill 自带一份）
- 接口规范：`$ROOT\bridge\docs\MCP-INTERFACE.md`
- 客户端 HTTP 字段：`$ROOT\mycard-client\docs\CONTROL-API.md`
- 排位实战记录：`$ROOT\bridge\docs\RANKED-REPORT.md`
