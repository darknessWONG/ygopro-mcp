# ygopro-mcp

把 **YGOPro 客户端**接到 **MCP（Model Context Protocol）**：LLM / agent 通过 14 个 MCP 工具，
用「语义动作」打牌——不用拼 CTOS/STOC 二进制帧，也不需要用像素点屏幕。

```
   LLM / agent（MCP 宿主）
        │  MCP over stdio (JSON-RPC)
        ▼
   bridge/mcp-server.mjs        薄桥：14 个工具 → HTTP
        │  HTTP 127.0.0.1:7788（房主）/ 7789（客机）
        ▼
   带控制层的 YGOPro 客户端      进程内 HTTP server + 动作编码 + UI 注入
        │  CTOS_RESPONSE / STOC_*
        ▼
   ygopro 内核（ocgcore）+ 真实客户端窗口
```

- **控制层**负责：协议编解码、线程安全、把「召唤/盖放/发动/攻击/选卡」编码成内核能接受的响应，
  并尽量走真实 UI 注入（点不中时自动回退为直连响应，保证绝不死锁）。
- **bridge** 只做两件事：把 MCP 工具映射成 HTTP 调用；提供一个参考策略（`policy-semantic.mjs`）
  和运维工具（doctor / supervisor / netfault / net-probe）。

---

## 1. 前置条件

| 需要 | 说明 |
|---|---|
| **带控制层的 YGOPro 客户端** | 本仓库**不包含**客户端二进制。控制层是客户端源码里的扩展（`gframe/control*.cpp`，HTTP 端点 `/state` `/prompt` `/wait_prompt` `/actions` `/act_id` `/net` `/ui` 等）。<br>**已测试构建**：`YGOPro.exe` **`2026-11-08 03:38:41` / `6,290,944 B`**（用 `node doctor.mjs --client <exe>` 可核对指纹）。<br>构建：用带控制层补丁的 YGOPro 源码（MyCard 客户端 fork）自行编译，产物放到例如 `mycard-client/bin/release/x64/YGOPro.exe`。 |
| **Node.js ≥ 18** | 只用内置模块（`fetch`/`http`/`child_process`），**零 npm 依赖**。 |
| （可选）卡组 `.ydk` | 客户端自己的 `deck/` 目录；控制层用 `POST /deck?name=Blackwing` 预载。本仓库不含卡图/卡表。 |

> 控制端口：房主默认 **7788**，客机默认 **7789**（客户端用 `YGO_CONTROL_PORT` 指定）。

---

## 2. 快速开始（3 步）

```powershell
# ① 先启动带控制层的客户端（房主 / 客机各一个进程）
#    房主示例（控制端口 7788，监听 7911）
$env:YGO_CONTROL_PORT='7788'
.\mycard-client\bin\release\x64\YGOPro.exe -c -h 127.0.0.1 -p 7911 -n HostA -d Blackwing -k

# ② 启动 MCP server（stdio；本身不占网络端口）
cd bridge
npm start                 # 等价于 node mcp-server.mjs
#   客机位（7789）时：
#   $env:CONTROL_URL='http://127.0.0.1:7789'; npm start

# ③ 在你的 MCP 宿主里配置（示例见 examples/）
#   command = node
#   args    = ["<绝对路径>/bridge/mcp-server.mjs"]
#   env     = { CONTROL_URL: "http://127.0.0.1:7788" }
```

宿主配置片段：`examples/claude_desktop_config.json`（Claude Desktop）、`examples/cursor.mcp.json`
（Cursor）、`examples/dsh.mcp.json`（DeepSeek Harness）。路径换成你自己的即可。

**最小调用循环**（agent 侧）：

```
control_wait_prompt({since: lastSeq})    // 长轮询，等一个需要你回答的 prompt
control_actions()                        // 本 prompt 的候选：{id, kind, label}
control_act_id({id})                     // 提交你选中的候选
lastSeq = prompt.seq
```

三条铁律：① 动作必须匹配当前 `seq`（旧 seq 会被拒：`stale seq`）；② `/state.started` ≠
`/health.started`（前者是"决斗已开始"，后者是"控制服务在监听"）；③ 看到 `UI fallback` 是正常兜底，不是故障。

---

## 3. 自检

```powershell
cd bridge
npm run doctor              # = node doctor.mjs（默认探测 127.0.0.1:7788）
node doctor.mjs --port 7789 # 客机位
node doctor.mjs --client "C:\path\to\YGOPro.exe"   # 顺带核对 exe 指纹
```

输出 `[GREEN]/[YELLOW]/[RED]/[INFO]` 每项检查 + `HINTS` + `JSON`；**退出码 0 = 全绿，1 = 有问题**。
没有客户端时会输出 RED 并提示「先启动带控制层的 YGOPro 客户端（房主 7788 / 客机 7789）」。

---

## 4. 目录说明

| 路径 | 类别 | 作用 |
|---|---|---|
| `mcp-server.mjs` | runtime | MCP stdio server，14 个工具 → HTTP |
| `policy-semantic.mjs` | runtime | 参考策略（语义决策循环；可当 LLM 的替身） |
| `supervisor.mjs` | runtime | 常驻监护：读 `/net` 判掉线；`--profile lan` 只记账，`--profile ranked` 重启客户端并重连+验证 |
| `doctor.mjs` | ops | 自检（本文件） |
| `netfault.mjs` | ops | 故障注入 TCP 代理（`freeze`/`drop`/`reject`），用于测掉线检测 |
| `net-probe.mjs` | ops | 轮询 `/net` 出时间线 CSV + `EVENT DEAD/ALIVE` |
| `lan-run.ps1` / `lan-host.cmd` / `lan-guest.cmd` | ops | 本地 LAN 一键起房/客机跑局 |
| `reconnect-lab-run.ps1` | ops | 掉线检测实验（host + 客机走 netfault + 注入故障 + 汇总） |
| `netfault.md` / `net-probe.md` | doc | 对应工具的用法 |
| `docs/` | doc | 权威接口规范与设计文档（见下） |
| `examples/` | doc | MCP 宿主配置片段 |
| `dev/` | dev-only | 维护者的开发/排障脚本（一次性探针、旧实验脚本），**不属于运行时分发内容**，分发时可整目录删掉 |

> 维护者的开发/排障脚本（一次性探针、旧实验脚本）不属于运行时分发内容。

---

## 5. 已知限制

- **LAN 不支持续局**：本地 LAN 服务端不能"掉线后回到原对局"；`supervisor --profile lan` 只检测+记账。
  真正的续局验证只能在线上（`--profile ranked`，需要客户端 journal/`/net` 支持）。
- **ranked（线上排位）** 需要较新的客户端构建（`/net`、`isWin/isLoss/isDraw`、`deckError`、prompt 快照一致性修复）；
  旧构建会缺字段（doctor 会提示，policy 会记 `isWin=unknown` 而不是猜）。
- **自动化有账号风险**：排位自动对战可能违反服务条款/被判异常，请自行评估；本仓库不含任何账号凭据。
- **不含卡图/卡表/卡组**：只做控制层桥接，卡牌数据由客户端自己管理。
- **UI 注入不是 100%**：部分语义词（`select/sum/sort/counter/announce/auto`）仍走直连响应（刻意保留的兜底），
  详见 [`docs/direct-actions.md`](docs/direct-actions.md)。
- 动作被内核拒绝时看 `/state.retryCount/retryStreak`；prompt 卡住时看 `/state.pipeline` 与
  `pipeline.recentMsgs`（需要新构建）。

---

## 6. 权威文档

| 文档 | 内容 |
|---|---|
| [`docs/MCP-INTERFACE.md`](docs/MCP-INTERFACE.md) | **接口规范（权威）**：14 个工具、所有 HTTP 端点、`/state`/`/prompt`/`/ui` 字段、`/actions` kind 全表、连锁语义、UI 注入设计、运行开关、排障 |
| [`docs/RECONNECT-DESIGN.md`](docs/RECONNECT-DESIGN.md) | 掉线/重连设计：`/net` 状态机、supervisor 职责、journal（`resume-context-<port>.json`）、探活参数 |
| [`docs/supervisor.md`](docs/supervisor.md) | supervisor 用法、状态机、JSONL 字段 |
| [`docs/direct-actions.md`](docs/direct-actions.md) | 哪些动作走 UI、哪些走直连、对 LLM 的影响、改进路线 |
| [`net-probe.md`](net-probe.md) / [`netfault.md`](netfault.md) | 掉线检测量化工具 / 故障注入代理用法 |

环境变量清单见 [`.env.example`](.env.example)（与代码里 `process.env.*` 一一对应）。

---

## 7. FAQ / 排障

**Q: `doctor.mjs` 报 RED "连不上 127.0.0.1:7788"？**
A: 客户端没起、或没用带控制层的构建、或端口不是 7788。检查客户端启动日志是否有
`control: started port=7788`；用 `netstat -ano | findstr :7788` 看端口。

**Q: 两个客户端同时跑，端口冲突？**
A: 每个客户端要不同的 `YGO_CONTROL_PORT`：房主 7788、客机 7789（`lan-run.ps1` 就是这么分的）。
对应 MCP server 的 `CONTROL_URL` 也要指向你要控制的那一端。

**Q: 客机想走代理/故障注入，但流量没过去？**
A: 客户端的 `-j` 参数会用 `system.conf` 的 `lasthost/lastport` 自动加入并**忽略 `-p`**；
要经代理必须**不带 `-j`**、起来后用控制层 `GET /join?ip=127.0.0.1&port=7912&pass=` 显式进房，
并断言代理 `totalConnections >= 1`（`reconnect-lab-run.ps1` 已内置该断言）。

**Q: 动作被拒 (`ok:false / stale seq`)？**
A: prompt 已经前进了。丢弃这次决策，重新 `control_wait_prompt` + `control_actions`；
`/state.retryStreak` 持续上涨说明响应编码有问题（看 `/state.lastRetryAfterMsg`）。

**Q: 卡组非法 / 开局不动？**
A: 新构建在 `/state.deckError` 给出原因；用合法的 `.ydk`（例如 `Blackwing.ydk`）。
旧构建会弹"卡组非法"模态框阻塞，需要新构建（会自动 suppress）。

**Q: 怎么确认"我们赢了还是输了"？**
A: 用 `/state.isWin`（本地视角）。**不要**用 `winPlayer`（那是 raw 座位号，本机是 raw seat 1，
`winPlayer=0` 表示对手赢）；旧构建没有 `isWin` 时用 `winPlayerLocal===0`，再没有就记 `unknown`，不要猜。
