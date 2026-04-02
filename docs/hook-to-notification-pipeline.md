# Hook → 通知完整调用链路

本文描述一个 Claude Code hook 事件从触发到最终出现在系统通知和 popover UI 的完整路径。

---

## 总览

```
Claude Code 内部事件
  → notify.sh (shell 脚本)
  → POST /event (HTTP, port 9876)
  → AuthMiddleware
  → EventHandler.postEvent
  ├── SessionStart / SessionEnd → SessionLifecycleService.handleSessionLifecycle
  └── 其他事件 → EventMapper.map
                → SessionLifecycleService.processEvent
                → StopWindowService (Stop / Notification 类型)
                → onEvent callback
                → NotificationBatcher.submit / flush
                → NotificationBatcher.onNotification callback
                → NotificationService.post
                → UNUserNotificationCenter  ← 系统通知
                → GRDB ValueObservation     ← popover UI 刷新
```

---

## 一、触发端：notify.sh

Claude Code 在每个 hook 事件（`PreToolUse`、`PostToolUse`、`Stop`、`Notification` 等）触发时，把 JSON payload 写入 `notify.sh` 的 stdin。

`notify.sh` 做三件事：
1. 把 payload 截断至 64 KB（`head -c 65536`）
2. 注入额外字段：`tty`（当前终端设备路径）、`terminal_app`（终端应用名）
3. 以 fire-and-forget（`&`）方式 `POST` 到 `http://127.0.0.1:9876/event`，永远不阻塞 Claude Code

如果应用未运行，HTTP 连接会静默失败，事件丢弃。

---

## 二、HTTP 层：AuthMiddleware → EventHandler

### AuthMiddleware

每个请求必须携带 `Authorization: Bearer <token>`。
token 来自 `~/.agent-dev-pilot/token`（0600 权限，由 `AuthTokenService` 在应用首次启动时生成）。
`/health` 路由绕过验证。

### EventHandler.postEvent

收到请求后：

1. 读取 body（上限 64 KB）
2. 用 `JSONDecoder` 反序列化为 `HookPayload`
3. 根据 `hookEventName` 分流：

```
hookEventName == "SessionStart" | "SessionEnd"
  → SessionLifecycleService.handleSessionLifecycle(payload:)
  → 直接返回 200，不产生 DevEvent

其他所有事件
  → EventMapper.map(payload) → DevEvent
  → SessionLifecycleService.processEvent(event:sessionTitle:)
  → 根据 hookEventName 分别投入 StopWindowService
  → onEvent(event) callback
```

---

## 三、数据层：EventMapper + SessionLifecycleService

### EventMapper

把 `HookPayload` 映射成 `DevEvent`：

| HookPayload 字段 | 推断逻辑 | DevEvent 字段 |
|---|---|---|
| `hookEventName` + `notificationType` | `inferEventType()` | `type` (EventType) |
| `hookEventName` + `notificationType` | `inferAttentionTier()` | `attentionTier` |
| `title` ?? 格式化 `message` | `messageTitle()` | `title` |
| `cwd` | 原样 | `detail` |
| 整个 payload | JSON 编码 | `payload` |

EventType 推断规则：

| hookEventName | notificationType | EventType | AttentionTier |
|---|---|---|---|
| `UserPromptSubmit` | — | `promptSubmitted` | `background` |
| `Stop` | — | `agentStopped` | `background` |
| `Notification` | `permission_prompt` / `elicitation_dialog` | `permissionNeeded` | **action** |
| `Notification` | `idle_prompt` | `agentStopped` | `background` |
| `Notification` | 其他 | `agentStopped` | `background` |
| `PreToolUse` / `PostToolUse` | — | `agentStopped` | `background` |

### SessionLifecycleService

#### handleSessionLifecycle（仅 SessionStart / SessionEnd）

```
SessionStart:
  session 存在 → UPDATE cwd, tty, terminal_app
                 若 payload.title 非空 → UPDATE custom_name
                 若 status == completed/stale → 重置为 idle, 清除 ended_at
  session 不存在 → INSERT 新 session（status: idle, customName: payload.title）

SessionEnd:
  session 存在 → UPDATE status = completed, ended_at = now
  session 不存在 → 静默忽略
```

#### processEvent（所有其他事件）

```
session 存在:
  status == completed/stale → 重置为 idle（重新激活）
  INSERT DevEvent
  UPDATE last_event_title
  若 sessionTitle 非空 → UPDATE custom_name（处理 /rename）
  switch event.type:
    promptSubmitted → status = busy
                      所有未消除通知 is_dismissed = 1（用户继续对话即隐式确认）
    permissionNeeded → status = waiting
    agentStopped / authSuccess → 不改变 status（由 StopWindowService 处理）
  若 event.tokenCount 非空 → total_tokens += tokenCount

session 不存在（应用重启后收到的第一个事件）:
  推断 project 和 initialStatus，INSERT session + event
```

---

## 四、状态机：StopWindowService

`agentStopped` 事件本身不直接改变 session status，由 `StopWindowService` 在 2 秒窗口内合并 `Stop` 和 `Notification` 事件再做决策。

```
recordStop(sessionId)
  → 重置/启动 2 秒计时器

recordNotification(sessionId)  （permission_prompt / elicitation_dialog / idle_prompt）
  → 标记 hasNotification = true
  → 重置/启动 2 秒计时器

窗口到期 flush:
  hasNotification == true → status = waiting
  hasNotification == false → status = idle
                             INSERT 合成事件（type: agentStopped, title: "Claude is ready", tier: review）
                             调用 onIdleResolved(sessionId)
```

**处理乱序到达**：两个事件无论哪个先到，都进入同一窗口，窗口到期时用合并后的状态做最终决策，不会出现状态闪烁。

---

## 五、通知路径：NotificationBatcher → NotificationService

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

idle 通知由 `StopWindowService.onIdleResolved` → `batcher.submitIdle()` 单独路径发出，绕过 submit/flush。

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

## 六、UI 刷新：GRDB ValueObservation

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

## 七、完整时序（以 permission_prompt 为例）

```
Claude Code 请求工具权限
  │
  ▼
notify.sh POST /event
  { hookEventName: "Notification", notificationType: "permission_prompt", ... }
  │
  ▼
AuthMiddleware 验证 Bearer token
  │
  ▼
EventHandler.postEvent
  │
  ├─ EventMapper.map → DevEvent(type: permissionNeeded, tier: action)
  │
  ├─ SessionLifecycleService.processEvent
  │    session.status → waiting
  │    INSERT DevEvent
  │
  ├─ StopWindowService.recordNotification
  │    hasNotification = true
  │    启动 2s 窗口（等待可能的 Stop 事件）
  │
  └─ onEvent(event)  [attentionTier == .action，不被过滤]
       │
       ▼
     NotificationBatcher.submit + flush
       │
       ▼
     emitNotification（globalCount 未超限）
       │
       ▼
     NotificationService.post
       content.sound = .default（action tier）
       │
       ▼
     UNUserNotificationCenter ← 系统弹出通知（有声音）

2s 窗口到期:
  StopWindowService.flush
    hasNotification = true → status = waiting（此处不发 idle 通知）

GRDB ValueObservation:
  activeSessions 更新 → SessionGroupView 显示红色 "needs input" 状态
```

---

## 八、关键设计决策

| 决策 | 原因 |
|---|---|
| `agentStopped` 不直接改 status | `Stop` 和 `Notification` 事件可能乱序到达，需要 2s 窗口合并再判断 |
| `background` tier 过滤在 `onEvent` | `promptSubmitted` 极频繁，不应产生通知；`agentStopped` 由 idle 路径单独处理 |
| `submitIdle` 绕过 submit/flush | idle 是合成事件，不是真实的 DevEvent，不参与 per-session 批处理计数 |
| `promptSubmitted` 批量 dismiss | 用户继续对话即隐式确认了之前所有通知，避免通知堆积 |
| notify.sh 用 `&` fire-and-forget | 绝对不能阻塞 Claude Code 执行流 |
