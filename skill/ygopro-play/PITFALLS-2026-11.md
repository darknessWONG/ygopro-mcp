# YGOPro 实战踩坑与解决手册（2026-11 一轮连续排位总结）

> **本文所有端点均以 MCP 工具名表述**（`control_state` / `control_net` / `control_actions` /
> `control_act_id` / `control_act` / `control_join` / `control_ready` / `control_leave` /
> `control_side_move` …）。如果你没有 MCP 而是直连控制层 HTTP，对照表见文末附录。
> 排队（`/ygopro/match`）**没有 MCP 等价工具**，仍要用桥接脚本（如 `bridge/queue-loop.mjs`）。


> 来源：2026-11-13 ~ 11-23 的连续排位实机操作（MC 线上排位，客户端 `19B8E843 / 2026-11-20 15:34:59`）。
> 每条都注明**实测证据**；没实测到的写「未验证」。

---

## A. ★★★ 最重要：「掉线」和「卡死」症状一样，处置相反

### 症状（两者完全相同）

```
timeLeft       冻结不动
sinceLastStoc  持续增长（收不到包）
awaiting       false
curMsg         停在一个等待态（常见 3 / 50 / 72）
net.state      仍然可能是 idle / healthy  ← 不能只看这个
```

### 判据（唯一可靠）

| `control_net().state` | 含义 | 处置 |
|---|---|---|
| `disconnected` / `confirmed_dead` | **我方掉线** | **重启客户端 → `control_join` → `control_ready` 重进**；先读 `control_state().resume`（非 null 才有续局 journal） |
| 健康，但 `stallMs > 120000 && oppClockFresh === false` | **对方客户端/服务端卡住** | **离桌重排**（`control_leave` → 重排），不是我们掉线 |
| 健康，且 `oppClockFresh === true` | 对手在正常长考 | 继续等，**不要离桌** |

### 我踩的坑（教训）

我一开始把「`timeLeft` 冻结 + 无包」直接等同于"卡死"，于是：
1. 连续几天把**掉线**误判成卡死，只会退房；
2. 更糟的是我的启动参数**把两个检测器都关了**：

```powershell
$env:YGO_NET_PROBE = '0'                 # 关探活 → control_net().state 永远不翻成 disconnected
$env:YGO_NET_DEAD_SILENCE_MS = '600000'  # 判死阈值拉满 → 等于永不判死
```

→ 结果：**永远分不清掉线和卡死**，只能猜。

### 实证（用正确参数后）

2026-11-20 16:57，同一个"冻结"现象在 **3 分钟内自己变成了明确的掉线状态**：

```
state=disconnected  stallMs=174281  oppFresh=false  curMsg=50
control_net(): closeReason="error"  alive=false  probe:{fails:3, rttMs:203}
      lastNetMsg:{ id:1502, text:"连接已断开。" }
control_state().resume = null   ← 没有续局上下文，这局救不回来
```

### 结论

**启动时不要设 `YGO_NET_PROBE=0`，也不要设 `YGO_NET_DEAD_SILENCE_MS=600000`。**
让探活开着、判死走默认（60000），然后**主动轮询 `control_net().state`**。
掉线后 `state` 会自己翻，翻之前你会看到 `stallMs` 一路涨。

> 注意：探活/判死需要时间。**不要**在 `stallMs` 刚到 60–120s 就下结论，等到 `state` 翻转或 `stallMs>150s` 且 `oppClockFresh=false` 为止。

---

## B. ★★★ `control_actions()` 的 `id` 会变，不能缓存

**现象**：读 `control_actions()` 拿到列表 → 想发第 7 项 → 实际点到了 `to_bp`（第 9 项）。

**原因**：客户端在两次请求之间又发布/刷新了 prompt，`id` 是相对**当前** prompt 的下标。

**实测**：2026-11-19 一局里我**两次**因为这个点错动作（想发 `群星` 却进了战斗阶段）。

**做法**：

```
1. 拉 control_actions()
2. **立刻**用刚返回的列表选动作、发 control_act_id
3. 中间不要插别的 await/sleep/查询
4. 更好：按 label 匹配（如 /activate.*46983930/），不要按索引
```

---

## C. ★★ `select` 类 prompt 只有一个 action id（固定选第一张）

**现象**：卡组选牌（`curMsg=15`，`kind:"select"`）候选有 20 多张，
但 `control_actions()` 只给一条 `0:select select first 1 card(s)` → 只能选第一张。

**想指定某张卡**：必须走底层 `/act` 发原始字节。

```
# 卡组选择（loc=1）用「卡的 seq」，不是列表下标
# 响应格式: [n, seq...]
control_act({ seq: control_prompt().seq, hex: "01" + <seq 两位十六进制> })

# 例子：要把 seq=2 的卡放卡组顶 → hex=0102
# 实测 2026-11-23 用 hex=0102 / hex=010b 成功指定卡组里的特定卡
```

> 顺带：`MSG_SELECT_PLACE` 是 `[place, loc, seq]` 三字节；`MSG_SORT_CARD` 是**裸位序无前缀**。

---

## D. ★★★ 摆位：超量/融合怪 **必须优先额外怪兽区（EMZ）**

**现象**：把超量怪摆进了**主怪兽区**（`loc=4 seq=0`），白白丢掉它"在 EMZ 才生效"的效果。

**实测**：2026-11-23 我有一次把本家 `停止下注` 放进 `seq0`，
结果「①不受其他卡效果影响」和「②把对方检索改写成我方抽 1」**全都没了**，等于一张 2100 白板。

**做法**：place 候选里只要有 EMZ 就必须选它。

```
# EMZ 在客户端里表现为 loc=4 且 seq=5 或 seq=6
const emz = places.find(p => /seq=([56])\b/.test(p.label));
const chosen = emz || places[0];   // 有 EMZ 用 EMZ，没有才退化
```

> 我在 `D:\dsh_workspaces\ygo_pro_bot_dsh\tools\place.mjs` 里把这个规则固化了，
> 所有 place prompt 现在都走它，不再写"取第一个"的临时逻辑。

---

## E. ★★★ `supervisor.mjs` **不能用来跑 Bo3**

**现象**：它把「15 秒没有入站 STOC 包」判成掉线，进而 **kill 客户端 + 重启**。

**为什么致命**：**Bo3 换备阶段本来就没有任何 STOC 包**（双方在编辑卡组）。
所以它**每场 Bo3 都会在 Game 2 前误杀客户端**。

**实测**（2026-11-23 01:20 的 supervisor 日志）：

```
hb ... inDuel=false turn=2 lp=0,8000        <- Game1 正常结束
hb ... inDuel=true  turn=1 lp=8000,8000     <- Game2 正常开始（恢复完好）
dead_detected reason=sinceLastStoc=15063ms  <- 只静默 15 秒
reconnecting_start -> leave -> killed pid=13936 -> client_start
```

→ 后果：**进行中的 Game2 被强杀，整场作废。**

**做法**：
- 打 Bo3 **不要挂 supervisor**（`--profile ranked` 也不行）；
- 改用自己轮询 `control_net().state`（判据见 A 节）；
- 只有**长时间单局、无换备**的场景才考虑它。

---

## F. ★★ 排队 `504` 不是"配对失败"，是反向代理超时

**事实**（来自 `ranked/logs/match-queue-research.md`）：
- 服务端 `/ygopro/match` 是**长轮询**，`server.timeout = 0`，**本该一直挂着直到配上**；
- `504` 是**反向代理/网关**在 ~600s 处切断；
- 所以「504」= 这一轮没配上，**重试即可**，不是故障。

**其它状态码**：

| 码 | 含义 | 动作 |
|---|---|---|
| `504` | 反代超时，本轮没对手 | 继续下一轮长轮询 |
| `502`/`503` | 网关/后端暂时不可用 | 等几十秒再试（实测凌晨出现过 2 次） |
| `401`/`403` | Basic auth 被拒，通常 `u16Secret` 已轮换 | **重新 `authUser` 取新 secret 后重试**（不是重登账号） |

---

## G. ★★ 死房间会被服务端**反复返回**，要退避 60s

**现象**：对局被强杀/退房后，下一次排队**立刻**返回**同一个房间**，`stale=true`，进房 `JOIN FAILED`。

**原因**：账号还留在服务端的 `playingPlayerPool` 里，要等 `longestMatchTime` 到期才清。

**做法**：识别到"与上次房间密码相同"→ **丢弃并退避 60 秒**再排。
（我原来写 3 秒重试，结果空转刷了几十轮。）

---

## H. ★★ 进房前必须确认客户端状态是干净的

**现象**：`play-round` 报 `DUEL STARTED`，但其实是**上一次对局残留的 `inDuel=true`**；
真正的房间是死的，`JOIN FAILED`。

**实测**：2026-11-23 01:35 我进房后看到 `turn=4 / LP=0/8000 / match.game=0 / games=[]`
—— 明显是上一场的残影，记录器启动 0.04s 就报"对局结束"。

**做法**：`control_join` 之前先查

```
inDuel === false
match.game === 0
match.games.length === 0
net.state 正常
```

不满足就先重启客户端。

---

## I. ★★ PowerShell 写 JSON 会带 BOM，会害死下游解析

**现象**：`Set-Content -Encoding UTF8` 在 Windows PowerShell 5.1 下**会加 BOM**；
Node 的 `JSON.parse` / supervisor 的 `--last-room` 直接报
`Unexpected token '﻿'`。

**做法**：

```powershell
$json = $obj | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
```

**实测**：修完后 `node` 读回首字节 = `123 34 97`（`{"a`），`BOM? false` ✅。

---

## J. ★★ `.ps1` 脚本里**不要写中文**

**现象**：脚本报一堆莫名其妙的语法错（`The string is missing the terminator`），
实际是中文注释被按 ANSI 解码成乱码、吃掉了引号。

**原因**：Windows PowerShell 读**无 BOM** 的 `.ps1` 时按 ANSI 解码。

**做法**：**PowerShell 脚本一律纯 ASCII**（注释也用英文）。
要输出中文，用 `node -e` 或写成 `.md` / `.json`（UTF-8）。

---

## K. ★ `1013xxxx` 卡号 = 客户端**未收录**的占位号

**现象**：日志/状态里出现 `code=101307042`、`101307015` 这类卡号，
去 `cards.cdb` 里查 → `NOT FOUND`。

**含义**：这是客户端给**本地卡库没有的卡**（新卡/先行卡）分配的合成号。

**做法**：
- **不要**凭卡名猜效果；
- 在文档里明确标「**待核实**」，等官方数据或实测再补。
- 我因此把「太阳神」系和部分「艮神鬼」卡都标了待核实，没有编。

---

## L. ★★ 夜间低分段可能**完全没有对手**

**实测**（2026-11-22 22:52 → 11-23 05:15）：

| 时段 | 结果 |
|---|---|
| 22:52–23:38 | 45 分钟未配上 |
| 23:57 | **配上**（1702s） |
| 01:37 | **配上**（1211s） |
| 01:47–05:15 | **11 次尝试 / 208 分钟 / 0 配对** |

- 账号 `pt=323 / 排名 410294`，**低分段**；
- 凌晨 1–5 点该分段没有活跃对手；
- 失败形态：504 多、502 ×2、401 ×5（自动恢复）、client timeout。

**做法**：
- 不要在没有对手的时段反复空排（纯烧时间）；
- 记住可用时段（本例：12:00+ / 18:00–22:00 都很快配上）；
- 判断"是没人还是我们坏了"：看 `net.state` 与 `probe` 是否健康 —— 健康就是没人。

---

## M. ★ `chainStack[].isMine` 不可信，敌我要靠卡名反查

**现象**：自己写日志工具时，把 `chainStack` 的 `isMine` 当真，结果**对方的卡全被标成我方**。

**原因**：它按「座位 0 = 本地」算；当我坐在 **seat 1** 时整个映射反了。

**实测**：2026-11-19 一次统计出「我方 21 条 / 对方 4 条」，
但链上明明是对方在检索/特召。

**做法**：**用卡名反查** —— 该卡名是否出现在我方 `monsters/spells/graves/banished/hand` 里，
在 = 我方，否则 = 对方；同时把原始 `isMine` 留作调试字段。

---

## N. 其它小坑（实测）

| 坑 | 现象 | 解决 |
|---|---|---|
| `play-round` 选卡组名写错 | `deckError` 出现在 `control_state().deckError`，`server.set=true` | 列 `$ROOT\mycard-bot\game\deck\*.ydk` 对照 |
| 换备 `counts must match` | `side_ok` 被拒 | 换进/换出张数必须守恒（40/15/15）；本卡组实测把 `side_swap` 按"进出等量"配对做最稳 |
| `room.json` 用 PowerShell 写 | `JSON.parse` 报非法 | 用编辑器/`write` 工具写 UTF-8，或 `[System.IO.File]::WriteAllText` |
| 记录器一启动就报"对局结束" | 客户端有上一局残留 `winPlayer` | 重启客户端再进房（新构建会在 `STOC_DUEL_START` 重置，旧构建不会） |
| 截图抓到纯白 | 窗口刚从最小化恢复，D3D 表面还没重建 | **等 2 秒重抓**；不要当成客户端渲染坏了 |

---

## 一句话总结

**先把检测器打开（探活 + 默认判死），用 `control_net().state` 区分"掉线 vs 对方卡死"；
动作一律「现拉 `control_actions()` → 立刻发」；摆位优先 EMZ；
打 Bo3 别挂 supervisor；排队 504 就重试；没人就换时段。**

---

---

## O. ★★ MCP 已可用 —— 优先用 MCP，不要绕 HTTP

2026-11-23 起本机注册了 `ygopro` MCP server，`control_*` 工具可直接调用。**实测可用**：

| 已验证 | 结果 |
|---|---|
| `control_health` / `control_state` / `control_net` | ✅ 正常，字段比 HTTP 更全 |
| `control_lobby` | ✅ 能看到双方 ready、卡组张数（`bothReady` 是开局的判据） |
| `control_deck` | ✅ 加载后 `deckMain=40` |
| `control_ready` | ✅ 之后 `ready:[1,1]` |
| `control_start` | ✅ 真的开出了对局（`STOC_DUEL_START`、`match.game=1`） |
| `control_actions` / `control_wait_prompt` | ✅ 无 prompt 时返回 `awaiting:false`，不报错 |

**`control_state` 比 HTTP 多出的有用字段**（以前搞不清的都在这）：

- **`lpOrder: "local"`** —— 直接告诉你 `lp[0]` 是本地玩家，**不用再猜 lp 数组顺序**
- `mySeat` / `winPlayerLocal` / `isWin` / `isLoss` —— 座位与胜负的本地化映射，不用自己换算
- `match.games[]` 带 `win`（本地视角）、`winnerSeat`、`reasonName`
- `prompt.places` / `placesMask` / `placeCoords` —— 摆位候选的原始坐标
- `chainCandidates` / `chainingTo` / `canDecline` —— 判断"这张卡能不能接"
- `ui.windows[]` / `windowsVisible` —— 客户端弹窗状态（排查"卡住"很有用）
- `pipeline.recentMsgs` —— 最近几条 STOC 消息号，判卡死用
- `resume` —— 续局 journal（`null` = 掉线后无法续，必须重开）
- `side.counts` / `limits` / `error` —— 换备是否守恒，客户端自己会校验

**MCP ↔ HTTP 全量对照见文末附录。** 排队配对（`/ygopro/match`）**没有 MCP 工具**，仍用桥接脚本。

---

## P. ★ 本地 `local-server`（ygocore-poc）**不能当真服务器用**

想用 MCP 练手时我试过本地起服务器，结论：**别在这上面浪费时间**。

配方（`bridge\lan-mcp-test.ps1`）：`local-server/server.mjs --port 7911` + host 客户端（`-c`，控制口 7788）
+ `proxy.mjs --listen 7912 --mode auto` + guest 客户端（`-j`，控制口 7789）。

两次实测的现象：

1. **第一次**：所有卡都报 `"CallCardFunction"(cXXXXX.initial_effect): attempt to call an error function`
   → 开局即 `MSG_WIN reason=2`。
   原因：`local-server/lib/deck.mjs` 的 `RES = ygocore-poc/resources`，
   其 `CardScripts` 是**旧快照**，缺新卡的 Lua（我的卡组 43 个脚本全缺）。
   补法：从 `mycard-bot/game/script` 把缺失的 `.lua` 复制进
   `ygocore-poc/resources/CardScripts/official/`。
2. **第二次**（补完脚本后）：对局能开起来，但**我 0 张手牌、`deck=[40,...]`**，
   一开局就 `winReason=2 (DECK_OUT)`。

→ 这是 **POC 测试服务器**（`demo.ps1` 里用 `--auto p1` 让服务端代答一侧，本来就只用于协议验证），
**不是可对局的服务器**。

**结论**：想验证 MCP 的"出牌"路径，只能等**线上排位**配上对手，不要靠本地 POC。

---

## 附录：MCP 工具 ↔ 控制层 HTTP 对照

| 用途 | MCP 工具 | HTTP 等价 |
|---|---|---|
| 健康检查 | `control_health` | `GET /health` |
| 完整局面 | `control_state` | `GET /state` |
| 当前 prompt | `control_prompt` | `GET /prompt` |
| 等下一个 prompt | `control_wait_prompt` | `GET /wait_prompt` |
| 语义候选动作 | `control_actions` | `GET /actions` |
| 按 id 作答 | `control_act_id` | `GET /act_id?id=` |
| 原始字节作答 | `control_act({seq, hex})` / `control_act({seq, i})` | `GET /act?seq=&hex=` |
| 网络/掉线诊断 | `control_net` | `GET /net` |
| 房间/准备状态 | `control_lobby` | `GET /lobby` |
| 整场结果 | `control_match` | `GET /state.match` |
| 进房 | `control_join` | `POST /join` |
| 选卡组 | `control_deck` | `GET/POST /deck?name=` |
| 准备 | `control_ready` | `POST /ready` |
| 开局 | `control_start` | `POST /start` |
| 离开 | `control_leave` | `POST /leave` |
| 投降 | `control_surrender` | `POST /surrender` |
| 换备（移牌） | `control_side_move` | `GET /side_swap?code=&from=&to=&n=` |
| 换备完成 | `control_side_done` | `/act_id kind=side_ok` |
| 聊天/系统消息 | `control_chat` | `GET /chat` |
| 最后一条原始消息 | `control_msg` | `GET /msg` |
| **排队配对** | ❌ **没有 MCP 工具** | `POST /ygopro/match`（用桥接脚本） |
| 客户端截图 / 日志尾 | ❌ 没有 MCP 工具 | 自己实现（截图 API + 读 `control-*.log`） |

> ⚠️ 两点不要混：
> 1. **排队配对**不在控制层里 —— MCP 只能操作"已经在客户端里"的对局；
>    配对仍要用桥接脚本（如 `bridge/queue-loop.mjs`）。
> 2. **`control_net().state` 是判掉线的唯一权威信号**，不要用"多久没包"代替。
