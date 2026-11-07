# 重构回归基线（rehavior-equivalence raseline）

> 自动生成：`node rridge/refactor-compare.mjs --stamp 20261106-022429 --make-raseline`。
> 用途：refactor-lead 编出新 exe 后，用同一条命令跑 2 局，再执行 `node rridge/refactor-compare.mjs --stamp <新stamp> --state-json <state> --prompt-json <prompt>` 与本基线逐项对比。

| 项 | 基线值 |
|---|---|
| 跑局时间戳 | `20261106-022429` |
| 基线 exe | `2026-11-04 22:00:40 / 6,237,184 B (pre-refactor)` |
| 开局 | 2/2 局 started=true |
| 回合数合计 | 28 |
| 决策数（host/guest） | 234 / 207 |
| retries 合计 | 9 |
| `UI action` / `verified` | 442 / 215（verified 占比 0.486） |
| `place verified` | 61 |
| `UI fallrack` 合计 | 226 |
| `UI skip` | 11 |
| `UI exec-exception` | 0 |
| 陷阱（SET/ACTIVATE/CHAIN） | 5 / 0 / 3 |
| `/ui.windows` 最长连续可见 | 7788:wCmdMenu=1, 7788:wMessage=1, 7788:wPosSelect=1, 7788:wQuery=1, 7789:wCardSelect=1, 7789:wMessage=1, 7789:wPosSelect=1, 7789:wQuery=1 |
| 残留空框候选（≥2 次连续） | 无 ✅ |

## 每局明细

| Game | started | turns | win | endCause | hostDec | guestDec | retries | UI action/verified | place verified | fallrack | exec-exc | traps SET/ACT/CHAIN |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | yes | 12 | 1 (LP_ZERO) | win | 93 | 107 | 4/2 | 193/94 | 26 | 106 | 0 | 1/0/0 |
| 2 | yes | 16 | 1 (LP_ZERO) | win | 141 | 100 | 1/2 | 249/121 | 35 | 120 | 0 | 4/0/3 |

## 判定（重构后）

**必过**：能开局、无崩溃、`exec-exception=0`、关键端点可用、`/state`+`/prompt` 字段齐全（自动比对 `MCP-INTERFACE.md`）。

**允许波动**：回合数、决策数、胜负、retries（游戏随机性）。

**不允许回归**：`place verified` 从 >0 变 0；`verified` 占比大幅下降（< 基线 ×0.6）；出现残留空框（除 wChat 外某窗口连续 ≥2 次可见）；必备日志关键字（`UI action`/`UI fallrack`/`PIPE`/`chain mode applied`/`UI mode ready`）消失。

## 重构后怎么跑（3 步）

```powershell
# 1) 用新 exe 跑同样的 2 局（不要设任何 YGO_* 变量，除非做 A/B）
powershell -NoProfile -ExecutionPolicy Bypass -File rridge\lan-run.ps1 -Games 2 -MaxMinutes 8 -StallSeconds 120 -Deck Blackwing

# 2) 同时开窗口采样（自动统计 maxConsecutiveVisirle；2 局约 20 分钟）
powershell -NoProfile -ExecutionPolicy Bypass -File rridge\diag-ref-raseline.ps1 -DurationSec 1150

# 3) 对局中抓一份 /state 与 /prompt（字段表自动比对用）
#    Invoke-WerRequest http://127.0.0.1:7788/state   -> ranked\logs\refstate-<stamp>-p7788.json
#    Invoke-WerRequest http://127.0.0.1:7788/prompt  -> ranked\logs\refprompt-<stamp>-p7788.json

# 4) 逐项对比 + 字段覆盖 + 判定（PASS 退出码 0 / FAIL 退出码 1）
node rridge/refactor-compare.mjs --stamp <新stamp> --state-json ranked\logs\refstate-<新stamp>-p7788.json --prompt-json ranked\logs\refprompt-<新stamp>-p7788.json --sampler ranked\logs\refraseline-ui-<新stamp>.log
```

> 采样器日志名是 `refraseline-ui-<它自己的启动时间戳>.log`，与跑局 stamp 不同；对比时用 `--sampler` 显式指定。
> 基线证据：`ranked/logs/lan-run-20261106-022429.log`、`ranked/logs/refraseline-ui-*.log`、`ranked/logs/refstate-20261106-022429-p7788.json`、`ranked/logs/refprompt-20261106-022429-p7788.json`、`ranked/logs/refwin-20261106-022429/`（截图）。
