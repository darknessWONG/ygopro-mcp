
---

## 6. 重复性验证（run K，lead 亲自执行）

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 12 -StallSeconds 150 -Deck Blackwing
```

| 指标 | 局 J（bot-scout） | 局 K（lead，复现） |
|---|---|---|
| WIN | player=1 reason=1 (LP_ZERO) | player=1 reason=1 (LP_ZERO) |
| 回合 | 8 | 14 |
| 决策 | 128 / 127 | 213 / 213 |
| retries | 0 / 0 | 0 / 0 |
| 时长 | 299s | 482s |
| natural | True | True |
| LP 收尾 | 5700/0 | 0/4700 |

结论：自然胜负**可复现**；两局都由 MCP 控制层驱动、协议层 0 重试。

证据：`ranked/logs/lan-run-20261103-233015.log`（局 K）、`ranked/logs/lan-run-20261103-232109.log`（局 J）
