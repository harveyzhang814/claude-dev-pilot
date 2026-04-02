# Hook Raw Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store every incoming Claude Code hook HTTP request as a raw debug log so developers can verify which hooks were received, when, and with what payload.

**Architecture:** A new `hook_logs` table (migration v8) stores one row per POST /event request, inserted before any business logic runs. `HookLog` is a GRDB model in Core; `HookLogStore` provides insert/fetch/prune. `EventHandler` inserts a preliminary row then updates it with decoded fields; all log writes are fire-and-forget (`try?`). `AppState.lazyPrune` prunes the table using the same `retentionDays` as events.

**Tech Stack:** Swift, GRDB, Hummingbird, Swift Testing (`@Test` / `#expect`)

---

## Branch setup

- [ ] Create feature branch from staging:

```bash
git fetch origin
git checkout staging
git pull origin staging
git checkout -b feat/hook-raw-log
```

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/Core/Models/HookLog.swift` | `HookLog` GRDB model |
| Create | `Sources/Core/Store/HookLogStore.swift` | insert / fetch / prune |
| Modify | `Sources/Core/Store/DatabaseManager.swift` | migration v8 |
| Modify | `Sources/Server/EventHandler.swift` | insert log before business logic |
| Modify | `Sources/App/AppState.swift` | add prune call in `lazyPrune()` |
| Create | `Tests/StoreTests/HookLogStoreTests.swift` | store unit tests |
| Modify | `Tests/ServerTests/EventHandlerTests.swift` | assert HookLog rows inserted |

---

## Task 1: HookLog model + v8 migration

**Files:**
- Create: `Sources/Core/Models/HookLog.swift`
- Create: `Tests/StoreTests/HookLogStoreTests.swift` (stub only — full tests in Task 2)
- Modify: `Sources/Core/Store/DatabaseManager.swift`

- [ ] **Step 1: Write a failing test that inserts and fetches a HookLog**

Create `Tests/StoreTests/HookLogStoreTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import Core

@Suite("HookLogStore")
struct HookLogStoreTests {

    private func makeDB() throws -> DatabaseQueue {
        try DatabaseManager.openInMemoryDatabase()
    }

    @Test("insert and fetch by session")
    func insertAndFetchBySession() async throws {
        let db = try makeDB()
        let log = HookLog(
            id: "log-001",
            receivedAt: Date(),
            hookEventName: "Notification",
            sessionId: "sess-abc",
            notificationType: "permission_prompt",
            rawPayload: #"{"hook_event_name":"Notification"}"#
        )
        try HookLogStore.insert(log, in: db)

        let results = try HookLogStore.fetchForSession("sess-abc", in: db)
        #expect(results.count == 1)
        #expect(results[0].id == "log-001")
        #expect(results[0].hookEventName == "Notification")
        #expect(results[0].notificationType == "permission_prompt")
    }
}
```

- [ ] **Step 2: Run — expect compile error (HookLog not defined)**

```bash
swift test --filter HookLogStoreTests 2>&1 | head -20
```

Expected: error about `HookLog` / `HookLogStore` not found.

- [ ] **Step 3: Create `Sources/Core/Models/HookLog.swift`**

```swift
import Foundation
import GRDB

public struct HookLog: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public let id: String
    public let receivedAt: Date
    public let hookEventName: String
    public let sessionId: String
    public let notificationType: String?
    public let rawPayload: String

    public static let databaseTableName = "hook_logs"

    public enum Columns: String, ColumnExpression {
        case id
        case receivedAt = "received_at"
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case rawPayload = "raw_payload"
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case receivedAt = "received_at"
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case rawPayload = "raw_payload"
    }

    public init(
        id: String,
        receivedAt: Date,
        hookEventName: String,
        sessionId: String,
        notificationType: String?,
        rawPayload: String
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.notificationType = notificationType
        self.rawPayload = rawPayload
    }
}
```

- [ ] **Step 4: Create stub `Sources/Core/Store/HookLogStore.swift`** (just enough to compile)

```swift
import Foundation
import GRDB

public enum HookLogStore {
    public static func insert(_ log: HookLog, in db: any DatabaseWriter) throws {
        try db.write { db in try log.insert(db) }
    }

    public static func fetchForSession(_ sessionId: String, in db: any DatabaseReader) throws -> [HookLog] {
        try db.read { db in
            try HookLog
                .filter(HookLog.Columns.sessionId == sessionId)
                .order(HookLog.Columns.receivedAt.desc)
                .fetchAll(db)
        }
    }
}
```

- [ ] **Step 5: Add migration v8 to `DatabaseManager.swift`**

After the `v7_session_custom_name` migration block, add:

```swift
migrator.registerMigration("v8_hook_logs") { db in
    try db.create(table: "hook_logs", ifNotExists: true) { t in
        t.primaryKey("id", .text)
        t.column("received_at", .text).notNull()
        t.column("hook_event_name", .text).notNull()
        t.column("session_id", .text).notNull()
        t.column("notification_type", .text)
        t.column("raw_payload", .text).notNull()
    }
    try db.create(index: "idx_hook_logs_session", on: "hook_logs",
                  columns: ["session_id"], ifNotExists: true)
    try db.create(index: "idx_hook_logs_received_at", on: "hook_logs",
                  columns: ["received_at"], ifNotExists: true)
}
```

- [ ] **Step 6: Run test — expect PASS**

```bash
swift test --filter HookLogStoreTests/insertAndFetchBySession
```

Expected: Test Suite 'HookLogStoreTests' passed.

- [ ] **Step 7: Commit**

```bash
git add Sources/Core/Models/HookLog.swift \
        Sources/Core/Store/HookLogStore.swift \
        Sources/Core/Store/DatabaseManager.swift \
        Tests/StoreTests/HookLogStoreTests.swift
git commit -m "feat: add HookLog model, HookLogStore stub, and v8 migration"
```

---

## Task 2: Complete HookLogStore

**Files:**
- Modify: `Sources/Core/Store/HookLogStore.swift`
- Modify: `Tests/StoreTests/HookLogStoreTests.swift`

- [ ] **Step 1: Write failing tests for fetchRecent and pruneOlderThan**

Add to `Tests/StoreTests/HookLogStoreTests.swift`:

```swift
    @Test("fetchRecent returns logs newest-first up to limit")
    func fetchRecentOrdered() async throws {
        let db = try makeDB()
        let now = Date()
        for i in 1...3 {
            let log = HookLog(
                id: "log-\(i)",
                receivedAt: now.addingTimeInterval(Double(i)),
                hookEventName: "Stop",
                sessionId: "sess-\(i)",
                notificationType: nil,
                rawPayload: "{}"
            )
            try HookLogStore.insert(log, in: db)
        }

        let results = try HookLogStore.fetchRecent(limit: 2, in: db)
        #expect(results.count == 2)
        #expect(results[0].id == "log-3")  // newest first
        #expect(results[1].id == "log-2")
    }

    @Test("pruneOlderThan deletes old logs, keeps recent")
    func pruneOlderThan() async throws {
        let db = try makeDB()
        let old = HookLog(
            id: "old-log",
            receivedAt: Date(timeIntervalSinceNow: -40 * 24 * 3600),  // 40 days ago
            hookEventName: "SessionStart",
            sessionId: "sess-old",
            notificationType: nil,
            rawPayload: "{}"
        )
        let recent = HookLog(
            id: "new-log",
            receivedAt: Date(),
            hookEventName: "SessionStart",
            sessionId: "sess-new",
            notificationType: nil,
            rawPayload: "{}"
        )
        try HookLogStore.insert(old, in: db)
        try HookLogStore.insert(recent, in: db)

        let deleted = try HookLogStore.pruneOlderThan(days: 30, in: db)
        #expect(deleted == 1)

        let remaining = try HookLogStore.fetchRecent(limit: 10, in: db)
        #expect(remaining.count == 1)
        #expect(remaining[0].id == "new-log")
    }
```

- [ ] **Step 2: Run — expect FAIL (methods not yet defined)**

```bash
swift test --filter HookLogStoreTests 2>&1 | head -30
```

Expected: compile errors for `fetchRecent` and `pruneOlderThan`.

- [ ] **Step 3: Add fetchRecent and pruneOlderThan to HookLogStore.swift**

Replace the contents of `Sources/Core/Store/HookLogStore.swift` with:

```swift
import Foundation
import GRDB

public enum HookLogStore {

    public static func insert(_ log: HookLog, in db: any DatabaseWriter) throws {
        try db.write { db in try log.insert(db) }
    }

    public static func fetchRecent(limit: Int, in db: any DatabaseReader) throws -> [HookLog] {
        try db.read { db in
            try HookLog
                .order(HookLog.Columns.receivedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public static func fetchForSession(_ sessionId: String, in db: any DatabaseReader) throws -> [HookLog] {
        try db.read { db in
            try HookLog
                .filter(HookLog.Columns.sessionId == sessionId)
                .order(HookLog.Columns.receivedAt.desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public static func pruneOlderThan(days: Int, in db: any DatabaseWriter) throws -> Int {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: cutoffDate)
        components.timeZone = TimeZone(identifier: "UTC")
        let cutoff = DatabaseDateComponents(components, format: .YMD_HMSS)
        return try db.write { db in
            try HookLog
                .filter(HookLog.Columns.receivedAt < cutoff.databaseValue)
                .deleteAll(db)
        }
    }
}
```

- [ ] **Step 4: Run all HookLogStore tests — expect PASS**

```bash
swift test --filter HookLogStoreTests
```

Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Store/HookLogStore.swift \
        Tests/StoreTests/HookLogStoreTests.swift
git commit -m "feat: complete HookLogStore with fetchRecent and pruneOlderThan"
```

---

## Task 3: EventHandler — insert log on every request

**Files:**
- Modify: `Sources/Server/EventHandler.swift`
- Modify: `Tests/ServerTests/EventHandlerTests.swift`

- [ ] **Step 1: Write failing tests for HookLog insertion**

Add to the `EventHandlerTests` struct in `Tests/ServerTests/EventHandlerTests.swift`:

```swift
    @Test("POST /event logs a HookLog row for Notification hook")
    func postEventLogsHookLog() async throws {
        let (app, db) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: validPayload())
            _ = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
        }
        let logs = try await db.read { try HookLog.fetchAll($0) }
        #expect(logs.count == 1)
        #expect(logs[0].hookEventName == "Notification")
        #expect(logs[0].sessionId == "abc123")
        #expect(logs[0].notificationType == nil)
        #expect(logs[0].rawPayload.contains("abc123"))
    }

    @Test("POST /event logs PARSE_ERROR for malformed JSON")
    func postEventLogsParseError() async throws {
        let (app, db) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: "not valid json {{{")
            _ = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
        }
        let logs = try await db.read { try HookLog.fetchAll($0) }
        #expect(logs.count == 1)
        #expect(logs[0].hookEventName == "PARSE_ERROR")
        #expect(logs[0].sessionId == "")
        #expect(logs[0].rawPayload == "not valid json {{{")
    }

    @Test("POST /event with SessionStart logs a HookLog row")
    func postEventSessionStartLogsHookLog() async throws {
        let (app, db) = try makeApp()
        try await app.test(.router) { client in
            let payload = """
            {
              "session_id": "sess-log-001",
              "cwd": "/Users/test/myproject",
              "hook_event_name": "SessionStart"
            }
            """
            _ = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: ByteBuffer(string: payload)
            )
        }
        let logs = try await db.read {
            try HookLog.filter(HookLog.Columns.sessionId == "sess-log-001").fetchAll($0)
        }
        #expect(logs.count == 1)
        #expect(logs[0].hookEventName == "SessionStart")
    }

    @Test("POST /event with Notification permission_prompt logs notificationType")
    func postEventLogsNotificationType() async throws {
        let (app, db) = try makeApp()
        let payload = """
        {
          "session_id": "sess-perm-001",
          "cwd": "/Users/test/myproject",
          "hook_event_name": "Notification",
          "message": "Permission required",
          "notification_type": "permission_prompt"
        }
        """
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: ByteBuffer(string: payload)
            )
        }
        let logs = try await db.read {
            try HookLog.filter(HookLog.Columns.sessionId == "sess-perm-001").fetchAll($0)
        }
        #expect(logs.count == 1)
        #expect(logs[0].notificationType == "permission_prompt")
    }
```

- [ ] **Step 2: Run — expect FAIL (EventHandler not yet inserting HookLog)**

```bash
swift test --filter EventHandlerTests/postEventLogsHookLog 2>&1 | head -20
```

Expected: test fails with `logs.count == 0`.

- [ ] **Step 3: Update EventHandler.swift**

Replace the `postEvent` function body with:

```swift
    static func postEvent(
        db: any DatabaseWriter & Sendable,
        stopWindow: StopWindowService,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> @Sendable (Request, BasicRequestContext) async throws -> Response {
        return { @Sendable request, context in
            // Collect body (max 64 KB)
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let data = Data(buffer: buffer)
            let rawPayload = String(data: data, encoding: .utf8) ?? "[non-UTF-8 body]"

            // Insert preliminary log before any business logic
            let logId = UUID().uuidString
            let log = HookLog(
                id: logId,
                receivedAt: Date(),
                hookEventName: "UNKNOWN",
                sessionId: "",
                notificationType: nil,
                rawPayload: rawPayload
            )
            try? HookLogStore.insert(log, in: db)

            // Parse HookPayload
            let payload: HookPayload
            do {
                payload = try JSONDecoder().decode(HookPayload.self, from: data)
            } catch {
                try? db.write { db in
                    try db.execute(
                        sql: "UPDATE hook_logs SET hook_event_name = 'PARSE_ERROR' WHERE id = ?",
                        arguments: [logId]
                    )
                }
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            // Update log with decoded fields
            try? db.write { db in
                try db.execute(
                    sql: """
                        UPDATE hook_logs
                        SET hook_event_name = ?, session_id = ?, notification_type = ?
                        WHERE id = ?
                        """,
                    arguments: [payload.hookEventName, payload.sessionId,
                                payload.notificationType, logId]
                )
            }

            // SessionStart / SessionEnd → lifecycle only, no DevEvent
            if payload.hookEventName == "SessionStart" || payload.hookEventName == "SessionEnd" {
                try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)
                return Response(status: .ok, headers: [:], body: .init())
            }

            // Map payload → DevEvent and persist
            let event = EventMapper.map(payload)
            try SessionLifecycleService.processEvent(event, sessionTitle: payload.title, in: db)

            // Feed Stop and Notification events into the stop window
            switch payload.hookEventName {
            case "Stop":
                await stopWindow.recordStop(sessionId: payload.sessionId)
            case "Notification":
                switch payload.notificationType {
                case "permission_prompt", "elicitation_dialog":
                    await stopWindow.recordNotification(sessionId: payload.sessionId)
                case "idle_prompt":
                    await stopWindow.recordStop(sessionId: payload.sessionId)
                default:
                    break
                }
            default:
                break
            }

            // Notify callback (drives NotificationBatcher → native notifications)
            onEvent(event)

            return Response(status: .ok, headers: [:], body: .init())
        }
    }
```

- [ ] **Step 4: Run all EventHandler tests — expect PASS**

```bash
swift test --filter EventHandlerTests
```

Expected: all tests passed (including the 4 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/Server/EventHandler.swift \
        Tests/ServerTests/EventHandlerTests.swift
git commit -m "feat: insert HookLog on every POST /event before business logic"
```

---

## Task 4: AppState — prune hook_logs daily

**Files:**
- Modify: `Sources/App/AppState.swift`

- [ ] **Step 1: Add pruning call in `lazyPrune()`**

In `Sources/App/AppState.swift`, find the `lazyPrune()` method:

```swift
    public func lazyPrune() {
        guard let db = db else { return }
        let now = Date()
        if now.timeIntervalSince(lastPruneDate) < 86400 { return }
        lastPruneDate = now
        let days = UserDefaults.standard.integer(forKey: "retentionDays")
        let retentionDays = days > 0 ? days : 30
        try? EventStore.pruneOlderThan(days: retentionDays, in: db)
    }
```

Replace with:

```swift
    public func lazyPrune() {
        guard let db = db else { return }
        let now = Date()
        if now.timeIntervalSince(lastPruneDate) < 86400 { return }
        lastPruneDate = now
        let days = UserDefaults.standard.integer(forKey: "retentionDays")
        let retentionDays = days > 0 ? days : 30
        try? EventStore.pruneOlderThan(days: retentionDays, in: db)
        try? HookLogStore.pruneOlderThan(days: retentionDays, in: db)
    }
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
swift build -c debug 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no errors.

- [ ] **Step 3: Run full test suite**

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppState.swift
git commit -m "feat: prune hook_logs daily alongside events"
```

---

## Verification

- [ ] Run the complete test suite one final time:

```bash
swift test
```

Expected: all tests pass with no failures.
