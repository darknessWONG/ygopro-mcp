# netfault.mjs — 带故障注入的 TCP 代理（模拟硬掉线 / 静默假死）

用来**确定性地**制造"客机与主机之间的链路坏掉"，测试重连检测（被动超时 + `/tip` 探活）用。
不改客户端、不改控制层、不碰排位：只是把客机的 `-p` 指到代理上。

```
客机(guest) ── TCP 127.0.0.1:7912 ──► [netfault.mjs] ── TCP 127.0.0.1:7911 ──► 主机(host, LAN 服务端)
                                          ▲
                        控制口 HTTP 127.0.0.1:7913（/status /mode /log）
```

## 启动

```powershell
node bridge/netfault.mjs
# 端口可配：
#   --listen 7912          代理监听（客机连这里）
#   --upstream 127.0.0.1:7911   真正的 LAN 服务端
#   --ctrl 7913            控制口
#   --log-size 500         /log 环形缓冲行数
```

然后在**客机**的启动参数里把 `-p 7911` 改成 **`-p 7912`**（其余 `-h 127.0.0.1 -j -n ... -d ...` 不变）；
主机不需要任何改动。代理是纯字节转发，不解析协议，**不改内容**。

## 四种故障模式

| 模式 | 命令 | 效果 | 用途 |
|---|---|---|---|
| `normal` | `POST /mode?m=normal`（或 `POST /thaw`） | 正常双向转发 | 基线 / 恢复 |
| `freeze` | `POST /mode?m=freeze` | **连接保持打开，但一个字节都不转发**：客户端既收不到数据也收不到 EOF | 模拟"静默假死"——被动超时该在这里触发 |
| `drop` | `POST /mode?m=drop` | **一次性**：立即 `destroy()` 所有现存连接（双方都看到关闭），随后模式自动回到 `normal` | 模拟"硬掉线"——客户端应立即感知 EOF 并允许重连 |
| `reject` | `POST /mode?m=reject` | 新连接**立即被关闭**（像连不上）；已存在的连接不动 | 区分"连不上"和"连上了但静默" |

要点：

- **freeze 期间到达的字节直接丢弃**（不缓存、不重放），并计入 `droppedBytes` / `droppedUp` / `droppedDown`；
  这更接近真实死链（恢复后不会突然收到一堆旧数据）。
- **drop 是一次性动作**，不常驻；`/status.mode` 会立刻显示回 `normal`，这样客户端重连才能成功。
- **reject 只影响新连接**；要同时干掉旧连接就先 `drop` 再 `reject`。

## 控制口

```powershell
curl.exe http://127.0.0.1:7913/status
# {"listen":"127.0.0.1:7912","upstream":"127.0.0.1:7911","mode":"normal",
#  "connections":1,"totalConnections":3,"bytesUp":4096,"bytesDown":8192,
#  "droppedBytes":0,"droppedUp":0,"droppedDown":0,
#  "droppedConnections":0,"rejectedConnections":0,"upstreamErrors":0,"clientErrors":0,...}

curl.exe -X POST "http://127.0.0.1:7913/mode?m=freeze"   # 静默假死
curl.exe -X POST "http://127.0.0.1:7913/mode?m=drop"     # 硬掉线（一次性）
curl.exe -X POST "http://127.0.0.1:7913/mode?m=reject"   # 拒绝新连接
curl.exe -X POST "http://127.0.0.1:7913/thaw"            # = /mode?m=normal
curl.exe "http://127.0.0.1:7913/log?tail=20"             # 最近 20 条事件
curl.exe "http://127.0.0.1:7913/help"                    # 简版用法
```

`/status` 里的 `connections` 是当前活连接数，`connectionsDetail[]` 有每个连接的方向字节数；
`uptimeMs` 是代理已运行时间。控制口同时接受 GET（方便浏览器/`Invoke-RestMethod`）与 POST。

## 典型测试流程

```powershell
# 1) 起代理（另开一个终端），然后按正常流程起 host/guest，但 guest 用 -p 7912
node bridge/netfault.mjs

# 2) 打到 turn >= 2，确认客机 /state 在动
curl.exe http://127.0.0.1:7789/state

# 3) 静默假死：客机应收不到任何东西（没有 EOF），检测逻辑应因"超时"报掉线
curl.exe -X POST "http://127.0.0.1:7913/mode?m=freeze"
#   观察 /status：connections 仍为 1，droppedBytes 持续增长

# 4) 恢复：验证"假死但链路其实没断"能不能自愈
curl.exe -X POST "http://127.0.0.1:7913/thaw"

# 5) 硬掉线：客户端应立即感知 EOF
curl.exe -X POST "http://127.0.0.1:7913/mode?m=drop"

# 6) 连不上：验证重连失败的分支
curl.exe -X POST "http://127.0.0.1:7913/mode?m=reject"
curl.exe -X POST "http://127.0.0.1:7913/mode?m=normal"
```

## 注意

- 代理自己只占 **7912 / 7913**，不会占用 7911 / 7788 / 7789（这些留给真正的客户端）。
- 日志同时写 **stderr** 和内存环形缓冲（`/log`）；`Ctrl+C` / `SIGTERM` 会优雅退出并打印累计字节数。
- 这是**外部工具**：不改任何 ygopro / 控制层代码，也不需要客户端配合。
- 纯 Node（18+）无依赖；自测用临时 echo 服务验证过 normal / freeze / thaw / drop / reject 五种路径。
