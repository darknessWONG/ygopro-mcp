# 重构最终报告 — control 层拆分（control.cpp → 7 模块）

> 任务：`task-24`（已 complete）
> 基线：git `6a9189d` "baseline before refactor"
> 终态：git `d7f38d1`（工作树 clean）
> 回归：**PASS 9/9**（bot-scout，`bridge/docs/refactor-verify.md`）
> 详细源码地图：`bridge/docs/MODULE-MAP.md`

---

## 1. 一句话结论

把 3008 行的单文件控制层拆成 **7 个 `.cpp` + 1 个内部头**，
**外部行为零变化**（HTTP 端点 / JSON 字段 / 连锁语义 / 环境变量 / 日志关键字全部保持不变），
并通过了 2 局全量回归 + 错误路径专项验证，无崩溃、无死锁、无 `UI exec-exception`。

---

## 2. 提交列表（master）

| commit | 内容 |
|---|---|
| `6a9189d` | **baseline before refactor** —— 重构前原样留档（含未跟踪的 control.{cpp,h}、control_sem.inc 与 5 个上游改动文件），提供回滚网 |
| `6683280` | **A**：新增 `control_internal.h`；`control.cpp` 拆出 `control_state.cpp`（快照 + 全部 JSON 序列化） |
| `68e1435` | **B**：拆出 `control_ui.cpp`（UI 注入/清理/窗口/连锁时点 + `ExecUiAction`）与 `control_lobby.cpp`（卡组/准备/开始/加入 + `ExecLobbyAction`）；`ExecuteAction` 变为瘦分发器 |
| `46cde55` | **C**：拆出 `control_actions.cpp`（`ExecuteAction` 分发 + 原始响应）与 `control_sem.cpp`（语义动作）；`HandleClient` 的端点表迁入 `RouteRequest()`；**两处跨作用域 `goto` 改为 `return`**；删除死文件 `control_sem.inc` |
| `d7f38d1` | `control.h` / `control.cpp` 补 GPLv2 头；`.gitignore` 补 `buildtmp_out/` |

每一批都是**独立可编译、可回退**的（B、C 失败可单独 `git revert` 而不动 A）。

---

## 3. 行数变化

| 文件 | 行数 | 职责 |
|---|---:|---|
| `control.cpp` | **1151** | 生命周期 / HTTP + `RouteRequest` / `Pump` / 上游钩子 / 日志 / **全局变量唯一定义处** |
| `control_internal.h` | 367 | 内部共享：Snap 结构 + `extern` 全局 + 跨 TU 声明 |
| `control_state.cpp` | 727 | 快照采集 + JSON 序列化 |
| `control_ui.cpp` | 652 | UI 注入 / 清理 / 窗口诊断 / 连锁时点 |
| `control_sem.cpp` | 306 | 语义动作列表与编码 |
| `control_lobby.cpp` | 274 | 卡组 / 准备 / 开始 / 加入 / 投降 |
| `control_actions.cpp` | 140 | 动作分发 + 原始响应 |
| `control.h` | 57 | 对外接口（+GPLv2 头） |
| **合计** | **3674** | 原单文件 3008 行 |

**为什么总量反而增加约 22%？**（如实说明，不是逻辑变多）

1. **GPLv2 头** 18 行 × 7 个新文件 ≈ **+126 行**；
2. **重复的 `#include` 块**（原单 TU 共享一份）≈ 44 行 × 6 个新文件 ≈ **+264 行**；
3. **namespace 包裹与函数包装**（`ExecUiAction`/`ExecLobbyAction` 的 switch 外壳、分区注释）≈ **+150 行**；
4. 保留的死代码/重复 helper（`g_uiActionCount`、`g_sentMain`、`HexBytes` 与 `Hex`、`CtlDbg` 与 `DbgLog`）**未删**，约 **+120 行** —— 因为删除会改变 diff 面且可能影响日志基线。

**净效果**：单文件 3008 行 → 最大单文件 1151 行；职责边界清晰，改动可定位。
若后续想压缩总量，可做：合并重复 include 到预编译头 / 清理上述死代码 / 抽取共用 helper —— 属独立小任务。

---

## 4. 回归结论（bot-scout，exe 02:56:20 / 6,242,304 B）

| 判定项 | 结果 |
|---|---|
| `all_games_started` | 2/2 ✅ |
| `no_client_crash` | ✅ |
| `exec_exception_zero` | 0 ✅ |
| `place_verified` | **63 ≥ 基线 61** ✅ |
| `ui_verified_ratio` | **0.483** vs 基线 0.486 ✅ |
| 日志关键字齐全 | ✅ |
| `/state` 字段 | 118 keys，**missing = 0** ✅ |
| `/prompt` 字段 | 54 keys，**missing = 0**（连锁 7 字段齐全）✅ |
| `no_stuck_window` | ✅（1×1 px ghost 元素经核查为采样噪声，基线同样存在） |

**错误路径专项**（对局进行中构造 7 次请求）：

| 请求 | 返回 | 结论 |
|---|---|---|
| 未知路径 | HTTP **404** | ✅ |
| `/act?seq=999999` | `{"ok":false,"error":"stale seq","seq":28}` | ✅ 带当前 seq |
| `/act` 无 i/hex | `{"ok":false,"error":"need hex or i"}` | ✅ |
| 非 awaiting 时 `/act` | `{"ok":false,"error":"not awaiting"}` | ✅ |
| 非 awaiting 时 `/act_id` | `{"ok":false,"error":"not awaiting"}` | ✅ |
| awaiting 时 `/act_id?id=9999` | `{"ok":false,"error":"bad action id"}` | ✅ |
| 打完后对局继续（G1 10 回合胜、G2 24 回合 deadline） | **无死锁** | ✅ |

`/state.retryCount` **仍出现两次**（既有行为，有意保留）。

---

## 5. 两个需要注意的发现（写给后来的维护者）

### 发现 1：`files { "*.cpp" }` 的 glob 是**生成工程时**求值，不是编译时

`gframe/premake5.lua` 里是 `files { "*.cpp", "*.h" }`，看起来"加文件不用改构建配置"。
但 premake 只在**生成** `build/YGOPro.vcxproj` 的那一刻展开 glob；已经生成好的 `.vcxproj` 里是
**显式文件列表**。所以新增 `.cpp` 后直接 `msbuild` **不会**被编译进去。

- 本次现象：拆出 `control_state.cpp` 后第一次 `ClCompile` 只编译了 `control.cpp`，
  编译"通过"是**假象**（`control_state.cpp` 根本没参与，链接时会缺符号）。
- 本次处理：手工把 6 个 `.cpp` 与 `control_internal.h` 补进 `build/YGOPro.vcxproj`
  （该文件被 `.gitignore` 忽略，不会提交；XML 已校验）。
- 对 fork 用户：走标准流程 `premake5 vs2022` 重新生成即可，**glob 会自动重新包含新文件，自愈**。
- 验收时正确的做法是 `/t:Build`（含链接）而不是 `/t:ClCompile`，否则查不出缺 TU。

### 发现 2：匿名 namespace 的成员**隐式可见**，具名 namespace **不是**

原 `control.cpp` 把整个主体放在 `namespace ygo { namespace { ... } }`。匿名 namespace 的成员
在**外层 namespace 内可以无限定名访问**：

```cpp
namespace ygo {
namespace { int g_seq; void Pump(); }
void Control::Foo() { Pump(); }   // OK
}
```

改成具名的 `namespace ctl` 后这条透明性消失，而 `Control::*` 的成员函数定义在 `ctl` 闭包**之后**
（它们必须留在 `ygo` 里，不能在 `ctl` 里定义 `ygo::Control` 的成员），于是全部失去对 `ctl` 符号的访问
—— 首轮编译直接 60+ 个 "未声明的标识符"。

**修法**：`} // namespace ctl` 之后加一行 `using namespace ctl;`。
**这一行不能删**；后续任何"定义在 ctl 闭包外、却要用 ctl 符号"的代码都依赖它。

---

## 6. 遗留事项（非阻塞，均已记录在 MODULE-MAP §7）

- `g_uiActionCount`、`g_sentMain`：**只写不读**的死变量，保留未删。
- `HexBytes`(原 340) vs `Hex`(原 1110)、`CtlDbg`(前缀 `CDBG`) vs `DbgLog`(前缀 `DBG`)：
  重复实现，但输出分别属于日志/JSON 基线，**保留双份**，合并需另开任务并回归。
- `VexHandler` 定义前多一行冗余声明，保留。
- 端点体仍在 `RouteRequest()` 的 if/else 链里（未拆成每端点一个 `RouteXxx()` 函数）。
  按 lead 要求的分阶段策略，先做完 `goto→return` 与 `RouteRequest` 抽取并回归通过，
  **下一步可继续把端点体下放到各模块**（`/ui`→ui、`/lobby` 系列→lobby、`/actions` 系列→actions），
  属纯机械搬移，风险低。

---

## 7. 二进制留档与复现

| 版本 | size | 位置 |
|---|---:|---|
| 重构前基线（`6a9189d` 重建） | **6,237,184 B** | `_backups/YGOPro-baseline-6a9189d-20261106-0308.exe` |
| 重构后（`d7f38d1`） | **6,242,304 B** | `_backups/YGOPro-refactor-20261106-0256.exe`（= 当前 `bin/release/x64/YGOPro.exe`） |

值得注意：从 `6a9189d` 源码重建的 exe 与重构前线上基线**字节数完全一致**，
说明基线源码状态是可确定复现的 —— 以后做新旧同场 A/B 可直接用这两个 exe。

复现命令（Windows）：

```
cd mycard-client
.\premake5.exe vs2022                      # 生成 build/*.vcxproj（glob 在此刻求值）
cd build
msbuild YGOPro.vcxproj /p:Configuration=Release /p:Platform=x64 /m:1
# 产物：mycard-client\bin\release\x64\YGOPro.exe
```

编前若报 `LNK1104`，说明有 `YGOPro.exe` 在跑（只按路径杀 `*mycard-client*` 的进程）。
