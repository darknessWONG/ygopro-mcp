# 重构回归验收（rerun of behavior-equivalence baseline）

> **状态：定稿（PASS）** —— 2026-11-06 回归执行方 bot-scout；重构方 refactor-lead（core-embedded-arch）。
> 对比对象：`bridge/docs/refactor-baseline.md`（基线与本次跑局均使用同一脚本、同一卡组、默认环境）。
> 判定脚本：`bridge/refactor-compare.mjs`（退出码 0=PASS）。

## 0. 结论

**PASS**（9/9 检查项通过，无 FAIL）。

| | 基线（重构前） | 本次（重构后） |
|---|---|---|
| exe | `2026-11-04 22:00:40 / 6,237,184 B`（control.cpp 3008 行单文件） | **`2026-11-06 02:56:20 / 6,242,304 B`**（7 模块：control.cpp 1152 行 + control_sem/actions/lobby/ui/state 等） |
| 跑局 | `lan-run-20261106-022429.log`（2 局） | `lan-run-20261106-025647.log`（2 局） |
| 采样 | `refbaseline-ui-20261106-022434.log` | `refbaseline-ui-20261106-025655.log` |
| 二进制留档 | `_backups\YGOPro-baseline-6a9189d-20261106-0308.exe`（6,237,184 B，SHA256 `319B7808…3F6D`） | `_backups\YGOPro-refactor-20261106-0256.exe`（6,242,304 B，SHA256 `E59B9ED6…8CBC`，与当前 `bin/release/x64/YGOPro.exe` 字节一致） |

> 补充：基线二进制一度以为"没有备份"，后由 refactor-lead 从 `6a9189d` 重建并归档，**size 与原始 22:00:40 完全一致（6,237,184 B）**，说明基线源码状态可确定性复现；新旧两版 exe 现已齐备，可随时做同场 A/B。

## 1. 逐项判定（`node bridge/refactor-compare.mjs --stamp 20261106-025647 ...`）

| 检查项 | 结果 | 说明 |
|---|---|---|
| `all_games_started` | ✅ PASS | 2/2 局 `started=true`，`[5/8] start bots` 均出现 |
| `no_client_crash` | ✅ PASS | G1 `endCause=win`、G2 `endCause=deadline`，无 client-exit/崩溃 |
| `exec_exception_zero` | ✅ PASS | `UI exec-exception` 合计 **0** |
| `place_verified_not_regressed` | ✅ PASS | **63 ≥ 基线 61**（G1 26 / G2 37） |
| `ui_verified_ratio` | ✅ PASS | **0.483 vs 基线 0.486**（阈值：≥基线×0.6） |
| `required_log_keywords` | ✅ PASS | `UI action / UI fallback / PIPE / chain mode applied / UI mode ready` 两端齐全 |
| `state_field_coverage` | ✅ PASS | 与 `MCP-INTERFACE.md` §4 字段表比对：**missing=0**（快照 123 keys） |
| `prompt_field_coverage` | ✅ PASS | **missing=0**（快照 41 keys；含连锁 7 字段） |
| `no_stuck_window` | ✅ PASS | 见 §3「1×1 ghost 说明」 |

## 2. 关键指标对比（允许波动的项仅作记录）

| 指标 | 基线 | 本次 | 判读 |
|---|---|---|---|
| 回合 / 决策 | 28 回合；hostDec 234 / guestDec 207 | **34 回合；hostDec 284 / guestDec 168** | 游戏随机，正常 |
| 胜负 | G1 win=1 LP_ZERO（natural）；G2 win=1 LP_ZERO（natural） | **G1 win=1 LP_ZERO（natural=True，10 回合/345s）；G2 deadline（24 回合/521s，未判定）** | 允许波动 |
| retries | 9 | 5 | 允许波动 |
| `UI action` / `verified` | 442 / 215（0.486） | **472 / 228（0.483）** | 一致 |
| `UI fallback` / `UI skip` | 226 / 11 | **224 / 13** | 一致 |
| 陷阱 SET/ACTIVATE/CHAIN | 5 / 0 / 3 | 2 / 0 / 1 | 抽牌随机，非回归项 |
| 采样样本 | — | 302 samples（151 duel / 41 idle）、26 截图 | — |

## 3. `no_stuck_window` 与 1×1 ghost 说明（重要）

第一次跑对照时该检查报 FAIL：`[["7788:wPosSelect",2],["7789:wQuery",2]]`。核查原始采样后确认**不是可见残留空框**：

- 命中项 rect 全部是 **1×1 像素**：`wPosSelect|993,454,994,455`、`wQuery|996,405,997,406`（area=1）
- 同坐标 1×1 元素**基线也存在**：基线采样里 `wPosSelect|993,454,994,455` 出现在 145s/442s/843s，`wQuery|996,405,997,406` 出现在 39s/727s/764s（只是没有连续两次被 5s 采样命中）
- 这是 irrlicht 折叠窗口留下的 1×1 "ghost" 元素，**屏幕上看不见**；对照截图（`ranked/logs/refwin-20261106-025655/lan-ref2-1.png` 等 60s 画面）无任何弹窗
- 真正会挂住的可见空框（用户报的 `wQuery` 350×62、textLen=0）本次未出现：大尺寸 `wQuery`（`821,348,1171,462`，textLen=14）只出现单次采样，且**有正文**
- 因此判定脚本的 `no_stuck_window` 改为"只统计 **area ≥ 16 px²** 的窗口连续 ≥2 次"（参数 `--min-stuck-area`，默认 16），并把 1×1 元素单列为 `sampler.ghosts` 留档；重跑后 **PASS**

## 4. 错误路径专项（refactor-lead 关心的 `goto → return` 改造）

在对局进行中（turn 3）手工打了 7 次错误请求，**全部返回等价错误体、无死锁**（打完后双方继续行动到该局结束）：

| 请求 | 返回 |
|---|---|
| `/act?seq=1`（无 i/hex） | `{"ok":false,"error":"need hex or i"}` |
| `/act?seq=999999&i=0`（过期 seq） | `{"ok":false,"error":"stale seq","seq":<当前>}` |
| `/act?seq=0&i=0`（not awaiting 时） | `{"ok":false,"error":"not awaiting"}` |
| `/act_id?id=9999`（not awaiting 时） | `{"ok":false,"error":"not awaiting"}` |
| `/act_id?id=9999`（**awaiting 时**，curMsg=41） | `{"ok":false,"error":"bad action id"}` |
| 未知路径 `/does-not-exist` | **HTTP 404**（空 body） |
| 全部 11 个 GET 端点（`/health /state /prompt /actions /ui /lobby /hs /stoc /ctos /msg /chat`） | HTTP 200 + 合法 JSON |

→ `HandleClient` 的 `return body` 改造与原来的 `goto` 语义等价，`lock_guard` 在 return 时正常释放；**没有死锁、没有异常、没有 404 漂移**。

## 5. 产物

- 对照报告（JSON）：`ranked/logs/refactor-compare-20261106-025647.json`
- 跑局日志：`ranked/logs/lan-run-20261106-025647.log`、`lan-state-20261106-025647-g1/g2.json`
- 控制层日志：`mycard-bot/game/control-2704.log`（G1 host）、`control-5356.log`（G1 guest）、`control-22600.log`（G2 host）、`control-3248.log`（G2 guest）
- 快照：`ranked/logs/refstate-20261106-0256-p7788/p7789.json`、`refprompt-20261106-0256-p7788/p7789.json`、`refprompt-chain-20261106-0256-p7788/p7789.json`
- 采样：`ranked/logs/refbaseline-ui-20261106-025655.log`、截图 `ranked/logs/refwin-20261106-025655/`（26 张）
- 脚本：`bridge/refactor-compare.mjs`（本次新增 `--min-stuck-area` 过滤、BOM 安全 JSON 读取、control 日志在 `mycard-bot/game/` 的路径修正）
