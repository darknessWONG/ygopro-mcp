# supervisor 使用说明（bridge/supervisor.mjs）

> 常驻监督进程：读客户端 `/net` 判断掉线，按 `--profile` 决定**只记账（lan）**还是**完整重连（ranked）**。
> 设计依据：[`RECONNECT-DESIGN.md`](RECONNECT-DESIGN.md) §2/§3.2；客户端契约来自 task-28（`/net`/`/leave`/journal）。
> 当前状态：**已实现 + `--mock` 自测 5/5 通过**；真实重连链路等客户端新 exe（task-28）落地后做本地实测（task-30）。

---

## 1. 快速开始

```powershell
# 线上：完整重连（默认 profile=ranked）
node bridge/supervisor.mjs --profile ranked --port 7788 `
  --client "mycard-client/bin/release/x64/YGOPro.exe" `
  --game-dir "mycard-bot/game" `
  --join-ip 127.0.0.1 --join-port 7911 --join-pass "" --nick GuestB --deck Blackwing `
  --policy "node bridge/policy-semantic.mjs"

# 本地 LAN：只检测 + 记账 + 收尾（不重连，LAN 续局必失败）
node bridge/supervisor.mjs --profile lan --port 7789

# 本地 LAN 长稳：掉线后以“新局”重启（明确不是续局）
node bridge/supervisor.mjs --profile lan --lan-restart-game --port 7789 `
  --client "mycard-client/bin/release/x64/YGOPro.exe" --game-dir "mycard-bot/game" `
  --policy "node bridge/policy-semantic.mjs"

# 无客户端自测（5 个场景，退出码 0=全过）
node bridge/supervisor.mjs --mock
```

> 不占 7788/7789/7911（mock 完全不联网；真实模式只读 HTTP，除非 ranked 重连/`--lan-restart-game` 需要重启客户端）。

---

## 2. 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--profile lan\|ranked` | `ranked` | ranked=完整重连；lan=只检测+记账+收尾，不重启/不 join |
| `--port N` | `7788` | 客户端控制端口（`GET /net` 等都在这个端口） |
| `--host` | `http://127.0.0.1` | 控制层地址 |
| `--interval` | `1000` | 监控循环间隔 ms |
| `--max-retries` | `5` | 重连最大尝试次数（ranked） |
| `--backoff` | `1000,2000,4000,8000,15000` | 每次失败后的退避序列（ms） |
| `--verify-timeout` | `30000` | VERIFY 超时（ms） |
| `--start-timeout` | `30000` | 重启客户端后等 `/health` 的超时（ms） |
| `--heartbeat` | `30000` | 心跳日志间隔（ms） |
| `--jsonl` | `ranked/logs/supervisor.jsonl` | JSONL 记账文件（追加写） |
| `--client <exe>` | — | 客户端可执行文件（ranked 重连时重启用） |
| `--game-dir <dir>` | exe 所在目录 | 客户端工作目录（decks/system.conf 在这） |
| `--client-start "<cmd>"` | — | 自定义启动命令（优先于 `--client`） |
| `--client-kill "<cmd>"` | 先杀自己 spawn 的 pid，再按路径过滤 mycard-client 的 YGOPro | 自定义 kill 命令（会打印 killed pid） |
| `--client-cmdline-join` / `--no-http-join` | 关（默认 http join） | 用命令行 `-j` 加入，**跳过** supervisor 的 `GET /join`（二选一，避免双 join） |
| `--join-ip/--join-port/--join-pass` | `127.0.0.1` / `7911` / 空 | 房间参数（优先级：`/net.room` → `--last-room` → 这三个） |
| `--last-room <file>` | — | 房间参数文件（JSON：`{addr,port,pass}` 或 `{joinIp,joinPort,joinPass}`） |
| `--port-release-timeout` | `5000` | kill 后等控制端口释放的超时（ms），释放后才重启客户端 |
| `--nick/--deck` | `GuestB` / `Blackwing` | 重启客户端用的昵称/卡组 |
| `--policy "<cmd>"` | — | 策略进程命令（READY→DUELING 时拉起；RECONNECTING 时停掉） |
| `--no-leave` | 关 | 不调 `POST /leave` |
| `--lan-restart-game` | 关 | 仅 lan：`RESULT(lan-no-resume)` 后以新局重启客户端+policy（日志 `new-game (NOT resume)`） |
| `--mock` / `--mock-verbose` | — | 无客户端自测 / 打印细节 |

---

## 3. 状态机

### 3.1 监控与判死（1s 循环）

读 `GET /net`：

- `alive === false` **连续 2 次** → dead
- 或 `inDuel && sinceLastStoc > 15000` → dead
- 或**自己 spawn 的客户端进程退出**（`hasChildExited()`）→ dead（`reason=client-process-exit`）
- **`/net` 不可用时**（客户端还是旧版没有 `/net`）：退化到 `GET /health`，health 连续失败 2 次 → dead（首次会打印 `[/net unavailable ...]` 提示；mock 场景 `net404_health_fallback` 覆盖此路径）
- **误报自愈**：已进入 `QUEUED`/软失败但下一轮恢复 alive → 记 `false_alarm`（stats.falseAlarms+1）并回到 `DUELING`

心跳：每 `--heartbeat` ms 打一行 `hb state=... alive/turn/lp/reconnects/uptime`。

### 3.2 状态

```
IDLE → READY → DUELING
                  │ dead
      ┌───────────┴────────────┐
      │ ranked                 │ lan
      ▼                        ▼
 RECONNECTING              RESULT(lan-no-resume)
   ├─ resolveRoom（/net.room → --last-room → CLI）
   ├─ leave
   ├─ kill client（先杀自己 spawn 的 pid，再路径过滤）
   ├─ 等控制端口释放（≤ --port-release-timeout，默认 5s）
   ├─ start client（http 模式不带 -j；随后 GET /join + /ready）
   ├─ VERIFY（started && inDuel && turn>=preTurn，≤verify-timeout）
   │    ok  → DUELING（拉起 policy）
   │    失败 → QUEUED → 退避 → 重试（≤max-retries）
   └─ 超限 → RESULT(lost)
```

**ranked**：完整重连流程（`resolveRoom → leave → kill → 等端口释放 → start → /health → GET /join → /ready → VERIFY → policy`）。
**lan**：`confirmed_dead` 后直接 `RESULT(reason=lan-no-resume)`，**不重启、不 join**；带 `--lan-restart-game` 时才以**新局**重启（日志 `new-game (NOT resume)`）。

**join 二选一**：默认 `--client-join-mode=http`（启动不带 `-j`，supervisor 发 `GET /join`）；传 `--client-cmdline-join` 则启动带 `-j`、跳过 HTTP join（只 `/ready`），避免双 join。

---

## 4. JSONL 记账字段

每行一个 JSON（追加到 `--jsonl`，默认 `ranked/logs/supervisor.jsonl`），**9 个规范字段恒存在**（缺失一律给 `null`）：

```json
{"ts":"2026-11-06T21:00:00.000Z","event":"dead_detected","profile":"ranked","state":"DUELING","attempt":0,
 "preTurn":null,"nowTurn":null,"gapMs":null,"ok":null,"reason":"alive=false x2",
 "net":{"alive":false,"connected":false,"inDuel":true,"turn":7,"sinceLastStoc":16000,"probe":{"fails":2,"rttMs":-1}}}
```

| 字段 | 说明 |
|---|---|
| `ts` / `event` / `profile` / `state` / `attempt` | 时间、事件名、profile、当前状态、重连尝试序号 |
| `preTurn` / `nowTurn` / `gapMs` | 重连前后 turn、耗时（ms）；无关事件为 `null` |
| `ok` / `reason` | 结果与失败原因（`alive=false x2`、`sinceLastStoc=..ms`、`client-process-exit`、`client-restart-fail`、`verify-timeout`、`lost`、`lan-no-resume`） |
| `net` | 触发时的 `/net` 快照（可选） |

**事件**：`start`、`state_ready`、`state_dueling`、`dead_detected`、`reconnecting_start`、`room_resolved`、`reconnect_attempt`、`leave`、`client_kill`、`port_released`、`client_start`、`join_ready`、`verify`、`backoff`、`false_alarm`、`reconnect_ok`、`reconnect_fail`、`result`、`new_game`、`duel_result`、`shutdown`、`exit`、`error`。

**对局结果（`duel_result`）**：每局结束记录一次，字段 `{ok,isWin,isLoss,isDraw,result,winPlayer,winPlayerLocal,winReason,winReasonName,turn,reason}`；
`result` = `win|loss|draw|unknown`。
**输赢口径**：raw `winPlayer` 是座位号（本机 raw seat 1 → `winPlayer=0` 表示**对手赢**），**不能直接当"我们赢"**；
优先用 `/state.isWin/isLoss`，其次 `winPlayerLocal`（0=我方赢）；旧 exe 都没有时 `isWin=null` + `reason` 标 `isWin unknown`（不猜 false）。
**平局**：`isDraw` 是权威字段（`winPlayerLocal=-1`/`winPlayer=2`/`isDraw:true`），此时 `isWin=null`、`ok=false`，`result="draw"` —— 平局不记成输。
**与 policy 对账**：policy 侧 `GAME OVER ... result=win|loss|draw|unknown`、`stats ... win=.. result=..` 与本事件的 `result` 用同一词汇表，
**以 `result` 作为 join key**（不要用 `isWin` 布尔值反推平局；平局时这里是 `null`、policy 保留客户端原值 false 但带 `draw=true`）。
未做 `duels.jsonl` 汇总（两份来源已够对账）；将来要做时两边共用 `game` id。

**SIGINT**：打印统计 `detections / falseAlarms / reconnectAttempts / reconnectOk / reconnectFail / newGames / lastGapMs / avgGapMs / uptime` 后退出（事件 `shutdown`）。

---

## 5. `--mock` 自测（无客户端）

`node bridge/supervisor.mjs --mock` 内置 6 个场景（纯内存，不联网、不起进程）：

| 场景 | 断言 |
|---|---|
| `ranked_reconnect_ok` | healthy→dead→room_resolved/leave/kill/port_released/start/join/ready/VERIFY ok→`reconnect_ok`，`reconnectOk=1` |
| `ranked_verify_retry_then_ok` | 第一次 VERIFY 失败（turn 回退）→ backoff → 第二次成功，`attempt=2` |
| `ranked_max_retry_lost` | 3 次全失败 → `reconnect_fail` + `RESULT(lost)`，`attempts=max-retries` |
| `lan_no_resume_no_reconnect` | dead → `RESULT(lan-no-resume)`，**无 `reconnecting_start`、无 kill/join/start 调用** |
| `lan_restart_game_new_game` | lan + `--lan-restart-game` → 先 `RESULT(lan-no-resume)`，再 `new_game`（kill+start+join） |
| `net404_health_fallback` | `/net` 404 → 退化 `/health` 判活/判死，仍能 `RESULT(lan-no-resume)` |

输出 `PASS/FAIL  <scene>  <events…>` + `[mock] 6/6 scenarios passed`；全过退出码 0，否则 1。
加 `--jsonl <file>` 可把 mock 事件也落盘（默认 mock 不写文件），可用于校验 9 个规范字段恒存在。

---

## 6. 与 netfault 配合（task-30 本地实测用）

```powershell
# 1) 起代理：客机 -p 7911 改 -p 7912 后会经过 netfault（7912 → 7911）
node bridge/netfault.mjs            # 默认 listen=7912, upstream=7911, ctrl=7913

# 2) 客机用代理端口加入：-p 7912（host 仍是 7911）
# 3) 假死（静默断流，连接不断）
curl -X POST "http://127.0.0.1:7913/mode?m=freeze"
# 4) 硬断（连接被 destroy，对端收到 EOF）
curl -X POST "http://127.0.0.1:7913/mode?m=drop"
# 5) 恢复
curl -X POST "http://127.0.0.1:7913/mode?m=normal"
```

supervisor 侧观察点：`/net.alive` 变 false 的时间（应 ≤10s）、`/wait_prompt` 是否返回 `{disconnected:true}`、模态框是否被抑制（`NETMSG suppressed`）、lan profile 是否只出 `RESULT(lan-no-resume)`、journal（`mycard-bot/game/resume-context.json`）是否生成 & 重启后 `/state.resume` 可读。

---

## 7. 当前依赖与限制（如实）

| 项 | 状态 |
|---|---|
| 客户端 `/net`、`/leave`、journal、抑制模态框 | **task-28 进行中**（poc-wasm-duel 在改 C++）；在它落地前，supervisor 的 `/net` 会 404 并退化到 `/health` 判活 |
| 真实重连链路（kill→重启→join→VERIFY） | 代码已实现，**未用真客户端跑过**（task-30 待做）；`--mock` 只验证状态机与调用顺序 |
| ranked 真机验证 | 只能在**线上排位 1 局**验证（LAN 不支持续局，见 `reconnect-lab.md`） |
| 默认 `--client-kill` | 先杀 supervisor 自己 spawn 的 `clientChild.pid`，再退回"仅 mycard-client 目录的 YGOPro"路径过滤（会打印 killed pid）；部署路径不同请用 `--client-kill` 显式指定 |
| 退出语义 | ranked 失败（`RESULT(lost)`）与 lan（`RESULT(lan-no-resume)`）都会退出；需要常驻请用外部守护/计划任务重启 supervisor |

## 8. 验收记录（本次实现）

- `node --check bridge/supervisor.mjs` → 通过（656 行）
- `node bridge/supervisor.mjs --mock` → **6/6 scenarios passed**，exit 0
- `--mock --jsonl <file>` 落盘 76 行事件，**9 个规范字段 0 缺失**（`ts/event/profile/attempt/preTurn/nowTurn/gapMs/ok/reason`）
- 真实模式 smoke（无客户端，`--profile lan --port 7799`）→ `/net` 404 退化 `/health` → dead → `RESULT(lan-no-resume)` → 退出码 0；SIGINT 统计含 `falseAlarms/avgGapMs`
- 代码审查修复（proxy 反馈）：A1 `--last-room` + `/net.room` 房间解析、A2 端口释放等待（≤5s）、A3 join 二选一（`--client-cmdline-join`）、A4 JSONL 规范字段 null 默认、A5 `falseAlarms/avgGapMs`、A6 进程退出参与判死、B7 help 修正、B8 kill 精度、B9 `GET /join`、B10 `/net` 404 退化场景
