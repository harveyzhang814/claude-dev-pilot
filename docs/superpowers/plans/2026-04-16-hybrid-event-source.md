# Hybrid Event Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a JSONL file watcher as a second event source alongside HTTP hooks, feeding both into the existing `HookStreamCoordinator` pipeline for experiment-driven accuracy comparison.

**Architecture:** `SessionFileWatcher` polls `~/.claude/projects/` every 3s, reads new JSONL lines, normalizes them to `HookPayload` via `JournalEventNormalizer`, and calls `HookStreamCoordinator.process()` — the same entry point used by HTTP hooks. A new `eventSource` field on `HookPayload` and `HookLog` enables experiment queries to compare the two sources.

**Tech Stack:** Swift 6, macOS, GRDB, Foundation (no new dependencies)

---

## File Map

| Action | File | What changes |
|--------|------|-------------|
| Modify | `Sources/Core/Models/HookPayload.swift` | Add `EventSource` enum + `eventSource` field (non-JSON, defaults to `.hook`) |
| Modify | `Sources/Core/Models/HookLog.swift` | Add `eventSource: String?` field |
| Modify | `Sources/Core/Store/DatabaseManager.swift` | Add `v10_hook_log_event_source` migration |
| Create | `Sources/Core/Services/JournalEventNormalizer.swift` | Pure function: JSONL dict → `HookPayload?` |
| Create | `Sources/Core/Services/SessionFileWatcher.swift` | Polls `~/.claude/projects/`, incremental reads, calls normalizer |
| Modify | `Sources/App/AppState.swift` | Start watcher, log file-watcher events to HookLog, expose `activeEventSources` |
| Modify | `Sources/App/Views/SettingsView.swift` | Add read-only "Event Sources" status row |
| Create | `Tests/ServiceTests/JournalEventNormalizerTests.swift` | Unit tests for all mapping rules |
| Create | `Tests/ServiceTests/SessionFileWatcherTests.swift` | Tests for incremental read + new-file detection |

---

## Task 1: Add `EventSource` to `HookPayload`

**Files:**
- Modify: `Sources/Core/Models/HookPayload.swift`

**Why:** Both event sources produce `HookPayload`. A non-JSON `eventSource` field lets the DB log distinguish them without touching the wire format or any existing decoder.

- [ ] **Step 1: Open the file and read the current struct**

Path: `Sources/Core/Models/HookPayload.swift`

The struct has a custom `init(from decoder:)` and a memberwise `init(...)`. There is already a `source: String?` field (used for SessionStart reason: "startup"/"resume"/"clear"/"compact"). Do NOT touch that field. Add a new field named `eventSource`.

- [ ] **Step 2: Add `EventSource` enum and `eventSource` field**

Replace the top of `HookPayload.swift` — add the enum before the struct, and the field + parameter inside:

```swift
import Foundation

public enum EventSource: String, Sendable {
    case hook        // arrived via HTTP (notify.sh / cursor-notify.sh)
    case fileWatcher // derived from JSONL session file monitoring
}

/// Raw JSON payload from Claude Code hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
public struct HookPayload: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let message: String
    public let transcriptPath: String?
    public let title: String?
    public let notificationType: String?
    public let permissionMode: String?
    public let source: String?
    public let model: String?
    public let tty: String?
    public let terminalApp: String?
    public let tool: String?
    public let toolName: String?
    /// Not part of the JSON wire format. Set programmatically to track event origin.
    public let eventSource: EventSource
```

- [ ] **Step 3: Update `init(from decoder:)` to set `eventSource = .hook`**

At the end of `init(from decoder:)`, after all `try c.decodeIfPresent(...)` calls, add:

```swift
        eventSource = .hook
```

- [ ] **Step 4: Update the memberwise `init(...)` to accept `eventSource`**

Add the parameter with a default:

```swift
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
        model: String? = nil,
        tty: String? = nil,
        terminalApp: String? = nil,
        tool: String? = nil,
        toolName: String? = nil,
        eventSource: EventSource = .hook
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
        self.tty = tty
        self.terminalApp = terminalApp
        self.tool = tool
        self.toolName = toolName
        self.eventSource = eventSource
    }
```

- [ ] **Step 5: Build to verify no regressions**

```bash
cd /Users/harveyzhang96/Projects/agent-dev-pilot/.worktrees/exp-session-file-reader
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Models/HookPayload.swift
git commit -m "feat: add EventSource enum and eventSource field to HookPayload"
```

---

## Task 2: Add `eventSource` to `HookLog` + DB Migration

**Files:**
- Modify: `Sources/Core/Models/HookLog.swift`
- Modify: `Sources/Core/Store/DatabaseManager.swift`

**Why:** The `hook_logs` table is the ground truth for the experiment. Storing `eventSource` lets us run `SELECT eventSource, COUNT(*) FROM hook_logs GROUP BY eventSource` to compare coverage between the two sources.

- [ ] **Step 1: Add `eventSource` field to `HookLog`**

In `Sources/Core/Models/HookLog.swift`, add after `endpoint`:

```swift
    /// "hook" or "file_watcher". Nil for rows written before v10 migration.
    public let eventSource: String?
```

Add to `Columns` enum:
```swift
        case eventSource = "event_source"
```

Add to `CodingKeys` enum:
```swift
        case eventSource = "event_source"
```

Update `init(...)` — add parameter with default `nil`:
```swift
    public init(
        id: String = UUID().uuidString,
        receivedAt: Date,
        hookEventName: String,
        sessionId: String,
        notificationType: String?,
        rawPayload: String,
        endpoint: String? = nil,
        eventSource: String? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.notificationType = notificationType
        self.rawPayload = rawPayload
        self.endpoint = endpoint
        self.eventSource = eventSource
    }
```

- [ ] **Step 2: Add v10 migration to `DatabaseManager.swift`**

After the `v9_hook_log_endpoint` migration block, add:

```swift
        migrator.registerMigration("v10_hook_log_event_source") { db in
            try db.alter(table: "hook_logs") { t in
                t.add(column: "event_source", .text)
            }
        }
```

- [ ] **Step 3: Build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Run existing tests to ensure migration didn't break anything**

```bash
swift test --filter AgentPilotTests 2>&1 | tail -10
swift test --filter ServerTests 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Models/HookLog.swift Sources/Core/Store/DatabaseManager.swift
git commit -m "feat: add eventSource column to hook_logs (v10 migration)"
```

---

## Task 3: Implement `JournalEventNormalizer`

**Files:**
- Create: `Sources/Core/Services/JournalEventNormalizer.swift`
- Create: `Tests/ServiceTests/JournalEventNormalizerTests.swift`

**Why:** Pure function that maps one JSONL entry (already parsed as `[String: Any]`) to `HookPayload?`. Keeping it pure makes it trivially testable and decoupled from file I/O.

- [ ] **Step 1: Write the failing tests first**

Create `Tests/ServiceTests/JournalEventNormalizerTests.swift`:

```swift
import Testing
@testable import Core

@Suite("JournalEventNormalizerTests")
struct JournalEventNormalizerTests {

    // MARK: - UserPromptSubmit

    @Test("user entry with plain string content → UserPromptSubmit")
    func userPlainString() {
        let entry: [String: Any] = [
            "type": "user",
            "sessionId": "sess-1",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": "hello"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "UserPromptSubmit")
        #expect(payload?.sessionId == "sess-1")
        #expect(payload?.cwd == "/tmp/proj")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("user entry with list content (tool_result) → nil")
    func userToolResult() {
        let entry: [String: Any] = [
            "type": "user",
            "sessionId": "sess-1",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "x"]]]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - AskUserQuestion

    @Test("assistant entry with AskUserQuestion tool_use → Notification/permissionNeeded")
    func assistantAskUserQuestion() {
        let entry: [String: Any] = [
            "type": "assistant",
            "sessionId": "sess-2",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:01:00.000Z",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": "AskUserQuestion", "id": "t1", "input": ["question": "proceed?"]]
                ]
            ]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "Notification")
        #expect(payload?.notificationType == "permissionNeeded")
        #expect(payload?.sessionId == "sess-2")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("assistant entry with other tool_use → nil")
    func assistantOtherTool() {
        let entry: [String: Any] = [
            "type": "assistant",
            "sessionId": "sess-2",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:01:00.000Z",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": "Bash", "id": "t2", "input": ["command": "ls"]]
                ]
            ]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - Stop (new format v2.1.92+)

    @Test("system entry with stop_hook_summary subtype → Stop")
    func systemStopHookSummary() {
        let entry: [String: Any] = [
            "type": "system",
            "sessionId": "sess-3",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:02:00.000Z",
            "message": ["type": "stop_hook_summary", "hookCount": 0]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "Stop")
        #expect(payload?.sessionId == "sess-3")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("system entry with turn_duration subtype → nil")
    func systemTurnDuration() {
        let entry: [String: Any] = [
            "type": "system",
            "sessionId": "sess-3",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:02:00.000Z",
            "message": ["type": "turn_duration", "durationMs": 1234]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - Legacy hook events (progress entries, v≤2.1.81)

    @Test("progress entry with hookEvent=SessionStart → SessionStart")
    func progressSessionStart() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:00.000Z",
            "data": ["type": "hook_progress", "hookEvent": "SessionStart", "hookName": "SessionStart:startup"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "SessionStart")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("progress entry with hookEvent=Stop → Stop")
    func progressStop() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:01.000Z",
            "data": ["type": "hook_progress", "hookEvent": "Stop", "hookName": "Stop:stop"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "Stop")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("progress entry with hookEvent=UserPromptSubmit → UserPromptSubmit")
    func progressUserPromptSubmit() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:02.000Z",
            "data": ["type": "hook_progress", "hookEvent": "UserPromptSubmit"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "UserPromptSubmit")
    }

    @Test("progress entry with hookEvent=PostToolUse → nil")
    func progressPostToolUse() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:03.000Z",
            "data": ["type": "hook_progress", "hookEvent": "PostToolUse"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - Missing fields

    @Test("entry missing sessionId → nil")
    func missingSessionId() {
        let entry: [String: Any] = [
            "type": "user",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": "hi"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    @Test("unknown entry type → nil")
    func unknownType() {
        let entry: [String: Any] = [
            "type": "file-history-snapshot",
            "sessionId": "sess-1",
            "cwd": "/tmp/proj"
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter JournalEventNormalizerTests 2>&1 | tail -5
```

Expected: compile error (JournalEventNormalizer not defined yet)

- [ ] **Step 3: Implement `JournalEventNormalizer`**

Create `Sources/Core/Services/JournalEventNormalizer.swift`:

```swift
import Foundation

public enum JournalEventNormalizer {

    /// Maps a single parsed JSONL entry to a `HookPayload`, or returns nil if
    /// the entry carries no meaningful session-state signal.
    public static func normalize(_ entry: [String: Any]) -> HookPayload? {
        guard
            let type = entry["type"] as? String,
            let sessionId = entry["sessionId"] as? String, !sessionId.isEmpty,
            let cwd = entry["cwd"] as? String
        else { return nil }

        switch type {

        case "user":
            // Only plain-string user messages map to UserPromptSubmit.
            // Tool results (list content) are ignored.
            guard
                let message = entry["message"] as? [String: Any],
                let content = message["content"],
                content is String
            else { return nil }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: "UserPromptSubmit",
                eventSource: .fileWatcher
            )

        case "assistant":
            // Detect AskUserQuestion tool calls → approximate as permissionNeeded.
            guard
                let message = entry["message"] as? [String: Any],
                let contentList = message["content"] as? [[String: Any]],
                contentList.contains(where: {
                    $0["type"] as? String == "tool_use" &&
                    $0["name"] as? String == "AskUserQuestion"
                })
            else { return nil }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: "Notification",
                notificationType: "permissionNeeded",
                eventSource: .fileWatcher
            )

        case "system":
            // stop_hook_summary = session stopped (v2.1.92+, fires even with hookCount=0)
            guard
                let message = entry["message"] as? [String: Any],
                message["type"] as? String == "stop_hook_summary"
            else { return nil }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: "Stop",
                eventSource: .fileWatcher
            )

        case "progress":
            // Legacy hook recording (v≤2.1.81). Only map events relevant to state machine.
            guard
                let data = entry["data"] as? [String: Any],
                let hookEvent = data["hookEvent"] as? String
            else { return nil }
            let mapped: String
            switch hookEvent {
            case "SessionStart":       mapped = "SessionStart"
            case "Stop":               mapped = "Stop"
            case "UserPromptSubmit":   mapped = "UserPromptSubmit"
            default:                   return nil   // PostToolUse, PreToolUse, etc. → ignore
            }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: mapped,
                eventSource: .fileWatcher
            )

        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter JournalEventNormalizerTests 2>&1 | tail -15
```

Expected: all 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/JournalEventNormalizer.swift \
        Tests/ServiceTests/JournalEventNormalizerTests.swift
git commit -m "feat: add JournalEventNormalizer with tests"
```

---

## Task 4: Implement `SessionFileWatcher`

**Files:**
- Create: `Sources/Core/Services/SessionFileWatcher.swift`
- Create: `Tests/ServiceTests/SessionFileWatcherTests.swift`

**Why:** Polls `~/.claude/projects/` every 3 seconds, finds files with `mtime` within the last 30 minutes, reads new lines from each, normalizes them, and forwards resulting payloads via a callback. Runs on a background queue.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ServiceTests/SessionFileWatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite("SessionFileWatcherTests")
struct SessionFileWatcherTests {

    @Test("incrementalRead returns only new lines after offset")
    func incrementalRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("test.jsonl")
        let line1 = "{\"type\":\"user\",\"sessionId\":\"s1\",\"cwd\":\"/p\"}\n"
        let line2 = "{\"type\":\"system\",\"sessionId\":\"s1\",\"cwd\":\"/p\"}\n"
        try line1.write(to: file, atomically: true, encoding: .utf8)

        var offset: Int = 0
        let first = SessionFileWatcher.readNewLines(from: file.path, offset: &offset)
        #expect(first.count == 1)
        #expect(first[0].contains("\"user\""))
        #expect(offset == line1.utf8.count)

        // Append second line
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(line2.data(using: .utf8)!)
        handle.closeFile()

        let second = SessionFileWatcher.readNewLines(from: file.path, offset: &offset)
        #expect(second.count == 1)
        #expect(second[0].contains("\"system\""))
        #expect(offset == line1.utf8.count + line2.utf8.count)
    }

    @Test("scanActiveFiles returns only files with mtime within window")
    func scanActiveFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recent = dir.appendingPathComponent("recent.jsonl")
        let old = dir.appendingPathComponent("old.jsonl")
        try "{}".write(to: recent, atomically: true, encoding: .utf8)
        try "{}".write(to: old, atomically: true, encoding: .utf8)

        // Back-date the old file to 2 hours ago
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: twoHoursAgo],
            ofItemAtPath: old.path
        )

        let found = SessionFileWatcher.scanActiveFiles(
            in: dir.path,
            activeWindowSeconds: 1800  // 30 min
        )
        #expect(found.contains(recent.path))
        #expect(!found.contains(old.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SessionFileWatcherTests 2>&1 | tail -5
```

Expected: compile error (SessionFileWatcher not defined)

- [ ] **Step 3: Implement `SessionFileWatcher`**

Create `Sources/Core/Services/SessionFileWatcher.swift`:

```swift
import Foundation

public final class SessionFileWatcher: @unchecked Sendable {

    public typealias PayloadHandler = @Sendable (HookPayload) -> Void

    private let projectsRoot: String
    private let pollInterval: TimeInterval
    private let activeWindowSeconds: TimeInterval
    private let onPayload: PayloadHandler
    private var offsets: [String: Int] = [:]   // filePath → byte offset
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.agentpilot.filewatcher", qos: .background)

    public init(
        projectsRoot: String = (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path),
        pollInterval: TimeInterval = 3.0,
        activeWindowSeconds: TimeInterval = 1800,  // 30 min
        onPayload: @escaping PayloadHandler
    ) {
        self.projectsRoot = projectsRoot
        self.pollInterval = pollInterval
        self.activeWindowSeconds = activeWindowSeconds
        self.onPayload = onPayload
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let files = Self.scanActiveFiles(in: projectsRoot, activeWindowSeconds: activeWindowSeconds)
        for path in files {
            var offset = offsets[path] ?? 0
            let lines = Self.readNewLines(from: path, offset: &offset)
            offsets[path] = offset
            for line in lines {
                guard
                    let data = line.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let payload = JournalEventNormalizer.normalize(obj)
                else { continue }
                onPayload(payload)
            }
        }
    }

    // MARK: - Testable helpers (internal static so tests can call directly)

    /// Returns paths of .jsonl files under `root` whose mtime is within `activeWindowSeconds`.
    public static func scanActiveFiles(in root: String, activeWindowSeconds: TimeInterval) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)
        var result: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { continue }
            if mtime >= cutoff {
                result.append(url.path)
            }
        }
        return result
    }

    /// Reads new UTF-8 lines from `path` starting at `offset`, updates `offset` in place.
    public static func readNewLines(from path: String, offset: inout Int) -> [String] {
        guard
            let handle = FileHandle(forReadingAtPath: path)
        else { return [] }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: UInt64(offset))
        let data = handle.readDataToEndOfFile()
        offset += data.count
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter SessionFileWatcherTests 2>&1 | tail -10
```

Expected: both tests pass.

- [ ] **Step 5: Build full project**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Services/SessionFileWatcher.swift \
        Tests/ServiceTests/SessionFileWatcherTests.swift
git commit -m "feat: add SessionFileWatcher with incremental JSONL read"
```

---

## Task 5: Wire `SessionFileWatcher` into `AppState`

**Files:**
- Modify: `Sources/App/AppState.swift`

**Why:** `AppState` owns the coordinator and controls the app lifecycle. It starts the file watcher when `fileWatcherEnabled` is true, logs each file-watcher event to `HookLog`, and exposes `activeEventSources` for the Settings UI.

- [ ] **Step 1: Add properties to `AppState`**

After `private var coordinator: HookStreamCoordinator?`, add:

```swift
    // File watcher (experimental — opt-in via UserDefaults "fileWatcherEnabled")
    private var fileWatcher: SessionFileWatcher?

    /// Which event sources have produced at least one payload this session.
    /// Read by SettingsView for debug display.
    private(set) var activeEventSources: Set<String> = []
```

- [ ] **Step 2: Start the file watcher in `start()`**

At the end of `start()`, just before `await startServer()`, add:

```swift
        // Start file watcher if enabled (experimental)
        let fileWatcherEnabled = UserDefaults.standard.bool(forKey: "fileWatcherEnabled")
        if fileWatcherEnabled {
            startFileWatcher()
        }
```

- [ ] **Step 3: Implement `startFileWatcher()`**

Add this private method to `AppState`, below `startServer()`:

```swift
    private func startFileWatcher() {
        guard let dbPool = db else { return }
        let watcher = SessionFileWatcher { [weak self] payload in
            guard let self else { return }
            // Log to HookLog for experiment analysis
            let log = HookLog(
                receivedAt: Date(),
                hookEventName: payload.hookEventName,
                sessionId: payload.sessionId,
                notificationType: payload.notificationType,
                rawPayload: "[file-watcher]",
                endpoint: "file-watcher",
                eventSource: "file_watcher"
            )
            try? dbPool.write { db in try log.insert(db) }
            // Feed into coordinator (same pipeline as HTTP hooks)
            Task {
                await self.coordinator?.process(payload)
                await MainActor.run {
                    self.activeEventSources.insert("fileWatcher")
                }
            }
        }
        fileWatcher = watcher
        watcher.start()
        activeEventSources.insert("fileWatcher")
    }
```

- [ ] **Step 4: Mark HTTP hook source active**

In `startServer()`, inside the `onEvent` callback closure (after `batcher?.flush()`), add a line to mark hooks as active. Find:

```swift
                    onEvent: { event in
                        guard event.attentionTier != .background else { return }
                        batcher?.submit(event)
                        batcher?.flush()
                    }
```

Change to:

```swift
                    onEvent: { [weak self] event in
                        guard event.attentionTier != .background else { return }
                        batcher?.submit(event)
                        batcher?.flush()
                        Task { @MainActor [weak self] in
                            self?.activeEventSources.insert("hook")
                        }
                    }
```

- [ ] **Step 5: Build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/App/AppState.swift
git commit -m "feat: wire SessionFileWatcher into AppState"
```

---

## Task 6: Settings UI — Event Source Status Row

**Files:**
- Modify: `Sources/App/Views/SettingsView.swift`

**Why:** Debugging visibility — shows which sources are currently active. Read-only, no user action required.

- [ ] **Step 1: Read current SettingsView**

File: `Sources/App/Views/SettingsView.swift`

The view has a `Form` with multiple `Section` blocks. Add a new "Debug" section at the bottom.

- [ ] **Step 2: Add the debug section**

Find the last `Section` closing brace before the closing `}` of `Form { ... }` and add after it:

```swift
            // Debug section — event source visibility
            Section("Debug") {
                HStack {
                    Text("Event Sources")
                    Spacer()
                    HStack(spacing: 6) {
                        Label("hooks", systemImage: "network")
                            .foregroundStyle(appState.activeEventSources.contains("hook") ? .green : .secondary)
                            .font(.caption)
                        Label("file watcher", systemImage: "doc.text")
                            .foregroundStyle(appState.activeEventSources.contains("fileWatcher") ? .green : .secondary)
                            .font(.caption)
                    }
                }
            }
```

- [ ] **Step 3: Build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Run all tests**

```bash
swift test 2>&1 | tail -15
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Views/SettingsView.swift
git commit -m "feat: add event source debug status row to Settings"
```

---

## Task 7: Experiment Enablement + README

**Files:**
- Modify: `docs/superpowers/experiments/session-file-reader-findings.md` (append experiment procedure)

**Why:** The experiment requires knowing how to toggle modes and query results. Document the exact steps so Claude can run the experiment autonomously.

- [ ] **Step 1: Append experiment procedure to findings doc**

Open `docs/superpowers/experiments/session-file-reader-findings.md` and append at the end:

```markdown

---

## Hybrid Experiment Procedure

### Enable file watcher

```bash
defaults write com.agentpilot.AgentPilot fileWatcherEnabled -bool true
```

### Disable file watcher (hooks-only baseline)

```bash
defaults write com.agentpilot.AgentPilot fileWatcherEnabled -bool false
```

### Query event source coverage (run after each config)

```bash
sqlite3 ~/Library/Application\ Support/AgentPilot/db.sqlite \
  "SELECT event_source, hook_event_name, COUNT(*) as n
   FROM hook_logs
   WHERE received_at > datetime('now', '-1 hour')
   GROUP BY event_source, hook_event_name
   ORDER BY event_source, n DESC;"
```

### Check for double-dismiss (UserPromptSubmit duplicates within 2s)

```bash
sqlite3 ~/Library/Application\ Support/AgentPilot/db.sqlite \
  "SELECT l1.session_id, l1.received_at, l2.received_at, l1.event_source, l2.event_source
   FROM hook_logs l1
   JOIN hook_logs l2
     ON l1.session_id = l2.session_id
     AND l1.hook_event_name = 'UserPromptSubmit'
     AND l2.hook_event_name = 'UserPromptSubmit'
     AND l1.id < l2.id
     AND (julianday(l2.received_at) - julianday(l1.received_at)) * 86400 < 2
   WHERE l1.received_at > datetime('now', '-1 hour');"
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/experiments/session-file-reader-findings.md
git commit -m "docs: add hybrid experiment procedure to findings"
```

---

## Self-Review

**Spec coverage:**
- `EventSource` enum + `eventSource` on `HookPayload` → Task 1 ✅
- `eventSource` on `HookLog` + v10 migration → Task 2 ✅
- `JournalEventNormalizer` with all mapping rules → Task 3 ✅
- `SessionFileWatcher` with polling + incremental read → Task 4 ✅
- `AppState` wiring + HookLog write + `activeEventSources` → Task 5 ✅
- Settings debug UI → Task 6 ✅
- Experiment toggle + query procedure → Task 7 ✅
- `fileWatcherEnabled` UserDefaults key, default false → Task 5 Step 2 ✅

**No placeholders:** All steps have complete code. ✅

**Type consistency:**
- `EventSource` defined in Task 1, used in Tasks 3, 4, 5 ✅
- `SessionFileWatcher.scanActiveFiles` and `readNewLines` defined in Task 4, tested in Task 4 ✅
- `HookLog.eventSource: String?` defined in Task 2, written in Task 5 ✅
- `activeEventSources: Set<String>` defined in Task 5, read in Task 6 ✅
