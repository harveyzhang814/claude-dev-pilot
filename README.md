# Agent Pilot

macOS 菜单栏应用：通过本地 HTTP 接收 **Claude Code** 与 **Cursor** 的 hook 事件，转为系统通知、悬浮窗与分组会话界面，便于在代理跑任务时掌握状态。

**悬浮窗** 常驻屏幕，显示各会话状态（busy / waiting / idle）。悬停展开 Hover View 后，点击工具栏锁定图标可固定为 Hover View 常驻模式（不再折叠为 compact pill），该偏好跨重启保留。

## 要求

- macOS 14（Sonoma）或更高版本
- Xcode / Swift 6.0 工具链（`swift build`、`swift test`）

## 快速开始（开发）

```bash
# 编译
swift build -c debug

# 运行全部测试
swift test

# 仅 Core / App 测试
swift test --filter AgentPilotTests

# 仅 HTTP 层集成测试
swift test --filter ServerTests
```

**运行应用：** 必须使用带 `CFBundleIdentifier` 的 `.app` 包，系统通知才能正常注册；不要用 `swift run` 代替日常启动。

```bash
make run        # 构建 debug .app 并打开
make bundle     # 只构建 debug .app，不启动
make dist       # Release 构建 + 代码签名，可拖到「应用程序」安装
make install    # Release 构建 + 直接复制到 /Applications
make clean      # 清理构建产物与本地 .app
```

默认 HTTP 端口为 **9876**，可在应用设置中修改（`UserDefaults` 键 `serverPort`）。

## 与 Claude Code / Cursor 集成

1. 启动应用并完成引导；应用会在 `~/.agentpilot/token` 生成 Bearer 令牌（权限 `0600`）。
2. 在应用内使用 **Hook 安装** 相关说明：会将 `notify.sh` / `cursor-notify.sh` 写入 `~/.agentpilot/hooks/`（内容以 `HookInstaller` 内嵌脚本为准）。
3. **Claude Code：** 按提示合并 hook 配置；脚本向 `POST /event` 上报，需携带 `Authorization: Bearer <token>`。
4. **Cursor：** 按提示将 hook 合并到 `~/.cursor/hooks.json`；`cursor-notify.sh` 向 `POST /cursor-event` 上报。可通过环境变量 `AGENT_PILOT_PORT` 覆盖端口（默认与上述端口一致）。

事件经服务端归一化后进入统一流水线（会话生命周期、通知合并与节流等）。更细的链路说明见 [`docs/hook-to-notification-pipeline.md`](docs/hook-to-notification-pipeline.md)。

## 仓库结构（SPM）

| 目标 | 路径 | 说明 |
|------|------|------|
| `Core` | `Sources/Core/` | 模型、GRDB 存储、业务服务；无 UI、不依赖 HTTP 框架 |
| `Server` | `Sources/Server/` | Hummingbird：`/event`、`/cursor-event`、`/health` |
| `AgentPilot` | `Sources/App/` | SwiftUI 可执行文件，依赖 Core + Server |
| `AgentPilotTests` | `Tests/`（不含 `ServerTests`） | Core / App 单元测试 |
| `ServerTests` | `Tests/ServerTests/` | `HummingbirdTesting` 集成测试 |

主要依赖：[Hummingbird](https://github.com/hummingbird-project/hummingbird)、[GRDB](https://github.com/groue/GRDB.swift)。

## 数据与隐私

- 本地 SQLite（WAL）：`~/Library/Application Support/AgentPilot/db.sqlite`
- 令牌与 hook 脚本：`~/.agentpilot/`
- 服务端仅监听本机；入站请求需有效 Bearer token（`/health` 除外）

## 更多文档

- [`CLAUDE.md`](CLAUDE.md) — 面向贡献者的架构、状态机、测试约定与 Git 工作流
- [`DESIGN.md`](DESIGN.md) — UI 字体、颜色与间距等设计约定

## 许可

若仓库根目录后续添加 `LICENSE`，以该文件为准。
