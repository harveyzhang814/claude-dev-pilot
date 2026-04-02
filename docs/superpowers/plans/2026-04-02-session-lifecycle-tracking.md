<!-- /autoplan restore point: /Users/harveyzhang96/.gstack/projects/agent-dev-pilot/main-autoplan-restore-20260402-102047.md -->
# Session Lifecycle Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register `SessionStart` and `SessionEnd` hooks to accurately count open terminals, store full `cwd` per session, and show which session each event belongs to in the popover UI.

**Architecture:** Session lifecycle (open/close) is handled entirely at the `SessionLifecycleService` layer, bypassing `EventMapper` and the `events` table. `EventHandler` routes session hooks directly to `SessionLifecycleService.handleSessionLifecycle()`. Task hooks (`Notification` etc.) continue through the existing `EventMapper → DevEvent` pipeline. `EventType` stays purely task-focused. `PopoverViewModel` gains `activeSessionCount` from a `ValueObservation` on the sessions table.

**Tech Stack:** Swift 5.9+, GRDB, SwiftUI `@Observable`, Hummingbird HTTP, GRDB `ValueObservation`

---

## Concept Boundary

```
Terminal lifecycle  →  sessions table only
                       (SessionStart / SessionEnd hooks)

Task events        →  events table + sessions table
                       (Notification hooks → EventMapper → DevEvent)
```

`EventType` is intentionally task-only. Future task hooks (`TaskCreated`, `TaskCompleted`) fit here naturally. Session hooks never touch `EventType`.

---

## File Map

| File | Change |
|------|--------|
| `Sources/Core/Models/HookPayload.swift` | Add `source`, `model` optional fields; make `message` optional (default `""`) |
| `Sources/Core/Models/DevSession.swift` | Add `cwd` column (full path) |
| `Sources/Core/Store/DatabaseManager.swift` | Add `v3_session_cwd` migration |
| `Sources/Core/Services/SessionLifecycleService.swift` | Add `handleSessionLifecycle(payload:in:)` — session-only path, no DevEvent |
| `Sources/Server/EventHandler.swift` | Route session hooks to `handleSessionLifecycle`, task hooks to existing path |
| `Sources/Core/Services/HookInstaller.swift` | Add `SessionStart` and `SessionEnd` to `claudeCodePrompt()` |
| `Sources/App/ViewModels/PopoverViewModel.swift` | Add `activeSessionCount` via GRDB `ValueObservation` on sessions |
| `Sources/App/Views/MenubarPopover.swift` | Show active session count banner |
| `Sources/App/Views/EventCardView.swift` | Show session start-time label when multiple sessions active |

---

## Task 1: Extend HookPayload

**Files:**
- Modify: `Sources/Core/Models/HookPayload.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ModelTests/HookPayloadTests.swift — add to existing test class
func testSessionStartPayloadDecoding() throws {
    let json = """
    {
        "session_id": "abc123",
        "cwd": "/Users/me/Projects/myapp",
        "hook_event_name": "SessionStart",
        "source": "startup",
        "model": "claude-sonnet-4-6"
    }
    """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    XCTAssertEqual(payload.hookEventName, "SessionStart")
    XCTAssertEqual(payload.source, "startup")
    XCTAssertEqual(payload.model, "claude-sonnet-4-6")
    XCTAssertEqual(payload.message, "")  // default when omitted
}

func testSessionEndPayloadDecodingWithoutMessage() throws {
    let json = """
    {
        "session_id": "abc123",
        "cwd": "/Users/me/Projects/myapp",
        "hook_event_name": "SessionEnd"
    }
    """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    XCTAssertEqual(payload.hookEventName, "SessionEnd")
    XCTAssertEqual(payload.message, "")
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter HookPayloadTests/testSessionStartPayloadDecoding
```

Expected: FAIL — `source`, `model` not on HookPayload; `message` is required

- [ ] **Step 3: Update HookPayload**

Replace the full struct in `Sources/Core/Models/HookPayload.swift`:

```swift
public struct HookPayload: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let message: String        // optional on wire, defaults to ""
    public let transcriptPath: String?
    public let title: String?
    public let notificationType: String?
    public let permissionMode: String?
    public let source: String?        // SessionStart: "startup"|"resume"|"clear"|"compact"
    public let model: String?         // SessionStart: e.g. "claude-sonnet-4-6"

    public enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case message
        case transcriptPath = "transcript_path"
        case title
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
        case source
        case model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        notificationType = try? c.decodeIfPresent(String.self, forKey: .notificationType)
        permissionMode = try? c.decodeIfPresent(String.self, forKey: .permissionMode)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
    }

    public init(
        sessionId: String,
        cwd: String,
        hookEventName: String,
        message: String = "",
        transcriptPath: String? = nil,
        title: String? = nil,
        notificationType: String? = nil,
        permissionMode: String? = nil,
        source: String? = nil,
        model: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.message = message
        self.transcriptPath = transcriptPath
        self.title = title
        self.notificationType = notificationType
        self.permissionMode = permissionMode
        self.source = source
        self.model = model
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter HookPayloadTests
```

Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Models/HookPayload.swift Tests/ModelTests/HookPayloadTests.swift
git commit -m "feat: extend HookPayload with source/model fields; make message optional"
```

---

## Task 2: Add `cwd` column to sessions

**Files:**
- Modify: `Sources/Core/Models/DevSession.swift`
- Modify: `Sources/Core/Store/DatabaseManager.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/StoreTests/SessionLifecycleTests.swift — add to existing class
func testSessionStartStoresCwd() throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    let payload = HookPayload(
        sessionId: "cwd-test",
        cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionStart",
        source: "startup"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let session = try db.read { db in
        try DevSession.fetchOne(db, key: "cwd-test")
    }
    XCTAssertNotNil(session)
    XCTAssertEqual(session?.cwd, "/Users/me/Projects/myapp")
    XCTAssertEqual(session?.status, .running)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter SessionLifecycleTests/testSessionStartStoresCwd
```

Expected: FAIL — `DevSession` has no `cwd`, `handleSessionLifecycle` doesn't exist yet

- [ ] **Step 3: Add `cwd` to DevSession**

In `Sources/Core/Models/DevSession.swift`, add `cwd` property:

```swift
public struct DevSession: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public let id: String
    public var project: String    // lastPathComponent of cwd
    public var cwd: String?       // full path (added v3)
    public var tool: String
    public var status: SessionStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var totalTokens: Int?
    public var lastEventTitle: String?

    public static let databaseTableName = "sessions"

    public enum Columns: String, ColumnExpression {
        case id, project, cwd, tool, status
        case startedAt = "started_at", endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    public enum CodingKeys: String, CodingKey {
        case id, project, cwd, tool, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    public init(
        id: String,
        project: String,
        cwd: String? = nil,
        tool: String,
        status: SessionStatus,
        startedAt: Date,
        endedAt: Date?,
        totalTokens: Int?,
        lastEventTitle: String?
    ) {
        self.id = id
        self.project = project
        self.cwd = cwd
        self.tool = tool
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalTokens = totalTokens
        self.lastEventTitle = lastEventTitle
    }
}
```

- [ ] **Step 4: Add v3 migration**

In `Sources/Core/Store/DatabaseManager.swift`, after the `v2_dismissed` block:

```swift
migrator.registerMigration("v3_session_cwd") { db in
    try db.alter(table: "sessions") { t in
        t.add(column: "cwd", .text)
    }
}
```

- [ ] **Step 5: Run tests to verify compile (handleSessionLifecycle still missing)**

```bash
swift build 2>&1 | head -20
```

Expected: build succeeds (handleSessionLifecycle test fails at runtime, not compile)

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Models/DevSession.swift Sources/Core/Store/DatabaseManager.swift
git commit -m "feat: add cwd column to sessions table (v3 migration)"
```

---

## Task 3: Add `handleSessionLifecycle` to SessionLifecycleService

This is the core of the new architecture. Session hooks never create `DevEvent` records — they only write to the `sessions` table.

**Files:**
- Modify: `Sources/Core/Services/SessionLifecycleService.swift`

- [ ] **Step 1: Write all failing tests**

```swift
// Tests/StoreTests/SessionLifecycleTests.swift
func testSessionStartCreatesSession() throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    let payload = HookPayload(
        sessionId: "s-start",
        cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionStart",
        source: "startup"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let session = try db.read { db in try DevSession.fetchOne(db, key: "s-start") }
    XCTAssertEqual(session?.status, .running)
    XCTAssertEqual(session?.project, "myapp")
    XCTAssertEqual(session?.cwd, "/Users/me/Projects/myapp")
    XCTAssertNil(session?.endedAt)
}

func testSessionStartReopensCompletedSession() throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    // Pre-insert a completed session
    try db.write { db in
        var s = DevSession(id: "s-reopen", project: "myapp", cwd: "/Users/me/Projects/myapp",
                           tool: "claude-code", status: .completed,
                           startedAt: Date(), endedAt: Date(), totalTokens: nil, lastEventTitle: nil)
        try s.insert(db)
    }
    let payload = HookPayload(
        sessionId: "s-reopen",
        cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionStart",
        source: "resume"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let session = try db.read { db in try DevSession.fetchOne(db, key: "s-reopen") }
    XCTAssertEqual(session?.status, .running)
    XCTAssertNil(session?.endedAt)
}

func testSessionEndClosesSession() throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    // Pre-insert a running session
    try db.write { db in
        var s = DevSession(id: "s-end", project: "myapp", cwd: "/Users/me/Projects/myapp",
                           tool: "claude-code", status: .running,
                           startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil)
        try s.insert(db)
    }
    let payload = HookPayload(
        sessionId: "s-end",
        cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionEnd"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let session = try db.read { db in try DevSession.fetchOne(db, key: "s-end") }
    XCTAssertEqual(session?.status, .completed)
    XCTAssertNotNil(session?.endedAt)
}

func testSessionStartDoesNotCreateDevEvent() throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    let payload = HookPayload(
        sessionId: "s-no-event",
        cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionStart"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let eventCount = try db.read { db in try DevEvent.fetchCount(db) }
    XCTAssertEqual(eventCount, 0, "SessionStart must not create DevEvent records")
}

func testSessionEndDoesNotCreateDevEvent() throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    try db.write { db in
        var s = DevSession(id: "s-end2", project: "myapp", cwd: nil,
                           tool: "claude-code", status: .running,
                           startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil)
        try s.insert(db)
    }
    let payload = HookPayload(
        sessionId: "s-end2",
        cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionEnd"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let eventCount = try db.read { db in try DevEvent.fetchCount(db) }
    XCTAssertEqual(eventCount, 0, "SessionEnd must not create DevEvent records")
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter SessionLifecycleTests/testSessionStartCreatesSession
```

Expected: FAIL — `handleSessionLifecycle` does not exist

- [ ] **Step 3: Implement `handleSessionLifecycle`**

Add this method to `SessionLifecycleService` in `Sources/Core/Services/SessionLifecycleService.swift`:

```swift
/// Handles SessionStart and SessionEnd hooks.
/// Only writes to the sessions table — never creates DevEvent records.
public static func handleSessionLifecycle(payload: HookPayload, in db: any DatabaseWriter) throws {
    let project = URL(fileURLWithPath: payload.cwd).lastPathComponent
    let now = ISO8601DateFormatter().string(from: Date())

    try db.write { db in
        let existing = try DevSession.fetchOne(db, key: payload.sessionId)

        switch payload.hookEventName {
        case "SessionStart":
            if let session = existing {
                // Reopen if closed; update cwd in case it changed
                if session.status == .completed || session.status == .error || session.status == .stale {
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'running', ended_at = NULL, cwd = ? WHERE id = ?",
                        arguments: [payload.cwd, payload.sessionId]
                    )
                }
                // If already running/waiting, no-op (idempotent)
            } else {
                // Create new session
                var session = DevSession(
                    id: payload.sessionId,
                    project: project,
                    cwd: payload.cwd,
                    tool: "claude-code",
                    status: .running,
                    startedAt: Date(),
                    endedAt: nil,
                    totalTokens: nil,
                    lastEventTitle: nil
                )
                try session.insert(db)
            }

        case "SessionEnd":
            if existing != nil {
                try db.execute(
                    sql: "UPDATE sessions SET status = 'completed', ended_at = ? WHERE id = ?",
                    arguments: [now, payload.sessionId]
                )
            }
            // If session not found (app restarted mid-session), silently ignore

        default:
            break
        }
    }
}
```

- [ ] **Step 4: Run all session lifecycle tests**

```bash
swift test --filter SessionLifecycleTests
```

Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/SessionLifecycleService.swift Tests/StoreTests/SessionLifecycleTests.swift
git commit -m "feat: add handleSessionLifecycle — session-only path, no DevEvent created"
```

---

## Task 4: Route session hooks in EventHandler

**Files:**
- Modify: `Sources/Server/EventHandler.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/ServerTests/EventHandlerTests.swift — add to existing class
func testSessionStartRoutesToSessionLifecycle() async throws {
    let app = try await buildApp(...)  // use existing test helper
    let body = """
    {
        "session_id": "srv-s1",
        "cwd": "/Users/me/Projects/myapp",
        "hook_event_name": "SessionStart",
        "source": "startup"
    }
    """
    let response = try await app.testing().execute(
        uri: "/event", method: .POST,
        headers: [.authorization: "Bearer \(testToken)", .contentType: "application/json"],
        body: ByteBuffer(string: body)
    )
    XCTAssertEqual(response.status, .ok)

    // Must have created session but NO events
    let eventCount = try testDB.read { db in try DevEvent.fetchCount(db) }
    XCTAssertEqual(eventCount, 0, "SessionStart must not produce DevEvent")

    let session = try testDB.read { db in try DevSession.fetchOne(db, key: "srv-s1") }
    XCTAssertNotNil(session)
    XCTAssertEqual(session?.status, .running)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter ServerTests/testSessionStartRoutesToSessionLifecycle
```

Expected: FAIL — session hook goes through EventMapper, creates DevEvent

- [ ] **Step 3: Add routing in EventHandler**

In `Sources/Server/EventHandler.swift`, update `postEvent` to fork before EventMapper:

```swift
static func postEvent(
    db: any DatabaseWriter & Sendable,
    onEvent: @Sendable @escaping (DevEvent) -> Void
) -> @Sendable (Request, BasicRequestContext) async throws -> Response {
    return { @Sendable request, context in
        let buffer = try await request.body.collect(upTo: 64 * 1024)
        let data = Data(buffer: buffer)

        let payload: HookPayload
        do {
            payload = try JSONDecoder().decode(HookPayload.self, from: data)
        } catch {
            throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
        }

        // Route session lifecycle hooks directly — they never create DevEvent records
        let sessionHooks: Set<String> = ["SessionStart", "SessionEnd"]
        if sessionHooks.contains(payload.hookEventName) {
            try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)
            return Response(status: .ok, headers: [:], body: .init())
        }

        // Task / notification hooks → existing pipeline
        let event = EventMapper.map(payload)
        try SessionLifecycleService.processEvent(event, in: db)
        onEvent(event)

        return Response(status: .ok, headers: [:], body: .init())
    }
}
```

- [ ] **Step 4: Run server tests**

```bash
swift test --filter ServerTests
```

Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Server/EventHandler.swift Tests/ServerTests/
git commit -m "feat: route SessionStart/SessionEnd to handleSessionLifecycle in EventHandler"
```

---

## Task 5: Update HookInstaller

**Files:**
- Modify: `Sources/Core/Services/HookInstaller.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/ServiceTests/HookInstallerTests.swift
func testClaudeCodePromptIncludesAllThreeHooks() {
    let prompt = HookInstaller.claudeCodePrompt()
    XCTAssertTrue(prompt.contains("Notification"))
    XCTAssertTrue(prompt.contains("SessionStart"))
    XCTAssertTrue(prompt.contains("SessionEnd"))
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter HookInstallerTests/testClaudeCodePromptIncludesAllThreeHooks
```

Expected: FAIL — prompt only mentions Notification

- [ ] **Step 3: Update `claudeCodePrompt()`**

Replace the return value of `claudeCodePrompt()` in `Sources/Core/Services/HookInstaller.swift`:

```swift
public static func claudeCodePrompt() -> String {
    """
    Please add Notification, SessionStart, and SessionEnd hooks to my Claude Code \
    settings (~/.claude/settings.json) for Agent Dev Pilot.

    All three hooks should run `~/.agent-dev-pilot/hooks/notify.sh`.

    Target JSON to merge under the "hooks" key:
    {
      "Notification": [
        {
          "matcher": "",
          "hooks": [{ "type": "command", "command": "~/.agent-dev-pilot/hooks/notify.sh" }]
        }
      ],
      "SessionStart": [
        {
          "matcher": "",
          "hooks": [{ "type": "command", "command": "~/.agent-dev-pilot/hooks/notify.sh" }]
        }
      ],
      "SessionEnd": [
        {
          "matcher": "",
          "hooks": [{ "type": "command", "command": "~/.agent-dev-pilot/hooks/notify.sh" }]
        }
      ]
    }

    Rules:
    - Only add entries that do not already exist.
    - Preserve all existing hooks and permissions exactly as-is.
    - Do not modify any other keys in settings.json.
    """
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter HookInstallerTests
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/HookInstaller.swift Tests/
git commit -m "feat: add SessionStart and SessionEnd to HookInstaller prompt"
```

---

## Task 6: Expose `activeSessionCount` in PopoverViewModel

**Files:**
- Modify: `Sources/App/ViewModels/PopoverViewModel.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/ViewModelTests/PopoverViewModelTests.swift
@MainActor
func testActiveSessionCountTracksRunningSessions() async throws {
    let db = try DatabaseManager.openInMemoryDatabase()
    let vm = PopoverViewModel()
    vm.startObserving(db: db)
    XCTAssertEqual(vm.activeSessionCount, 0)

    // SessionStart arrives → session created
    let startPayload = HookPayload(
        sessionId: "vm-s1", cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionStart", source: "startup"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: startPayload, in: db)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(vm.activeSessionCount, 1)

    // SessionEnd arrives → session closed
    let endPayload = HookPayload(
        sessionId: "vm-s1", cwd: "/Users/me/Projects/myapp",
        hookEventName: "SessionEnd"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: endPayload, in: db)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(vm.activeSessionCount, 0)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter PopoverViewModelTests/testActiveSessionCountTracksRunningSessions
```

Expected: FAIL — `activeSessionCount` does not exist

- [ ] **Step 3: Add `activeSessionCount` to PopoverViewModel**

In `Sources/App/ViewModels/PopoverViewModel.swift`, add property and observation inside `startObserving`:

```swift
public var activeSessionCount: Int = 0   // new

// Add inside startObserving, after existing observations:
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
```

Also expose session start times for disambiguation in Task 7:

```swift
private(set) var sessionStartTimes: [String: Date] = [:]   // sessionId → startedAt

// Add inside startObserving:
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

public func sessionStartedAt(for sessionId: String) -> Date? {
    sessionStartTimes[sessionId]
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter AgentDevPilotTests
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/App/ViewModels/PopoverViewModel.swift Tests/
git commit -m "feat: add activeSessionCount and sessionStartTimes to PopoverViewModel"
```

---

## Task 7: UI — Active session count banner + session label on event cards

**Files:**
- Modify: `Sources/App/Views/MenubarPopover.swift`
- Modify: `Sources/App/Views/EventCardView.swift`

No unit tests for pure layout — verify with `make run`.

- [ ] **Step 1: Add session count banner to MenubarPopover**

In `Sources/App/Views/MenubarPopover.swift`, add banner at the top of `body`, before "Needs Attention" section header:

```swift
// Active session count banner — show only when sessions exist
if viewModel.activeSessionCount > 0 {
    HStack(spacing: 6) {
        Circle()
            .fill(Color.green)
            .frame(width: 7, height: 7)
        Text("\(viewModel.activeSessionCount) active session\(viewModel.activeSessionCount == 1 ? "" : "s")")
            .font(.caption2)
            .foregroundColor(.secondary)
        Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 2)
}
```

- [ ] **Step 2: Add `sessionLabel` to EventCardView**

In `Sources/App/Views/EventCardView.swift`, add optional `sessionLabel` parameter and render it inline with project name:

```swift
struct EventCardView: View {
    let event: DevEvent
    var sessionLabel: String? = nil   // e.g. "started 5m ago"
    var onOpenTerminal: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    // ...

    // In cardContent, replace the project name block:
    if !event.project.isEmpty {
        HStack(spacing: 4) {
            Text(event.project)
                .font(.caption2)
                .bold()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let label = sessionLabel {
                Text("·")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
```

- [ ] **Step 3: Wire session label in MenubarPopover**

In `Sources/App/Views/MenubarPopover.swift`, compute label when passing events to `EventCardView`:

```swift
ForEach(viewModel.actionEvents) { event in
    EventCardView(
        event: event,
        sessionLabel: viewModel.activeSessionCount > 1
            ? viewModel.sessionStartedAt(for: event.sessionId).map { sessionAgeLabel($0) }
            : nil,
        onOpenTerminal: onOpenTerminal
    ) {
        viewModel.dismiss(eventId: event.id)
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 4)
}
```

Apply identical pattern to `recentEvents`.

Add helper at file scope:

```swift
private func sessionAgeLabel(_ date: Date) -> String {
    let s = Int(-date.timeIntervalSinceNow)
    if s < 60 { return "started just now" }
    if s < 3600 { return "started \(s / 60)m ago" }
    return "started \(s / 3600)h ago"
}
```

- [ ] **Step 4: Build and verify**

```bash
make bundle
```

Expected: build succeeds

- [ ] **Step 5: Launch and smoke test**

```bash
make run
```

Open two Claude Code terminals in different directories. Check:
- Popover shows "2 active sessions" banner
- Event cards from the older terminal show "myapp · started Xm ago"
- Close one terminal → banner drops to "1 active session"

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Views/MenubarPopover.swift Sources/App/Views/EventCardView.swift
git commit -m "feat: show active session count and session age label in popover UI"
```

---

## Task 8: Full test run

- [ ] **Step 1: Run all tests**

```bash
swift test
```

Expected: all PASS

- [ ] **Step 2: Commit if any fixes were needed**

```bash
git add -p
git commit -m "fix: address any failing tests from integration"
```

---

## v2 Backlog

- **Ghostty window focus via TTY:** In `notify.sh`, capture `$TTY` and include in payload. Store on session. "Open Terminal" button uses AppleScript to focus the matching Ghostty window.
- **Task events:** Register `TaskCreated`, `TaskCompleted` hooks from Claude Code. Route through `EventMapper` as task events — fits naturally into the existing pipeline since session/task concepts are now cleanly separated.
- **Existing install detection:** Detect users who installed hooks before v3 and prompt them to re-run the Claude Code setup prompt.

---

## Known Limitations

- **Ungraceful exits:** If terminal is Force Quit, `SessionEnd` won't fire. Session stays active until 30-min stale timer fires.
- **Existing installs:** Users who installed before this version won't have `SessionStart`/`SessionEnd` hooks until they re-run the setup prompt from Settings.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 1 | clean | Stop→SessionEnd corrected; session/task concept boundary established |
| Eng Review | `/plan-eng-review` | Architecture & tests | 1 | clean | 5 gaps found and fixed inline |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |

**VERDICT:** APPROVED. Architecture is clean: session lifecycle bypasses EventMapper/DevEvent entirely. EventType stays task-only. Ready to implement.
