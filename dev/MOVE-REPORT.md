# bridge/ 整理报告（task-31，可独立分发形态）

> 只做**分类与搬迁**：没有启动客户端、没有跑局、没有改 runtime 代码逻辑（只改路径引用）。
> 时间：2026-11-08。

## 1. 分类总表（搬迁前）

| 类别 | 文件 | 处理 |
|---|---|---|
| **runtime（留原地）** | `mcp-server.mjs`、`policy-semantic.mjs`、`supervisor.mjs`、`get-room.mjs`、`netfault.mjs`、`net-probe.mjs`、`doctor.mjs`（打包层新建） | 保留 |
| **ops（留原地）** | `lan-run.ps1`、`shot.ps1`、`lan-host.cmd`、`lan-guest.cmd`、`reconnect-lab-run.ps1`、`reconnect-lab.ps1`、`reconnect-lab2.ps1`、`ranked-play.ps1`、`ranked-reconnect-lab.ps1`、`refactor-compare.mjs` | 保留 |
| **doc（留原地/打包层）** | `README.md`、`netfault.md`、`net-probe.md`、`docs/**` | 保留 |
| **dev-only → `dev/`** | `_probe-*.mjs`(6)、`_launchtest.mjs`、`_cdb.py`、`_deckcomp.py`、`_decktypes.py`、`custom-room-test.{mjs,ps1}`、`hs2.ps1`、`hs-probe.ps1`、`lobby-test*.ps1`(2)、`play-room.ps1`、`room-join-run.ps1`、`final-run.ps1`、`wait-and-run.ps1`、`watch-demo.ps1`、`synchro-test.ps1`、`sem-test*.ps1`(2)、`lan-test.ps1`、`ranked-*.ps1`(5：bot 除外，除 ranked-play)、`ranked-bot.mjs`、`ranked-run.mjs`、`ranked-proxy.ps1`、`policy-basic.mjs`、`policy-heuristic.mjs`、`policy-naive.mjs`、`overlay.mjs`、`mcp-selftest.mjs`、`capture-chain.ps1`、`diag-*.ps1`(2)、`launch-guest.cmd`、`run-guest.cmd` | **移动（41 个，文件名不变）** |
| **artifact → `dev/artifacts/`** | `ranked-0*.png`(4)、`shot-ctl1.png`、`stock-ready-rank.png`、`mcp-err.txt`、`mcp-out.jsonl`、`mcp-req.jsonl` | **移动（9 个）** |
| **删除** | 无（证据类只搬不删，`dev/artifacts` 用 `.gitignore` 排除入库） | — |

## 2. 新增文件

| 文件 | 内容 |
|---|---|
| `bridge/dev/README.md` | 说明"dev/ 不属于运行时、可整目录删除"，并按类别列出内容 |
| `bridge/.gitignore` | 忽略 `dev/artifacts/`、`*.png`、`mcp-*.jsonl`、`mcp-*.txt`、`*.log`、`ranked/`、`logs/`、`node_modules/`、`.env` 等 |

## 3. 修改的引用

| 文件 | 修改 |
|---|---|
| `bridge/refactor-compare.mjs` | 基线复跑说明里的采样器路径：`bridge\diag-ref-baseline.ps1` → `bridge\dev\diag-ref-baseline.ps1` |
| `bridge/dev/*.ps1`（12 个） | 兄弟脚本引用改为 `bridge\dev\policy-heuristic.mjs` / `policy-basic.mjs` / `ranked-bot.mjs` / `overlay.mjs` |
| `bridge/dev/ranked-run.mjs` | 日志文本里的 `bridge/policy-basic.mjs` → `bridge/dev/policy-basic.mjs` |
| `bridge/dev/ranked-proxy.ps1` | 搬移时注释被 ASCII 归一化，原含中文的 `MSG_WIN|...` 正则改为 ASCII 等价词 `MSG_WIN|GAME OVER|LP_ZERO|winReason`（**逻辑不变**） |
| `bridge/dev/diag-ui-windows.ps1` | 同上：头注释改为英文（脚本行为不变） |
| `bridge/docs/MCP-INTERFACE.md` | `bridge/diag-ui-windows.ps1` → `bridge/dev/...`（2 处） |
| `bridge/docs/ui-verify.md` | 采样器路径改为 `bridge\dev\diag-ui-windows.ps1`（顺带修了原有的 `rridge` 笔误） |
| `bridge/docs/refactor-baseline.md` | `bridge\diag-ref-baseline.ps1` → `bridge/dev/...` |

> 说明：dev 脚本的注释在搬迁时被统一成 ASCII（PowerShell 5.1 无 BOM 场景下最稳）；
> 仅注释文本变化，**脚本逻辑、参数、默认值均未改**。

## 4. 验收

| 检查 | 结果 |
|---|---|
| runtime/ops `node --check`（mcp-server / policy-semantic / supervisor / get-room / netfault / net-probe / refactor-compare） | **7/7 OK** |
| ops `.ps1` PS5.1 `Parser::ParseFile`（lan-run / shot / reconnect-lab / reconnect-lab2 / reconnect-lab-run / ranked-play / ranked-reconnect-lab） | **0 error** |
| `dev/*.ps1` 语法解析（只 parse，不运行） | **0 error** |
| bridge 根脚本对已移动文件的旧路径引用 | **0** |
| docs 对已移动脚本的旧路径引用 | **0** |
| 启动过客户端 / 占端口 | **否** |

## 5. 最终 `bridge/` 根形态

```
bridge/
├── .gitignore
├── doctor.mjs                 # 打包层自检（task-32）
├── get-room.mjs
├── lan-guest.cmd / lan-host.cmd
├── lan-run.ps1
├── LICENSE                    # task-32
├── mcp-server.mjs
├── netfault.mjs / netfault.md
├── net-probe.mjs / net-probe.md
├── package.json               # task-32
├── policy-semantic.mjs
├── ranked-play.ps1
├── ranked-reconnect-lab.ps1
├── README.md                  # task-32
├── reconnect-lab.ps1 / reconnect-lab2.ps1 / reconnect-lab-run.ps1
├── refactor-compare.mjs
├── shot.ps1
├── supervisor.mjs
├── dev/                       # 开发/排障脚本（可整目录删除）+ artifacts/
├── docs/                      # 文档（未动内容，仅修路径引用）
└── examples/                  # MCP 宿主配置示例（task-32）
```
