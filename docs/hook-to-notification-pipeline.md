# Hook → 通知完整调用链路

本文描述一个 Claude Code hook 事件从触发到最终出现在系统通知和 popover UI 的完整路径。

> 架构版本：`HookStreamCoordinator` pipeline（2026-04-07 hook-stream-experiment 合并后）。
> 旧版本（`EventMapper` / `SessionLifecycleService` / `StopWindowService`）已废弃。

---

## 总览

```
Claude Code 内部事件
  → notify.sh (shell 脚本)
  → POST /event (HTTP, port 9876)
  → AuthMiddleware
  → EventHandler.postEvent
      ├── HookLog INSERT (原始审计，每条请求均写入)
      ├── HookEventClassifier.classify(payload) → HookEvent (typed)
      └── HookStreamCoordinator.process(payload)
            ├── SessionStateReducer.reduce(state, event) → (nextState, [Action])
            └── execute(actions):
                  ├── upsertSession / updateSessionStatus  → GRDB 写入
                  ├── insertDevEvent                       → GRDB 写入
                  ├── dismissPriorEvents                   → GRDB 写入
                  └── startStopWindow / cancelStopWindow   → 内部 Task 管理

onEvent callback (EventHandler → AppState)
  → NotificationBatcher.submit + flush
  → NotificationBatcher.onNotification callback
  → NotificationService.post
  → UNUserNotificationCenter  ← 系统通知

GRDB ValueObservation       ← popover UI 自动刷新
```

---

## 一、触发端：notify.sh

Claude Code 在每个 hook 事件（`PreToolUse`、`PostToolUse`、`Stop`、`Notification` 等）触发时，把 JSON payload 写入 `notify.sh` 的 stdin。

`notify.sh` 做三件事：
1. 把 payload 截断至 64 KB（`head -c 65536`）
2. 注入额外字段：`tty`（当前终端设备路径）、`terminal_app`（终端应用名）
3. 以 fire-and-forget（`&`）方式 `POST` 到 `http://127.0.0.1:9876/event`，永远不阻塞 Claude Code

如果应用未运行，HTTP 连接会静默失败，事件丢弃。

**⚠️ 异步投递**：`&` 意味着同一 session 的多个 hook 可能乱序到达服务器（尤其 `PostToolUse` 有时晚于 `Stop`，`Notification` 有时晚于 `PostToolUse`）。状态机设计必须容忍乱序。

---

## 二、HTTP 层：AuthMiddleware → EventHandler

### AuthMiddleware

每个请求必须携带 `Authorization: Bearer <token>`。
token 来自 `~/.agent-dev-pilot/token`（0600 权限，由 `AuthTokenService` 在应用首次启动时生成）。
`/health` 路由绕过验证。

### EventHandler.postEvent

收到请求后：

1. 读取 body（上限 64 KB）
2. 尝试用 `JSONDecoder` 反序列化为 `HookPayload`
3. 将原始请求写入 `HookLog`（无论解析成功与否，audit trail 优先）
4. 解析失败 → 返回 400
5. 解析成功 → 调用 `coordinator.process(payload)`
6. 从 DB 读取该 session 的最新 `DevEvent`，若存在则调用 `onEvent` callback

---

## 三、核心管道：HookEventClassifier → SessionStateReducer → HookStreamCoordinator

### HookEventClassifier

把 `HookPayload`（raw JSON struct）转换为强类型 `HookEvent`：

| hookEventName | 额外条件 | HookEvent |
|--------------|---------|-----------|
| `SessionStart` | — | `.sessionStart(sid, cwd, tty, terminalApp, tool, source)` |
| `SessionEnd` | — | `.sessionEnd(sid)` |
| `UserPromptSubmit` | — | `.userPromptSubmit(sid)` |
| `PreToolUse` | `tool_name` 非空 | `.preToolUse(sid, toolName)` |
| `PostToolUse` | `tool_name` 非空 | `.postToolUse(sid, toolName)` |
| `Notification` | `notificationType` 映射 | `.notification(sid, kind)` |
| `Stop` | — | `.stop(sid)` |
| 其他 / `tool_name` 为空 | — | `nil`（静默丢弃） |

`Notification` 的 `kind` 映射：

| `notificationType` | `NotificationKind` |
|-------------------|--------------------|
| `permission_prompt` / `elicitation_dialog` | `.permissionPrompt` |
| `idle_prompt` | `.idlePrompt` |
| 其他 | `.other` |

### SessionStateReducer

纯函数：`(SessionMachineState, HookEvent) → (SessionMachineState, [Action])`，不做 I/O。
详见 [session-state-from-hooks.md](./session-state-from-hooks.md) 的完整 11 条规则。

### HookStreamCoordinator（actor）

持有所有 session 的内存状态表（`states: [String: SessionMachineState]`）。

```
process(payload):
  1. classify(payload) → event（nil 则直接返回）
  2. current = states[sid] ?? .initial
  3. 若 current.cwd == nil 且 payload.cwd 非空 → current.cwd = payload.cwd
     （missed-SessionStart fallback：捕获任意 hook 的 cwd，防止会话显示为 "unknown"）
  4. (next, actions) = SessionStateReducer.reduce(current, event)
  5. states[sid] = next
  6. execute(actions) — 按序执行各 Action
```

`execute` 支持的 Action：

| Action | 效果 |
|--------|------|
| `upsertSession` | 若 session 存在 → 更新 cwd/tty/tool；若不存在 → INSERT 新 session |
| `updateSessionStatus` | UPDATE sessions SET status = ?；若 session 不存在 → INSERT 最小 session（idle） |
| `insertDevEvent` | INSERT events |
| `dismissPriorEvents` | UPDATE events SET is_dismissed = 1 WHERE session_id = ? |
| `startStopWindow` | 启动 2s Task；到期后注入虚拟 `.stopWindowExpired` 事件 |
| `cancelStopWindow` | 取消正在运行的 stop window Task |

**Stop window 机制**：`Stop` hook 触发 `.startStopWindow`，2 秒后若无其他 action 取消，`injectExpired` 向 reducer 注入 `.stopWindowExpired` 虚拟事件，reducer Rule 10 将 session 设为 `idle` 并写入 `agentStopped` 事件。

**应用重启恢复**：`AppState.startServer()` 在服务器绑定端口前调用 `coordinator.restoreStates(from: dbSessions)`，将 DB 中非 completed/stale 的 session 状态加载入内存，保证重启后的新 hook 能从正确状态继续。

---

## 四、通知路径：NotificationBatcher → NotificationService

### onEvent callback（AppState）

```swift
onEvent: { event in
    guard event.attentionTier != .background else { return }
    batcher?.submit(event)
    batcher?.flush()
}
```

**background tier 事件（promptSubmitted、agentStopped）在此过滤掉，不发通知。**
只有 `action` tier（permissionNeeded）和 `review` tier 事件进入 batcher。

idle 通知由 `HookStreamCoordinator.onIdleResolved` → `batcher.submitIdle()` 单独路径发出，绕过 submit/flush。

### NotificationBatcher

两级限流：

**Level 1：per-session 批处理**

```
submit(event):
  窗口内（< 2s）→ 累积到 pendingEvents[sessionId]
  窗口到期 → flushSession

flushSession:
  events.count > 3 → 合并为一条："N events from <project>" + "Latest: <title>"
  events.count ≤ 3 → 每条单独发出
```

**Level 2：全局限流**

```
globalNotificationCount > 5 (per 10s):
  不再发各自的通知
  改为发一条汇总："N events across multiple projects"
```

### NotificationService

把 `NotificationBatcher.Notification` 转为 `UNNotificationRequest` 发往系统：

```
content.title = notification.title
content.body  = notification.body
content.userInfo = { sessionId, isBatched, isSummary }

声音规则：
  action tier (permissionNeeded)  → 有声音
  synthetic (idle, event == nil)  → 有声音
  其他 (review tier, batched 等)  → 静音
```

通知带有 `"Open Terminal"` action button，点击后唤起终端焦点。

---

## 五、UI 刷新：GRDB ValueObservation

DB 写入后，`PopoverViewModel` 通过 `ValueObservation` 自动感知变化：

```
activeSessionsAndEventsObservation:
  读 sessions（status IN idle/busy/waiting）
  读 EventStore.fetchGroupedBySession（每 session ≤5 条未消除非 background 事件）
  → activeSessions, eventsBySession 原子更新
  → SwiftUI @Observable 触发 MenubarPopover 重新渲染
```

DB 写入和 UI 刷新之间无需手动通知，GRDB 的 WAL 模式下写入完成即触发观察者。

---

## 六、完整时序（以 permission_prompt 为例）

```
Claude Code 请求工具权限（Bash）
  │
  ▼
notify.sh &  →  POST /event { hookEventName: "Notification", notificationType: "permission_prompt" }
  │
  ▼
EventHandler: INSERT HookLog
  │
  ▼
HookEventClassifier: → .notification(sid, .permissionPrompt)
  │
  ▼
HookStreamCoordinator.process:
  current.status = .busy (session was busy)
  SessionStateReducer Rule 6: .busy → .waiting
  execute:
    updateSessionStatus(.waiting) → DB
    insertDevEvent(permissionNeeded, .action) → DB
  │
  ├─ onEvent(.action) → NotificationBatcher.submit + flush
  │     → NotificationService.post (有声音)
  │     → UNUserNotificationCenter ← 系统弹出通知
  │
  └─ GRDB ValueObservation → PopoverViewModel 更新 → 红色 "needs input" 状态

用户批准权限，Bash 运行完成
  │
  ▼
notify.sh &  →  POST /event { hookEventName: "PostToolUse", tool_name: "Bash" }
  │
  ▼
HookStreamCoordinator.process:
  current.status = .waiting
  SessionStateReducer Rule 8: .waiting + PostToolUse → .busy
  execute:
    updateSessionStatus(.busy) → DB
  │
  └─ GRDB ValueObservation → 状态恢复 busy

Claude 完成，Stop 触发
  │
  ▼
SessionStateReducer Rule 9: start stop window
  │
  2s 内无 Notification（已批准，notification 不会再来）
  │
  ▼
injectExpired → Rule 10: .busy → .idle
  insertDevEvent(agentStopped, .review) → DB
  onIdleResolved → batcher.submitIdle() → "Claude is ready" 通知
```

---

## 七、关键设计决策

| 决策 | 原因 |
|------|------|
| `SessionStateReducer` 纯函数 | 便于单元测试 13 条规则；HookStreamCoordinator 负责 I/O 和并发 |
| stop window 用 Task 而非 timer | actor 内部安全；可精确 cancel；虚拟事件走相同 reduce 路径 |
| Rule 5（stop window 中的 Notification）→ no-op | `notify.sh &` 延迟投递：permission_prompt 可能在 PostToolUse + Stop 之后才到。Stop 只在 agent loop 退出后触发，此时权限已处理完毕，迟到的 notification 为噪声，不应取消 stop window |
| Rule 6 仅从 `.busy` 触发 waiting | 防止迟到通知把 idle/completed session 拉回 waiting |
| `promptSubmitted` → dismissPriorEvents | 用户继续对话即隐式确认之前所有通知，避免通知堆积 |
| missed-SessionStart fallback | 应用离线期间 SessionStart 被丢弃；后续任意 hook 携带 cwd，Coordinator 从中恢复 session 信息 |
| `background` tier 在 onEvent 过滤 | `promptSubmitted` 极频繁，不应产生通知；`agentStopped` 由 idle 路径单独处理 |
| notify.sh 用 `&` fire-and-forget | 绝对不能阻塞 Claude Code 执行流 |
