# Agent Dev Pilot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menubar app that receives Claude Code hook events via a local HTTP server, persists them in SQLite, and surfaces them through a menubar popover, floating session panel, and native notifications — with a 3-tier attention model (action/review/background).

**Architecture:** Hummingbird 2 HTTP server on 127.0.0.1:19876 receives hook JSON via POST, maps it to `DevEvent`, writes to SQLite (GRDB.swift, WAL mode). GRDB `ValueObservation` bridges SQLite writes to `@MainActor` SwiftUI views. Native notifications via `UNUserNotificationCenter` with batching and global throttle. Auth via Bearer token stored in `~/.agent-dev-pilot/token`.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), Hummingbird 2, GRDB.swift, UserNotifications framework

**Design doc:** `~/.gstack/projects/agent-dev-pilot/harveyzhang96-unknown-design-20260401-131205.md`
**Test plan:** `~/.gstack/projects/agent-dev-pilot/harveyzhang96-unknown-test-plan-20260401-144415.md`

---

## IMPORTANT: Hook Schema Update

The design doc's `HookPayload` is based on guesses. The **actual** Claude Code Notification hook schema (verified against docs) is:

```json
{
  "session_id": "string",
  "transcript_path": "string",
  "cwd": "string",
  "hook_event_name": "Notification",
  "message": "string",
  "title": "string (optional)",
  "notification_type": "permission_prompt|idle_prompt|auth_success|elicitation_dialog",
  "permission_mode": "string (optional)"
}
```

Key differences from design doc:
1. `notification_type` field exists — we can detect `permission_prompt` directly (no fragile text matching needed for permissions!)
2. `hook_event_name` is always `"Notification"` for v1
3. `transcript_path` gives us a path to the full conversation JSON
4. `permission_mode` tells us the current Claude Code permission mode
5. No `type` field — the design doc's `type: "notification"` doesn't exist

**Impact on EventType inference:**
- `notification_type == "permission_prompt"` → `.permissionNeeded` (deterministic, not text-matching)
- `notification_type == "idle_prompt"` → `.taskCompleted` (Claude is idle, task likely done)
- `notification_type == "auth_success"` → `.taskStarted` (background, informational)
- `notification_type == "elicitation_dialog"` → `.permissionNeeded` (MCP server asking for input)
- Text matching on `message` field is still used as a secondary signal for `taskCompleted` vs `taskError` when `notification_type` is `idle_prompt`

---

## File Structure

```
AgentDevPilot/
├── Package.swift                          // SPM manifest
├── Sources/
│   ├── App/
│   │   ├── AgentDevPilotApp.swift         // @main, MenuBarExtra, app lifecycle
│   │   └── AppState.swift                 // Top-level @Observable state coordinator
│   ├── Models/
│   │   ├── HookPayload.swift              // Raw JSON from Claude Code hooks
│   │   ├── DevEvent.swift                 // Internal event model + AttentionTier + EventType
│   │   ├── DevSession.swift               // Session model + SessionStatus
│   │   └── EventMapper.swift              // HookPayload → DevEvent mapping
│   ├── Store/
│   │   ├── DatabaseManager.swift          // GRDB setup, migrations, WAL mode
│   │   ├── EventStore.swift               // Event CRUD operations
│   │   └── SessionStore.swift             // Session lifecycle CRUD
│   ├── Server/
│   │   ├── EventServer.swift              // Hummingbird HTTP server setup
│   │   ├── EventHandler.swift             // POST /event, GET /health route handlers
│   │   └── AuthMiddleware.swift           // Bearer token validation + size limit
│   ├── Services/
│   │   ├── AuthTokenService.swift         // Token generation and file I/O
│   │   ├── SessionLifecycleService.swift  // Session state machine (create/update/close/reopen/stale)
│   │   ├── NotificationService.swift      // UNUserNotificationCenter wrapper
│   │   └── NotificationBatcher.swift      // Batching (>3 in 2s) + global throttle (5 per 10s)
│   ├── ViewModels/
│   │   ├── PopoverViewModel.swift         // ValueObservation for event list + badge
│   │   └── SessionPanelViewModel.swift    // ValueObservation for session grid
│   └── Views/
│       ├── MenubarPopover.swift           // Popover content (needs attention + recent activity)
│       ├── EventCardView.swift            // Individual event card
│       ├── SessionPanelView.swift         // Floating window content
│       ├── SessionRowView.swift           // Individual session row
│       ├── SettingsView.swift             // Preferences window
│       └── OnboardingView.swift           // 3-step setup wizard
├── Tests/
│   ├── ModelTests/
│   │   ├── HookPayloadTests.swift         // JSON parsing tests
│   │   ├── EventMapperTests.swift         // Mapping + EventType inference + AttentionTier
│   │   └── DevSessionTests.swift          // Session model tests
│   ├── StoreTests/
│   │   ├── DatabaseManagerTests.swift     // Migration, WAL mode
│   │   ├── EventStoreTests.swift          // Event CRUD
│   │   └── SessionStoreTests.swift        // Session CRUD
│   ├── ServerTests/
│   │   ├── EventHandlerTests.swift        // HTTP route tests
│   │   └── AuthMiddlewareTests.swift      // Auth + size limit tests
│   └── ServiceTests/
│       ├── AuthTokenServiceTests.swift    // Token gen/read tests
│       ├── SessionLifecycleTests.swift    // State machine tests
│       └── NotificationBatcherTests.swift // Batching + throttle tests
└── Resources/
    └── notify.sh                          // Hook helper script
```

---

## Task 1: Create Swift Package Project

**Files:**
- Create: `Package.swift`
- Create: `Sources/App/AgentDevPilotApp.swift` (minimal placeholder)

- [ ] **Step 1: Initialize Swift package**

```bash
cd /Users/harveyzhang96/Projects/agent-dev-pilot
swift package init --type executable --name AgentDevPilot
```

- [ ] **Step 2: Configure Package.swift with dependencies**

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDevPilot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentDevPilot",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "AgentDevPilotTests",
            dependencies: [
                "AgentDevPilot",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests"
        ),
    ]
)
```

- [ ] **Step 3: Create minimal app entry point**

Create `Sources/App/AgentDevPilotApp.swift`:

```swift
import SwiftUI

@main
struct AgentDevPilotApp: App {
    var body: some Scene {
        MenuBarExtra("Agent Dev Pilot", systemImage: "bell") {
            Text("Agent Dev Pilot")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

- [ ] **Step 4: Verify it builds**

```bash
cd /Users/harveyzhang96/Projects/agent-dev-pilot
swift build
```

Expected: BUILD SUCCEEDED. A menubar app icon appears if you run it.

- [ ] **Step 5: Initialize git and commit**

```bash
cd /Users/harveyzhang96/Projects/agent-dev-pilot
git init
cat > .gitignore << 'EOF'
.build/
.swiftpm/
*.xcodeproj/
xcuserdata/
DerivedData/
.DS_Store
EOF
git add Package.swift Sources/ Tests/ .gitignore CLAUDE.md docs/
git commit -m "feat: scaffold Swift package with Hummingbird + GRDB dependencies"
```

---

## Task 2: Define Data Models

**Files:**
- Create: `Sources/Models/HookPayload.swift`
- Create: `Sources/Models/DevEvent.swift`
- Create: `Sources/Models/DevSession.swift`
- Create: `Tests/ModelTests/HookPayloadTests.swift`

- [ ] **Step 1: Write HookPayload parsing tests**

Create `Tests/ModelTests/HookPayloadTests.swift`:

```swift
import Testing
import Foundation
@testable import AgentDevPilot

@Suite("HookPayload JSON Parsing")
struct HookPayloadTests {

    @Test("Valid JSON with all fields")
    func validFullPayload() throws {
        let json = """
        {
            "session_id": "abc-123",
            "transcript_path": "/Users/dev/.claude/sessions/abc.json",
            "cwd": "/Users/dev/myproject",
            "hook_event_name": "Notification",
            "message": "Task completed successfully",
            "title": "Claude Code",
            "notification_type": "idle_prompt",
            "permission_mode": "default"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.sessionId == "abc-123")
        #expect(payload.transcriptPath == "/Users/dev/.claude/sessions/abc.json")
        #expect(payload.cwd == "/Users/dev/myproject")
        #expect(payload.hookEventName == "Notification")
        #expect(payload.message == "Task completed successfully")
        #expect(payload.title == "Claude Code")
        #expect(payload.notificationType == "idle_prompt")
        #expect(payload.permissionMode == "default")
    }

    @Test("Valid JSON with only required fields")
    func validMinimalPayload() throws {
        let json = """
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/myproject",
            "hook_event_name": "Notification",
            "message": "Hello"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.sessionId == "abc-123")
        #expect(payload.title == nil)
        #expect(payload.notificationType == nil)
        #expect(payload.transcriptPath == nil)
        #expect(payload.permissionMode == nil)
    }

    @Test("Malformed JSON returns nil")
    func malformedJson() {
        let json = "not json at all".data(using: .utf8)!
        let payload = try? JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload == nil)
    }

    @Test("Empty JSON object returns nil (missing required fields)")
    func emptyObject() {
        let json = "{}".data(using: .utf8)!
        let payload = try? JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload == nil)
    }

    @Test("Array instead of object returns nil")
    func arrayInsteadOfObject() {
        let json = "[1, 2, 3]".data(using: .utf8)!
        let payload = try? JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload == nil)
    }

    @Test("Unknown fields are ignored")
    func unknownFieldsIgnored() throws {
        let json = """
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/myproject",
            "hook_event_name": "Notification",
            "message": "Hello",
            "some_future_field": "unknown",
            "another_field": 42
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.sessionId == "abc-123")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter HookPayloadTests 2>&1 | head -30
```

Expected: compilation error — `HookPayload` type doesn't exist yet.

- [ ] **Step 3: Implement HookPayload**

Create `Sources/Models/HookPayload.swift`:

```swift
import Foundation

/// Raw JSON payload from Claude Code hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
struct HookPayload: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let hookEventName: String
    let message: String
    let transcriptPath: String?
    let title: String?
    let notificationType: String?
    let permissionMode: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case message
        case transcriptPath = "transcript_path"
        case title
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter HookPayloadTests
```

Expected: All 6 tests pass.

- [ ] **Step 5: Define EventType, AttentionTier, and DevEvent**

Create `Sources/Models/DevEvent.swift`:

```swift
import Foundation
import GRDB

enum EventType: String, Codable, Sendable, DatabaseValueConvertible {
    case taskCompleted
    case permissionNeeded
    case taskError
    case taskStarted
}

enum AttentionTier: String, Codable, Sendable, DatabaseValueConvertible {
    case action      // permissionNeeded → red badge, native notification
    case review      // taskCompleted, taskError → popover list, gray badge
    case background  // taskStarted → session panel only
}

struct DevEvent: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    let id: String              // UUID string
    let sessionId: String
    let type: EventType
    let title: String
    let detail: String?
    let payload: String         // raw JSON text for debug view
    let tokenCount: Int?
    let durationSeconds: Double?
    let timestamp: Date
    let attentionTier: AttentionTier

    static let databaseTableName = "events"

    enum Columns: String, ColumnExpression {
        case id, sessionId = "session_id", type, title, detail
        case payload, tokenCount = "token_count"
        case durationSeconds = "duration_seconds"
        case timestamp, attentionTier = "attention_tier"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case type, title, detail, payload
        case tokenCount = "token_count"
        case durationSeconds = "duration_seconds"
        case timestamp
        case attentionTier = "attention_tier"
    }
}
```

- [ ] **Step 6: Define SessionStatus and DevSession**

Create `Sources/Models/DevSession.swift`:

```swift
import Foundation
import GRDB

enum SessionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running, waiting, completed, error, stale
}

struct DevSession: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    let id: String
    var project: String
    var tool: String
    var status: SessionStatus
    var startedAt: Date
    var endedAt: Date?
    var totalTokens: Int?
    var lastEventTitle: String?

    static let databaseTableName = "sessions"

    enum Columns: String, ColumnExpression {
        case id, project, tool, status
        case startedAt = "started_at", endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    enum CodingKeys: String, CodingKey {
        case id, project, tool, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }
}
```

- [ ] **Step 7: Run build to verify models compile**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Sources/Models/ Tests/ModelTests/
git commit -m "feat: add HookPayload, DevEvent, DevSession models with GRDB conformance"
```

---

## Task 3: Event Mapper (HookPayload → DevEvent)

**Files:**
- Create: `Sources/Models/EventMapper.swift`
- Create: `Tests/ModelTests/EventMapperTests.swift`

- [ ] **Step 1: Write EventMapper tests**

Create `Tests/ModelTests/EventMapperTests.swift`:

```swift
import Testing
import Foundation
@testable import AgentDevPilot

@Suite("EventMapper")
struct EventMapperTests {

    // MARK: - notification_type → EventType

    @Test("permission_prompt → permissionNeeded")
    func permissionPrompt() throws {
        let payload = makePayload(notificationType: "permission_prompt", message: "Tool use requires approval")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("elicitation_dialog → permissionNeeded")
    func elicitationDialog() throws {
        let payload = makePayload(notificationType: "elicitation_dialog", message: "MCP server needs input")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("idle_prompt → taskCompleted")
    func idlePrompt() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Claude is ready for your next request")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskCompleted)
        #expect(event.attentionTier == .review)
    }

    @Test("auth_success → taskStarted (background)")
    func authSuccess() throws {
        let payload = makePayload(notificationType: "auth_success", message: "Successfully authenticated")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskStarted)
        #expect(event.attentionTier == .background)
    }

    // MARK: - Text matching fallback (when notification_type is nil or unknown)

    @Test("Message with 'error' and no notification_type → taskError")
    func errorFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Build failed with error")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskError)
        #expect(event.attentionTier == .review)
    }

    @Test("Message with 'permission' and no notification_type → permissionNeeded")
    func permissionFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Permission required to write file")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("Message with 'completed' and no notification_type → taskCompleted")
    func completedFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Task completed successfully")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskCompleted)
        #expect(event.attentionTier == .review)
    }

    @Test("No pattern match → taskCompleted (safe default)")
    func noMatchFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Something happened")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskCompleted)
        #expect(event.attentionTier == .review)
    }

    @Test("Multiple keywords: 'completed with error' → error wins (higher priority)")
    func multipleKeywords() throws {
        let payload = makePayload(notificationType: nil, message: "Task completed with error")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskError)
    }

    // MARK: - Field mapping

    @Test("Project extracted from cwd as last path component")
    func projectFromCwd() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Done", cwd: "/Users/dev/Projects/my-app")
        let event = EventMapper.map(payload)
        #expect(event.title.contains("my-app") || event.detail == "/Users/dev/Projects/my-app")
    }

    @Test("Session ID carried through from payload")
    func sessionIdPassthrough() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Done", sessionId: "test-session-42")
        let event = EventMapper.map(payload)
        #expect(event.sessionId == "test-session-42")
    }

    @Test("Raw payload stored as JSON string")
    func rawPayloadStored() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Done")
        let event = EventMapper.map(payload)
        #expect(event.payload.contains("idle_prompt"))
    }

    // MARK: - Helpers

    private func makePayload(
        notificationType: String? = nil,
        message: String = "test",
        cwd: String = "/Users/dev/project",
        sessionId: String = "test-session"
    ) -> HookPayload {
        HookPayload(
            sessionId: sessionId,
            cwd: cwd,
            hookEventName: "Notification",
            message: message,
            transcriptPath: nil,
            title: nil,
            notificationType: notificationType,
            permissionMode: nil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter EventMapperTests 2>&1 | head -20
```

Expected: compilation error — `EventMapper` doesn't exist.

- [ ] **Step 3: Implement EventMapper**

Create `Sources/Models/EventMapper.swift`:

```swift
import Foundation

enum EventMapper {

    /// Maps a raw hook payload to an internal DevEvent.
    static func map(_ payload: HookPayload) -> DevEvent {
        let eventType = inferEventType(payload)
        let tier = attentionTier(for: eventType)
        let rawJson = encodePayload(payload)

        return DevEvent(
            id: UUID().uuidString,
            sessionId: payload.sessionId,
            type: eventType,
            title: payload.title ?? messageTitle(payload.message, project: projectName(from: payload.cwd)),
            detail: payload.cwd,
            payload: rawJson,
            tokenCount: nil,
            durationSeconds: nil,
            timestamp: Date(),
            attentionTier: tier
        )
    }

    // MARK: - EventType Inference

    /// Priority: notification_type (deterministic) > text matching (fallback) > .taskCompleted (safe default)
    static func inferEventType(_ payload: HookPayload) -> EventType {
        // 1. Deterministic: use notification_type if present
        if let notifType = payload.notificationType {
            switch notifType {
            case "permission_prompt", "elicitation_dialog":
                return .permissionNeeded
            case "idle_prompt":
                return inferFromMessage(payload.message) ?? .taskCompleted
            case "auth_success":
                return .taskStarted
            default:
                // Unknown notification_type — fall through to text matching
                break
            }
        }

        // 2. Fallback: text matching on message
        return inferFromMessage(payload.message) ?? .taskCompleted
    }

    /// Text-match priority: error > permission > completed.
    /// Error checked first because "completed with error" should be an error.
    private static func inferFromMessage(_ message: String) -> EventType? {
        let lowered = message.lowercased()

        // Error patterns (highest priority)
        let errorPatterns = ["error", "failed", "failure"]
        if errorPatterns.contains(where: { lowered.contains($0) }) {
            return .taskError
        }

        // Permission patterns
        let permissionPatterns = ["permission", "approve", "allow"]
        if permissionPatterns.contains(where: { lowered.contains($0) }) {
            return .permissionNeeded
        }

        // Completion patterns
        let completionPatterns = ["completed", "finished", "done"]
        if completionPatterns.contains(where: { lowered.contains($0) }) {
            return .taskCompleted
        }

        return nil
    }

    // MARK: - AttentionTier

    static func attentionTier(for eventType: EventType) -> AttentionTier {
        switch eventType {
        case .permissionNeeded:
            return .action
        case .taskCompleted, .taskError:
            return .review
        case .taskStarted:
            return .background
        }
    }

    // MARK: - Helpers

    static func projectName(from cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func messageTitle(_ message: String, project: String) -> String {
        let prefix = "\(project): "
        let maxLen = 80 - prefix.count
        if message.count <= maxLen {
            return prefix + message
        }
        return prefix + message.prefix(maxLen - 1) + "…"
    }

    private static func encodePayload(_ payload: HookPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter EventMapperTests
```

Expected: All 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/EventMapper.swift Tests/ModelTests/EventMapperTests.swift
git commit -m "feat: add EventMapper with notification_type-based inference and text fallback"
```

---

## Task 4: SQLite Database Setup (GRDB)

**Files:**
- Create: `Sources/Store/DatabaseManager.swift`
- Create: `Tests/StoreTests/DatabaseManagerTests.swift`

- [ ] **Step 1: Write DatabaseManager tests**

Create `Tests/StoreTests/DatabaseManagerTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import AgentDevPilot

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    @Test("Creates tables on first run")
    func createsTables() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)

        try dbQueue.read { db in
            #expect(try db.tableExists("sessions"))
            #expect(try db.tableExists("events"))
        }
    }

    @Test("WAL mode is enabled")
    func walMode() throws {
        // WAL requires a file-based database, not in-memory
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let dbQueue = try DatabaseQueue(path: dbPath)
        try DatabaseManager.migrate(dbQueue)

        let journalMode = try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(journalMode == "wal")
    }

    @Test("Sessions table has expected columns")
    func sessionsColumns() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)

        try dbQueue.read { db in
            let columns = try db.columns(in: "sessions").map(\.name)
            #expect(columns.contains("id"))
            #expect(columns.contains("project"))
            #expect(columns.contains("tool"))
            #expect(columns.contains("status"))
            #expect(columns.contains("started_at"))
            #expect(columns.contains("ended_at"))
            #expect(columns.contains("total_tokens"))
            #expect(columns.contains("last_event_title"))
        }
    }

    @Test("Events table has expected columns")
    func eventsColumns() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)

        try dbQueue.read { db in
            let columns = try db.columns(in: "events").map(\.name)
            #expect(columns.contains("id"))
            #expect(columns.contains("session_id"))
            #expect(columns.contains("type"))
            #expect(columns.contains("title"))
            #expect(columns.contains("detail"))
            #expect(columns.contains("payload"))
            #expect(columns.contains("token_count"))
            #expect(columns.contains("duration_seconds"))
            #expect(columns.contains("timestamp"))
            #expect(columns.contains("attention_tier"))
        }
    }

    @Test("Migration is idempotent (running twice doesn't crash)")
    func idempotent() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        try DatabaseManager.migrate(dbQueue)  // second run should be a no-op
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter DatabaseManagerTests 2>&1 | head -20
```

Expected: compilation error — `DatabaseManager` doesn't exist.

- [ ] **Step 3: Implement DatabaseManager**

Create `Sources/Store/DatabaseManager.swift`:

```swift
import Foundation
import GRDB

enum DatabaseManager {

    /// Opens (or creates) the app's SQLite database with WAL mode and runs migrations.
    static func openDatabase(at path: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL for concurrent read/write
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        let dbPool = try DatabasePool(path: path, configuration: config)
        try migrate(dbPool)
        return dbPool
    }

    /// Creates an in-memory database (for tests or degraded mode).
    static func openInMemoryDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try migrate(dbQueue)
        return dbQueue
    }

    /// Runs all migrations. Safe to call multiple times (GRDB tracks applied migrations).
    static func migrate(_ db: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "sessions", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("project", .text).notNull()
                t.column("tool", .text).notNull().defaults(to: "claude-code")
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("started_at", .text).notNull()
                t.column("ended_at", .text)
                t.column("total_tokens", .integer)
                t.column("last_event_title", .text)
            }

            try db.create(table: "events", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("payload", .text).notNull()
                t.column("token_count", .integer)
                t.column("duration_seconds", .double)
                t.column("timestamp", .text).notNull()
                t.column("attention_tier", .text).notNull().defaults(to: "review")
            }

            try db.create(
                index: "idx_events_session",
                on: "events",
                columns: ["session_id"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_events_timestamp",
                on: "events",
                columns: ["timestamp"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_sessions_status",
                on: "sessions",
                columns: ["status"],
                ifNotExists: true
            )
        }

        try migrator.migrate(db)
    }

    /// Returns the default database file path: ~/Library/Application Support/AgentDevPilot/db.sqlite
    static var defaultDatabasePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AgentDevPilot")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("db.sqlite").path
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter DatabaseManagerTests
```

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Store/DatabaseManager.swift Tests/StoreTests/DatabaseManagerTests.swift
git commit -m "feat: add DatabaseManager with GRDB migrations, WAL mode, and indexes"
```

---

## Task 5: Event and Session Stores (CRUD)

**Files:**
- Create: `Sources/Store/EventStore.swift`
- Create: `Sources/Store/SessionStore.swift`
- Create: `Tests/StoreTests/EventStoreTests.swift`
- Create: `Tests/StoreTests/SessionStoreTests.swift`

- [ ] **Step 1: Write EventStore tests**

Create `Tests/StoreTests/EventStoreTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import AgentDevPilot

@Suite("EventStore")
struct EventStoreTests {

    private func makeDb() throws -> DatabaseQueue {
        try DatabaseManager.openInMemoryDatabase()
    }

    private func makeEvent(
        sessionId: String = "session-1",
        type: EventType = .taskCompleted,
        tier: AttentionTier = .review
    ) -> DevEvent {
        DevEvent(
            id: UUID().uuidString,
            sessionId: sessionId,
            type: type,
            title: "Test event",
            detail: nil,
            payload: "{}",
            tokenCount: nil,
            durationSeconds: nil,
            timestamp: Date(),
            attentionTier: tier
        )
    }

    private func insertSession(_ db: DatabaseQueue, id: String = "session-1") throws {
        try db.write { db in
            try DevSession(
                id: id, project: "/test", tool: "claude-code",
                status: .running, startedAt: Date(), endedAt: nil,
                totalTokens: nil, lastEventTitle: nil
            ).insert(db)
        }
    }

    @Test("Insert and fetch event")
    func insertAndFetch() throws {
        let db = try makeDb()
        try insertSession(db)
        let event = makeEvent()

        try EventStore.insert(event, in: db)
        let fetched = try EventStore.fetch(id: event.id, in: db)

        #expect(fetched != nil)
        #expect(fetched?.id == event.id)
        #expect(fetched?.type == .taskCompleted)
        #expect(fetched?.attentionTier == .review)
    }

    @Test("Fetch recent events ordered by timestamp descending")
    func fetchRecent() throws {
        let db = try makeDb()
        try insertSession(db)

        let old = DevEvent(
            id: "old", sessionId: "session-1", type: .taskCompleted,
            title: "Old", detail: nil, payload: "{}", tokenCount: nil,
            durationSeconds: nil, timestamp: Date(timeIntervalSinceNow: -100),
            attentionTier: .review
        )
        let new = DevEvent(
            id: "new", sessionId: "session-1", type: .taskCompleted,
            title: "New", detail: nil, payload: "{}", tokenCount: nil,
            durationSeconds: nil, timestamp: Date(),
            attentionTier: .review
        )

        try EventStore.insert(old, in: db)
        try EventStore.insert(new, in: db)

        let recent = try EventStore.fetchRecent(limit: 10, in: db)
        #expect(recent.count == 2)
        #expect(recent.first?.id == "new")  // newest first
    }

    @Test("Prune events older than retention days")
    func pruneOld() throws {
        let db = try makeDb()
        try insertSession(db)

        let old = DevEvent(
            id: "ancient", sessionId: "session-1", type: .taskCompleted,
            title: "Ancient", detail: nil, payload: "{}", tokenCount: nil,
            durationSeconds: nil,
            timestamp: Date(timeIntervalSinceNow: -31 * 24 * 3600), // 31 days ago
            attentionTier: .review
        )
        let recent = makeEvent()

        try EventStore.insert(old, in: db)
        try EventStore.insert(recent, in: db)

        let pruned = try EventStore.pruneOlderThan(days: 30, in: db)
        #expect(pruned == 1)

        let remaining = try EventStore.fetchRecent(limit: 100, in: db)
        #expect(remaining.count == 1)
    }

    @Test("Count action-tier events (for badge)")
    func countActionEvents() throws {
        let db = try makeDb()
        try insertSession(db)

        let action = makeEvent(type: .permissionNeeded, tier: .action)
        let review = makeEvent(type: .taskCompleted, tier: .review)

        try EventStore.insert(action, in: db)
        try EventStore.insert(review, in: db)

        let count = try EventStore.countActionTier(in: db)
        #expect(count == 1)
    }
}
```

- [ ] **Step 2: Write SessionStore tests**

Create `Tests/StoreTests/SessionStoreTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import AgentDevPilot

@Suite("SessionStore")
struct SessionStoreTests {

    private func makeDb() throws -> DatabaseQueue {
        try DatabaseManager.openInMemoryDatabase()
    }

    private func makeSession(
        id: String = "session-1",
        status: SessionStatus = .running
    ) -> DevSession {
        DevSession(
            id: id, project: "/Users/dev/project", tool: "claude-code",
            status: status, startedAt: Date(), endedAt: nil,
            totalTokens: nil, lastEventTitle: nil
        )
    }

    @Test("Insert and fetch session")
    func insertAndFetch() throws {
        let db = try makeDb()
        var session = makeSession()
        try db.write { db in try session.insert(db) }

        let fetched = try SessionStore.fetch(id: "session-1", in: db)
        #expect(fetched != nil)
        #expect(fetched?.status == .running)
    }

    @Test("Update session status")
    func updateStatus() throws {
        let db = try makeDb()
        var session = makeSession()
        try db.write { db in try session.insert(db) }

        try SessionStore.updateStatus(id: "session-1", to: .waiting, in: db)

        let fetched = try SessionStore.fetch(id: "session-1", in: db)
        #expect(fetched?.status == .waiting)
    }

    @Test("Close session sets endedAt")
    func closeSession() throws {
        let db = try makeDb()
        var session = makeSession()
        try db.write { db in try session.insert(db) }

        try SessionStore.close(id: "session-1", status: .completed, in: db)

        let fetched = try SessionStore.fetch(id: "session-1", in: db)
        #expect(fetched?.status == .completed)
        #expect(fetched?.endedAt != nil)
    }

    @Test("Reopen completed session clears endedAt")
    func reopenSession() throws {
        let db = try makeDb()
        var session = makeSession(status: .completed)
        session.endedAt = Date()
        try db.write { db in try session.insert(db) }

        try SessionStore.reopen(id: "session-1", in: db)

        let fetched = try SessionStore.fetch(id: "session-1", in: db)
        #expect(fetched?.status == .running)
        #expect(fetched?.endedAt == nil)
    }

    @Test("Mark stale sessions")
    func markStale() throws {
        let db = try makeDb()
        var old = DevSession(
            id: "old", project: "/test", tool: "claude-code",
            status: .running, startedAt: Date(timeIntervalSinceNow: -3600),
            endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
        try db.write { db in try old.insert(db) }

        let staleCount = try SessionStore.markStaleSessions(
            olderThan: 1800, // 30 minutes
            in: db
        )
        #expect(staleCount == 1)

        let fetched = try SessionStore.fetch(id: "old", in: db)
        #expect(fetched?.status == .stale)
    }

    @Test("Fetch active sessions (running, waiting)")
    func fetchActive() throws {
        let db = try makeDb()
        for (id, status) in [("s1", SessionStatus.running), ("s2", .waiting), ("s3", .completed), ("s4", .stale)] {
            var s = DevSession(
                id: id, project: "/test", tool: "claude-code",
                status: status, startedAt: Date(), endedAt: nil,
                totalTokens: nil, lastEventTitle: nil
            )
            try db.write { db in try s.insert(db) }
        }

        let active = try SessionStore.fetchActive(in: db)
        #expect(active.count == 2)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift test --filter "EventStoreTests|SessionStoreTests" 2>&1 | head -20
```

Expected: compilation error — `EventStore`, `SessionStore` don't exist.

- [ ] **Step 4: Implement EventStore**

Create `Sources/Store/EventStore.swift`:

```swift
import Foundation
import GRDB

enum EventStore {

    static func insert(_ event: DevEvent, in db: any DatabaseWriter) throws {
        try db.write { db in
            try event.insert(db)
        }
    }

    static func fetch(id: String, in db: any DatabaseReader) throws -> DevEvent? {
        try db.read { db in
            try DevEvent.fetchOne(db, key: id)
        }
    }

    static func fetchRecent(limit: Int, in db: any DatabaseReader) throws -> [DevEvent] {
        try db.read { db in
            try DevEvent
                .order(DevEvent.Columns.timestamp.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    static func fetchForSession(_ sessionId: String, in db: any DatabaseReader) throws -> [DevEvent] {
        try db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.sessionId == sessionId)
                .order(DevEvent.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    static func countActionTier(in db: any DatabaseReader) throws -> Int {
        try db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue)
                .fetchCount(db)
        }
    }

    /// Deletes events older than `days`. Returns the number deleted.
    @discardableResult
    static func pruneOlderThan(days: Int, in db: any DatabaseWriter) throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let formatter = ISO8601DateFormatter()
        let cutoffStr = formatter.string(from: cutoff)

        return try db.write { db in
            try DevEvent
                .filter(DevEvent.Columns.timestamp < cutoffStr)
                .deleteAll(db)
        }
    }
}
```

- [ ] **Step 5: Implement SessionStore**

Create `Sources/Store/SessionStore.swift`:

```swift
import Foundation
import GRDB

enum SessionStore {

    static func fetch(id: String, in db: any DatabaseReader) throws -> DevSession? {
        try db.read { db in
            try DevSession.fetchOne(db, key: id)
        }
    }

    static func fetchActive(in db: any DatabaseReader) throws -> [DevSession] {
        try db.read { db in
            try DevSession
                .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue]
                    .contains(DevSession.Columns.status))
                .order(DevSession.Columns.startedAt.desc)
                .fetchAll(db)
        }
    }

    static func fetchAll(in db: any DatabaseReader) throws -> [DevSession] {
        try db.read { db in
            try DevSession
                .order(DevSession.Columns.startedAt.desc)
                .fetchAll(db)
        }
    }

    static func updateStatus(id: String, to status: SessionStatus, in db: any DatabaseWriter) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    static func close(id: String, status: SessionStatus, in db: any DatabaseWriter) throws {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        try db.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = ?, ended_at = ? WHERE id = ?",
                arguments: [status.rawValue, now, id]
            )
        }
    }

    static func reopen(id: String, in db: any DatabaseWriter) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = 'running', ended_at = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Marks running/waiting sessions as stale if they have no events newer than `seconds` ago.
    /// Returns count of sessions marked stale.
    @discardableResult
    static func markStaleSessions(olderThan seconds: TimeInterval, in db: any DatabaseWriter) throws -> Int {
        let formatter = ISO8601DateFormatter()
        let cutoff = formatter.string(from: Date(timeIntervalSinceNow: -seconds))

        return try db.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions SET status = 'stale'
                    WHERE status IN ('running', 'waiting')
                    AND started_at < ?
                    AND id NOT IN (
                        SELECT DISTINCT session_id FROM events WHERE timestamp > ?
                    )
                    """,
                arguments: [cutoff, cutoff]
            )
            return db.changesCount
        }
    }

    static func updateLastEvent(id: String, title: String, tokens: Int?, in db: any DatabaseWriter) throws {
        try db.write { db in
            if let tokens = tokens {
                try db.execute(
                    sql: """
                        UPDATE sessions
                        SET last_event_title = ?,
                            total_tokens = COALESCE(total_tokens, 0) + ?
                        WHERE id = ?
                        """,
                    arguments: [title, tokens, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE sessions SET last_event_title = ? WHERE id = ?",
                    arguments: [title, id]
                )
            }
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
swift test --filter "EventStoreTests|SessionStoreTests"
```

Expected: All 10 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Store/EventStore.swift Sources/Store/SessionStore.swift Tests/StoreTests/
git commit -m "feat: add EventStore and SessionStore with CRUD, pruning, and stale detection"
```

---

## Task 6: Session Lifecycle Service

**Files:**
- Create: `Sources/Services/SessionLifecycleService.swift`
- Create: `Tests/ServiceTests/SessionLifecycleTests.swift`

- [ ] **Step 1: Write SessionLifecycle tests**

Create `Tests/ServiceTests/SessionLifecycleTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import AgentDevPilot

@Suite("SessionLifecycleService")
struct SessionLifecycleTests {

    private func makeDb() throws -> DatabaseQueue {
        try DatabaseManager.openInMemoryDatabase()
    }

    private func makeEvent(
        sessionId: String = "session-1",
        type: EventType = .taskCompleted,
        tier: AttentionTier = .review,
        cwd: String = "/Users/dev/project"
    ) -> DevEvent {
        DevEvent(
            id: UUID().uuidString, sessionId: sessionId, type: type,
            title: "Test event", detail: cwd, payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: Date(), attentionTier: tier
        )
    }

    @Test("First event creates new session as running")
    func firstEventCreatesSession() throws {
        let db = try makeDb()
        let event = makeEvent()

        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: "session-1", in: db)
        #expect(session != nil)
        #expect(session?.status == .running)
        #expect(session?.project == "/Users/dev/project")
    }

    @Test("permissionNeeded event sets status to waiting")
    func permissionSetsWaiting() throws {
        let db = try makeDb()
        let first = makeEvent(type: .taskStarted, tier: .background)
        try SessionLifecycleService.processEvent(first, in: db)

        let perm = makeEvent(type: .permissionNeeded, tier: .action)
        try SessionLifecycleService.processEvent(perm, in: db)

        let session = try SessionStore.fetch(id: "session-1", in: db)
        #expect(session?.status == .waiting)
    }

    @Test("taskCompleted event closes session")
    func completedCloses() throws {
        let db = try makeDb()
        let first = makeEvent(type: .taskStarted, tier: .background)
        try SessionLifecycleService.processEvent(first, in: db)

        let done = makeEvent(type: .taskCompleted, tier: .review)
        try SessionLifecycleService.processEvent(done, in: db)

        let session = try SessionStore.fetch(id: "session-1", in: db)
        #expect(session?.status == .completed)
        #expect(session?.endedAt != nil)
    }

    @Test("taskError event closes session")
    func errorCloses() throws {
        let db = try makeDb()
        let first = makeEvent(type: .taskStarted, tier: .background)
        try SessionLifecycleService.processEvent(first, in: db)

        let err = makeEvent(type: .taskError, tier: .review)
        try SessionLifecycleService.processEvent(err, in: db)

        let session = try SessionStore.fetch(id: "session-1", in: db)
        #expect(session?.status == .error)
    }

    @Test("Event for completed session reopens it")
    func reopenCompletedSession() throws {
        let db = try makeDb()
        let first = makeEvent(type: .taskStarted, tier: .background)
        try SessionLifecycleService.processEvent(first, in: db)

        let done = makeEvent(type: .taskCompleted, tier: .review)
        try SessionLifecycleService.processEvent(done, in: db)

        // Session is now completed. New event should reopen.
        let newEvent = makeEvent(type: .taskStarted, tier: .background)
        try SessionLifecycleService.processEvent(newEvent, in: db)

        let session = try SessionStore.fetch(id: "session-1", in: db)
        #expect(session?.status == .running)
        #expect(session?.endedAt == nil)
    }

    @Test("Subsequent event updates lastEventTitle")
    func updatesLastTitle() throws {
        let db = try makeDb()
        let first = makeEvent(type: .taskStarted, tier: .background)
        try SessionLifecycleService.processEvent(first, in: db)

        let second = DevEvent(
            id: UUID().uuidString, sessionId: "session-1", type: .taskCompleted,
            title: "Build succeeded", detail: "/test", payload: "{}",
            tokenCount: 500, durationSeconds: nil, timestamp: Date(),
            attentionTier: .review
        )
        try SessionLifecycleService.processEvent(second, in: db)

        let session = try SessionStore.fetch(id: "session-1", in: db)
        #expect(session?.lastEventTitle == "Build succeeded")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SessionLifecycleTests 2>&1 | head -20
```

Expected: compilation error — `SessionLifecycleService` doesn't exist.

- [ ] **Step 3: Implement SessionLifecycleService**

Create `Sources/Services/SessionLifecycleService.swift`:

```swift
import Foundation
import GRDB

enum SessionLifecycleService {

    /// Processes a DevEvent: creates/updates the session, inserts the event, transitions session state.
    ///
    /// Session state machine:
    /// ```
    /// [new event, unknown session] → create session (.running)
    /// [permissionNeeded]           → .waiting
    /// [taskCompleted]              → .completed (endedAt set)
    /// [taskError]                  → .error (endedAt set)
    /// [any event on .completed/.error session] → reopen (.running, endedAt cleared)
    /// [any other event]            → .running
    /// ```
    static func processEvent(_ event: DevEvent, in db: any DatabaseWriter) throws {
        try db.write { db in
            // 1. Check if session exists
            let existingSession = try DevSession.fetchOne(db, key: event.sessionId)

            if let session = existingSession {
                // Reopen if closed
                if session.status == .completed || session.status == .error {
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'running', ended_at = NULL WHERE id = ?",
                        arguments: [event.sessionId]
                    )
                }

                // Insert the event
                try event.insert(db)

                // Transition state based on event type
                switch event.type {
                case .permissionNeeded:
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'waiting', last_event_title = ? WHERE id = ?",
                        arguments: [event.title, event.sessionId]
                    )
                case .taskCompleted:
                    let now = ISO8601DateFormatter().string(from: Date())
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'completed', ended_at = ?, last_event_title = ? WHERE id = ?",
                        arguments: [now, event.title, event.sessionId]
                    )
                case .taskError:
                    let now = ISO8601DateFormatter().string(from: Date())
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'error', ended_at = ?, last_event_title = ? WHERE id = ?",
                        arguments: [now, event.title, event.sessionId]
                    )
                case .taskStarted:
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'running', last_event_title = ? WHERE id = ?",
                        arguments: [event.title, event.sessionId]
                    )
                }

                // Update token count if present
                if let tokens = event.tokenCount {
                    try db.execute(
                        sql: "UPDATE sessions SET total_tokens = COALESCE(total_tokens, 0) + ? WHERE id = ?",
                        arguments: [tokens, event.sessionId]
                    )
                }
            } else {
                // Create new session
                let now = ISO8601DateFormatter().string(from: Date())
                let session = DevSession(
                    id: event.sessionId,
                    project: event.detail ?? "unknown",
                    tool: "claude-code",
                    status: .running,
                    startedAt: Date(),
                    endedAt: nil,
                    totalTokens: event.tokenCount,
                    lastEventTitle: event.title
                )
                try session.insert(db)

                // Insert the event
                try event.insert(db)

                // Apply state transition for first event too
                if event.type == .permissionNeeded {
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'waiting' WHERE id = ?",
                        arguments: [event.sessionId]
                    )
                } else if event.type == .taskCompleted {
                    let endNow = ISO8601DateFormatter().string(from: Date())
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'completed', ended_at = ? WHERE id = ?",
                        arguments: [endNow, event.sessionId]
                    )
                } else if event.type == .taskError {
                    let endNow = ISO8601DateFormatter().string(from: Date())
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'error', ended_at = ? WHERE id = ?",
                        arguments: [endNow, event.sessionId]
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SessionLifecycleTests
```

Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/SessionLifecycleService.swift Tests/ServiceTests/SessionLifecycleTests.swift
git commit -m "feat: add SessionLifecycleService with state machine (create/update/close/reopen)"
```

---

## Task 7: Auth Token Service

**Files:**
- Create: `Sources/Services/AuthTokenService.swift`
- Create: `Tests/ServiceTests/AuthTokenServiceTests.swift`

- [ ] **Step 1: Write AuthTokenService tests**

Create `Tests/ServiceTests/AuthTokenServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import AgentDevPilot

@Suite("AuthTokenService")
struct AuthTokenServiceTests {

    private let testDir: String = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-dev-pilot-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    @Test("Generate token creates 32-byte hex string")
    func generateToken() {
        let token = AuthTokenService.generateToken()
        #expect(token.count == 64) // 32 bytes = 64 hex chars
        #expect(token.allSatisfy { $0.isHexDigit })
    }

    @Test("Save and load token roundtrip")
    func saveAndLoad() throws {
        let tokenPath = "\(testDir)/token"
        let token = AuthTokenService.generateToken()

        try AuthTokenService.save(token: token, to: tokenPath)
        let loaded = try AuthTokenService.load(from: tokenPath)

        #expect(loaded == token)
    }

    @Test("Token file has restricted permissions (owner read-only)")
    func filePermissions() throws {
        let tokenPath = "\(testDir)/token2"
        let token = AuthTokenService.generateToken()

        try AuthTokenService.save(token: token, to: tokenPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("ensureToken creates token if missing, reuses if exists")
    func ensureToken() throws {
        let tokenPath = "\(testDir)/token3"

        let first = try AuthTokenService.ensureToken(at: tokenPath)
        let second = try AuthTokenService.ensureToken(at: tokenPath)

        #expect(first == second) // same token reused
        #expect(first.count == 64)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter AuthTokenServiceTests 2>&1 | head -20
```

Expected: compilation error.

- [ ] **Step 3: Implement AuthTokenService**

Create `Sources/Services/AuthTokenService.swift`:

```swift
import Foundation

enum AuthTokenService {

    /// Default token file path: ~/.agent-dev-pilot/token
    static var defaultTokenPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agent-dev-pilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token").path
    }

    /// Generates a cryptographically random 32-byte hex token.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Saves a token to disk with 0600 permissions (owner read/write only).
    static func save(token: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try token.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    /// Loads a token from disk. Returns the trimmed token string.
    static func load(from path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns existing token or generates and saves a new one.
    static func ensureToken(at path: String? = nil) throws -> String {
        let tokenPath = path ?? defaultTokenPath
        if FileManager.default.fileExists(atPath: tokenPath) {
            return try load(from: tokenPath)
        }
        let token = generateToken()
        try save(token: token, to: tokenPath)
        return token
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter AuthTokenServiceTests
```

Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/AuthTokenService.swift Tests/ServiceTests/AuthTokenServiceTests.swift
git commit -m "feat: add AuthTokenService with token generation, 0600 permissions, and ensureToken"
```

---

## Task 8: HTTP Server (Hummingbird)

**Files:**
- Create: `Sources/Server/EventServer.swift`
- Create: `Sources/Server/EventHandler.swift`
- Create: `Sources/Server/AuthMiddleware.swift`
- Create: `Tests/ServerTests/EventHandlerTests.swift`
- Create: `Tests/ServerTests/AuthMiddlewareTests.swift`

- [ ] **Step 1: Write EventHandler tests**

Create `Tests/ServerTests/EventHandlerTests.swift`:

```swift
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import GRDB
@testable import AgentDevPilot

@Suite("EventHandler")
struct EventHandlerTests {

    private func makeTestApp() throws -> (Application, DatabaseQueue, String) {
        let db = try DatabaseManager.openInMemoryDatabase()
        let token = "test-token-abc123"
        let app = try EventServer.buildApp(db: db, authToken: token)
        return (app, db, token)
    }

    @Test("POST /event with valid JSON returns 200")
    func validPost() async throws {
        let (app, _, token) = try makeTestApp()
        let body = """
        {
            "session_id": "s1",
            "cwd": "/Users/dev/project",
            "hook_event_name": "Notification",
            "message": "Task completed"
        }
        """

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/event",
                method: .post,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(token)"
                ],
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("POST /event with malformed JSON returns 400")
    func malformedJson() async throws {
        let (app, _, token) = try makeTestApp()

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/event",
                method: .post,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(token)"
                ],
                body: ByteBuffer(string: "not json")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("GET /health returns 200 with version")
    func healthCheck() async throws {
        let (app, _, _) = try makeTestApp()

        try await app.test(.live) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("version"))
            }
        }
    }

    @Test("POST /event without auth returns 401")
    func noAuth() async throws {
        let (app, _, _) = try makeTestApp()

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("POST /event with wrong token returns 401")
    func wrongToken() async throws {
        let (app, _, _) = try makeTestApp()

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/event",
                method: .post,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer wrong-token"
                ],
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter EventHandlerTests 2>&1 | head -20
```

Expected: compilation error.

- [ ] **Step 3: Implement AuthMiddleware**

Create `Sources/Server/AuthMiddleware.swift`:

```swift
import Foundation
import Hummingbird

/// Middleware that validates Bearer token on protected routes.
/// GET /health is exempt (no auth needed).
struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String
    let maxBodySize: Int = 65_536 // 64KB

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Health check is public
        if request.uri.path == "/health" && request.method == .get {
            return try await next(request, context)
        }

        // Validate Bearer token
        guard let authHeader = request.headers[.authorization],
              authHeader == "Bearer \(token)" else {
            return Response(status: .unauthorized, body: .init(byteBuffer: .init(string: "Unauthorized")))
        }

        return try await next(request, context)
    }
}
```

- [ ] **Step 4: Implement EventHandler**

Create `Sources/Server/EventHandler.swift`:

```swift
import Foundation
import Hummingbird
import GRDB

enum EventHandler {

    /// POST /event — receives hook JSON, maps to DevEvent, persists.
    static func handleEvent(
        request: Request,
        context: some RequestContext,
        db: any DatabaseWriter,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) async throws -> Response {
        // Read body
        let body = try await request.body.collect(upTo: 65_536) // 64KB limit

        // Parse HookPayload
        let decoder = JSONDecoder()
        let payload: HookPayload
        do {
            payload = try decoder.decode(HookPayload.self, from: body)
        } catch {
            return Response(
                status: .badRequest,
                body: .init(byteBuffer: .init(string: "Invalid JSON: \(error.localizedDescription)"))
            )
        }

        // Map to DevEvent
        let event = EventMapper.map(payload)

        // Persist and process session lifecycle
        try SessionLifecycleService.processEvent(event, in: db)

        // Notify listeners (for notifications, UI updates)
        onEvent(event)

        return Response(status: .ok, body: .init(byteBuffer: .init(string: "{\"status\":\"ok\"}")))
    }

    /// GET /health — returns version and server status.
    static func handleHealth() -> Response {
        let json = """
        {"version":"1.0.0","status":"running"}
        """
        return Response(status: .ok, body: .init(byteBuffer: .init(string: json)))
    }
}
```

- [ ] **Step 5: Implement EventServer**

Create `Sources/Server/EventServer.swift`:

```swift
import Foundation
import Hummingbird
import GRDB

enum EventServer {

    /// Builds the Hummingbird application with routes and middleware.
    static func buildApp(
        db: any DatabaseWriter & Sendable,
        authToken: String,
        onEvent: @Sendable @escaping (DevEvent) -> Void = { _ in }
    ) throws -> Application {
        let router = Router()

        // Auth middleware on all routes (health check exempted inside middleware)
        router.middlewares.add(AuthMiddleware<BasicRequestContext>(token: authToken))

        // Routes
        router.get("/health") { _, _ in
            EventHandler.handleHealth()
        }

        router.post("/event") { request, context in
            try await EventHandler.handleEvent(
                request: request,
                context: context,
                db: db,
                onEvent: onEvent
            )
        }

        let app = Application(router: router)
        return app
    }

    /// Starts the HTTP server on 127.0.0.1 at the given port.
    static func start(
        db: any DatabaseWriter & Sendable,
        authToken: String,
        port: Int = 19876,
        onEvent: @Sendable @escaping (DevEvent) -> Void = { _ in }
    ) async throws -> Application {
        let app = try buildApp(db: db, authToken: authToken, onEvent: onEvent)

        // Configure to bind to loopback only
        app.server.configuration.address = .hostname("127.0.0.1", port: port)

        return app
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
swift test --filter EventHandlerTests
```

Expected: All 5 tests pass. (Note: the exact Hummingbird 2 API may need adjustments — if tests fail due to API differences, adapt the implementation to match the actual Hummingbird 2 API. The test expectations remain the same.)

- [ ] **Step 7: Commit**

```bash
git add Sources/Server/ Tests/ServerTests/
git commit -m "feat: add Hummingbird HTTP server with auth middleware, POST /event, GET /health"
```

---

## Task 9: Notification Batcher

**Files:**
- Create: `Sources/Services/NotificationBatcher.swift`
- Create: `Tests/ServiceTests/NotificationBatcherTests.swift`

- [ ] **Step 1: Write NotificationBatcher tests**

Create `Tests/ServiceTests/NotificationBatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import AgentDevPilot

@Suite("NotificationBatcher")
struct NotificationBatcherTests {

    private func makeEvent(
        sessionId: String = "session-1",
        type: EventType = .permissionNeeded,
        tier: AttentionTier = .action
    ) -> DevEvent {
        DevEvent(
            id: UUID().uuidString, sessionId: sessionId, type: type,
            title: "Event", detail: "/project", payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: Date(), attentionTier: tier
        )
    }

    @Test("Single event produces immediate notification")
    func singleEvent() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }

        batcher.submit(makeEvent())
        batcher.flush()

        #expect(notifications.count == 1)
        #expect(notifications.first?.isBatched == false)
    }

    @Test("2 events within 2s same session produce 2 separate notifications")
    func twoEventsSameSession() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }

        batcher.submit(makeEvent())
        batcher.submit(makeEvent())
        batcher.flush()

        #expect(notifications.count == 2)
    }

    @Test("4+ events within 2s same session produce 1 batched notification")
    func batchedSameSession() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }

        for _ in 0..<4 {
            batcher.submit(makeEvent())
        }
        batcher.flush()

        #expect(notifications.count == 1)
        #expect(notifications.first?.isBatched == true)
        #expect(notifications.first?.eventCount == 4)
    }

    @Test("4 events within 2s different sessions produce 4 notifications")
    func differentSessions() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }

        for i in 0..<4 {
            batcher.submit(makeEvent(sessionId: "session-\(i)"))
        }
        batcher.flush()

        #expect(notifications.count == 4)
    }

    @Test("Global throttle: 6th notification in window becomes summary")
    func globalThrottle() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher(globalMaxPerWindow: 5) { notifications.append($0) }

        // 6 events, each from different session (no per-session batching)
        for i in 0..<6 {
            batcher.submit(makeEvent(sessionId: "s-\(i)"))
        }
        batcher.flush()

        // First 5 individual, 6th is a summary
        let summaries = notifications.filter(\.isSummary)
        #expect(summaries.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter NotificationBatcherTests 2>&1 | head -20
```

Expected: compilation error.

- [ ] **Step 3: Implement NotificationBatcher**

Create `Sources/Services/NotificationBatcher.swift`:

```swift
import Foundation

/// Batches notifications to prevent spam.
/// - Per-session: >3 events in 2s → one batched notification.
/// - Global: max 5 notifications per 10s window → summary.
final class NotificationBatcher: @unchecked Sendable {

    struct Notification: Sendable {
        let event: DevEvent?          // nil for summary notifications
        let sessionId: String
        let eventCount: Int
        let isBatched: Bool           // true when >3 events collapsed
        let isSummary: Bool           // true when global throttle fires
        let title: String
        let body: String
    }

    private let batchThreshold = 3
    private let batchWindowSeconds: TimeInterval = 2.0
    private let globalMaxPerWindow: Int
    private let globalWindowSeconds: TimeInterval = 10.0

    private var pendingEvents: [String: [DevEvent]] = [:]  // sessionId → events
    private var pendingTimestamps: [String: Date] = [:]     // sessionId → first event time
    private var globalNotificationCount = 0
    private var globalWindowStart = Date()

    private let onNotification: (Notification) -> Void

    init(
        globalMaxPerWindow: Int = 5,
        onNotification: @escaping (Notification) -> Void
    ) {
        self.globalMaxPerWindow = globalMaxPerWindow
        self.onNotification = onNotification
    }

    func submit(_ event: DevEvent) {
        let sid = event.sessionId
        let now = Date()

        // Reset batch window if expired
        if let firstTime = pendingTimestamps[sid],
           now.timeIntervalSince(firstTime) > batchWindowSeconds {
            flushSession(sid)
        }

        if pendingEvents[sid] == nil {
            pendingEvents[sid] = []
            pendingTimestamps[sid] = now
        }
        pendingEvents[sid]?.append(event)
    }

    func flush() {
        let sessionIds = Array(pendingEvents.keys)
        for sid in sessionIds {
            flushSession(sid)
        }
    }

    private func flushSession(_ sessionId: String) {
        guard let events = pendingEvents[sessionId], !events.isEmpty else { return }

        let now = Date()

        // Reset global window if expired
        if now.timeIntervalSince(globalWindowStart) > globalWindowSeconds {
            globalNotificationCount = 0
            globalWindowStart = now
        }

        if events.count > batchThreshold {
            // Batched notification
            emitNotification(Notification(
                event: events.last,
                sessionId: sessionId,
                eventCount: events.count,
                isBatched: true,
                isSummary: false,
                title: "\(events.count) events from \(projectName(events.first))",
                body: "Latest: \(events.last?.title ?? "unknown")"
            ))
        } else {
            // Individual notifications
            for event in events {
                emitNotification(Notification(
                    event: event,
                    sessionId: sessionId,
                    eventCount: 1,
                    isBatched: false,
                    isSummary: false,
                    title: event.title,
                    body: event.detail ?? ""
                ))
            }
        }

        pendingEvents[sessionId] = nil
        pendingTimestamps[sessionId] = nil
    }

    private func emitNotification(_ notification: Notification) {
        globalNotificationCount += 1

        if globalNotificationCount > globalMaxPerWindow {
            // Global throttle: emit summary instead
            onNotification(Notification(
                event: nil,
                sessionId: "",
                eventCount: globalNotificationCount,
                isBatched: false,
                isSummary: true,
                title: "\(globalNotificationCount) events across multiple projects",
                body: "Open Agent Dev Pilot to see details"
            ))
        } else {
            onNotification(notification)
        }
    }

    private func projectName(_ event: DevEvent?) -> String {
        guard let detail = event?.detail else { return "unknown" }
        return URL(fileURLWithPath: detail).lastPathComponent
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter NotificationBatcherTests
```

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/NotificationBatcher.swift Tests/ServiceTests/NotificationBatcherTests.swift
git commit -m "feat: add NotificationBatcher with per-session batching and global throttle"
```

---

## Task 10: Notification Service (UNUserNotificationCenter)

**Files:**
- Create: `Sources/Services/NotificationService.swift`

- [ ] **Step 1: Implement NotificationService**

Create `Sources/Services/NotificationService.swift`:

```swift
import Foundation
import UserNotifications

@MainActor
final class NotificationService {

    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private let categoryIdentifier = "AGENT_DEV_PILOT_EVENT"

    private init() {}

    /// Request notification permission on first launch.
    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                registerCategories()
            }
            return granted
        } catch {
            return false
        }
    }

    /// Check if notifications are authorized.
    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Post a notification from the batcher output.
    func post(_ notification: NotificationBatcher.Notification, playSound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = categoryIdentifier

        if playSound && notification.event?.attentionTier == .action {
            content.sound = .default
        }

        // Store session info for tap handling
        content.userInfo = [
            "sessionId": notification.sessionId,
            "isBatched": notification.isBatched,
            "isSummary": notification.isSummary
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        center.add(request)
    }

    /// Register notification categories with actions.
    private func registerCategories() {
        let openTerminal = UNNotificationAction(
            identifier: "OPEN_TERMINAL",
            title: "Open Terminal",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openTerminal],
            intentIdentifiers: []
        )

        center.setNotificationCategories([category])
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED. (UNUserNotificationCenter requires running on macOS, can't unit test easily — covered by E2E tests.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Services/NotificationService.swift
git commit -m "feat: add NotificationService with UNUserNotificationCenter, permission request, and Open Terminal action"
```

---

## Task 11: ViewModels with GRDB ValueObservation

**Files:**
- Create: `Sources/ViewModels/PopoverViewModel.swift`
- Create: `Sources/ViewModels/SessionPanelViewModel.swift`

- [ ] **Step 1: Implement PopoverViewModel**

Create `Sources/ViewModels/PopoverViewModel.swift`:

```swift
import Foundation
import GRDB
import Observation
import Combine

/// Observes events table via GRDB ValueObservation.
/// Publishes to @MainActor for SwiftUI consumption.
///
/// Data flow:
/// ```
/// SQLite write (by EventHandler)
///     ↓ GRDB ValueObservation detects change
///     ↓ publishes to @MainActor
/// PopoverViewModel.events / .actionCount updated
///     ↓ SwiftUI observes @Observable
/// MenubarPopover re-renders
/// ```
@MainActor
@Observable
final class PopoverViewModel {
    var actionEvents: [DevEvent] = []
    var recentEvents: [DevEvent] = []
    var actionCount: Int = 0

    private var cancellable: AnyCancellable?

    func startObserving(db: any DatabaseReader) {
        // Observe action-tier events (needs attention section)
        let actionObservation = ValueObservation.tracking { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(20)
                .fetchAll(db)
        }

        // Observe recent events (recent activity section)
        let recentObservation = ValueObservation.tracking { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier != AttentionTier.background.rawValue)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(50)
                .fetchAll(db)
        }

        // Combine both observations
        let combined = ValueObservation.tracking { db -> ([DevEvent], [DevEvent]) in
            let action = try DevEvent
                .filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(20)
                .fetchAll(db)

            let recent = try DevEvent
                .filter(DevEvent.Columns.attentionTier != AttentionTier.background.rawValue)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(50)
                .fetchAll(db)

            return (action, recent)
        }

        cancellable = combined
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] action, recent in
                    self?.actionEvents = action
                    self?.recentEvents = recent
                    self?.actionCount = action.count
                }
            )
    }

    func resetBadge() {
        actionCount = 0
    }

    func stopObserving() {
        cancellable?.cancel()
        cancellable = nil
    }
}
```

- [ ] **Step 2: Implement SessionPanelViewModel**

Create `Sources/ViewModels/SessionPanelViewModel.swift`:

```swift
import Foundation
import GRDB
import Observation
import Combine

@MainActor
@Observable
final class SessionPanelViewModel {
    var activeSessions: [DevSession] = []
    var completedSessions: [DevSession] = []
    var staleSessions: [DevSession] = []

    private var cancellable: AnyCancellable?

    func startObserving(db: any DatabaseReader) {
        let observation = ValueObservation.tracking { db -> ([DevSession], [DevSession], [DevSession]) in
            let active = try DevSession
                .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue]
                    .contains(DevSession.Columns.status))
                .order(DevSession.Columns.startedAt.desc)
                .fetchAll(db)

            let completed = try DevSession
                .filter([SessionStatus.completed.rawValue, SessionStatus.error.rawValue]
                    .contains(DevSession.Columns.status))
                .order(DevSession.Columns.startedAt.desc)
                .limit(20)
                .fetchAll(db)

            let stale = try DevSession
                .filter(DevSession.Columns.status == SessionStatus.stale.rawValue)
                .order(DevSession.Columns.startedAt.desc)
                .fetchAll(db)

            return (active, completed, stale)
        }

        cancellable = observation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] active, completed, stale in
                    self?.activeSessions = active
                    self?.completedSessions = completed
                    self?.staleSessions = stale
                }
            )
    }

    func stopObserving() {
        cancellable?.cancel()
        cancellable = nil
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/ViewModels/
git commit -m "feat: add PopoverViewModel and SessionPanelViewModel with GRDB ValueObservation"
```

---

## Task 12: App State Coordinator

**Files:**
- Create: `Sources/App/AppState.swift`

- [ ] **Step 1: Implement AppState**

Create `Sources/App/AppState.swift`:

```swift
import Foundation
import GRDB
import Observation

/// Top-level app state coordinator. Owns the database, server, and notification batcher.
/// Wired into the SwiftUI app at startup.
@MainActor
@Observable
final class AppState {
    let db: any DatabaseWriter & Sendable
    let authToken: String
    let popoverVM: PopoverViewModel
    let sessionPanelVM: SessionPanelViewModel
    let notificationBatcher: NotificationBatcher

    var serverRunning = false
    var notificationsAuthorized = false
    var showOnboarding = false
    var serverError: String?
    var soundEnabled = true

    private var staleTimer: Timer?
    private var pruneDate: Date?

    init() throws {
        // Database (fall back to in-memory if file-based fails)
        let dbPath = DatabaseManager.defaultDatabasePath
        do {
            self.db = try DatabaseManager.openDatabase(at: dbPath)
        } catch {
            self.db = try DatabaseManager.openInMemoryDatabase()
        }

        // Auth token
        self.authToken = try AuthTokenService.ensureToken()

        // ViewModels
        self.popoverVM = PopoverViewModel()
        self.sessionPanelVM = SessionPanelViewModel()

        // Notification batcher
        self.notificationBatcher = NotificationBatcher { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                // Only post native notifications for action-tier events
                if notification.event?.attentionTier == .action || notification.isSummary {
                    NotificationService.shared.post(notification, playSound: self.soundEnabled)
                }
            }
        }
    }

    func start() async {
        // Start observing database
        popoverVM.startObserving(db: db)
        sessionPanelVM.startObserving(db: db)

        // Request notification permission
        notificationsAuthorized = await NotificationService.shared.requestPermission()

        // Check if onboarding needed (no events in DB)
        let eventCount = try? EventStore.fetchRecent(limit: 1, in: db).count
        showOnboarding = (eventCount ?? 0) == 0

        // Start stale session timer (60-second interval)
        startStaleTimer()

        // Start HTTP server
        await startServer()
    }

    private func startServer() async {
        do {
            let app = try await EventServer.start(
                db: db,
                authToken: authToken,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in
                        self.notificationBatcher.submit(event)
                        self.notificationBatcher.flush()
                        self.lazyPrune()
                    }
                }
            )
            try await app.run()
            serverRunning = true
        } catch {
            serverError = "Could not start server on port 19876: \(error.localizedDescription)"
        }
    }

    private func startStaleTimer() {
        staleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                try? SessionStore.markStaleSessions(olderThan: 1800, in: self.db)
            }
        }
    }

    /// Prune old events once per day (lazy check on first event after midnight).
    private func lazyPrune() {
        let today = Calendar.current.startOfDay(for: Date())
        if pruneDate == nil || pruneDate! < today {
            pruneDate = today
            try? EventStore.pruneOlderThan(days: 30, in: db)
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/AppState.swift
git commit -m "feat: add AppState coordinator with database, server, notifications, and stale timer"
```

---

## Task 13: Menubar Popover View

**Files:**
- Create: `Sources/Views/MenubarPopover.swift`
- Create: `Sources/Views/EventCardView.swift`

- [ ] **Step 1: Implement EventCardView**

Create `Sources/Views/EventCardView.swift`:

```swift
import SwiftUI

struct EventCardView: View {
    let event: DevEvent
    let onOpenTerminal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status color bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(statusColor)
                .frame(width: 3, height: 40)

            // Icon
            Image(systemName: iconName)
                .foregroundColor(statusColor)
                .frame(width: 20)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(projectName)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Text(relativeTime)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(event.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                // Action button for permission/error events
                if event.attentionTier == .action || event.type == .taskError {
                    Button("Open Terminal", action: onOpenTerminal)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.type.rawValue) in \(projectName) at \(relativeTime). \(event.attentionTier == .action ? "Action available." : "")")
    }

    private var projectName: String {
        guard let detail = event.detail else { return "Unknown" }
        return URL(fileURLWithPath: detail).lastPathComponent
    }

    private var statusColor: Color {
        switch event.type {
        case .permissionNeeded: return .red
        case .taskError: return .orange
        case .taskCompleted: return .green
        case .taskStarted: return .blue
        }
    }

    private var iconName: String {
        switch event.type {
        case .permissionNeeded: return "exclamationmark.triangle.fill"
        case .taskError: return "xmark.circle.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .taskStarted: return "play.circle.fill"
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: event.timestamp, relativeTo: Date())
    }
}
```

- [ ] **Step 2: Implement MenubarPopover**

Create `Sources/Views/MenubarPopover.swift`:

```swift
import SwiftUI

struct MenubarPopover: View {
    let viewModel: PopoverViewModel
    let onOpenTerminal: (DevEvent) -> Void
    let onOpenSessionPanel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Needs Attention section
            if !viewModel.actionEvents.isEmpty {
                sectionHeader("Needs Attention", systemImage: "exclamationmark.triangle.fill", color: .red)

                ForEach(viewModel.actionEvents) { event in
                    EventCardView(event: event) {
                        onOpenTerminal(event)
                    }
                    Divider()
                }
            }

            // Recent Activity section
            sectionHeader("Recent Activity", systemImage: "clock", color: .secondary)

            if viewModel.recentEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.recentEvents) { event in
                            EventCardView(event: event) {
                                onOpenTerminal(event)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer
            HStack {
                Button("Open Session Panel") {
                    onOpenSessionPanel()
                }
                .buttonStyle(.link)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
                .foregroundColor(.secondary)
            }
            .padding(8)
        }
        .frame(width: 360)
    }

    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundColor(color)
            Text(title)
                .font(.headline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No events yet.")
                .font(.subheadline)
            Text("Start a Claude Code session to see activity here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/Views/EventCardView.swift Sources/Views/MenubarPopover.swift
git commit -m "feat: add MenubarPopover and EventCardView with attention sections and empty states"
```

---

## Task 14: Session Panel View

**Files:**
- Create: `Sources/Views/SessionPanelView.swift`
- Create: `Sources/Views/SessionRowView.swift`

- [ ] **Step 1: Implement SessionRowView**

Create `Sources/Views/SessionRowView.swift`:

```swift
import SwiftUI

struct SessionRowView: View {
    let session: DevSession

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator (color + shape, never color alone)
            statusIndicator
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(projectName)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(1)

                    Text(session.tool)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(3)
                }

                if let title = session.lastEventTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(elapsedTime)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let tokens = session.totalTokens {
                    Text(formatTokens(tokens))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .opacity(session.status == .stale ? 0.5 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.status.rawValue) session in \(projectName), \(session.tool)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .running:
            Circle().fill(.green)
                .accessibilityLabel("running")
        case .waiting:
            Image(systemName: "triangle.fill")
                .foregroundColor(.yellow)
                .font(.caption2)
                .accessibilityLabel("waiting")
        case .completed:
            Image(systemName: "checkmark")
                .foregroundColor(.green)
                .font(.caption2)
                .accessibilityLabel("completed")
        case .error:
            Image(systemName: "xmark")
                .foregroundColor(.red)
                .font(.caption2)
                .accessibilityLabel("error")
        case .stale:
            Rectangle()
                .fill(.gray)
                .frame(width: 10, height: 2)
                .accessibilityLabel("stale")
        }
    }

    private var projectName: String {
        URL(fileURLWithPath: session.project).lastPathComponent
    }

    private var elapsedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: session.startedAt, relativeTo: Date())
    }

    private func formatTokens(_ count: Int) -> String {
        if count < 1000 {
            return "\(count) tok"
        }
        return "\(count / 1000)K tok"
    }
}
```

- [ ] **Step 2: Implement SessionPanelView**

Create `Sources/Views/SessionPanelView.swift`:

```swift
import SwiftUI

struct SessionPanelView: View {
    let viewModel: SessionPanelViewModel
    @State private var alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Sessions")
                    .font(.headline)

                Spacer()

                let activeCount = viewModel.activeSessions.count
                Text("\(activeCount) active")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle(isOn: $alwaysOnTop) {
                    Image(systemName: "pin")
                }
                .toggleStyle(.button)
                .onChange(of: alwaysOnTop) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "alwaysOnTop")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.activeSessions.isEmpty && viewModel.completedSessions.isEmpty && viewModel.staleSessions.isEmpty {
                emptyState
            } else {
                List {
                    // Active sessions (running + waiting)
                    if !viewModel.activeSessions.isEmpty {
                        Section("Active") {
                            ForEach(viewModel.activeSessions) { session in
                                SessionRowView(session: session)
                            }
                        }
                    }

                    // Completed sessions
                    if !viewModel.completedSessions.isEmpty {
                        Section("Completed") {
                            ForEach(viewModel.completedSessions) { session in
                                SessionRowView(session: session)
                            }
                        }
                    }

                    // Stale sessions (collapsed by default)
                    if !viewModel.staleSessions.isEmpty {
                        DisclosureGroup("Inactive (\(viewModel.staleSessions.count))") {
                            ForEach(viewModel.staleSessions) { session in
                                SessionRowView(session: session)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No active sessions.")
                .font(.subheadline)
            Text("Start a Claude Code session in any project to see it here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/Views/SessionPanelView.swift Sources/Views/SessionRowView.swift
git commit -m "feat: add SessionPanelView and SessionRowView with status indicators and accessibility"
```

---

## Task 15: Settings View

**Files:**
- Create: `Sources/Views/SettingsView.swift`

- [ ] **Step 1: Implement SettingsView**

Create `Sources/Views/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @AppStorage("serverPort") private var serverPort: Int = 19876
    @AppStorage("retentionDays") private var retentionDays: Int = 30
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false

    @State private var showDebugView = false
    @State private var recentPayloads: [String] = []

    var body: some View {
        Form {
            Section("Server") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $serverPort, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Text("Restart required after changing port.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Notifications") {
                Toggle("Sound alerts on permission events", isOn: $soundEnabled)
            }

            Section("Data") {
                HStack {
                    Text("Keep events for")
                    Spacer()
                    TextField("Days", value: $retentionDays, format: .number)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("days")
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Session panel always on top", isOn: $alwaysOnTop)
            }

            Section("Debug") {
                Button("Show Recent Payloads") {
                    showDebugView = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
        .sheet(isPresented: $showDebugView) {
            DebugPayloadsView(payloads: recentPayloads)
        }
    }
}

struct DebugPayloadsView: View {
    let payloads: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            HStack {
                Text("Recent Raw Payloads")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            if payloads.isEmpty {
                Text("No payloads received yet.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(Array(payloads.enumerated()), id: \.offset) { _, payload in
                    Text(payload)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(width: 500, height: 400)
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/Views/SettingsView.swift
git commit -m "feat: add SettingsView with port, retention, sound, and debug payload viewer"
```

---

## Task 16: Onboarding Wizard

**Files:**
- Create: `Sources/Views/OnboardingView.swift`

- [ ] **Step 1: Implement OnboardingView**

Create `Sources/Views/OnboardingView.swift`:

```swift
import SwiftUI

struct OnboardingView: View {
    let authToken: String
    let onComplete: () -> Void

    @State private var step = 1
    @State private var testStatus: TestStatus = .idle
    @State private var copied = false

    enum TestStatus {
        case idle, testing, success, failed(String)
    }

    private var hooksJson: String {
        """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/.agent-dev-pilot/hooks/notify.sh"
                  }
                ]
              }
            ]
          }
        }
        """
    }

    var body: some View {
        VStack(spacing: 20) {
            // Progress
            HStack(spacing: 8) {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            switch step {
            case 1:
                step1CopyConfig
            case 2:
                step2Test
            default:
                step3Done
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    // MARK: - Step 1: Copy hooks config

    private var step1CopyConfig: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundColor(.accentColor)

            Text("Configure Claude Code Hooks")
                .font(.headline)

            Text("Add this to your `.claude/settings.json` file:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(hooksJson)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .textSelection(.enabled)

            HStack {
                Button(copied ? "Copied!" : "Copy JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hooksJson, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .buttonStyle(.borderedProminent)

                Button("Next") { step = 2 }
            }
        }
    }

    // MARK: - Step 2: Test connection

    private var step2Test: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundColor(.accentColor)

            Text("Test Connection")
                .font(.headline)

            Text("Click Test to verify Agent Dev Pilot is receiving events.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            switch testStatus {
            case .idle:
                Button("Test") { runTest() }
                    .buttonStyle(.borderedProminent)
            case .testing:
                ProgressView("Testing...")
            case .success:
                Label("Connection working!", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Button("Next") { step = 3 }
                    .buttonStyle(.borderedProminent)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                Button("Retry") { runTest() }
            }
        }
    }

    // MARK: - Step 3: Done

    private var step3Done: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("You're all set!")
                .font(.headline)

            Text("Events from Claude Code will appear here when Claude Code sends events.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { onComplete() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Test logic

    private func runTest() {
        testStatus = .testing

        Task {
            do {
                // Hit GET /health first
                let healthURL = URL(string: "http://127.0.0.1:19876/health")!
                let (_, healthResponse) = try await URLSession.shared.data(from: healthURL)
                guard (healthResponse as? HTTPURLResponse)?.statusCode == 200 else {
                    testStatus = .failed("Server not responding. Is Agent Dev Pilot running?")
                    return
                }

                // Send a test event
                var request = URLRequest(url: URL(string: "http://127.0.0.1:19876/event")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = """
                {
                    "session_id": "onboarding-test",
                    "cwd": "/tmp/test-project",
                    "hook_event_name": "Notification",
                    "message": "Test event from onboarding wizard",
                    "notification_type": "idle_prompt"
                }
                """.data(using: .utf8)

                let (_, eventResponse) = try await URLSession.shared.data(for: request)
                if (eventResponse as? HTTPURLResponse)?.statusCode == 200 {
                    testStatus = .success
                } else {
                    testStatus = .failed("Server returned an error. Check the debug view in Settings.")
                }
            } catch {
                testStatus = .failed("Could not connect to server: \(error.localizedDescription)")
            }
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/Views/OnboardingView.swift
git commit -m "feat: add OnboardingView with 3-step wizard, copy JSON, and test connection"
```

---

## Task 17: Wire Up the App Entry Point

**Files:**
- Modify: `Sources/App/AgentDevPilotApp.swift`

- [ ] **Step 1: Rewrite AgentDevPilotApp with full wiring**

Replace `Sources/App/AgentDevPilotApp.swift`:

```swift
import SwiftUI

@main
struct AgentDevPilotApp: App {
    @State private var appState: AppState?
    @State private var showSessionPanel = false
    @State private var initError: String?

    var body: some Scene {
        MenuBarExtra {
            if let appState {
                if appState.showOnboarding {
                    OnboardingView(authToken: appState.authToken) {
                        appState.showOnboarding = false
                    }
                } else {
                    MenubarPopover(
                        viewModel: appState.popoverVM,
                        onOpenTerminal: { event in openTerminal(at: event.detail) },
                        onOpenSessionPanel: { showSessionPanel = true }
                    )
                }
            } else if let error = initError {
                VStack {
                    Text("Failed to start")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                }
                .padding()
            } else {
                ProgressView("Starting...")
                    .padding()
            }
        } label: {
            if let appState {
                let count = appState.popoverVM.actionCount
                if count > 0 {
                    Label("\(count)", systemImage: "bell.badge.fill")
                } else {
                    Label("Agent Dev Pilot", systemImage: "bell")
                }
            } else {
                Label("Agent Dev Pilot", systemImage: "bell")
            }
        }
        .menuBarExtraStyle(.window)
        .task {
            do {
                let state = try AppState()
                self.appState = state
                await state.start()
            } catch {
                initError = error.localizedDescription
            }
        }

        // Session panel as separate window
        Window("Sessions", id: "session-panel") {
            if let appState {
                SessionPanelView(viewModel: appState.sessionPanelVM)
            }
        }
        .defaultSize(width: 400, height: 500)

        // Settings window
        Settings {
            SettingsView()
        }
    }

    /// Open Terminal.app at the given directory path.
    /// SECURITY: Uses Process + /usr/bin/open, NOT NSAppleScript.
    private func openTerminal(at path: String?) {
        guard let path else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/AgentDevPilotApp.swift
git commit -m "feat: wire up AgentDevPilotApp with MenuBarExtra, session panel, and settings"
```

---

## Task 18: notify.sh Helper Script

**Files:**
- Create: `Resources/notify.sh`

- [ ] **Step 1: Create the helper script**

Create `Resources/notify.sh`:

```bash
#!/bin/bash
# Agent Dev Pilot — Claude Code hook helper script
# Reads hook event JSON from stdin and forwards to the local HTTP server.
#
# SECURITY: Use --data-binary @- to pipe stdin directly to curl.
# Do NOT capture stdin into a variable (shell expansion risk).
# head -c 65536 enforces 64KB max payload at the source.
TOKEN=$(cat ~/.agent-dev-pilot/token 2>/dev/null)
cat | head -c 65536 | curl -s -X POST http://127.0.0.1:19876/event \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @- \
  --max-time 2 \
  >/dev/null 2>&1 &
# Fire-and-forget: if app is not running, event is silently lost.
# This is intentional — hooks must never block Claude Code's workflow.
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Resources/notify.sh
```

- [ ] **Step 3: Commit**

```bash
git add Resources/notify.sh
git commit -m "feat: add notify.sh hook helper script with auth token and 64KB size limit"
```

---

## Task 19: Run Full Test Suite and Fix Issues

- [ ] **Step 1: Run all tests**

```bash
cd /Users/harveyzhang96/Projects/agent-dev-pilot
swift test 2>&1
```

- [ ] **Step 2: Fix any compilation errors or test failures**

Address each failure individually. Common issues:
- GRDB API differences (check GRDB 7.x docs)
- Hummingbird 2 API differences (check Hummingbird 2.x docs)
- Swift 6 strict concurrency warnings (add `@Sendable`, `sending`, or actor isolation)

- [ ] **Step 3: Run tests again to confirm all pass**

```bash
swift test
```

Expected: All tests pass.

- [ ] **Step 4: Commit fixes**

```bash
git add -A
git commit -m "fix: resolve compilation and test issues for Swift 6 strict concurrency"
```

---

## Task 20: End-to-End Smoke Test

- [ ] **Step 1: Build and run the app**

```bash
swift build
.build/debug/AgentDevPilot &
sleep 2
```

- [ ] **Step 2: Verify health endpoint**

```bash
curl http://127.0.0.1:19876/health
```

Expected: `{"version":"1.0.0","status":"running"}`

- [ ] **Step 3: Send a test event**

```bash
TOKEN=$(cat ~/.agent-dev-pilot/token)
curl -X POST http://127.0.0.1:19876/event \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "session_id": "smoke-test",
    "cwd": "/Users/harveyzhang96/Projects/agent-dev-pilot",
    "hook_event_name": "Notification",
    "message": "Smoke test completed",
    "notification_type": "idle_prompt"
  }'
```

Expected: `{"status":"ok"}`

- [ ] **Step 4: Verify auth rejection**

```bash
curl -X POST http://127.0.0.1:19876/event \
  -H 'Content-Type: application/json' \
  -d '{"message":"no auth"}'
```

Expected: `Unauthorized` (HTTP 401)

- [ ] **Step 5: Stop the app and commit**

```bash
kill %1
git add -A
git commit -m "test: verify end-to-end smoke test passes"
```

---

## Summary

| Task | Component | Tests |
|------|-----------|-------|
| 1 | Swift Package scaffold | — |
| 2 | Data models (HookPayload, DevEvent, DevSession) | 6 |
| 3 | EventMapper (payload → event) | 12 |
| 4 | DatabaseManager (GRDB, migrations, WAL) | 5 |
| 5 | EventStore + SessionStore (CRUD) | 10 |
| 6 | SessionLifecycleService (state machine) | 6 |
| 7 | AuthTokenService (token gen/storage) | 4 |
| 8 | HTTP Server (Hummingbird, routes, auth) | 5 |
| 9 | NotificationBatcher (batching + throttle) | 5 |
| 10 | NotificationService (UNUserNotificationCenter) | — (E2E) |
| 11 | ViewModels (GRDB ValueObservation) | — (builds) |
| 12 | AppState coordinator | — (builds) |
| 13 | MenubarPopover + EventCardView | — (builds) |
| 14 | SessionPanelView + SessionRowView | — (builds) |
| 15 | SettingsView | — (builds) |
| 16 | OnboardingView (3-step wizard) | — (builds) |
| 17 | App entry point wiring | — (builds) |
| 18 | notify.sh helper script | — |
| 19 | Full test suite pass | all |
| 20 | E2E smoke test | manual |

**Total unit/integration tests: ~53**
