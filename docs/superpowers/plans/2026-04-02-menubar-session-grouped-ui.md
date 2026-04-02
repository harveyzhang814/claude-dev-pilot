# Menubar Session-Grouped UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 menubar popover 改写为以 session 为主维度展示事件，替代原有的 Needs Attention / Recent Activity 双区块结构。

**Architecture:** 新增 `EventStore.fetchGroupedBySession`（Core 层，可测试）供 `PopoverViewModel` 在 ValueObservation 中调用；新增 `SessionGroupView` 组件负责渲染单个 session 分组；重写 `MenubarPopover.body` 使用新组件。

**Tech Stack:** SwiftUI (macOS 14+), GRDB ValueObservation, Swift Testing

---

## File Map

| File | Change |
|------|--------|
| `Sources/Core/Store/EventStore.swift` | 新增 `fetchGroupedBySession(sessionIds:limit:in:)` |
| `Tests/StoreTests/EventStoreGroupedTests.swift` | 新建，测试 fetchGroupedBySession |
| `Sources/App/ViewModels/PopoverViewModel.swift` | 新增 `activeSessions`、`eventsBySession`；合并现有两个 session 观察为一个 |
| `Sources/App/Views/SessionGroupView.swift` | 新建，单个 session 分组 UI 组件 |
| `Tests/AgentDevPilotTests/SessionGroupViewTests.swift` | 新建，测试 sessionStatusTag / sessionStatusColor helpers |
| `Sources/App/Views/MenubarPopover.swift` | 重写 body，移除旧区块，改用 SessionGroupView |

---

## Task 1: EventStore.fetchGroupedBySession

**Files:**
- Modify: `Sources/Core/Store/EventStore.swift`
- Create: `Tests/StoreTests/EventStoreGroupedTests.swift`

- [ ] **Step 1: 写 failing 测试**

创建 `Tests/StoreTests/EventStoreGroupedTests.swift`：

```swift
import Testing
import Foundation
import GRDB
@testable import Core

@Suite("EventStore.fetchGroupedBySession")
struct EventStoreGroupedTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        return db
    }

    private func makeSession(id: String, status: SessionStatus = .running) -> DevSession {
        DevSession(
            id: id, project: id, cwd: "/Users/dev/\(id)",
            tool: "claude-code", status: status,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
    }

    private func makeEvent(
        id: String, sessionId: String,
        tier: AttentionTier = .review,
        timestamp: Date = Date(),
        isDismissed: Bool = false
    ) -> DevEvent {
        DevEvent(
            id: id, sessionId: sessionId, type: .taskCompleted,
            title: "Test", detail: nil, payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: timestamp, attentionTier: tier,
            isDismissed: isDismissed
        )
    }

    @Test("groups events by session")
    func groupsBySession() throws {
        let db = try makeDB()
        try db.write { db in
            try makeSession(id: "s1").insert(db)
            try makeSession(id: "s2").insert(db)
            try makeEvent(id: "e1", sessionId: "s1").insert(db)
            try makeEvent(id: "e2", sessionId: "s1").insert(db)
            try makeEvent(id: "e3", sessionId: "s2").insert(db)
        }
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1", "s2"], in: db)
        }
        #expect(grouped["s1"]?.count == 2)
        #expect(grouped["s2"]?.count == 1)
    }

    @Test("limits to 5 events per session")
    func limitsToFive() throws {
        let db = try makeDB()
        try db.write { db in
            try makeSession(id: "s1").insert(db)
            for i in 1...7 {
                try makeEvent(id: "e\(i)", sessionId: "s1").insert(db)
            }
        }
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: db)
        }
        #expect(grouped["s1"]?.count == 5)
    }

    @Test("excludes background tier events")
    func excludesBackground() throws {
        let db = try makeDB()
        try db.write { db in
            try makeSession(id: "s1").insert(db)
            try makeEvent(id: "e1", sessionId: "s1", tier: .background).insert(db)
            try makeEvent(id: "e2", sessionId: "s1", tier: .review).insert(db)
        }
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: db)
        }
        #expect(grouped["s1"]?.count == 1)
        #expect(grouped["s1"]?.first?.id == "e2")
    }

    @Test("excludes dismissed events")
    func excludesDismissed() throws {
        let db = try makeDB()
        try db.write { db in
            try makeSession(id: "s1").insert(db)
            try makeEvent(id: "e1", sessionId: "s1", isDismissed: true).insert(db)
            try makeEvent(id: "e2", sessionId: "s1", isDismissed: false).insert(db)
        }
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: db)
        }
        #expect(grouped["s1"]?.count == 1)
        #expect(grouped["s1"]?.first?.id == "e2")
    }

    @Test("returns empty dict for empty sessionIds")
    func emptySessionIds() throws {
        let db = try makeDB()
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: [], in: db)
        }
        #expect(grouped.isEmpty)
    }

    @Test("orders events by timestamp descending within group")
    func orderedDescending() throws {
        let db = try makeDB()
        let now = Date()
        try db.write { db in
            try makeSession(id: "s1").insert(db)
            try makeEvent(id: "older", sessionId: "s1",
                          timestamp: now.addingTimeInterval(-60)).insert(db)
            try makeEvent(id: "newer", sessionId: "s1",
                          timestamp: now).insert(db)
        }
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: db)
        }
        #expect(grouped["s1"]?.first?.id == "newer")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter EventStoreGroupedTests 2>&1 | tail -10
```

Expected: compile error — `fetchGroupedBySession` not defined yet.

- [ ] **Step 3: 在 EventStore.swift 末尾（`}` 前一行）新增方法**

在 `Sources/Core/Store/EventStore.swift` 的最后一个 `}` 前插入：

```swift
    /// Undismissed, non-background events grouped by session ID.
    /// Results within each group are timestamp-descending, capped at `limit`.
    /// Designed for use inside a `ValueObservation.tracking` closure.
    public static func fetchGroupedBySession(
        sessionIds: [String],
        limit: Int = 5,
        in db: Database
    ) throws -> [String: [DevEvent]] {
        guard !sessionIds.isEmpty else { return [:] }
        let events = try DevEvent
            .filter(sessionIds.contains(DevEvent.Columns.sessionId))
            .filter(DevEvent.Columns.attentionTier != AttentionTier.background.rawValue)
            .filter(DevEvent.Columns.isDismissed == false)
            .order(DevEvent.Columns.timestamp.desc)
            .fetchAll(db)
        return Dictionary(grouping: events, by: \.sessionId)
            .mapValues { Array($0.prefix(limit)) }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter EventStoreGroupedTests 2>&1 | tail -10
```

Expected: `Test Suite 'EventStoreGroupedTests' passed`, 6 tests pass.

- [ ] **Step 5: 确认全部测试无回归**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Store/EventStore.swift Tests/StoreTests/EventStoreGroupedTests.swift
git commit -m "feat: add EventStore.fetchGroupedBySession for popover session grouping"
```

---

## Task 2: PopoverViewModel — 新增 activeSessions 和 eventsBySession

**Files:**
- Modify: `Sources/App/ViewModels/PopoverViewModel.swift`

- [ ] **Step 1: 新增两个 published 属性**

在 `PopoverViewModel` 的属性区（`actionEvents` 下方）添加：

```swift
public var activeSessions: [DevSession] = []
public var eventsBySession: [String: [DevEvent]] = [:]
```

- [ ] **Step 2: 替换现有的两个 session 观察**

在 `startObserving(db:)` 中，找到并**删除**这两段：

```swift
let sessionCountObservation = ValueObservation.tracking { db in
    try DevSession
        .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue]
            .contains(DevSession.Columns.status))
        .fetchCount(db)
}

sessionCountObservation
    .publisher(in: db, scheduling: .immediate)
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] count in
            self?.activeSessionCount = count
        }
    )
    .store(in: &cancellables)

let sessionTimesObservation = ValueObservation.tracking { db in
    try DevSession
        .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue]
            .contains(DevSession.Columns.status))
        .fetchAll(db)
        .reduce(into: [String: Date]()) { $0[$1.id] = $1.startedAt }
}

sessionTimesObservation
    .publisher(in: db, scheduling: .immediate)
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] times in
            self?.sessionStartTimes = times
        }
    )
    .store(in: &cancellables)
```

**替换**为以下三段（一个 session 观察 + 一个 eventsBySession 观察）：

```swift
// Single observation: active sessions sorted by startedAt desc
let sessionObservation = ValueObservation.tracking { db in
    try DevSession
        .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue]
            .contains(DevSession.Columns.status))
        .order(DevSession.Columns.startedAt.desc)
        .fetchAll(db)
}

sessionObservation
    .publisher(in: db, scheduling: .immediate)
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] sessions in
            guard let self else { return }
            self.activeSessions = sessions
            self.activeSessionCount = sessions.count
            self.sessionStartTimes = sessions.reduce(into: [:]) { $0[$1.id] = $1.startedAt }
        }
    )
    .store(in: &cancellables)

// Events grouped by active session
let eventsGroupedObservation = ValueObservation.tracking { db in
    let sessionIds = try DevSession
        .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue]
            .contains(DevSession.Columns.status))
        .fetchAll(db)
        .map(\.id)
    return try EventStore.fetchGroupedBySession(sessionIds: sessionIds, in: db)
}

eventsGroupedObservation
    .publisher(in: db, scheduling: .immediate)
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] grouped in
            self?.eventsBySession = grouped
        }
    )
    .store(in: &cancellables)
```

- [ ] **Step 3: Build 验证**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/App/ViewModels/PopoverViewModel.swift
git commit -m "feat: add activeSessions and eventsBySession to PopoverViewModel"
```

---

## Task 3: 新建 SessionGroupView

**Files:**
- Create: `Sources/App/Views/SessionGroupView.swift`
- Create: `Tests/AgentDevPilotTests/SessionGroupViewTests.swift`

- [ ] **Step 1: 写 failing 测试**

创建 `Tests/AgentDevPilotTests/SessionGroupViewTests.swift`：

```swift
import Testing
import Foundation
import Core
@testable import AgentDevPilot

@Suite("SessionGroupView helpers")
struct SessionGroupViewTests {

    private func makeSession(status: SessionStatus) -> DevSession {
        DevSession(
            id: "s1", project: "my-project", cwd: "/Users/dev/my-project",
            tool: "claude-code", status: status,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
    }

    @Test("statusTag for running session")
    func statusTagRunning() {
        #expect(sessionStatusTag(makeSession(status: .running)) == "running")
    }

    @Test("statusTag for waiting session")
    func statusTagWaiting() {
        #expect(sessionStatusTag(makeSession(status: .waiting)) == "needs input")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter SessionGroupViewTests 2>&1 | tail -5
```

Expected: compile error — `sessionStatusTag` not defined yet.

- [ ] **Step 3: 创建 SessionGroupView.swift**

创建 `Sources/App/Views/SessionGroupView.swift`：

```swift
import SwiftUI
import Core

struct SessionGroupView: View {
    let session: DevSession
    let events: [DevEvent]
    var onOpenTerminal: ((String) -> Void)?
    var onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header row
            HStack(spacing: 7) {
                Circle()
                    .fill(sessionStatusColor(session))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(session.project)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(sessionStatusTag(session))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sessionStatusColor(session))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sessionStatusColor(session).opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 5)

            if events.isEmpty {
                Text("Working...")
                    .font(.caption)
                    .italic()
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ForEach(events) { event in
                    EventCardView(
                        event: event,
                        sessionLabel: nil,
                        onOpenTerminal: onOpenTerminal
                    ) {
                        onDismiss(event.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.project), \(sessionStatusTag(session))")
    }
}

// Internal so tests can reach without crossing module boundary.
func sessionStatusTag(_ session: DevSession) -> String {
    session.status == .waiting ? "needs input" : "running"
}

func sessionStatusColor(_ session: DevSession) -> Color {
    session.status == .waiting
        ? Color(red: 1.0,  green: 0.271, blue: 0.227)  // #FF453A
        : Color(red: 1.0,  green: 0.624, blue: 0.039)  // #FF9F0A
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SessionGroupViewTests 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Build 验证**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Views/SessionGroupView.swift Tests/AgentDevPilotTests/SessionGroupViewTests.swift
git commit -m "feat: add SessionGroupView with session header and event list"
```

---

## Task 4: 重写 MenubarPopover

**Files:**
- Modify: `Sources/App/Views/MenubarPopover.swift`

- [ ] **Step 1: 用新 body 完整替换 MenubarPopover.swift**

将 `Sources/App/Views/MenubarPopover.swift` 改写为：

```swift
import SwiftUI
import Core

struct MenubarPopover: View {
    @Environment(\.openWindow) private var openWindow
    let viewModel: PopoverViewModel
    var onOpenTerminal: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.activeSessions.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                        .opacity(0.25)
                        .accessibilityHidden(true)
                    Text("No active sessions")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("Start Claude Code in any project\nto see it here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.activeSessions.enumerated()), id: \.element.id) { index, session in
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 2)
                            }
                            SessionGroupView(
                                session: session,
                                events: viewModel.eventsBySession[session.id] ?? [],
                                onOpenTerminal: onOpenTerminal
                            ) { eventId in
                                viewModel.dismiss(eventId: eventId)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()

            // Footer
            HStack {
                Button("Session Panel") {
                    openWindow(id: "session-panel")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            if let count {
                Text("\(count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
```

注意：`SectionHeader` 和 `sessionAgeLabel` 函数保留 `SectionHeader`（可能被其他地方引用），但 `sessionAgeLabel` 私有函数移除（MenubarPopover 中不再使用）。

- [ ] **Step 2: Build 验证，观察 warning**

```bash
swift build -c debug 2>&1
```

如果出现 `sessionAgeLabel` 未使用 warning，找到文件中的 `private func sessionAgeLabel` 并删除整个函数体（约第 105–110 行）。

Expected 最终：`Build complete!` 无 warning。

- [ ] **Step 3: 全量测试**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass（原 69 条 + 新增 8 条 = 77 条）。

- [ ] **Step 4: Commit**

```bash
git add Sources/App/Views/MenubarPopover.swift
git commit -m "feat: restructure MenubarPopover to session-grouped layout"
```

---

## Self-Review

### Spec Coverage

| Spec 要求 | 对应 Task |
|-----------|-----------|
| 事件按 session 分组，session 为标题 | Task 3 (SessionGroupView) + Task 4 (MenubarPopover) |
| session 按 startedAt 降序 | Task 2 (PopoverViewModel) |
| session header：项目名 + 状态标签 | Task 3 |
| waiting = red, running = amber `#FF9F0A` | Task 3 (sessionStatusColor) |
| 无事件显示 "Working..." | Task 3 |
| 无活跃 session 显示空状态（terminal 图标）| Task 4 |
| footer 保留 Session Panel \| Quit | Task 4 |
| 每 session 最多 5 条事件，排除 background + dismissed | Task 1 (EventStore) |

所有 spec 要求均有对应实现。

### Placeholder Scan
无 TBD / TODO / "similar to Task N" 模式。

### Type Consistency
- `sessionStatusTag(_:)` 定义于 Task 3，在 Task 3 测试中使用 ✅
- `sessionStatusColor(_:)` 定义于 Task 3，在 SessionGroupView 内使用 ✅
- `viewModel.activeSessions` 定义于 Task 2，在 Task 4 使用 ✅
- `viewModel.eventsBySession` 定义于 Task 2，在 Task 4 使用 ✅
- `EventStore.fetchGroupedBySession` 定义于 Task 1，在 Task 2 调用 ✅
