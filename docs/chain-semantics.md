# 连锁语义（chain semantics）—— `/prompt` 与 `/state` 的字段定义

> task-19，只改 `mycard-client/gframe/control.cpp`。目的：让 MCP/LLM 能像人一样回答
> 「**谁在连锁谁、为什么能连、要不要连**」。

## 1. 数据来源

| 字段 | 来源 |
| --- | --- |
| 链栈（已经成立的链） | `dField.chains`（`ClientField::ChainInfo`：`code/desc/controler/location/sequence/solved`），`MSG_CHAIN_END` 时客户端会 `chains.clear()` |
| 可连锁候选 | `dField.activatable_cards[i]` + `dField.activatable_descs[i]`（`.first`=desc id，`.second`=flag；`flag & 0x100` = 必发；`flag & EDESC_OPERATION` = 操作） |
| 卡名 | `dataManager.GetName(code)` → `wchar_t*` → UTF-8 |
| 效果文本 | `dataManager.GetDesc(desc)` → UTF-8（中文） |
| 最近一次链事件 | `OnMessageBegin` 里的 `MSG_CHAINING(70)/MSG_CHAINED(71)/MSG_CHAIN_SOLVED(73)/MSG_CHAIN_END(74)` 原始字节，UI 线程再解析成文字 |
| 提示文本 | `dField.select_hint`（`MSG_HINT` 的 `HINT_SELECTMSG`）→ `dataManager.GetDesc()` |
| 是否“我方” | `controler == SelfSeat()`（-c=0，-j=1） |

## 2. 字段（`/prompt`、`/state` 同名字段）

### 2.1 `chainDepth`
当前链数（`chainStack.length`）。0 = 场上没有链。

### 2.2 `chainStack[]`
已经加入连锁的环，按**加入顺序**（link 从 1 开始）：

```json
{
  "link": 2,
  "code": 53582587,
  "name": "激流葬",
  "desc": 1140,
  "descText": "破坏场上所有怪兽",
  "ctrl": 1,
  "loc": 4,
  "seq": 0,
  "type": "effect",
  "forced": false,
  "isMine": true,
  "solved": false,
  "summary": "我方[激流葬]（破坏场上所有怪兽） 已加入连锁"
}
```

- `ctrl/loc/seq`：卡的控制者 / 位置（4=MZONE, 8=SZONE, 2=手牌…）/ 序号
- `isMine`：这环是不是我方发动（判断“我要不要连自己的”很有用）
- `solved`：这一环是否已结算（`MSG_CHAIN_SOLVING` 之后）
- `summary`：**一句话中文决策摘要**

### 2.3 `chainingTo`
当前要回应的那一环（一般 = `chainStack` 最后一环；空链时为 `null`）：

```json
{"link": 1, "code": 53582587, "name": "激流葬", "descText": "破坏场上所有怪兽",
 "summary": "对手[激流葬]（破坏场上所有怪兽）"}
```

### 2.4 `chainCandidates[]`
本次 `MSG_SELECT_CHAIN` 里**可以点选**的每一项，`index` 就是响应要回的下标
（`/act_id` 选 `kind=chain` 时用的那个 index）：

```json
{
  "index": 0,
  "code": 65559450,
  "name": "黑羽-极北之布利扎德",
  "desc": 1141,
  "descText": "特殊召唤墓地1只怪兽",
  "forced": false,
  "isMine": true,
  "ctrl": 0, "loc": 4, "seq": 2,
  "summary": "我方[黑羽-极北之布利扎德]（特殊召唤墓地1只怪兽） 可以连锁 对手[激流葬]（破坏全场怪兽） — 可选"
}
```

> `chainCandidates` 为空 + `curMsg=16` 说明这次没有可连锁项，只能不连锁（或按 `canDecline` 判断）。

### 2.5 `canDecline`
是否允许“不连锁”。`= !dField.chain_forced`。`chain_forced=true` 时必须选一个候选。

### 2.6 `hint`
本次选择的提示文本（`select_hint`/`MSG_HINT` 的中文描述），无则空串。例：`"请选择要发动的效果"`。

### 2.7 `lastChainEvent`
最近一次连锁事件的可读描述，跟着战况走，例如：

- `我方发动 [激流葬]（破坏全场怪兽）→ 连锁`
- `连锁成立: [激流葬]`
- `连锁结算: [激流葬]`
- `连锁结束（清空）`

### 2.8 `/state.activeEffects`
改为**可读的链栈**（每项 = `chainStack[].summary`）。`MSG_CHAIN_END` 后客户端清空 `dField.chains`，
数组自动变空。原来“持续效果”的数据移到 `continuousEffects[]`（字段同旧版 `activeEffects`）。

## 3. LLM 决策建议（怎么判断要不要连锁）

1. **先看 `curMsg`**：只有 `curMsg==16`（`MSG_SELECT_CHAIN`）才是“要不要连锁”的决策点；
2. **看 `chainCandidates`**：
   - 含目标陷阱（`53582587` 激流葬 / `84749824` 神之警告 / `59839761` 三角乌鸦阵）→ 优先用它；
   - 候选里 `forced=true` 的必须选（`canDecline=false` 时也必须选一个）；
   - `isMine=true` 的候选通常是自己的诱发效果，可按“是否划算”选择；
3. **看 `chainingTo`**：要回应的是对手的哪张卡/什么效果（`descText` 就是它的效果文本），据此判断干扰/保护价值；
4. **看 `canDecline`**：`true` 时可以选择“不连锁”（`kind=decline`），`false` 时不能；
5. **看 `hint`**：服务器/客户端给的提示（例如“请选择要发动的效果”）；
6. 决策完调 `POST /act_id?id=<动作 index>`；`kind=chain` 的 `id` 顺序与 `chainCandidates` 一一对应。

## 4. 与 MCP 的交互示例

```text
GET /prompt
→ {"seq":41,"curMsg":16,"chainDepth":1,
   "chainStack":[{"link":1,"code":53582587,"name":"激流葬",
                  "descText":"破坏场上所有怪兽","isMine":false,
                  "summary":"对手[激流葬]（破坏场上所有怪兽） 已加入连锁"}],
   "chainingTo":{"link":1,"code":53582587,"name":"激流葬","descText":"破坏场上所有怪兽"},
   "chainCandidates":[{"index":0,"code":84749824,"name":"神之警告",
                        "descText":"支付2000LP，无效特殊召唤并破坏",
                        "forced":false,"isMine":true,
                        "summary":"我方[神之警告]（无效特殊召唤并破坏） 可以连锁 对手[激流葬] — 可选"}],
   "canDecline":true,"hint":"请选择要发动的效果"}

→ 判断：用神之警告去连锁激流葬没意义（激流葬不是特殊召唤）；不连锁。
POST /act_id?id=<decline 的 index>

GET /state → {"activeEffects":["对手[激流葬]（破坏全场怪兽） 已加入连锁"], "lastChainEvent":"对手发动 [激流葬]（破坏全场怪兽）→ 连锁"}
```

## 5. 日志标记

```
chain mode applied: ...
UI action kind=chain msg=16 -> card+menu chain (0) ok=1      # task-18 的实际点卡+菜单
```
（`lastChainEvent`/`chainStack` 不做逐条日志，避免刷屏；取证请抓 `/prompt`、`/state` 快照。）

## 6. 已知限制

- `chainStack.forced` 目前恒为 `false`：链历史（`dField.chains`）里没有 forced 信息，只有**候选**
  的 forced（`chainCandidates[].forced`）是准的；
- `type` 暂固定 `"effect"`（客户端链历史不区分 effect/operation；操作的候选在 `activatable_descs`
  里可用 `flag & EDESC_OPERATION` 判定，后续可加）；
- `descText` 依赖 `cards.cdb`+`strings.conf` 的 desc id 表，若服务端发的 desc 未收录则为空串（不影响 index）。
