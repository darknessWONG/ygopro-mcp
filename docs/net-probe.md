# 网络探活与重连基础能力（net-probe）

> task-28 的客户端实现说明。设计依据：[`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md)。
> 涉及文件：`mycard-client/gframe/control.cpp`（网络状态/探活/journal/端点）、
> `control_state.cpp`（`/state` 序列化）、`control_lobby.cpp`（Join/Leave）、
> `control_actions.cpp`（Leave 分发）、`duelclient.cpp`（OnChat/Hooks/模态框替换）。
> exe 基线：2026-11-06 20:57:32（size 6,270,976）。

---

## 1. 一句话

客户端现在会**自己**判断"连接是否还算活着"（被动 `sinceLastStoc` + 主动 `/tip` 探活），
通过 **`GET /net`** 暴露给 supervisor / 排障；**断线类原生弹窗默认不弹**（只记日志）；
对局中的连锁上下文会**落盘 journal**，重连后可从 `/state.resume` 读回；`POST /leave` 用于干净退出。

> 原则：探测自动、接口只读、LLM 不触发；客户端不做重连编排（那是 `bridge/supervisor.mjs` 的事）。

---

## 2. `GET /net`

一次返回当前网络状态（HTTP 线程读取原子量，不碰 GUI）：

```json
{
  "connected": true,
  "connectState": 3,
  "closeReason": "none",
  "joined": true,
  "inDuel": true,
  "turn": 7,
  "lastStocAt": 123456789,
  "lastStocName": "STOC_GAME_MSG",
  "sinceLastStoc": 1420,
  "alive": true,
  "state": "healthy",
  "uptimeMs": 123400000,
  "probe": {
    "enabled": true,
    "unsupported": false,
    "lastSentAt": 123455000,
    "lastReplyAt": 123455120,
    "rttMs": 120,
    "fails": 0,
    "lastReplyPlayerType": 8,
    "lastReplyText": "系统消息…"
  },
  "lastNetMsg": { "id": 1401, "text": "连接已断开。", "ageMs": 30000 },
  "version": "net-1"
}
```

| 字段 | 含义 |
| --- | --- |
| `connected` | TCP 是否连接（`OnNetConnected/OnNetDisconnected` 维护） |
| `connectState` | 0=未连接 2=已连接 3=已进房 |
| `closeReason` | `none / stop / exit / eof / error / connect-timeout / ...`（最近一次断开原因） |
| `joined` | 是否已进房（`STOC_JOIN_GAME` 成功） |
| `inDuel` / `turn` | 从最近一次 `/state` 快照带出 |
| `lastStocAt` | 最近一个 `STOC_*` 的 `GetTickCount64()`；`0` = 从未 |
| `lastStocName` | 最近 STOC 名字（如 `STOC_GAME_MSG`） |
| `sinceLastStoc` | 距最近 STOC 的毫秒数（-1 = 从未收到） |
| `alive` | **`connected && prober-ok`**（断线立即 false；supervisor 用它决策） |
| `state` | `disconnected / idle / healthy / probing / probe_failed / unsupported / confirmed_dead` |
| `probe.*` | 探活器内部状态（见 §4） |
| `lastNetMsg` | 最近一条被抑制/弹出的断线类原生消息（id 对应 `strings.conf`） |

`/state` 会在末尾附带 `"net":{...}`（同一份 JSON）与 `"resume":...`（见 §6）。

---

## 3. 网络生命周期钩子

`duelclient.cpp` 中新增调用：

| 事件 | 调用 | 效果 |
| --- | --- | --- |
| `BEV_EVENT_CONNECTED`（`connect_state |= CONNECTED` 之后） | `Control::OnNetConnected()` | `connected=true, joined=false, alive=true, fails=0, closeReason="none"` |
| `STOC_JOIN_GAME`（`connect_state |= JOINED` 之后） | `Control::OnNetJoined()` | `joined=true` |
| `BEV_EVENT_EOF/ERROR` 分支 | `Control::OnNetDisconnected("eof"/"error")` | `connected=false`，记录 closeReason |
| `DuelClient::StopClient(reason)` | `Control::OnNetDisconnected("exit"/"stop")` | 同上 |

任何 `STOC_*` 到达（`Control::OnStocPacket` 顶部）都会：
- 更新 `g_lastStocTick`（→ `sinceLastStoc`）；
- 刷新 alive grace；
- 若正在探活（`probePendingSince != 0`）→ 视为探活回复；
- 若之前判死 → 记 `NET alive (stoc XXX)` 恢复。

---

## 4. 自动 `/tip` 探活（不需要 LLM）

Pump（UI 线程）每次调用 `NetPumpProber()`：

**发送条件**（全部满足）
1. `connected && dInfo.isStarted && dInfo.isInDuel`（只在对局中探活）
2. `sinceLastStoc > idle`（默认 **2500ms**，env `YGO_NET_IDLE_MS`）
3. `now - probe.lastSentAt >= gap`（默认 **3000ms**，env `YGO_NET_PROBE_GAP_MS`）
4. 没有 pending 动作：`!g_awaiting`、动作队列空、无 UI 600ms 校验（`g_uiPending.active==false`）
5. 当前没有在途探活（`probePendingSince==0`）

**动作**：`CTOS_CHAT` 文本 `"/tip"`（UTF-16，含结尾 null；`DuelClient::SendBufferToServer`），
记录 `probe.lastSentAt`、`probePendingSince`，日志 `NET probe sent (auto|manual) sinceStoc=..ms`。

**判定**（默认 1500ms 窗口，env `YGO_NET_PROBE_WINDOW_MS`）
- 收到**系统回包** `STOC_CHAT(player_type==8)` 且文本 != `"/tip"` → `probe.lastReplyAt/rttMs`
  （`reply >= sentAt` 同毫秒也有效，rtt 同毫秒记 0），`fails=0`，`alive=true`，立即取消超时；
  日志 `NET probe reply rtt=..ms playerType=..`；恢复时 `NET alive recovered (hits=N stoc=..)`。
- **LAN 回显不算回包**：服务端把发送者聊天广播回来（`player_type=1, text="/tip"`）时记
  `NET probe echo ignored (own /tip broadcast)`，**不记 reply / 不算 rtt / 不涨 alive**。
  `YGO_NET_PROBE_REQUIRE_SYSTEM=0` 可放宽为"任意非回显 chat"都算回复（排障用）。
- 非 chat 的 `STOC_*` 在窗口内到达 → 也算链路活着（探活成功）。
- 超时：
  - 若窗口内有**非 chat STOC 流量** → 说明链路通、只是服务器不支持 `/tip` 系统回包：
    记 `NET probe unsupported (traffic ok, no system /tip reply) -> passive mode`，
    `probe.unsupported=true`、`probe.enabled=false`、`fails=0`，之后只走被动探测；
  - 否则 `probe.fails++`，日志 `NET probe timeout fails=N`。

**判死**
- `probe.fails >= 2` → `alive=false`，日志 `NET DEAD reason=probe-fails fails=..`；
- 或对局中 `sinceLastStoc > silence`（默认 **10000ms**，env `YGO_NET_DEAD_SILENCE_MS`）且距上次
  alive >2.5s、非 busy → `alive=false`，日志 `NET DEAD reason=stoc-timeout since=..ms`。

**判死后的去抖（防 alive 抖动）**
- 判死后必须累计 **2 个非 chat STOC** 才恢复（`g_netAliveHits`），日志
  `NET alive recovered (hits=2 stoc=STOC_GAME_MSG)`；
- chat 回显不计数；探活成功（系统回包）可正常恢复。

**只置状态，不自动重连**（重连由 supervisor 决策）。

**说明**
- LAN 服务端若不回应系统 `/tip`：第一次探活超时会走 `unsupported` 降级（不会计 fails），
  之后靠被动 `silence` 判死；freeze 实测判死约 **8.5s**（探活路径）或 **10s**（被动路径）。
- 手动排障：`GET/POST /net/probe` 会强制立即探一次并最多等 3s 返回
  `{ok, sent, rttMs, alive, fails, lastReplyPlayerType}`；不满足发送条件时 `sent:false`。
- 启动日志会打当前参数：`NET probe cfg idle=..ms gap=..ms window=..ms silence=..ms requireSystem=..`。

---

## 5. 断线不弹原生模态框

`duelclient.cpp` 中原先的 `mainGame->env->addMessageBox(L"", dataManager.GetSysString(id))`
已替换为 `Control::NotifyUser(id, tag)`：

| 文案 id | 场景 | tag |
| --- | --- | --- |
| 1400 | 连接失败/超时 | `connect-timeout` / `connect-failed` |
| 1401 | 对局中断线（EOF） | `disconnect-eof` |
| 1402 | 传输错误 | `transport` |
| 1502 | 决斗模式掉线 | `duel-disconnect` |
| 1403 / 1404 / 1405 | 加入失败 / 密码错误 / 被拒绝 | `join-fail` / `join-pass` / `join-rejected` |

行为：
- `YGO_SUPPRESS_MODALS`（默认 **1**）：**不弹框**，日志
  `NETMSG suppressed id=<id> tag=<tag> text=<文案>`，并写入 `/net.lastNetMsg{id,text,ageMs}`；
- `YGO_SUPPRESS_MODALS=0`：恢复原生的 `addMessageBox` 行为（对照用）。

正常结算文案（`stMessage` 1500）和其它非网络类消息框**未改动**。

---

## 6. journal（连锁上下文落盘 / resume）

- 路径：进程 cwd（= game 目录）**`resume-context-<控制端口>.json`**（如 `resume-context-7788.json`）；
  `YGO_RESUME_PATH` 可覆盖（测试用）。**按端口隔离**：LAN/多开时两个客户端共用 game 目录
  也不会互相覆盖（历史 bug：单文件被无 room 的 host 覆盖成空）。
- 写：`tmp` + `MoveFileEx(REPLACE_EXISTING)`（原子替换）。
- 触发：`chainStack`/`chainingTo`/`pendingPrompt`/`turn` 变化时写；**≤1 次/秒**；5s 兜底一次；
  只在对局中（`started`）写。
- 内容：

```json
{
  "savedAt": "2026-11-06T12:01:02Z", "savedAtMs": 1762430462345,
  "room": { "addr": "127.0.0.1", "port": 7911, "passHash": "fnv1a:9f3a…" },
  "turn": 7, "mySeat": 1, "phase": 4, "lp": [7300, 6100],
  "chainDepth": 1,
  "chainStack": [ { "link":1,"code":84749824,"name":"神之警告","desc":1141,"descText":"…",
                    "ctrl":0,"loc":8,"seq":0,"type":"effect","forced":false,"isMine":true,
                    "summary":"我方[神之警告] 已加入连锁" } ],
  "chainingTo": { "summary": "我方[神之警告]" },
  "canDecline": true,
  "pendingPrompt": { "seq": 123, "curMsg": 16, "awaiting": true,
                     "chainCandidates": [{"index":0,"code":53582587,"name":"激流葬","forced":false,"isMine":true}] }
}
```

- **密码不落明文**：只存 `fnv1a:` 64 位哈希（同一房/密码校验够用）。
- **room 继承**：LAN 两客户端可能共用同一 game 目录/同一 journal 文件；没有 `/join` 的 host
  在自己 `room` 为空时**从旧文件继承** `room{addr,port,passHash}`，不会把 guest 写入的 room 覆盖成空。
- 启动时读取（`Control::EnsureStarted` → `JournalLoadAtStartup()`）：
  - 文件不存在 → 日志 `RESUME journal absent (...)`；
  - `<60s` 且 `turn>0` → 载入，日志 `RESUME journal loaded savedAt=.. gapMs=.. turn=.. seat=.. chainDepth=.. stack=..`；
  - 过期/损坏 → `RESUME journal ignored reason=expired|parse-error|invalid-turn`。
- 暴露：`/state.resume`，载入成功时非空：

```json
"resume": {
  "stale": true, "fromJournal": true,
  "savedAt": 1762430462345, "gapMs": 12345,
  "preTurn": 7, "chainDepth": 1,
  "chainStack": [ { "link":1, "code":84749824, "name":"神之警告", "descText":"…", "summary":"…" } ],
  "chainingTo": { "summary": "我方[神之警告]" },
  "pendingPrompt": { …原始 JSON… },
  "reason": "absent|expired|..."
}
```

未载入时 `resume: null`。策略/supervisor 可据此比对 `preTurn`、重建连锁上下文。

---

## 7. `POST /leave`

入队一个 `ActionKind::Leave`（UI 线程执行）：

```
StopClient(CLIENT_CLOSE_REASON_EXIT)
隐藏对局弹窗（wPosSelect/wOptions/wCardSelect/wCmdMenu/wMessage/wQuery）
dInfo.isStarted=false / isInDuel=false / isFinished=false / is_building=false
device->setEventReceiver(&menuHandler)  // 回主菜单
```

返回 `{"ok":true,"queued":true}`（入队即返回，实际执行在下一帧 Pump）。
日志：`leave: StopClient(EXIT) + reset dInfo`。

---

## 8. 开关（环境变量）

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `YGO_NET_PROBE` | 1 | `0` = 关闭自动 `/tip` 探活（`/net.probe.enabled=false`） |
| `YGO_NET_PROBE_REQUIRE_SYSTEM` | 1 | `0` = 任意非回显 chat 都算探活回复（排障用） |
| `YGO_NET_IDLE_MS` | 2500 | 多久没有 STOC 才允许探活 |
| `YGO_NET_PROBE_GAP_MS` | 3000 | 两次探活最小间隔 |
| `YGO_NET_PROBE_WINDOW_MS` | 1500 | 探活回复窗口（超时判定） |
| `YGO_NET_DEAD_SILENCE_MS` | 10000 | 被动判死：多久没 STOC 判死（另有 2.5s grace） |
| `YGO_SUPPRESS_MODALS` | 1 | `0` = 恢复断线原生弹框（对照/人工排查用） |
| `YGO_RESUME_JOURNAL` | 1 | `0` = 不写 `resume-context-<port>.json` |
| `YGO_RESUME_PATH` | `resume-context-<port>.json` | journal 路径覆盖（测试用） |
| `YGO_CTRL_DEBUG` | 未设 | 额外 CDBG 日志 |

启动日志新增：`netProbe=%d suppressModals=%d journal=%d`。

---

## 9. 日志关键字（测试/排障）

```
NET connected
NET joined room
NET disconnected reason=..
NET probe sent (auto|manual) sinceStoc=..ms
NET probe reply rtt=..ms playerType=..
NET probe echo ignored (own /tip broadcast)
NET probe unsupported (traffic ok, no system /tip reply) -> passive mode
NET probe timeout fails=N
NET DEAD reason=probe-fails|stoc-timeout since=..ms
NET alive recovered (hits=2 stoc=STOC_GAME_MSG)
NETMSG suppressed id=.. tag=.. text=..
NETMSG modal id=.. tag=.. text=..
RESUME journal absent|loaded|ignored reason=..
leave: StopClient(EXIT) + reset dInfo
NET probe cfg idle=..ms gap=..ms window=..ms silence=..ms requireSystem=..
```

---

## 10. 实测结果（LAN · netfault · 最终验收版）

最终验收 exe：**22:03:58 / 6,275,584 B**（`task-28` 验收通过；其后 22:23:28 仅把
`/state.resume.reason` 从 `"absent"` 改为 `"loaded"`，不影响行为）。

| 场景 | 结果 |
| --- | --- |
| **freeze（静默假死，EOF 不触发）** | **detectMs = 6751ms**（`/net.alive` 首次 false，`state=confirmed_dead`，`closeReason:"none"`）≤10s ✅；prober：`sent sinceStoc=2516 → timeout fails=1(4032) → sent(5516) → timeout fails=2(7032) → NET DEAD reason=probe-fails`；`/net` 与日志**同帧同步**（6751 vs 7032 只是 0.5s 采样粒度） |
| **drop（硬断 EOF）** | **detectMs = 610ms**；`alive:false state:disconnected closeReason:eof`；`NETMSG suppressed id=1502 tag=duel-disconnect`；`/health` 全程可用 |
| **thaw/自愈** | `NET alive recovered (hits=2 stoc=..)`、**recovered=True at 9495ms**、`alive=True`（之后对局无流量再 DEAD 属预期） |
| **journal（按端口隔离）** | `resume-context-7789.json`（客机，`room={127.0.0.1:7912,fnv1a:...}`）与 `resume-context-7788.json`（host，各自独立）；重启加载 → `/state.resume={stale:true,fromJournal:true,gapMs:825,preTurn:2,...}`；过期 → `resume:null` + `RESUME journal ignored reason=expired` |
| **supervisor lan** | `state_ready → state_dueling → dead_detected(reason=net.state=disconnected) → leave → result(lan-no-resume) → exit`，`reconnectAttempts=0`，无 kill/join |
| **回归** | 1 局正常 LAN `turns=4`、retries 0/1、无崩溃/client-exit，结束后 0 进程 |

**单一状态源**（本轮修复）：`/net.state` 由 `g_netState` 唯一决定（`disconnected/idle/healthy/probing/
probe_failed/unsupported/confirmed_dead`），prober 判死与 `/net.alive=false` **同一帧**；
`alive = connected && state∉{confirmed_dead,disconnected}`。

参数结论（默认值即实测值）：`idle=2500 / gap=3000 / window=1500 / silence=10000` 在 LAN 下
freeze 判死 6.75s、drop 0.61s，符合验收（≤10s）；如线上延迟更高，可用 env 调 `window`/`gap`。

## 11. 已知限制

- LAN 服务端不回应系统 `/tip`：第一次探活超时后走 `unsupported` 降级（不计 fails），之后靠被动
  `silence` 判死；若对局本身无流量，也会按 `probe-fails` 判死（预期）；
- `/wait_prompt` 的 `disconnected:true` 语义属设计 §6，本次未实现（supervisor 用 `/net.alive`）；
- 探活只在 `isStarted && isInDuel` 时运行（lobby/准备阶段只显示 `idle`，不判死）；
- `closeReason` 为字符串（`none/stop/exit/eof/error/...`），不是数字枚举；
- journal 按控制端口隔离 `resume-context-<port>.json`（`YGO_RESUME_PATH` 可覆盖）；文件保留，
  重连成功后由 supervisor/policy 决定是否归档；
- `alive` = `connected && prober-ok`：断线立即 false。
