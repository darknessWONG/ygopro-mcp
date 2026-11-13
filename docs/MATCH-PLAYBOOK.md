# 对局操作手册（给 AI / agent）

> 这份文档回答一个问题：**一个 AI 要“亲手”在 YGOPro 客户端里打完一场排位/局域网 Bo3，按什么顺序调什么接口、每步等到什么状态才算成功、卡住了怎么办。**
> 接口字段细节见 [`MCP-INTERFACE.md`](MCP-INTERFACE.md)（MCP 工具层）与客户端仓库的 `docs/CONTROL-API.md`（HTTP 层）。
> 参考实现：[`../ranked-loop.ps1`](../ranked-loop.ps1)（排位连续跑）、[`../bo3-run.ps1`](../bo3-run.ps1)（本机 Bo3）、[`../lan-run.ps1`](../lan-run.ps1)（局域网）。

## 0. 一句话状态机

```
排队/拿房 → 进房 → 选卡组 → 准备(ready) → 双方 ready 后开始(start)
   → 先/后攻(TP) → 对局决策循环 …
   → 一局结束(MSG_WIN) →【换备牌阶段 CHANGE_SIDE】→ 换备 + 完成换备(side_ok)
   → 下一局(DUEL_START) → TP → 决策循环 …
   → 整场结束(STOC_DUEL_END) → 离开房间 → 重新排队
```

**最容易错的点**：`ready` 和 `start` 是**两个动作**。双方都显示 ready **不会自动开局**，必须有人发 `HS_START`（我们客户端用 `/start`），并且要一直轮询到 `state.started == true` 才算成功。

---

## 1. 进房前：排队拿房（线上排位）

```bash
node bridge/get-room.mjs            # MC_ACCOUNT_ID 固定账号；返回 address/port/password
```

- 返回 409 / 超时：说明账号**还在上一场没结束的房间/对局里**（或被队列占用）。先确认上一场是否真的结束（`/state.started=false` + `STOC_DUEL_END`），再重试；必要时用官方客户端把残留对局退掉。
- 拿到房后**立刻** `/join`（房间密码有时效）。

## 2. 进房并选卡组

| 步骤 | 调用 | 判定成功 | 备注 |
|---|---|---|---|
| 进房 | `GET /join?ip=<addr>&port=<port>&pass=<pwd>` | `/net.connected==true && /net.joined==true`（或 `/ui.windowsVisible` 不再有 `wLanWindow`） | 只填窗口不点“加入游戏”会看起来“进了”其实没进 → 必须用 `connected+joined` 判定 |
| 选卡组 | `GET /deck?name=<卡组名>` | 日志 `deck: load '<名>' ok=1 main=..` / `/lobby.deckMain>0` | 卡组要在客户端 `game/deck/` 里存在；换备测试要用带 `!side` 的卡组 |
| 准备 | `GET /ready` | `/lobby.ready[mySeat]==1` | **可重试**：准备窗没建好时第一次点击会丢，建议每 1–2s 调一次直到 ready=1 |

## 3. 开局：双方 ready 之后必须“开始”

| 步骤 | 调用 | 判定成功 | 备注 |
|---|---|---|---|
| 开始 | `GET /start` | `/state.started==true` | **双方 ready ≠ 开局**。要每 2–3s 发一次、直到 `started=true`（有 host 权限的一方发；排位房一般由服务端/房主推进，但重复发是安全的） |
| 开局后 | `GET /state` | `started=true`，`turn` 开始增长 | 若 `duel did NOT start` 超时：看 `/lobby.ready`（是否真 ready）、`/lobby.playerCount`（是否只有自己 → 空房：**进房 35s 内没人进来就 `/leave` 重排**） |

> 典型故障：截图里“双方都 ✓ 但没开始”= 只做了 ready、没做 start（或 start 发得太早，之后没重试）。

## 4. 先/后攻（TP）

开局前会出现合成 prompt：`/prompt.tpPending=true`、`/actions` 里有 `{"kind":"tp","index":1|2}`。

```
GET /act_id?id=0     # 先攻（index=1）
GET /act_id?id=1     # 后攻（index=2）
```

判定：客户端日志 `TP choice res=1 (from control)`，随后 `state.started=true`。

## 5. 对局中：决策循环

```
循环 {
  GET /prompt     → awaiting=true 才需要动作
  GET /actions    → 拿 [{id,kind,label,...}]
  GET /act_id?id=<选中的 id>
  （等下一条 prompt / 或对手回合时等待）
}
```

- `awaiting=false` 表示**现在不需要你动作**（通常是对手回合或连锁在对手那边）——不要乱发 `/act_id`。
- 看到 `/prompt.tpPending` → 走第 4 节；看到 `/prompt.sidePending` → 走第 6 节。
- 若 `awaiting=true` 且 `/actions` 为空持续 >30s：先查 `/ui.windowsVisible` 是否有阻塞窗（`wQuery/wCardSelect/...`），再看 `/state.pipeline` 与客户端日志；这是客户端 bug，不是"该等"。

## 6. 一局之间：换备牌（Bo3 关键步骤）

一局结束（`MSG_WIN`）后，服务端会在 match 模式下发 `STOC_CHANGE_SIDE`：

```
GET /state                     → side.available=true, side.pending=true
GET /state.side.main/extra/side → 各区按卡号聚合的 [{code,name,count}]
GET /state.side.counts/pre/limits
```

**换牌（可选）**：

```
POST /side_swap?code=<卡号>&from=side&to=main&n=1     # 换入
POST /side_swap?code=<卡号>&from=main&to=side&n=1     # 换出（保持各区张数不变）
```

**完成换备（必须做，否则停在这）**：

```
GET /actions                 # 只有一条 {"id":0,"kind":"side_ok",...}
GET /act_id?id=0             # = 点真实 btnSideOK / MCP: control_side_done
```

判定成功：客户端日志 `SIDE ok clicked (from control)`。
失败语义：
- `{"ok":false,"error":"counts must match"}` → 主/额外/副卡组张数与进来时不一致，换回等量再试；
- `{"ok":false,"error":"side swap pending, retry"}` → 上一个 swap 还没执行，等 100–300ms 重试；
- `{"ok":false,"error":"side prompt not published yet, retry"}` → 等 100–300ms 重试。

**换备后等对手**：`/state.side.waiting=true` 表示"自己已确认、对手还没确认"。

- `waiting` 是瞬时值，LAN 实测常 0–16ms；要判断是否等过对手用 sticky 字段 `waitingSeen` / `lastWaitMs` / `elapsedMs`。
- 等待期间用 `/net`（`alive` / `sinceLastStoc` / `closeReason`）判断掉线；**不要**因为 waiting 就重复发 `side_ok`（会重复点按钮）。
- 对手长时间不确认（>数分钟）且 `/net` 判定失联 → 离开房间重排队（见第 8 节）。

## 7. 下一局开始 & 整场结束

- 下一局开始：客户端日志 `DUEL_START reset result state (match game N)`，`/state.winPlayer` 重置为 -1（**否则会误判"已结束"**），随后重新进入 TP → 第 4 节。
- 整场结束：`STOC_DUEL_END`（`/state.lastStocName` 或 `/net.lastStocName` 可见）。
- 判定一局 vs 一整场：**看 `STOC_DUEL_END`**，不是看第一次 `MSG_WIN`。一局结束在 Bo3 里还会继续。

**每局/整场结束后，用 `control_match` 报告结果（给用户/给自己）**：

- 它返回 `{match, summary}`，`summary` 是中文一句话：谁赢、为什么、大比分、是否结束（例：`比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：对手掉线/失联（DISCONNECT）`）。
- `/state.match` 原始字段（2026-11-13 版起）：`game`(当前局)、`over`、`games:[{game,win,winnerSeat,reason,reasonName}]`、`gamesWonLocal`/`gamesWonOpp`、`lastWinnerLocal`/`lastReasonName`；`win` 是本地视角，`winnerSeat` 是 raw 座位号。
- **不要**自己从 `/state.winPlayer` 推整场结论（那只代表当前局；Bo3 里一局结束还会继续）。
- 典型用法（每局结束 / 换备前 / 整场 `STOC_DUEL_END` 后各调一次）：
  - 局间（side 阶段）：`第 1 局：你赢了，原因 LP_ZERO（对手 LP 归零）；当前大比分 1:0（你领先）`
  - 整场结束：`比赛结束：你赢了这场 Bo3（2:0）。最后一局原因：…`（或你输了/N:0）
- 旧客户端（无 `state.match`）会返回 `fallback:true` 并用当前局字段尽力表达；拿不到就按 `/state.winPlayerLocal` 语业务必说明"仅当前局"。
- 原因翻译：`SURRENDER`=投降、`LP_ZERO`=LP 归零、`DECK_OUT`=抽卡耗尽、`TIMEOUT`=超时、`DISCONNECT`=掉线/失联，其它原样。

## 8. 收尾与异常处理

| 情况 | 处理 |
|---|---|
| 整场结束 `STOC_DUEL_END` | `GET /leave` → 杀客户端 → 重新排队（下一场） |
| 对手回合长时间无包（`sinceLastStoc` 持续增长、`timeLeft` 冻结、`awaiting=false`） | 判"对手失联/空等"：静默 2–5 分钟后 `/leave` + 重排（不要一直等） |
| 空房（进房后 **35 秒**内没有第二个人进来，`/lobby.playerCount<2`） | 立即 `/leave` + 重排；不要傻等（`ranked-loop.ps1 -EmptyRoomSec 35`，默认 35s） |
| `connection lost` / `/net.state=="disconnected"` | 中止本场、重排（可选：`/join` 同房重连，有 journal 时能回同一局） |
| 准备/开始失败 | 重试 ready（每 1–2s）、start（每 2–3s），最多 ~30 次；仍失败则离开重排并抓 `/lobby`、`/state.deckError` |
| 打完发现输多赢少 | 那是策略问题（policy 偏保守），不是流程问题 |

## 9. 最小正确序列（可直接照抄）

```
# 线上排位一场 Bo3
node bridge/get-room.mjs                                   # 拿房
GET  /join?ip=..&port=..&pass=..                           # 进房（等 connected+joined）
GET  /deck?name=BlackwingHT2S                              # 选卡组
循环 GET /ready 直到 /lobby.ready[mySeat]==1                # 准备（可重试）
循环 GET /start 直到 /state.started==true                   # 开始（双方 ready 也要发！）
# 对局
循环 { /prompt → 若 tpPending: /act_id?id=0|1
                若 sidePending: (/side_swap ...) → /actions → /act_id?id=0（side_ok）
                否则 awaiting && actions 非空: /act_id?id=<选一个> }
# 整场结束
等 /state.lastStocName == "STOC_DUEL_END" → /leave → 重排下一场
```

## 10. 参考实现与证据

- `bridge/ranked-loop.ps1`：连续排位（排队→进房→deck→ready→start→对局→换备→下一局→DUEL_END→重排，每 10s 截图，静默/空房/断线自动中止）
- `bridge/bo3-run.ps1`：本机局域网 Bo3（双方 bot，验证 side/TP/Game2/Game3）
- `bridge/lan-run.ps1`：局域网起局链路
- 实战记录：`bridge/docs/RANKED-REPORT.md`、`ranked/logs/consecutive-bo3-run.md`
