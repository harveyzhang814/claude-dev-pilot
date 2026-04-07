# HookStreamDetector 设计规格

**目标：** 基于多场景实验数据，设计一套新的 session 状态检测算法，替换现有的 `EventMapper` + `SessionLifecycleService` + `StopWindowService` 三组件架构。

**数据来源：** `docs/session-state-from-hooks.md`（实验分支 `feat/hook-stream-experiment`）

**架构方式：** 纯函数 Reducer + Actor 协调层（方案 B）

---

## 背景：现有系统的问题

现有架构是**单事件反应式**的：每个 `HookPayload` 独立经过 `EventMapper` 转换为 `DevEvent`，再由 `SessionLifecycleService` 更新状态。跨事件决策（Stop + Notification 合并）由 `StopWindowService` 打补丁实现。

实验发现三个被现有系统丢弃的有效信号：

| 丢弃的信号 | 实际含义 | 现有处理 |
|-----------|---------|---------|
| `PreToolUse/AskUserQuestion` | `busy → waiting`，比 Notification 早 6s | 映射为 `agentStopped/background`，丢弃 |
| `PostToolUse` (任意 tool，当前状态为 waiting) | `waiting → busy` | 映射为 `agentStopped/background`，丢弃 |
| `Notification.message` 内容 | 区分触发类型 | 统一映射为 `permissionNeeded`，无区分 |

---

## 架构

```
HookPayload (raw JSON)
    │
    ▼
HookEventClassifier              ← 无状态，仅做类型转换
    │
    ▼ HookEvent (typed enum)
    │
    ▼
SessionStateReducer
.reduce(state, event)            ← 纯函数，包含所有判断规则
    │
    ▼ (SessionMachineState, [Action])
    │
    ▼
HookStreamCoordinator (actor)    ← 执行副作用：写 DB、管 2s 定时器
    │
    ▼
DB (DevSession.status, DevEvent)
```

三个组件职责严格分离：
- **HookEventClassifier**：原始 payload → 有类型的事件，不做判断
- **SessionStateReducer**：纯函数，所有状态转换规则，完全可单元测试
- **HookStreamCoordinator**：唯一知道"时间"和"副作用"的地方

---

## 类型定义

### HookEvent

```swift
enum HookEvent {
    case sessionStart(sessionId: String, cwd: String?, tty: String?,
                      terminalApp: String?, tool: String?)
    case sessionEnd(sessionId: String)
    case userPromptSubmit(sessionId: String)
    case preToolUse(sessionId: String, tool: String)
    case postToolUse(sessionId: String, tool: String)
    case notification(sessionId: String, kind: NotificationKind)
    case stop(sessionId: String)
    case stopWindowExpired(sessionId: String)  // Coordinator 定时器触发后注入的虚拟事件
}

enum NotificationKind {
    case permissionPrompt   // notification_type == "permission_prompt" 或 "elicitation_dialog"
    case idlePrompt         // notification_type == "idle_prompt"
    case other
}
```

`stopWindowExpired` 是虚拟事件，由 Coordinator 的定时器回调注入，使 reducer 对定时器的处理和普通事件完全一致，无需特殊代码路径。

### SessionMachineState

```swift
struct SessionMachineState {
    var status: SessionStatus   // idle | busy | waiting | completed | stale
    var stopWindowActive: Bool  // true = 收到 Stop，2s 窗口计时中
    var dbSessionExists: Bool   // SessionStart 是否已写入 DB

    static let initial = SessionMachineState(
        status: .idle,
        stopWindowActive: false,
        dbSessionExists: false
    )
}
```

### Action

```swift
enum Action: Equatable {
    case upsertSession(sessionId: String, status: SessionStatus, metadata: SessionMetadata?)
    case updateSessionStatus(sessionId: String, status: SessionStatus)
    case insertDevEvent(DevEvent)
    case dismissPriorEvents(sessionId: String)
    case startStopWindow(sessionId: String)
    case cancelStopWindow(sessionId: String)
}
```

---

## Reducer 规则表

```swift
static func reduce(
    _ state: SessionMachineState,
    _ event: HookEvent
) -> (SessionMachineState, [Action])
```

规则按优先级从高到低排列，第一条命中即返回。

| 优先级 | 事件 | 条件 | 新状态 | Actions |
|--------|------|------|--------|---------|
| 1 | `sessionStart` | 任意 | `idle`（reopen if completed/stale） | `upsertSession(idle, metadata)`, `cancelStopWindow` |
| 2 | `sessionEnd` | 任意 | `completed` | `updateStatus(completed)`, `cancelStopWindow` |
| 3 | `userPromptSubmit` | 任意 | `busy` | `updateStatus(busy)`, `dismissPriorEvents`, `insertEvent(promptSubmitted/background)` |
| 4 | `preToolUse(AskUserQuestion)` | 任意 | `waiting` | `updateStatus(waiting)`, `insertEvent(permissionNeeded/action)` |
| 5 | `notification(permissionPrompt)` | `stopWindowActive == true` | `waiting` | `cancelStopWindow`, `updateStatus(waiting)`, `insertEvent(permissionNeeded/action)` |
| 6 | `notification(permissionPrompt)` | `status != waiting` | `waiting` | `updateStatus(waiting)`, `insertEvent(permissionNeeded/action)` |
| 7 | `notification(permissionPrompt)` | `status == waiting` | `waiting`（no-op） | `[]`（幂等，不重复插入事件） |
| 8 | `postToolUse` (任意 tool) | `status == waiting` | `busy` | `updateStatus(busy)` |
| 9 | `stop` | 任意 | 状态不变，`stopWindowActive = true` | `startStopWindow` |
| 10 | `stopWindowExpired` | 任意 | `idle` | `updateStatus(idle)`, `insertEvent(agentStopped/review)` |
| 11 | `preToolUse` (非 AskUserQuestion) | `status == idle \|\| waiting` | `busy` | `updateStatus(busy)` |
| 12 | `notification(idlePrompt)` | 任意 | no-op | `[]`（Stop 后 60s 触发，状态早已决策，忽略）|
| 13 | 其余所有事件 | 任意 | no-op | `[]` |

---

## 三条关键路径完整走法

### AskUserQuestion 路径

```
UserPromptSubmit          → busy                          [Rule 3]
PreToolUse/AskUserQuestion → waiting + permissionNeeded   [Rule 4]
Notification(permission_prompt)
                           → no-op，幂等                  [Rule 7]
PostToolUse/AskUserQuestion → busy                        [Rule 8]
Stop                       → stopWindowActive=true        [Rule 9]
(2s 内无 Notification)
stopWindowExpired          → idle + agentStopped/review   [Rule 10]
```

### 权限审批路径

```
UserPromptSubmit          → busy                          [Rule 3]
PreToolUse/Bash           → busy（已是 busy，no-op）      [Rule 11 不触发，Rule 13]
Notification(permission_prompt)
                          → waiting + permissionNeeded    [Rule 6]
PostToolUse/Bash          → busy                          [Rule 8]
Stop                      → stopWindowActive=true         [Rule 9]
(2s 内无 Notification)
stopWindowExpired         → idle + agentStopped/review    [Rule 10]
```

### 正常完成路径

```
UserPromptSubmit          → busy                          [Rule 3]
PreToolUse/工具           → busy（已是 busy，no-op）      [Rule 13]
PostToolUse/工具          → busy（status!=waiting，no-op）[Rule 13]
Stop                      → stopWindowActive=true         [Rule 9]
(2s 内无 Notification)
stopWindowExpired         → idle + agentStopped/review    [Rule 10]
```

---

## HookStreamCoordinator

```swift
actor HookStreamCoordinator {
    private var states: [String: SessionMachineState] = [:]
    private var stopWindowTasks: [String: Task<Void, Never>] = [:]
    private let db: DatabaseManager
    private let stopWindowDuration: Duration

    // 唯一公开入口
    func process(_ payload: HookPayload) async {
        let event = HookEventClassifier.classify(payload)
        guard let sessionId = event.sessionId else { return }

        let currentState = states[sessionId] ?? .initial
        let (nextState, actions) = SessionStateReducer.reduce(currentState, event)
        states[sessionId] = nextState

        await execute(actions)
    }

    // 启动时从 DB 恢复 active session 状态
    func restoreStates(from sessions: [DevSession]) {
        for session in sessions {
            states[session.sessionId] = SessionMachineState(
                status: session.status,
                stopWindowActive: false,
                dbSessionExists: true
            )
        }
    }

    private func execute(_ actions: [Action]) async {
        for action in actions {
            switch action {
            case .startStopWindow(let sessionId):
                stopWindowTasks[sessionId]?.cancel()
                stopWindowTasks[sessionId] = Task { [weak self] in
                    try? await Task.sleep(for: stopWindowDuration)
                    guard !Task.isCancelled else { return }
                    await self?.injectExpired(sessionId: sessionId)
                }

            case .cancelStopWindow(let sessionId):
                stopWindowTasks[sessionId]?.cancel()
                stopWindowTasks[sessionId] = nil

            case .upsertSession(let sessionId, let status, let metadata):
                try? await db.upsertSession(sessionId, status: status, metadata: metadata)

            case .updateSessionStatus(let sessionId, let status):
                try? await db.updateSessionStatus(sessionId, status: status)

            case .insertDevEvent(let event):
                try? await db.insertDevEvent(event)

            case .dismissPriorEvents(let sessionId):
                try? await db.dismissAllEvents(for: sessionId)
            }
        }
    }

    private func injectExpired(sessionId: String) async {
        let currentState = states[sessionId] ?? .initial
        let (nextState, actions) = SessionStateReducer.reduce(
            currentState,
            .stopWindowExpired(sessionId: sessionId)
        )
        states[sessionId] = nextState
        await execute(actions)
    }
}
```

**关键决策：**

- **`states` 字典在内存**：避免每个 hook 都查 DB。App crash 后通过 `restoreStates` 从 DB 恢复，`stopWindowActive` 不持久化（crash 期间的 Stop window 丢失，最多影响一次 idle/waiting 误判，可接受）
- **定时器用 `Task.sleep` + cancel**：和 actor 模型天然契合，无 `DispatchSourceTimer` 线程安全问题
- **`stopWindowDuration` 可注入**：便于测试时使用极短的 duration（如 `.milliseconds(10)`）

---

## 集成

`EventHandler` 改动极小：

```swift
// 现有
await sessionLifecycleService.handleSessionLifecycle(payload)
let event = eventMapper.map(payload)
await sessionLifecycleService.processEvent(event)

// 新
await coordinator.process(payload)
```

`AppState.start()` 启动时恢复状态：

```swift
let activeSessions = try await sessionStore.fetchActive()
await coordinator.restoreStates(from: activeSessions)
```

`EventMapper`、`SessionLifecycleService`、`StopWindowService` 三个文件在新实现通过测试后删除。

---

## 文件结构

```
Sources/Core/
  Services/
    HookStreamCoordinator.swift   ← 新建（actor，执行副作用）
    HookEventClassifier.swift     ← 新建（纯函数，payload → HookEvent）
    SessionStateReducer.swift     ← 新建（纯函数，reducer 规则表）
    StopWindowService.swift       ← 删除（逻辑迁移到 reducer）
    SessionLifecycleService.swift ← 删除（逻辑迁移到 reducer + coordinator）
  Models/
    EventMapper.swift             ← 删除（逻辑迁移到 classifier + reducer）
    HookEvent.swift               ← 新建（HookEvent enum、NotificationKind）
    SessionMachineState.swift     ← 新建（状态结构体）

Tests/
  SessionStateReducerTests.swift  ← 新建（纯函数，穷举每条规则）
  HookStreamCoordinatorTests.swift ← 新建（集成测试，in-memory DB + 真实 Task.sleep）
```

---

## 测试策略

`SessionStateReducer` 是纯函数，每条规则独立可测，无需 mock：

```swift
func testAskUserQuestionFullPath() {
    var state = SessionMachineState.initial
    var actions: [Action]

    // UserPromptSubmit → busy
    (state, actions) = reduce(state, .userPromptSubmit("sid"))
    XCTAssertEqual(state.status, .busy)

    // PreToolUse/AskUserQuestion → waiting + permissionNeeded 事件
    (state, actions) = reduce(state, .preToolUse("sid", tool: "AskUserQuestion"))
    XCTAssertEqual(state.status, .waiting)
    XCTAssert(actions.containsInsertEvent(type: .permissionNeeded))

    // Notification 幂等：不重复插入事件
    (state, actions) = reduce(state, .notification("sid", kind: .permissionPrompt))
    XCTAssertEqual(state.status, .waiting)
    XCTAssertTrue(actions.isEmpty)

    // PostToolUse → busy
    (state, actions) = reduce(state, .postToolUse("sid", tool: "AskUserQuestion"))
    XCTAssertEqual(state.status, .busy)

    // Stop → window active
    (state, actions) = reduce(state, .stop("sid"))
    XCTAssertTrue(state.stopWindowActive)
    XCTAssert(actions.contains(.startStopWindow("sid")))

    // stopWindowExpired → idle + agentStopped 事件
    (state, actions) = reduce(state, .stopWindowExpired("sid"))
    XCTAssertEqual(state.status, .idle)
    XCTAssertFalse(state.stopWindowActive)
    XCTAssert(actions.containsInsertEvent(type: .agentStopped))
}
```

Coordinator 集成测试覆盖两个定时器场景：
- Stop + 无 Notification → 2s 后 idle
- Stop + Notification → 立即 waiting，定时器取消

---

## 现有组件对应关系

| 现有组件 | 代码行数 | 新对应 |
|---------|---------|-------|
| `EventMapper` | ~120 行 | `HookEventClassifier` + `SessionStateReducer` Rules 3–8 |
| `SessionLifecycleService` | ~150 行 | `SessionStateReducer` Rules 1–3, 11 + `HookStreamCoordinator` |
| `StopWindowService` | ~130 行 | `SessionStateReducer` Rules 9–10 + Coordinator 定时器 |
| **合计 ~400 行** | | **预计 ~250 行，逻辑全集中在 reducer** |
