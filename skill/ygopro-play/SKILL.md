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
2. **判死阈值**：旧版（≤2026-11-15 19:05:42）默认 10s，会把"自己回合思考中"误判 `confirmed_dead` → 管线冻结 → 被踢，**旧版启动必须设 `YGO_NET_DEAD_SILENCE_MS=600000`**；当前版默认 60s 且**我方回合/倒计时/awaiting 时永不判死**（`NET ALIVE reason=our-turn-idle`）。**另一旧版 bug：`/tip` probe 2 次超时即 `NET DEAD reason=probe-fails`+断线**（对手长展开 ~7.5s 被误踢）；`11:31:00` 起 probe 失败只降级 `probe_failed`（`YGO_NET_PROBE_FAIL_MAX=5` 仅日志/降级），判死走被动静默。旧版可用 `YGO_NET_PROBE=0` 规避。
3. **MSG_SORT_CARD（洗牌/排序）响应是裸位序字节、无长度前缀**：两张卡保持原序 = `hex="0001"`；用 `control_act({seq, hex})`，**不要**加计数前缀（会死循环）。
4. **多怪兽攻击目标**：旧版会核心拒绝（`curMsg` 15↔10 反复、攻击消耗但不结算）；新 exe 已修（见 PLAYBOOK-FULL §3.7.2），若仍遇到就降级：直接攻击 / `to_m2` / `end_battle`。
5. **announce 140–143**：旧版 `curMsg=143` 前会 `awaiting=false` 卡住；新 exe（20:11:00+）`/actions` 提供 `announce_race/announce_attrib/announce_card/announce_number`，编码 **race/attrib=掩码、card=卡号、number=数值本身**（候选见 `/prompt.announceNumberValues`）。
6. **`awaiting=false` 不发动作**；同一条 prompt 只回一次（`seq` 去重）；`/act_id` 带 `seq=` 防过期。
7. **整场胜负只信 `control_match`**，不要用 `winPlayer` 推。
8. **EOF guard（10:25:14 版起）**：prompt 空等 ~90s 会被 MC 排位按 AFK `eof` 踢；`YGO_PROMPT_AUTO_DEFAULT_MS`（默认 60000，0=关）45s 打 `PROMPT idle warning`、60s 自动发保守默认（`PROMPT auto-default ... (idle guard, LLM silent)`）。**超 60s 没答会被 guard 顶掉（保守动作），但别依赖它——正常要快**；`/prompt.awaitingSinceMs` 可看等待时长。

## 1. 先确认可用（30 秒）

1. MCP 工具里应能看到 `control_*` 共 **18** 个：`control_state`、`control_match`、`control_prompt`、`control_wait_prompt`、`control_act`、`control_ready`、`control_actions`、`control_act_id`、`control_lobby`、`control_deck`、`control_start`、`control_surrender`、`control_chat`、`control_join`、`control_msg`、`control_health`、`control_side_move`、`control_side_done`。
2. `control_health` → `{"ok":true,...}` 说明客户端控制层在跑（host 7788，guest 7789）。
3. 没起来：让用户启动，或按第 6 节用脚本起（`ranked-loop.ps1` / `bo3-run.ps1`）。

> 只读安全：`control_state` / `control_prompt` / `control_lobby` / `control_actions` / `control_match` / `control_chat` / `control_msg` / `control_health`。会动 UI：`control_join` / `control_deck` / `control_ready` / `control_start` / `control_act_id` / `control_side_move` / `control_side_done` / `control_surrender`。

## 2. 一局的生命周期（照着走）

| # | 阶段 | 调用 | 判定成功（字段） | 失败/重试 |
|---|---|---|---|---|
| 1 | 排队拿房（仅线上） | `node $ROOT\bridge\get-room.mjs` | 拿到 `{address,port,password}` | 长轮询超时/409 正常；30–60s 重试，8 次后停 5 分钟 |
| 2 | 进房 | `control_join(address,port,pass)` | `/net.connected && /net.joined` | 2s 重试；3 次失败回第 1 步 |
| 3 | 选卡组 | `control_deck(name)` | `control_lobby.deckMain>0` | 卡组不存在 → 列 `$ROOT\mycard-bot\game\deck\*.ydk` |
| 4 | 准备 | `control_ready()` | `control_lobby.ready[mySeat]==1` | 1–2s 重试 |
| 5 | **开始** | `control_start()` | `control_state.started==true` | 双方 ready ≠ 开局；2–3s 重发最多 30 次 |
| 6 | 先/后攻 | `control_prompt().tpPending` / `control_actions` 的 `kind:"tp"` → `control_act_id` | 日志 `TP choice res=` / `TP auto-answered`；2s 内不答会自动选 | **超过 13s 服务端踢人** |
| 7 | 对局决策 | `control_prompt`/`control_wait_prompt` → `control_actions` → `control_act_id(id, seq)` | `prompt.seq` 增长、`awaiting` 变化 | `awaiting=false` 不动；同 prompt 只回一次 |
| 8 | 一局结束 | 等 `state.match.games` 多一条 | `control_match.match.games[].reasonName` | 立刻 `control_match` 报告 |
| 9 | 换备（Bo3） | `state.side.pending` →（可选 `control_side_move`）→ `control_side_done()` | 日志 `SIDE ok clicked`；`state.match.game` 递增 | 两侧都要 side_ok；张数不守恒会被拒 |
| 10 | 下一局 | 等 `DUEL_START reset (match game N)` | `started` 重新 true、`match.game` 递增 | TP 再来（2s 自动） |
| 11 | 整场结束 | 等 `state.match.over==true` | `control_match.summary` 给比分与原因 | 报用户，然后重排 |

## 3. 对局决策循环（核心）

```
while not state.match.over:
  s = control_state()
  if not s.started: 处理开局/换备（表 1）
  p = control_prompt()              # 或 control_wait_prompt(since=上次seq, timeout_ms=15000)
  if not p.awaiting: sleep 1–2s; continue
  a = control_actions()             # [{id, kind, label, ...}]
  control_act_id(选中的 id, seq=p.seq)
```

选动作：`yesno` 按收益；`option` 按效果；`card/place` 用 prompt 里的 `selectableCards/placeOptions`（旧版 select 有攻击目标 bug，新 exe 已修）；`chain` 有反制才链；`position` 按场面；`idlecmd` 展开/结束；`side_ok` 见第 2 节第 9 步；`tp` 必须快。

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
| `eof` 前有 `PROMPT publish`、~88s 无 `SEND RESPONSE` | 未答 AFK（MC 排位 ~90s；LAN srvpro 是 180s TIMEOUT） | `10:25:14` 版 guard 60s 自动兜底；`/prompt.awaitingSinceMs` 看等待长度；LLM 60s 内必答 |
| 卡 `STOC_SELECT_TP` | `prompt.tpPending` | 立刻 `control_act_id`（13s 内） |
| 卡 `STOC_CHANGE_SIDE` | `state.side.pending` | 两侧 `control_side_done` |
| `side_ok` 报 `counts must match` | 换备不守恒 | 换回等量再 done |
| 攻击目标提交无效（旧版） | `curMsg` 15↔10 反复 | 升级 exe；否则降级直接攻击/to_m2/end_battle |
| 排序 prompt 死循环 | `curMsg==25` 反复 | `control_act({seq, hex:"0001"})` 裸字节重发；20:11:00 已改直连字节 |
| 卡在 `curMsg==143`、`awaiting=false` | 旧版 announce prompt 未发布 | 升级 20:11:00+；用 `/actions` 的 `announce_number`（数值本身）/`announce_race/attrib/card` |
| `stale action id` | `/act_id` 的 seq 旧了 | 重新 `control_actions` 再发 |
| `confirmed_dead` 误判 | 我方回合思考>10s | 设 `YGO_NET_DEAD_SILENCE_MS=600000`（新 exe 默认已修） |
| `NET DEAD reason=probe-fails` → `disconnected error` | 旧版 probe 独立 2 次阈值误判（对手长展开 ~7.5s 静默） | 升级 `11:31:00+`（probe 失败只降级）；旧版 `YGO_NET_PROBE=0` 规避或 `YGO_NET_PROBE_FAIL_MAX` 调大 |
| `/net.state=="probe_failed"` 但 `alive=true` | 新版正常（probe 让位守卫，logs `NET probe deferred ...`） | 不用处理，继续对局 |
| MC API 连续超时 8 次 | 排队失败 | 停 5 分钟再试 |
| `state.started==false` 但 ready=1/1 | 没人发 HS_START | 继续 2–3s `control_start()` |

## 6. 无人值守跑分

```powershell
cd $ROOT
$env:YGO_NET_DEAD_SILENCE_MS = '600000'
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

## 8. 更多细节

- **同目录 `PLAYBOOK-FULL.md`**：18 个工具逐个、每阶段返回示例、字段字典、计时表、真实 run、21 行排错表
- `$ROOT\bridge\docs\MCP-INTERFACE.md`、`$ROOT\mycard-client\docs\CONTROL-API.md`、`$ROOT\bridge\docs\RANKED-REPORT.md`
