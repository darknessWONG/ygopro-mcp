# MCP 宿主配置示例

三个文件内容同构，只是放置位置不同（`command` 都是 `node`，`args` 指向 `bridge/mcp-server.mjs`，
`env.CONTROL_URL` 指向你要控制的客户端控制端口）：

| 文件 | 放到哪里 |
|---|---|
| `claude_desktop_config.json` | Claude Desktop 的配置（Windows: `%APPDATA%\Claude\claude_desktop_config.json`）的后半段 |
| `cursor.mcp.json` | Cursor 项目里的 `.cursor/mcp.json` |
| `dsh.mcp.json` | DeepSeek Harness 的 MCP server 配置片段 |

**用法**：把 `C:/path/to/bridge/mcp-server.mjs` 换成你本机 `bridge/mcp-server.mjs` 的真实绝对路径；
客机位把 `CONTROL_URL` 改成 `http://127.0.0.1:7789`。

验证：启动宿主前先跑到 `node bridge/doctor.mjs` 全绿（或至少客户端可达），否则 MCP 工具会全部报连接失败。
