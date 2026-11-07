# net-probe + reconnect-lab-run：掉线检测的量化与一键实验

两个新工具，用来在**本地 LAN** 上量化"客户端多久发现链路坏了"，不碰排位、不改客户端代码：

| 文件 | 作用 |
|---|---|
| `bridge/net-probe.mjs` | 轮询 `GET /net`，输出时间线 CSV + `EVENT DEAD/ALIVE`，最后给 `SUMMARY` |
| `bridge/reconnect-lab-run.ps1` | 一键实验：起 host(7911) + 客机走 netfault(7912) → 采样 → 注入 `freeze`/`drop` → 汇总 → 清理 |

配套：`bridge/netfault.mjs`（故障注入代理，控制口 7913）、`bridge/shot.ps1`（截图，检查模态框）。

---

## 实测基线（最终，2026-11-06 22:03:58 版 exe）

故障**确实经过 netfault**（注入前断言 `totalConnections >= 1` 生效），以下为最终结论：

| 场景 | 实测结果 |
|---|---|
| **freeze（静默假死）** | **`detectMs=6751ms`**；客户端日志 `NET DEAD` 7032ms；`/net.state=confirmed_dead`，`closeReason=none` |
| **drop（硬掉线）** | **`detectMs=610ms`**；`/net.state=disconnected`，`closeReason=eof` |
| **thaw（假死后恢复）** | **9.5s 自愈**（`NET alive recovered hits=2`） |
| 模态框抑制 | `NETMSG suppressed id=1502`，**无原生弹框**（截图无阻断） |
| journal / resume | `resume-context-<port>.json`；重启后 `/state.resume={stale:true,gapMs:825}`；过期 journal 返回 `null` |

> 结论：被动超时（freeze）≈**6.8s**、EOF（drop）≈**0.6s** 就能判死，都在 ≤10s 目标内；恢复需要 2 个非 chat STOC（≈9.5s 自愈）。
> 本轮跑通前修掉的 5 个坑（都已修）：① 客户端 `-j` 会用 `system.conf` 的 `lasthost/lastport`、**忽略 `-p`**（必须显式 `/join?port=7912`）；
> ② 探活把自己 `/tip` 的 LAN 回显当回包；③ `/net.alive` 与日志不同帧（已统一为单一状态源）；④ journal 两客户端共用（已按端口区分）；
> ⑤ harness 里截图阻塞采样循环（已移出）。

---

## 1. `net-probe.mjs`

```powershell
# 基本：轮询 7789，500ms 一次，跑 60s，CSV 落盘
node bridge/net-probe.mjs --port 7789 --interval 500 --duration 60000 --csv ranked\logs\net.csv

# 跑到 Ctrl+C（duration=0），只打事件不刷 CSV 行
node bridge/net-probe.mjs --port 7789 --duration 0 --quiet
```

**CSV 列（固定顺序）**

`ts,elapsed_ms,alive,sinceLastStoc,rttMs,fails,connected,closeReason,inDuel,turn,probeState`

- `ts`：ISO-8601 UTC；`elapsed_ms`：相对 probe 启动
- `alive` / `connected` / `inDuel`：`true|false`（客户端没给就留空）
- `sinceLastStoc`：距最后一个服务器包多少 ms；`rttMs`/`fails`：探活 RTT / 连续失败数
- `closeReason`：socket 关闭原因（带逗号会自动加引号）
- `probeState`：客户端检测状态 `healthy|idle|probing|probe_failed|confirmed_dead|disconnected`；读不到 `/net` 时是 `net-unavailable`（404，旧 exe）或 `http-error`

**判别事件**（stdout，可直接 grep）

```
EVENT DEAD at t=869ms (sinceLastStoc=16000, fails=2, state=confirmed_dead)
EVENT ALIVE at t=1850ms (after 981ms)
# state healthy -> confirmed_dead at t=869ms
SUMMARY {"samples":24,"deadCount":1,"firstDeadAtMs":869,"aliveRecoveries":1,"maxSinceLastStoc":16000,...}
```

- `--csv` 文件是**纯 CSV**（表头+数据行），stdout 才是"CSV+事件+SUMMARY"日志流。
- 其他参数：`--host`（默认 `http://127.0.0.1`）、`--summary <file>`（把 SUMMARY 存 JSON）、`--timeout`、`--append`、`--no-header`。
- **兼容两种 `/net` 字段形态**：设计契约（`sinceLastStocMs` / `probe.failStreak` / `state`）与 supervisor 使用的短形态（`sinceLastStoc` / `probe.fails` / `alive`），新旧客户端都能采。

**判读**：`EVENT DEAD` 的 `t=` 就是"从 probe 启动到发现掉线"的时间；配合实验脚本记录的注入时刻，可算出**检测延迟**（目标 ≤10s；**实测 freeze 6.75s / drop 0.61s**）。

---

## 2. `reconnect-lab-run.ps1`

```powershell
# 静默假死（连接不断、包全丢）：最贴近线上掉线
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\reconnect-lab-run.ps1 -Mode freeze -HoldSeconds 20

# 硬掉线（连接被 destroy，客机看到 EOF）
powershell ... -File bridge\reconnect-lab-run.ps1 -Mode drop -HoldSeconds 20

# 假死后再恢复（测"没判死能不能自愈"）
powershell ... -File bridge\reconnect-lab-run.ps1 -Mode freeze -HoldSeconds 20 -Thaw -ThawWaitSeconds 10

# 只演练不启动（打印将执行的命令、检查路径/端口）
powershell ... -File bridge\reconnect-lab-run.ps1 -Mode freeze -DryRun
```

**流程（9 步）**：预检（端口/已有 YGOPro，冲突就拒绝运行，绝不杀别人的进程）→ 起 `netfault`（7912→7911）→ 起 host（`-p 7911`，控制口 7788）→ 起客机（**不带 `-j`**，控制口 7789，`-p 7912`）→ `/deck` → **客机 `GET /join?port=7912`** → **断言 netfault `totalConnections >= 1`** → `/ready` `/start` 并等到 `turn >= -TurnTarget`（默认 2）→ 起 `net-probe` 采样 → 注入 `POST /mode?m=<mode>` → 保持 `-HoldSeconds` 期间采样 `/health` `/state` `/net` 并截图 → 停 probe、解析 CSV、汇总、清理（`-KeepClients` 可保留客户端）。

**参数**：`-Mode freeze|drop`、`-HoldSeconds`(20)、`-Deck`(Blackwing)、`-Port`(7789 客机控制口)、`-Thaw`、`-ThawWaitSeconds`(10)、`-TurnTarget`(2)、`-StartupTimeoutSec`(150)、`-ServerPort`(7911)、`-ProxyListen`(7912)、`-ProxyCtrl`(7913)、`-HostPort`(7788)、`-HostNick`/`-GuestNick`、`-ClientExe`、`-GameDir`、`-OutDir`(ranked\logs)、`-ProbeIntervalMs`(500)、`-LaunchTimeoutSec`(25)、`-SkipShot`、`-ClientDebug`（给客户端加 `YGO_CTRL_DEBUG=1`）、`-KeepClients`、`-SkipProxyAssert`（不推荐）、`-DryRun`、`-SelfTest`（只测启动管道，不起客户端）。

> **客机不能带 `-j`（重要，实测踩过）**：`-j` 自动加入用的是 `system.conf` 的 `lasthost/lastport`，
> **会忽略 `-p`**（新 exe 日志：`StartClient enter ip=0x7f000001 port=7911`）。所以 guest 用 `-j -p 7912` 时
> 流量其实直连 7911，`netfault` 的 `totalConnections` 一直是 0 —— 此时 `freeze`/`drop` **什么也没挡住**，
> 得到的 `detectMs=null` 是**测试方法问题**，不能算客户端检测失败。
> 现在 harness 的做法：guest **不带 `-j`** → 起来后显式 `GET /join?ip=127.0.0.1&port=7912&pass=` → `/ready`，
> 并在注入前**硬断言** `totalConnections >= 1`（否则直接报错退出，`verdict` 会写 `INVALID`）。

> **客户端是怎么起来的（重要，已修过一版）**：
> 不能用 `Start-Process -FilePath <YGOPro.exe>` 直接起 GUI exe —— 实测 `Start-Process` 起 host 花了 **14 秒**、
> 起客机直接**永久阻塞**（客机进程从未出现，`/status.totalConnections=0`）。
> 现在改成和 `bridge\lan-host.cmd` / `lan-guest.cmd` 一样的做法：**生成一个 .cmd 包装**
> （`cd /d <game dir>` + `set YGO_CONTROL_PORT=...` + `start "" "<exe>" <args>`），用 `cmd /c <包装>` 启动，
> 再用 `Get-Process YGOPro` 的 **pid 差集**认出真正的进程（带 `-LaunchTimeoutSec` 硬超时）。
> 超时会**打印诊断并报错退出**（不再干等）：YGOPro 进程列表、netfault `/status`、最近的 `control-*.log`。
> 生成的包装留在 `ranked\logs\client-<name>-<stamp>.cmd`，可直接拿来复现。

**产物**（都在 `ranked\logs\`）

- `reconnect-lab-<stamp>.log`（全过程）/ `.json`（结构化摘要，含 `detectMs` / `controlApiAliveDuringFault` / `disconnectedSeen` / `netDuring` 等）
- `netprobe-<stamp>.csv`（时间线）+ `netprobe-*.stdout.txt`（事件）/ `.stderr.txt`
- `netfault-*.stdout/stderr.txt`（代理日志）
- `reconnect-<mode>*.png`（客机截图，用于看**是否弹模态框**）
- `reconnect-pre-<stamp>.json`（注入前 `/state` 快照：turn/lp/inDuel）

**摘要怎么读**

| 字段 | 含义 / 判读 |
|---|---|
| `dead detected after` | 注入 → 首次 `alive=false` 的毫秒数；**≤10000 视为达标** |
| `traffic via proxy` | 注入时代理的 `totalConnections/bytesUp/bytesDown`；**为 false 就说明故障没作用在对局流量上，整轮无效** |
| `control API alive` | 故障期间客机 `/health` 仍可用 → 说明检测不能靠 HTTP，必须靠 `/net`（这是本实验的关键结论） |
| `disconnected seen` | `/net.state=confirmed_dead` 或 `connected=false`/`alive=false` 出现即 true |
| `guest process alive` | 故障后客机进程是否还在（`drop` 不应导致客户端退出） |
| `recovered after thaw` | `-Thaw` 时，恢复后 `alive` 是否回到 true |
| `verdict` | `PASS` = 检测到掉线且控制口存活；`PASS(detected)` = 检测到但控制口不可用；`FAIL` = 未检测到；`INVALID` = 流量没经过代理（故障没作用在真实流量上，整轮无效） |

---

## 3. 注意

- 脚本**独占** 7911/7912/7913/7788/7789；已有 YGOPro 或端口被占时会直接拒绝（不会 kill 别人的进程）。`-DryRun` 只警告不阻塞。
- `.ps1` 特意写成**纯 ASCII**（Windows PowerShell 5.1 按 ANSI 解析 `.ps1`，中文会乱码/解析失败）。
- **排障：卡在 `[3/9]`/`[4/9] start host/guest client`** → 现在最多等 `-LaunchTimeoutSec` 秒就会报错并打印诊断；把诊断（YGOPro 进程/`/status`/最新 `control-*.log`）发回即可。想放宽等待就加 `-LaunchTimeoutSec 60`。单独验证启动管道：`-SelfTest`（只跑 `cmd`，不起 YGOPro）。
- **排障：`detectMs=null` / `traffic via proxy=false`** → 十有八九是流量没走代理。**客户端 `-j` 会自动加入 `system.conf` 的 `lasthost/lastport` 并忽略 `-p`**（实测日志 `StartClient enter ip=0x7f000001 port=7911`），所以 `-j -p 7912` 实际直连 7911。正确做法：客机**不带 `-j`**，起来后显式 `GET /join?ip=127.0.0.1&port=7912&pass=`；注入前必须确认 `netfault /status.totalConnections >= 1`（harness 已硬断言，`-SkipProxyAssert` 不建议用）。
- `netfault` 的 `freeze` 只挡游戏流量，**不挡客机自己的控制口**——所以实验里"客机 `/health` 仍然活着"是预期现象。
- 想验证旧 exe（没有 `/net`）：probe 会显示 `probeState=net-unavailable`，说明需要客户端新 exe（`/net`）。
- LAN 服务端**不支持续局**，本实验室只测"检测/记账"；真正重连验证要等 ranked（见 `RECONNECT-DESIGN.md`）。
