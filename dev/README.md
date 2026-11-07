# bridge/dev —— 开发/排障脚本（不属于运行时）

这个目录里的东西**不是**分发版运行所需的文件，保留只是为了让维护者能复现早期实验与排障；
拿出去用的人可以整个删掉 `dev/`，运行时不受影响。

## 内容分类

| 类别 | 例子 | 说明 |
|---|---|---|
| `_probe-*.mjs`、`_launchtest.mjs`、`_cdb.py`、`_deckcomp.py`、`_decktypes.py` | 早期协议/卡库探测脚本 | 一次性诊断用，硬编码了当时的实验条件 |
| `*-test.ps1`、`hs2.ps1`、`hs-probe.ps1`、`lobby-test*.ps1`、`play-room.ps1`、`room-join-run.ps1`、`final-run.ps1`、`wait-and-run.ps1`、`watch-demo.ps1`、`synchro-test.ps1`、`sem-test*.ps1`、`lan-test.ps1`、`capture-chain.ps1`、`diag-*.ps1` | 旧版跑局器/采样器 | 多被 `lan-run.ps1` / `reconnect-lab-run.ps1` 取代；保留作对照 |
| `policy-basic.mjs`、`policy-heuristic.mjs`、`policy-naive.mjs`、`ranked-bot.mjs`、`ranked-run.mjs`、`overlay.mjs`、`mcp-selftest.mjs` | 旧策略/工具 | 运行时策略是 `../policy-semantic.mjs` |
| `ranked-*.ps1`（`ranked-play.ps1` 除外，它在 `../` 是运维脚本） | 早期排位尝试脚本 | 账号/房间条件已过时 |
| `artifacts/` | 旧截图（`*.png`）、MCP 自测输出（`mcp-*.jsonl/txt`） | 纯证据文件，可随时删除 |

## 注意

- 这些脚本里引用的兄弟脚本路径已改为 `bridge/dev/...`；但**旧脚本本身没有维护承诺**，接口可能对不上当前客户端。
- 不要把这些脚本放进分发包的入口（`package.json` 的 `bin/scripts` 只指向 `../mcp-server.mjs`、`../doctor.mjs` 等）。
- 需要复现某段历史时，配合 `../docs/` 下对应报告看（例如 `../docs/reconnect-lab.md`、`../docs/ui-verify.md`）。
