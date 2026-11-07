# 同调 + 超量 + 胜利（本地演示局）

## 结果

### 局 1（2026-11-04 00:04，`ranked/logs/lan-run-20261104-000400.log`）

| 项目 | 结果 |
|---|---|
| 同调召唤 | `17377751 黑羽-煌星之怒剑鸟`（Lv5 Synchro）——**双方各一次** |
| 超量召唤 | `73347079 急袭猛禽-武力林鸮`（Rank4 XYZ）——**双方各一次** |
| 结局 | **`MSG_WIN player=0 reason=1(LP_ZERO)`** |
| 回合 / 时长 | 11 回合 / 415 秒 |
| 决策 | host 183 / guest 177 |
| retries | 0 / 0 |
| LP 轨迹 | 8000/8000 → … → **8000 / 0** |
| natural | True |

两端 bot 日志都出现：

```
MISSION synchro DONE (field type 0x2000) -> synchro=OK xyz=TODO
MISSION xyz DONE (field type 0x800000) -> synchro=OK xyz=OK
duel finished turn=11 winPlayer=0 reason=1 winReasonName=LP_ZERO
```

两端客户端日志：`MSG_WIN player=0 reason=1(LP_ZERO)`。

### 局 2（2026-11-04 00:11，`ranked/logs/lan-run-20261104-001137.log`）

| 项目 | 结果 |
|---|---|
| 同调召唤（host） | `73580471 黑蔷薇龙`（Lv7 Synchro） |
| 超量召唤（host） | `73347079 急袭猛禽-武力林鸮`（Rank4 XYZ） |
| 结局 | **`MSG_WIN player=0 reason=1(LP_ZERO)`** |
| 回合 / 时长 | 9 回合 / 473 秒 |
| 决策 | host 223 / guest 186 |
| retries | 0 / 0 |
| natural | True |

## 实现

`bridge/policy-semantic.mjs` 新增 **MISSION 模式**：

- 从 `/state` 的 `monsters[0][].ty` 判断场上是否有同调（`0x2000`）/ 超量（`0x800000`）怪兽；
- 两个都完成前：不攻击（保留素材），按缺口选择 `spsummon`（优先缺的类型），召唤时优先选择与场上等级相同的怪兽（为超量准备素材）；
- 两个都完成后：切回 aggro 策略，正常进攻直到胜利。

`/actions` 里 `spsummon` 的 label 已带类型标签（`synchro` / `xyz` / `link`），bot 直接按标签选。

## 复现命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 1 -MaxMinutes 18 -StallSeconds 200 -Deck Blackwing
```

跑起来后会弹出两个 YGOPro 窗口（host 7788 / guest 7789），可以直接看它们打。
