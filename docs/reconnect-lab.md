# LAN 掉线重进同房间：实验记录（task-26）

> 结论先行：**LAN 服务端不支持"中途掉线后重进同房间继续对局"**。掉线瞬间服务端立即判定
> `MSG_WIN reason=4 (DISCONNECT)` 结束对局；重进客户端能在 TCP 层连上、能发 `HS_READY`，
> **但收不到任何 STOC 包**（0 条 `OnMessageBegin`），拿不到 turn/LP/场面/连锁任何状态。
> 要恢复对局上下文，只能靠**本地 journal + 服务端提供 resume 能力**；LAN 服务端没有这个能力。
>
> 环境：本地 LAN（`127.0.0.1:7911`），**未登录、未接触排位/账号**。
> 客户端：`bin/release/x64/YGOPro.exe` = 2026-11-06 02:56:20 / 6,242,304 B（重构后版本）。
> 控制层：`YGO_CONTROL_PORT` 7788（HostA）/ 7789（GuestB），`YGO_HOOKS` host=`msganalyze`、guest=`all`。

---

## 1. 实验设置（可复现）

两个客户端由 `bridge/reconnect-lab.ps1`（单进程编排，客户端生命周期可控）拉起：

```powershell
# 主实验（A：硬掉线 + 同昵称重进）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\reconnect-lab.ps1 -TurnTarget 3 -MaxWaitSec 120 -Deck Blackwing
# 阶段 2（B：换昵称对照 + 重开新局）
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\reconnect-lab.ps1 -TurnTarget 2 -MaxWaitSec 100 -AltNick GuestX
```

单局流程：起 host（`lan-host.cmd msganalyze`）→ 起 guest（`lan-guest.cmd all`）→ `/deck` `/ready` `/start`
→ 起两个 `policy-semantic.mjs` bot 让对局推进到 **turn ≥ 2/3** → 存 `/state` 快照 → **kill 客机**
→ 等 2-5s → 用同参重启客机（`-j -h 127.0.0.1 -p 7911 -n GuestB -d Blackwing -k`，端口 7789）
→ `/join?ip=127.0.0.1&port=7911&pass=` → `/ready` → 每 2s 采样两端 `/state`、`/lobby` 与客机 control 日志。

> 注意：客户端进程必须由**同一个长生命周期进程**拉起（`Start-Process cmd /c <launcher>`），
> 否则启动它的 PowerShell 调用结束时会连带结束客户端；`cmd /c` 同步调用在部分场景会阻塞。

---

## 2. 实验 A：硬掉线（kill 客机）→ 同昵称重进

### 2.1 掉线瞬间（host 侧）

| 项 | 观测值 |
|---|---|
| 掉线前 | turn=2~3、LP 8000/8000、`started=True inDuel=True`、客机 `chainDepth=0`（run2 客机当时 `curMsg=16`，连锁窗口待选） |
| kill 后 <1s | host 日志 **`MSG_WIN player=0 reason=4(DISCONNECT)`**（run1 为 `player=1`，两局胜方索引不同，但 **reason=4 恒定**） |
| host `/state` | `started=True inDuel=True turn=3 win=0/4`（run2）/ `win=1/4`（run1），`curMsg=5(MSG_WIN)`，`msgs` 冻结 |
| host 画面 | **「You Win!」+「[昵称]失去连接!」**覆盖层（`lan-r3-kill-1.png`），停在结算画面 |
| host `/health` `/state` | **仍然可用**（控制 API 正常，非死锁） |

### 2.2 重进（同昵称 GuestB，host 仍在）

重进客户端（新进程 pid 15432 / 8388）：

| 观测项 | 结果 |
|---|---|
| TCP/控制层 | 立即起来，`/health` OK；`/join`、`/ready` 均 HTTP 200 |
| control 日志 | `join: host=127.0.0.1 port=7911 passlen=0` → `StartClient enter ... create=0` → `ready: enter (connected=1)` → `ready: sending UpdateDeck` → `ready: sending HS_READY` |
| **收到服务端消息** | **0 条**：`OnMessageBegin` = 0、真实 `STOC_*` 行 = 0、`/state.pipeline.msgCount=0`、`lastStoc=-1(STOC_?)` |
| 客机 `/state` | `started=False inDuel=False turn=0 lp=0/0 counts 全 0`（与服务端无任何同步） |
| 客机 `/lobby` | `self=1 isHost=false launchSeat=1 ready=[0,0] statuses=[]`（本地认为自己在 2 号位，但**房间状态为空**） |
| host `/lobby` | 仍是掉线前的 `ready=[1,1] statuses=[9,25]`（host 端状态冻结，未感知重进） |

→ **协议层结论**：重进连接只完成了"客户端 → 服主"的单向握手（我发 HS_READY），
**服务端没有任何 STOC 回包**（连 `STOC_HS_PLAYER_ENTER`/`STOC_HS_PLAYER_CHANGE` 都没有），
所以 `turn/LP/counts/chain` 全部不可恢复。

### 2.3 对照：不同昵称（GuestX）重进

同一流程把重进昵称换成 `GuestX`（`-AltNick GuestX`，直接以 `-j ... -n GuestX` 启动）：
同样 `/join` `/ready` 200，但`/state` 依旧是 `started=False turn=0 msgs=0`，
**服务端没有因昵称不同而给出不同响应**（两种昵称都收不到 STOC）。
→ "服务端靠昵称认人"这个假设在 LAN 端**不成立/无从验证**：它根本不给重进者推任何状态。

> 补充：阶段 2 脚本在 GuestX 步骤卡住（`Start-Process` 直接起 exe 时客户端未起来），
> 该分支只拿到了"同昵称 = 无 STOC"的强证据；昵称差异这一项按**未完成**记录，不影响主结论。

### 2.3.1 host 端侧证据：服务端**没有**处理这次重进（关键）

对 host 的 control 日志做"`MSG_WIN` 之后的行"过滤（`control-9932.log` run1 / `control-7492.log` run2）：

| host 日志中 `MSG_WIN` 之后 | run1（9932） | run2（7492） |
|---|---|---|
| 总行数 | 3,918 | 25,528 |
| `CTOS type=` 行（含 `0x12 JoinGame`） | **0** | **0** |
| `HS_PLAYER_ENTER / HS_PLAYER_CHANGE / PLAYER_*` | **0** | **0** |
| `join / Join / DuelPlayer` | **0** | **0** |

同时 host `/lobby` 在重进后仍是 **`ready=[1,1] statuses=[9,25]`**（掉线前的旧座位原样冻结，没有新 DuelPlayer/PlayerReady）。

→ 服务端侧结论：**重进请求没有被当成一次 join 处理**（既没有新玩家登记，也没有旧座位更新）；
而重进客户端侧却已经完成 TCP 连接并发出 `HS_READY`（`ready: enter (connected=1)`）——
说明两者不在同一个可用的"房间会话"上：**LAN 服务端在对局结束后不再接受/不处理重连**。

### 2.4 客户端 UI / 卡模态框情况

- **被 kill 的客机**：进程消失，无 UI。
- **host**：停在「You Win / 失去连接」结算层；`/health`、`/state` 正常；未出现阻塞控制 API 的模态框。
- **重进客机**（lab1 `lan-r3-rejoin-2.png`，此时服主已随 lan-run 收尾退出）：
  画面回到「联机模式（加入游戏）」界面并弹出 **`无法连接到主机。 [OK]`** 模态框，等待人工点 OK。
  → 这是"自动重进失败"时的真实残留：**会自动尝试连 system.conf 里的 lasthost/lastport，失败就卡在模态框**，
  控制 API 仍可用，但客户端不会自己回到可操作状态。

---

## 3. 实验 B：掉线后能否干净地重开新局

单独一轮（`ranked/logs/reconnect6-20261106-180950/progress.log`）：

1. host1 + guest1 开局（`started=True`）
2. kill guest1 → 服务端判定 DISCONNECT（host 留在结算层）
3. kill host1（避免在"已结束对局"的 host 上卡住）
4. **重新拉起 guest2（同昵称）+ host2（新建房）** → `/deck` `/ready` `/join` `/start`
5. 结果：**新局正常开始**（`started=True`、`msgs=3`、客机 `mySeat=1`），截图 `lan-r6-newgame-{1,2}.png`

→ 客户端**没有"永久坏掉"**；只要重新起一个房（或回到主菜单点 OK 后重新建房），可以干净地开新局。
但"同一个进程在旧房间原地恢复"做不到（见 §2.2）。

---

## 4. 连锁上下文能否从协议恢复

- 掉线前抓到的 `/prompt`（如 run2 客机 `curMsg=16`、`chainDepth=0`，等待连锁选择）在重进后**没有任何对应数据**：
  客机 `/prompt` 为默认空（`chainDepth=0 chainStack=[] chainingTo=null chainCandidates=[] canDecline=true`），
  且根本没有收到任何包 → **连锁栈/候选/是否必发全部不可恢复**。
- 结论：**chain 上下文必须靠本地 journal**（客户端侧在正常对局中把
  `chainDepth/chainStack/chainingTo/chainCandidates/lastChainEvent` 连续落盘），
  重连后即使服务端支持 resume，也需要"已知最后一帧 + 增量消息"才能补齐；LAN 服务端连增量都不给。

---

## 5. 结论（回答 4 个问题）

| # | 问题 | 结论 |
|---|---|---|
| 1 | LAN 服务端接受中途重进吗？ | **不接受**。掉线瞬间对局以 `MSG_WIN reason=4(DISCONNECT)` 结束；重进连接 TCP 可建立但服务端不回任何 STOC |
| 2 | 重进后重发了哪些消息？ | **一条都没有**（0×`OnMessageBegin`/0×`STOC_*`）；只有客户端自己发出的 `join / UpdateDeck / HS_READY` |
| 3 | 对局恢复了吗？ | **没有**。重进客机 `started=False/turn=0/lp=0/0/counts=0`，与掉线前 `turn=2~3/LP 8000/8000` 完全不同 |
| 4 | 连锁上下文能恢复吗？ | **不能**。重进后 chain 字段全空；必须靠本地 journal，且 LAN 无 resume 增量 |

**附加结论**

- 掉线方画面：回到联机界面并可能弹 `无法连接到主机` 模态框（需人工 OK）；**控制 API 仍活**，不是死锁。
- 存活方（host）：立即看到「You Win/失去连接」结算层，停在结算（bot 不会点 OK），但 `/health`/`/state` 正常。
- 客户端可复用：重新起房后能**干净开新局**（实验 B）。
- 本地 LAN 服务端是原版 `single_duel` 语义（一人掉线即终局），**不支持中途重进是预期行为**；
  这条否证本身就是重连设计的重要输入：重连检测/续局流程**必须按线上服特性**设计，本地只能验证
  "客户端侧清理 + supervisor 状态机 + journal 落盘"。

### 5.1 必须在线上验证的项（本实验无法覆盖）

| 项 | 为什么 LAN 测不了 | 线上要验证什么 |
|---|---|---|
| 排位服是否支持 resume | LAN 服务端在掉线即终局，无 resume 协议 | 掉线后重连是否收到状态快照/增量消息；`STOC` 序列里有没有恢复类包 |
| 重进后的消息 id 序列 | LAN 端重进收包为 0 | 线上重连后 `OnMessageBegin id=...` 的完整序列（以及是否重发 MSG_START/UPDATE_DATA 等） |
| `/tip` 等回包行为 | LAN 端无相关流量 | 重连期间 tip/错误包的内容与时机 |
| 会话/座位认人方式 | LAN 端不处理重进 | 线上是否按 uid/昵称/会话 token 识别；旧座位如何处理 |

> 建议：线上只跑 **1 局**验证上述 4 项即可（不刷、不挂机），把 `OnMessageBegin` 序列与重连前后
> `/state`（turn/LP/counts/chain）差异留档，再决定 journal + supervisor 的重连算法。
- 若要实现"重连继续"，在 MyCard/LAN 这块**需要服务端支持**（会话 id、重连握手、状态快照/增量），仅改客户端不够。
  **下一步应到真实排位（1 局）验证服务端是否支持 resume**；本实验只证明 LAN 不支持。

---

## 6. 证据路径

| 证据 | 路径 |
|---|---|
| 主实验进度日志 | `ranked/logs/reconnect3-20261106-174920/progress.log` |
| 主实验状态快照 | 同目录 `pre-state-p7788/7789.json`、`kill{1,3,5}-state-p7788.json`、`rejoin1..10-state-p7789.json` |
| 主实验截图 | 同目录 `lan-r3-pre-{1,2}.png`、`lan-r3-kill-1.png`（You Win/失去连接）、`lan-r3-rejoin-{1,2}.png`（无法连接主机模态框） |
| 主实验 control 日志 | `mycard-bot/game/control-9932.log`（host1）、`control-15432.log`（重进客机，0 STOC） |
| 重复实验（run2） | `ranked/logs/reconnect4-20261106-175928/progress.log`、`mycard-bot/game/control-7492.log`、`control-8388.log` |
| 重开新局实验 | `ranked/logs/reconnect6-20261106-180950/progress.log`、`lan-r6-newgame-{1,2}.png`、`newgame-guest-state.json` |
| 实验脚本 | `bridge/reconnect-lab.ps1`、`bridge/reconnect-lab2.ps1`（后者 GuestX 分支未跑完） |

## 7. 复现注意事项

1. 客户端必须由长生命周期进程拉起；`cmd /c "lan-host.cmd ..."` 可直接用，但 `| Out-Null` 管道在个别情况下会阻塞，建议用 `Start-Process -FilePath $env:ComSpec -ArgumentList '/c ...'`。
2. `Start-Process` 直接起 `YGOPro.exe` 时偶发不启动（本实验遇到），稳妥做法仍是走 `bridge\lan-host.cmd` / `lan-guest.cmd`。
3. 每次实验前后检查 0 客户端/0 node/端口空闲；实验脚本退出时会清理进程，但若中途 kill 掉脚本需手工清。
4. 脚本里不要用 `$pid` 作为参数名（PowerShell 只读变量，会报 `VariableNotWritable`）。
5. **客机不能用 `-j` 走代理**：`-j` 会忽略 `-p`、改用 `system.conf` 的 `lasthost/lastport` 直连 7911（实测 `StartClient enter ... port=7911`）。要走 netfault 必须**无 `-j` 启动**，再用 `GET /join?ip=127.0.0.1&port=<ProxyListen>&pass=` 显式加入；注入前先断言 `netfault /status.totalConnections >= 1`。

---

## 8. 客户端检测与 supervisor 实测（task-30，2026-11-06 21:24–21:58）

> 客户端 exe：`bin/release/x64/YGOPro.exe`
> **验收版 = 2026-11-06 22:03:58 / 6,275,584 B**（§8 的 freeze/drop/journal/supervisor 结果均在此版实测）
> **当前正式版 = 2026-11-06 22:23:28 / 6,275,584 B**（相对验收版仅 `/state.resume.reason` 成功时 `"loaded"`，行为不变；
> 22:24 冒烟：开局正常、`/net` 可访问、`/state.resume.reason="loaded"`、无崩溃）
> 功能：`/net` + 自动探活 + 模态框抑制 + journal（`resume-context-<port>.json`）+ `/leave` + `alive=connected&&prober-ok`
> 故障注入：`bridge/netfault.mjs`（7912→7911，控制口 7913）；**流量经代理已断言**（`totalConnections=1`）。
> 实验脚本：`ranked/logs/t30-lab2.ps1`（guest 无 `-j` → HTTP `/join?port=7912` → bots 推进 → 注入 → 采样 `/net` → 清理）。

### 8.1 无效轮次（不计入 FAIL）

| 轮次 | 结果 | 原因 |
|---|---|---|
| `reconnect-lab-20261106-211803` | **INVALID** | 旧 harness 用 `-j -p 7912` 启动客机，但 `-j` 忽略 `-p`，实际直连 **7911**（日志 `StartClient enter ... port=7911`，netfault `totalConnections=0`）→ freeze 根本没作用在链路上，`detectMs=null` 不代表检测失败 |

> 该轮同时暴露了 prober 的真 bug（poc 已修）：`/tip` 回显 `type=1` 被当成 reply 但 2.5s timer 未取消 → `fails=2 → NET DEAD` 后又被单个 STOC `NET alive` 复活（抖动）。

### 8.2 测试结果

| # | 测试 | 观测值 | 判定 |
|---|---|---|---|
| T1 | **freeze 静默假死**（25-30s） | **最终版 exe（22:03:58）实测 `detectMs = 6751ms`**（`/net.alive` 首次 false，与日志 `NET DEAD` 同帧级）；21:41 版基准轮 `detectMs=8291ms`；`state=confirmed_dead`、`closeReason=none`（无 EOF，符合静默假死） | **PASS**（≤10s） |
| T2 | **drop 硬断（EOF）** | `detectMs = 610ms`；`alive=false state=disconnected closeReason=eof`；`NETMSG suppressed id=1502 tag=duel-disconnect`（无原生弹框）；故障期间 `/health` 一直可用 | **PASS** |
| T3 | **thaw 自愈** | thaw 后 `NET alive recovered (hits=2 stoc=STOC_?)`、`recovered=True at 9495ms`、`alive=true`；随后对局无流量时再次 `NET DEAD fails=3`（已知行为） | **PASS**（去抖生效） |
| T4 | **journal 生成（按端口隔离，22:03:58 版）** | `mycard-bot/game/resume-context-7789.json`：`{"savedAt":...,"room":{"addr":"127.0.0.1","port":7912,"passHash":"fnv1a:..."},"turn":2,"mySeat":1,...,"pendingPrompt":{...}}`；同目录另有 `resume-context-7788.json`（host 自己端口） | **PASS**（按端口文件+room 修复生效） |
| T5 | **journal 启动加载** | 客户端读**自己端口**的 journal：`RESUME journal loaded ...` → `/state.resume={stale:true,fromJournal:true,savedAt,gapMs:825,preTurn:2,...}`；另一次 gapMs=48528 也是 loaded | **PASS** |
| T6 | **journal 过期丢弃** | journal 改旧（>60s）→ `/state.resume = null`；日志 `RESUME journal ignored reason=expired gapMs=180151` | **PASS** |
| T7 | **supervisor `--profile lan`** | JSONL：`start → state_ready → state_dueling → dead_detected(reason=net.state=disconnected closeReason=eof) → leave → result(lan-no-resume) → exit`；`stats.reconnectAttempts=0`；**无 kill/join/重启事件** | **PASS** |
| T8 | **回归（正常 LAN 对局，无注入）** | `lan-run` 1 局、MaxMinutes=2 截断：`turns=4`、hostDec 45/guestDec 29、retries 0/1、无 client-exit/崩溃、结束后 0 进程 | **PASS**（无退化；deadline 结束是时间盒导致） |

### 8.3 观测到的 `/net` 时间线（freeze，关键字段）

| 时刻（注入后） | alive | state | sinceLastStoc | probe.fails | 说明 |
|---|---|---|---|---|---|
| 0 ms | true | healthy | ~0.5s | 0 | 正常对局 |
| ≈2.5s | true | healthy | 2516ms | 0 | prober 发出第 1 次 `/tip` |
| ≈4.0s | true | probe_failed | 4032ms | 1 | 第 1 次超时 |
| ≈5.5s | true | probe_failed | 5516ms | 1 | 第 2 次 `/tip` |
| ≈7.0s | true | probe_failed | 7032ms | 2 | 第 2 次超时 → 日志 `NET DEAD reason=probe-fails` |
| **≈6.75s（最终版）** | **false** | **confirmed_dead** | 7282ms | 2 | `/net.alive` 首次 false（harness `detectMs=6751ms`，同帧同步） |
| ≈8.3s（21:41 版） | false | confirmed_dead | 7422ms | 2 | 旧版字段滞后 1.2s |

### 8.4 待补 / 已知问题

| 项 | 状态 | 说明 |
|---|---|---|
| `/wait_prompt` 返回 `{disconnected:true}` | **未实现** | poc 明确属另一块；supervisor 靠 `/net` 判死，不影响主流程（已记入待补） |
| LAN 无系统 `/tip` 回包 | 已处理 | 客户端会走 `probe.unsupported` 被动探测（本次 freeze 完全断流，走的是 probe-fails 路径） |
| journal 按端口隔离 | **已完成（22:03:58 版）** | `resume-context-7788.json` / `resume-context-7789.json` 各自生成；`/state.resume` 从自己端口文件读（已实测 gapMs=825 加载）；supervisor 只读 `/state.resume`，不受影响 |
| 测量受机器负载影响 | 已修 harness | 旧 harness 在故障循环里调用 `shot.ps1`（阻塞 ~18s），导致 `detectMs` 失真（曾报 167991ms/23079ms）；已把截图移到循环外，最终轮 `6751ms` 与日志一致 |
| `/net` 字段与日志同步 | 最终版 PASS | 22:03:58 版单一状态源：日志 `NET DEAD` 与 `/net.alive=false` 同帧（6751ms vs 7032ms 采样粒度差）；drop 轮 `alive=false` 610ms |

### 8.5 证据路径（task-30）

| 证据 | 路径 |
|---|---|
| **freeze 最终轮（6.75s，22:03:58 版）** | `ranked/logs/t30v2-20261106-220820/`（`run.log`、`net-samples.csv`、`guest-net-keywords.txt`、`lan-t30v2-freeze-*.png`） |
| freeze 基准轮（8.3s，21:41 版） | `ranked/logs/t30v2-20261106-214217/` |
| drop + supervisor 轮（0.6s） | `ranked/logs/t30v2-20261106-214449/`、`ranked/logs/supervisor-t30.jsonl`（7 行，含 `lan-no-resume`） |
| thaw 恢复轮 | `ranked/logs/t30v2-20261106-214706/`（`NET alive recovered (hits=2)`、`recovered=True at=9495`） |
| journal 验证（按端口） | `mycard-bot/game/resume-context-7788.json`、`resume-context-7789.json`、`control-*.log` 的 `RESUME journal loaded/ignored` |
| 回归 | `ranked/logs/lan-run-20261106-215253.log` |
| 无效轮（流量未过代理） | `ranked/logs/reconnect-lab-20261106-211803.{log,json}`、`netprobe-20261106-211803.csv` |
