# Terminal Focus — Jump to Session Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking a session in the popover or Session Panel focuses the existing Ghostty/Terminal.app window running that Claude Code session; falls back to NSAlert → "Open New Window" if not found.

**Architecture:** `notify.sh` captures `$TTY` and `$TERM_PROGRAM` and injects them into the JSON payload via `jq`. These are stored on `DevSession` (v4 migration). A new `TerminalFocusService` in `Sources/App/` dispatches to `GhosttyFocuser` (cwd-match via AppleScript) or `TerminalAppFocuser` (tty-match via AppleScript). Session rows in both the popover and Session Panel become tap targets; `EventCardView` loses its "Open Terminal" button.

**Tech Stack:** Swift 5.9+, GRDB, SwiftUI `@Observable`, NSAppleScript, Swift Testing framework (`@Suite`/`@Test`/`#expect`)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Resources/notify.sh` | Modify | Inject `tty` + `terminal_app` into payload via `jq` |
| `Sources/Core/Models/HookPayload.swift` | Modify | Add `tty`, `terminalApp` optional fields |
| `Sources/Core/Models/DevSession.swift` | Modify | Add `tty`, `terminalApp` optional columns |
| `Sources/Core/Store/DatabaseManager.swift` | Modify | Add `v4_session_terminal` migration |
| `Sources/Core/Services/SessionLifecycleService.swift` | Modify | Write `tty`/`terminalApp` at `SessionStart` |
| `Sources/App/Services/TerminalFocus/TerminalFocuser.swift` | Create | Protocol + error type |
| `Sources/App/Services/TerminalFocus/GhosttyFocuser.swift` | Create | Ghostty AppleScript impl (cwd match) |
| `Sources/App/Services/TerminalFocus/TerminalAppFocuser.swift` | Create | Terminal.app AppleScript impl (tty match) |
| `Sources/App/Services/TerminalFocus/TerminalFocusService.swift` | Create | Dispatcher → `FocusResult` |
| `Sources/App/Views/EventCardView.swift` | Modify | Remove "Open Terminal" button |
| `Sources/App/Views/SessionGroupView.swift` | Modify | Header row → `Button`; `onOpenTerminal` → `onFocusSession`; add `↗` hint |
| `Sources/App/Views/MenubarPopover.swift` | Modify | Thread `onFocusSession` to `SessionGroupView` |
| `Sources/App/Views/SessionRowView.swift` | Modify | Active rows: capsule status + clickable + `↗`; inactive rows: unchanged |
| `Sources/App/Views/SessionPanelView.swift` | Modify | Thread `onFocusSession` to `SessionRowView` |
| `Sources/App/AgentDevPilotApp.swift` | Modify | Implement `focusSession()` with `TerminalFocusService` + NSAlert fallback |
| `Tests/ModelTests/HookPayloadTests.swift` | Modify | Add `tty`/`terminalApp` decode tests |
| `Tests/ServiceTests/SessionLifecycleTests.swift` | Modify | Add tty/terminalApp storage test |

---

## Task 1: HookPayload — add tty and terminalApp fields

**Files:**
- Modify: `Sources/Core/Models/HookPayload.swift`
- Modify: `Tests/ModelTests/HookPayloadTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ModelTests/HookPayloadTests.swift` inside `struct HookPayloadTests`:

```swift
@Test("SessionStart payload with tty and terminal_app")
func sessionStartWithTtyAndTerminalApp() throws {
    let json = """
    {
        "session_id": "s1",
        "cwd": "/Users/dev/myapp",
        "hook_event_name": "SessionStart",
        "tty": "/dev/ttys003",
        "terminal_app": "ghostty"
    }
    """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    #expect(payload.tty == "/dev/ttys003")
    #expect(payload.terminalApp == "ghostty")
}

@Test("Payload without tty or terminal_app decodes as nil")
func payloadWithoutTtyIsNil() throws {
    let json = """
    {
        "session_id": "s2",
        "cwd": "/Users/dev/myapp",
        "hook_event_name": "Notification",
        "message": "done"
    }
    """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    #expect(payload.tty == nil)
    #expect(payload.terminalApp == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter HookPayloadTests
```

Expected: FAIL — `HookPayload` has no `tty` or `terminalApp` properties.

- [ ] **Step 3: Add fields to HookPayload**

In `Sources/Core/Models/HookPayload.swift`, add two optional properties and their coding keys. The struct already has `source` and `model` fields — add after them:

```swift
// In the struct body, after `public let model: String?`:
public let tty: String?           // e.g. "/dev/ttys003", injected by notify.sh
public let terminalApp: String?   // e.g. "ghostty", "Apple_Terminal"
```

In `CodingKeys`:
```swift
case tty
case terminalApp = "terminal_app"
```

In `init(from decoder:)`, after the `model` decode:
```swift
tty = try? c.decodeIfPresent(String.self, forKey: .tty)
terminalApp = try? c.decodeIfPresent(String.self, forKey: .terminalApp)
```

In the memberwise `init(...)`, add two new parameters after `model`:
```swift
tty: String? = nil,
terminalApp: String? = nil
```

And assign them:
```swift
self.tty = tty
self.terminalApp = terminalApp
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter HookPayloadTests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Models/HookPayload.swift Tests/ModelTests/HookPayloadTests.swift
git commit -m "feat: add tty and terminalApp fields to HookPayload"
```

---

## Task 2: DevSession + v4 migration

**Files:**
- Modify: `Sources/Core/Models/DevSession.swift`
- Modify: `Sources/Core/Store/DatabaseManager.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/StoreTests/DatabaseManagerTests.swift`:

```swift
@Test("v4 migration adds tty and terminal_app columns")
func v4MigrationAddsTtyColumns() throws {
    let db = try DatabaseQueue()
    try DatabaseManager.migrate(db)
    let columns = try db.read { db in
        try db.columns(in: "sessions").map(\.name)
    }
    #expect(columns.contains("tty"))
    #expect(columns.contains("terminal_app"))
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter DatabaseManagerTests/v4MigrationAddsTtyColumns
```

Expected: FAIL — columns don't exist.

- [ ] **Step 3: Add tty and terminalApp to DevSession**

In `Sources/Core/Models/DevSession.swift`, add after `cwd`:

```swift
public var tty: String?           // TTY device path, e.g. "/dev/ttys003"
public var terminalApp: String?   // "ghostty" or "Apple_Terminal"
```

In `Columns`:
```swift
case tty
case terminalApp = "terminal_app"
```

In `CodingKeys`:
```swift
case tty
case terminalApp = "terminal_app"
```

In `init(...)`, add after `cwd`:
```swift
tty: String? = nil,
terminalApp: String? = nil,
```

And assign:
```swift
self.tty = tty
self.terminalApp = terminalApp
```

- [ ] **Step 4: Add v4 migration to DatabaseManager**

In `Sources/Core/Store/DatabaseManager.swift`, after the `v3_session_cwd` block:

```swift
migrator.registerMigration("v4_session_terminal") { db in
    try db.alter(table: "sessions") { t in
        t.add(column: "tty", .text)
        t.add(column: "terminal_app", .text)
    }
}
```

- [ ] **Step 5: Run tests**

```bash
swift test --filter DatabaseManagerTests
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Models/DevSession.swift Sources/Core/Store/DatabaseManager.swift Tests/StoreTests/DatabaseManagerTests.swift
git commit -m "feat: add tty and terminalApp columns to DevSession (v4 migration)"
```

---

## Task 3: SessionLifecycleService — store tty/terminalApp at SessionStart

**Files:**
- Modify: `Sources/Core/Services/SessionLifecycleService.swift`
- Modify: `Tests/ServiceTests/SessionLifecycleTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ServiceTests/SessionLifecycleTests.swift` inside `struct SessionLifecycleTests`:

```swift
@Test("SessionStart stores tty and terminalApp on new session")
func sessionStartStoresTtyAndTerminalApp() throws {
    let db = try makeDB()
    let payload = HookPayload(
        sessionId: "tty-test",
        cwd: "/Users/dev/myapp",
        hookEventName: "SessionStart",
        tty: "/dev/ttys003",
        terminalApp: "ghostty"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let session = try db.read { db in try DevSession.fetchOne(db, key: "tty-test") }
    #expect(session?.tty == "/dev/ttys003")
    #expect(session?.terminalApp == "ghostty")
}

@Test("SessionStart updates tty and terminalApp on reopen")
func sessionStartUpdatesTtyOnReopen() throws {
    let db = try makeDB()
    // Pre-insert a completed session without tty
    try db.write { db in
        var s = DevSession(
            id: "reopen-tty", project: "myapp", cwd: "/Users/dev/myapp",
            tool: "claude-code", status: .completed,
            startedAt: Date(), endedAt: Date(), totalTokens: nil, lastEventTitle: nil
        )
        try s.insert(db)
    }
    let payload = HookPayload(
        sessionId: "reopen-tty",
        cwd: "/Users/dev/myapp",
        hookEventName: "SessionStart",
        tty: "/dev/ttys007",
        terminalApp: "Apple_Terminal"
    )
    try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

    let session = try db.read { db in try DevSession.fetchOne(db, key: "reopen-tty") }
    #expect(session?.status == .running)
    #expect(session?.tty == "/dev/ttys007")
    #expect(session?.terminalApp == "Apple_Terminal")
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter SessionLifecycleTests/sessionStartStoresTtyAndTerminalApp
```

Expected: FAIL — tty/terminalApp not stored.

- [ ] **Step 3: Update SessionLifecycleService**

In `Sources/Core/Services/SessionLifecycleService.swift`, update the `SessionStart` branch:

For **new sessions** (the `else` branch inside `case "SessionStart"`), change the `DevSession` init to include `tty` and `terminalApp`:
```swift
var session = DevSession(
    id: payload.sessionId,
    project: project,
    cwd: payload.cwd,
    tty: payload.tty,
    terminalApp: payload.terminalApp,
    tool: "claude-code",
    status: .running,
    startedAt: Date(),
    endedAt: nil,
    totalTokens: nil,
    lastEventTitle: nil
)
try session.insert(db)
```

For **reopen** (the `if` branch for existing closed session), update the SQL:
```swift
try db.execute(
    sql: "UPDATE sessions SET status = 'running', ended_at = NULL, cwd = ?, tty = ?, terminal_app = ? WHERE id = ?",
    arguments: [payload.cwd, payload.tty, payload.terminalApp, payload.sessionId]
)
```

- [ ] **Step 4: Run all session lifecycle tests**

```bash
swift test --filter SessionLifecycleTests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/SessionLifecycleService.swift Tests/ServiceTests/SessionLifecycleTests.swift
git commit -m "feat: store tty and terminalApp on session at SessionStart"
```

---

## Task 4: TerminalFocusService — protocol, implementations, dispatcher

**Files:**
- Create: `Sources/App/Services/TerminalFocus/TerminalFocuser.swift`
- Create: `Sources/App/Services/TerminalFocus/GhosttyFocuser.swift`
- Create: `Sources/App/Services/TerminalFocus/TerminalAppFocuser.swift`
- Create: `Sources/App/Services/TerminalFocus/TerminalFocusService.swift`

Note: These files are in the `App` target (the SwiftUI executable), which has no dedicated test target. Verify correctness via `swift build` and `make run` smoke testing at the end.

- [ ] **Step 1: Create TerminalFocuser protocol**

Create `Sources/App/Services/TerminalFocus/TerminalFocuser.swift`:

```swift
import Foundation

/// Abstraction for focusing a specific terminal window.
/// Implementations are per terminal app (Ghostty, Terminal.app, etc.).
protocol TerminalFocuser {
    /// Attempt to focus the terminal window matching the given cwd and tty.
    /// - Returns: `true` if a matching window was found and focused, `false` if not found.
    /// - Throws: `TerminalFocusError` on AppleScript execution failure.
    func focus(cwd: String, tty: String?) throws -> Bool
}

enum TerminalFocusError: Error {
    case appleScriptFailed(String)
}
```

- [ ] **Step 2: Create GhosttyFocuser**

Create `Sources/App/Services/TerminalFocus/GhosttyFocuser.swift`:

```swift
import Foundation

/// Focuses a Ghostty window by matching its tab's `working directory` to the session's cwd.
/// Uses Ghostty's AppleScript API (proven by the `haunt` tool: github.com/janpaepke/haunt).
struct GhosttyFocuser: TerminalFocuser {
    func focus(cwd: String, tty: String?) throws -> Bool {
        let escapedCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            set matchCount to 0
            repeat with w in every window
                repeat with t in every tab of w
                    set wd to working directory of (focused terminal of t)
                    if wd is equal to "\(escapedCwd)" then
                        select tab t
                        activate window w
                        set matchCount to 1
                        exit repeat
                    end if
                end repeat
                if matchCount > 0 then exit repeat
            end repeat
            return matchCount
        end tell
        """
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw TerminalFocusError.appleScriptFailed("Failed to create NSAppleScript")
        }
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            throw TerminalFocusError.appleScriptFailed(errorDict.description)
        }
        return result.int32Value > 0
    }
}
```

- [ ] **Step 3: Create TerminalAppFocuser**

Create `Sources/App/Services/TerminalFocus/TerminalAppFocuser.swift`:

```swift
import Foundation

/// Focuses a Terminal.app tab by matching its `tty` property.
/// Terminal.app's AppleScript dictionary exposes `tty` on each tab natively.
struct TerminalAppFocuser: TerminalFocuser {
    func focus(cwd: String, tty: String?) throws -> Bool {
        guard let tty else { return false }  // tty required for Terminal.app matching
        let escapedTty = tty
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            set matchCount to 0
            repeat with w in every window
                repeat with t in every tab of w
                    if tty of t is equal to "\(escapedTty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        set matchCount to 1
                        exit repeat
                    end if
                end repeat
                if matchCount > 0 then exit repeat
            end repeat
            return matchCount
        end tell
        """
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw TerminalFocusError.appleScriptFailed("Failed to create NSAppleScript")
        }
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            throw TerminalFocusError.appleScriptFailed(errorDict.description)
        }
        return result.int32Value > 0
    }
}
```

- [ ] **Step 4: Create TerminalFocusService**

Create `Sources/App/Services/TerminalFocus/TerminalFocusService.swift`:

```swift
import Core

public enum FocusResult: Equatable {
    case success
    case notFound
}

/// Routes focus requests to the correct TerminalFocuser based on the session's terminalApp.
/// Catches all errors internally and maps them to FocusResult.notFound.
enum TerminalFocusService {
    static func focus(session: DevSession) -> FocusResult {
        guard let cwd = session.cwd, !cwd.isEmpty else { return .notFound }

        let focuser: TerminalFocuser = switch session.terminalApp {
            case "Apple_Terminal": TerminalAppFocuser()
            default: GhosttyFocuser()  // "ghostty" + nil + unknown → Ghostty
        }

        do {
            let found = try focuser.focus(cwd: cwd, tty: session.tty)
            return found ? .success : .notFound
        } catch {
            return .notFound
        }
    }
}
```

- [ ] **Step 5: Verify it builds**

```bash
swift build -c debug 2>&1 | head -30
```

Expected: build succeeds with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Services/TerminalFocus/
git commit -m "feat: add TerminalFocusService with GhosttyFocuser and TerminalAppFocuser"
```

---

## Task 5: EventCardView — remove "Open Terminal" button

**Files:**
- Modify: `Sources/App/Views/EventCardView.swift`

- [ ] **Step 1: Remove the button block**

In `Sources/App/Views/EventCardView.swift`, remove the entire button block (lines 99–107 in the current file):

```swift
// DELETE these lines:
if event.attentionTier == .action || event.type == .taskError {
    Button("Open Terminal") {
        onOpenTerminal?(event.detail ?? "")
    }
    .buttonStyle(.bordered)
    .controlSize(.mini)
    .accessibilityLabel("Open terminal for \(event.title)")
    .padding(.top, 2)
}
```

Also remove the `onOpenTerminal` property (currently `var onOpenTerminal: ((String) -> Void)?`) since nothing uses it after this change.

The `cardContent` VStack body should now read:
```swift
VStack(alignment: .leading, spacing: 2) {
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
    Text(event.title)
        .font(.callout)
        .lineLimit(2)
}
```

- [ ] **Step 2: Fix the compiler error in SessionGroupView**

`SessionGroupView.swift` currently passes `onOpenTerminal:` to `EventCardView`. Since that parameter no longer exists, remove it:

In `Sources/App/Views/SessionGroupView.swift`, change:
```swift
EventCardView(
    event: event,
    sessionLabel: nil,
    onOpenTerminal: onOpenTerminal
) {
```
to:
```swift
EventCardView(
    event: event,
    sessionLabel: nil
) {
```

Also remove the `var onOpenTerminal: ((String) -> Void)?` property from `SessionGroupView` — it's no longer needed.

- [ ] **Step 3: Verify build**

```bash
swift build -c debug 2>&1 | head -30
```

Expected: build succeeds (there may be a warning in `MenubarPopover.swift` about unused `onOpenTerminal` — that's OK, we'll fix it in Task 6).

- [ ] **Step 4: Commit**

```bash
git add Sources/App/Views/EventCardView.swift Sources/App/Views/SessionGroupView.swift
git commit -m "feat: remove Open Terminal button from EventCardView; clean up onOpenTerminal from SessionGroupView"
```

---

## Task 6: SessionGroupView — header row becomes clickable + onFocusSession

**Files:**
- Modify: `Sources/App/Views/SessionGroupView.swift`
- Modify: `Sources/App/Views/MenubarPopover.swift`

- [ ] **Step 1: Update SessionGroupView**

Replace the entire `SessionGroupView` struct in `Sources/App/Views/SessionGroupView.swift`:

```swift
struct SessionGroupView: View {
    let session: DevSession
    let events: [DevEvent]
    var onFocusSession: ((DevSession) -> Void)?
    var onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header row — entire row is a tap target for terminal focus
            Button {
                onFocusSession?(session)
            } label: {
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
                        .layoutPriority(1)

                    Text(sessionStatusTag(session))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(sessionStatusColor(session))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sessionStatusColor(session).opacity(0.12))
                        .clipShape(Capsule())

                    Spacer()

                    Text("↗")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 5)
            .accessibilityLabel("\(session.project), \(sessionStatusTag(session)), tap to focus terminal")

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
                        sessionLabel: nil
                    ) {
                        onDismiss(event.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
```

- [ ] **Step 2: Update MenubarPopover**

In `Sources/App/Views/MenubarPopover.swift`, replace `onOpenTerminal` with `onFocusSession` throughout:

Change the struct property:
```swift
// Remove:
var onOpenTerminal: ((String) -> Void)?
// Add:
var onFocusSession: ((DevSession) -> Void)?
```

Change the `SessionGroupView` call:
```swift
// Remove:
SessionGroupView(
    session: session,
    events: viewModel.eventsBySession[session.id] ?? [],
    onOpenTerminal: onOpenTerminal
) { eventId in
    viewModel.dismiss(eventId: eventId)
}
// Add:
SessionGroupView(
    session: session,
    events: viewModel.eventsBySession[session.id] ?? [],
    onFocusSession: onFocusSession
) { eventId in
    viewModel.dismiss(eventId: eventId)
}
```

- [ ] **Step 3: Verify build**

```bash
swift build -c debug 2>&1 | head -30
```

Expected: one compiler error in `AgentDevPilotApp.swift` about the renamed parameter — we'll fix that in Task 8.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/Views/SessionGroupView.swift Sources/App/Views/MenubarPopover.swift
git commit -m "feat: SessionGroupView header row is now clickable, add onFocusSession callback"
```

---

## Task 7: SessionRowView — active sessions get capsule + clickable row

**Files:**
- Modify: `Sources/App/Views/SessionRowView.swift`
- Modify: `Sources/App/Views/SessionPanelView.swift`

The `sessionStatusTag()` and `sessionStatusColor()` free functions defined in `SessionGroupView.swift` are `internal` to the `AgentDevPilot` module and can be used in `SessionRowView.swift` directly.

- [ ] **Step 1: Update SessionRowView**

Replace the entire `SessionRowView` in `Sources/App/Views/SessionRowView.swift`:

```swift
import SwiftUI
import Core

struct SessionRowView: View {
    let session: DevSession
    var onFocusSession: ((DevSession) -> Void)?

    private var isActive: Bool {
        session.status == .running || session.status == .waiting
    }

    var body: some View {
        if isActive {
            Button {
                onFocusSession?(session)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            if isActive {
                // Capsule status badge — matches SessionGroupView style
                Text(sessionStatusTag(session))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sessionStatusColor(session))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sessionStatusColor(session).opacity(0.12))
                    .clipShape(Capsule())
            } else {
                statusIndicator
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(statusLabel)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.project)
                    .font(.callout)
                    .bold()
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(session.tool)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(elapsedTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isActive {
                Text("↗")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.3))
            }

            if let tokens = session.totalTokens {
                Text(tokenLabel(tokens))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .opacity(session.status == .stale ? 0.5 : 1.0)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .running, .waiting:
            EmptyView()  // handled by capsule branch above
        case .completed:
            Image(systemName: "checkmark")
                .foregroundColor(.blue)
                .imageScale(.small)
        case .error:
            Image(systemName: "xmark")
                .foregroundColor(.red)
                .imageScale(.small)
        case .stale:
            Rectangle()
                .fill(Color.gray)
                .frame(width: 10, height: 3)
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .running: return "Running"
        case .waiting: return "Waiting for permission"
        case .completed: return "Completed"
        case .error: return "Error"
        case .stale: return "Stale"
        }
    }

    private var elapsedTime: String {
        let end = session.endedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(session.startedAt))
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
    }

    private var rowAccessibilityLabel: String {
        let tokens = session.totalTokens.map { ", \($0) tokens" } ?? ""
        let focusHint = isActive ? ", tap to focus terminal" : ""
        return "\(session.project), \(session.tool), \(statusLabel), \(elapsedTime)\(tokens)\(focusHint)"
    }
}
```

- [ ] **Step 2: Update SessionPanelView to thread onFocusSession**

In `Sources/App/Views/SessionPanelView.swift`:

Add `onFocusSession` property to the struct (after `let viewModel`):
```swift
var onFocusSession: ((DevSession) -> Void)?
```

In the `List` body, update the `ForEach` in the "Active" section to pass the callback:
```swift
// Change:
SessionRowView(session: session)
// To (in the Active section only):
SessionRowView(session: session, onFocusSession: onFocusSession)
```

The Completed and Inactive sections pass no callback (those rows are not clickable):
```swift
SessionRowView(session: session)  // no onFocusSession — completed/stale rows don't focus
```

- [ ] **Step 3: Verify build**

```bash
swift build -c debug 2>&1 | head -30
```

Expected: one compiler error in `AgentDevPilotApp.swift` about `SessionPanelView` missing `onFocusSession` argument — fixed in Task 8.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/Views/SessionRowView.swift Sources/App/Views/SessionPanelView.swift
git commit -m "feat: active SessionRowView rows are clickable with onFocusSession and status capsule"
```

---

## Task 8: AgentDevPilotApp — wire onFocusSession + NSAlert fallback

**Files:**
- Modify: `Sources/App/AgentDevPilotApp.swift`

- [ ] **Step 1: Update AgentDevPilotApp**

Replace the entire `AgentDevPilotApp.swift`:

```swift
import SwiftUI
import Core

@main
struct AgentDevPilotApp: App {
    @State private var appState: AppState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if appState.showOnboarding {
                    OnboardingView {
                        appState.completeOnboarding()
                    }
                } else {
                    MenubarPopover(
                        viewModel: appState.popoverViewModel,
                        onFocusSession: { session in
                            focusSession(session)
                        }
                    )
                }
            }
            .task {
                await appState.start()
            }
        } label: {
            if appState.popoverViewModel.actionCount > 0 {
                Image(systemName: "bell.badge.fill")
            } else {
                Image(systemName: "bell")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sessions", id: "session-panel") {
            SessionPanelView(
                viewModel: appState.sessionPanelViewModel,
                onFocusSession: { session in
                    focusSession(session)
                }
            )
        }
        .defaultSize(width: 400, height: 500)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Terminal focus

private func focusSession(_ session: DevSession) {
    let result = TerminalFocusService.focus(session: session)
    guard result == .notFound else { return }

    let alert = NSAlert()
    alert.messageText = "Terminal window not found"
    alert.informativeText = "The terminal running \"\(session.project)\" may have been closed. Open a new window instead?"
    alert.addButton(withTitle: "Open New Window")
    alert.addButton(withTitle: "Cancel")

    if alert.runModal() == .alertFirstButtonReturn {
        openTerminal(at: session.cwd ?? "", terminalApp: session.terminalApp)
    }
}

// MARK: - Terminal helper

/// Opens a new terminal window at `path`, using the correct terminal app if known.
private func openTerminal(at path: String, terminalApp: String? = nil) {
    let url: URL
    if path.isEmpty {
        url = URL(fileURLWithPath: NSHomeDirectory())
    } else {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
    }
    let appName: String
    switch terminalApp {
    case "ghostty": appName = "Ghostty"
    default: appName = "Terminal"
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appName, url.path]
    try? process.run()
}
```

- [ ] **Step 2: Verify build**

```bash
swift build -c debug 2>&1 | head -30
```

Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/AgentDevPilotApp.swift
git commit -m "feat: wire onFocusSession in AgentDevPilotApp with TerminalFocusService and NSAlert fallback"
```

---

## Task 9: notify.sh — inject tty and terminal_app

**Files:**
- Modify: `Resources/notify.sh`

- [ ] **Step 1: Update notify.sh**

Replace the entire `Resources/notify.sh`:

```bash
#!/bin/bash
# Agent Dev Pilot — Claude Code hook helper script
# Reads hook event JSON from stdin and forwards to the local HTTP server.
# Injects tty and terminal_app fields for terminal window focus feature.
#
# SECURITY: Use --data-binary @- to pipe stdin directly to curl.
# Do NOT capture stdin into a variable (shell expansion risk).
# head -c 65536 enforces 64KB max payload at the source.
TOKEN=$(cat ~/.agent-dev-pilot/token 2>/dev/null)
TTY_PATH=$(tty 2>/dev/null || echo "")
TERM_PROG="${TERM_PROGRAM:-}"

if command -v jq &>/dev/null; then
    # Inject tty and terminal_app into the JSON payload
    cat | head -c 65536 \
      | jq --arg tty "$TTY_PATH" --arg terminal_app "$TERM_PROG" \
           '. + {tty: $tty, terminal_app: $terminal_app}' \
      | curl -s -X POST http://127.0.0.1:9876/event \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          --data-binary @- \
          --max-time 2 \
          >/dev/null 2>&1 &
else
    # jq not available — forward as-is; terminal focus won't work but events still flow
    cat | head -c 65536 | curl -s -X POST http://127.0.0.1:9876/event \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      --data-binary @- \
      --max-time 2 \
      >/dev/null 2>&1 &
fi
# Fire-and-forget: if app is not running, event is silently lost.
# This is intentional — hooks must never block Claude Code's workflow.
```

- [ ] **Step 2: Reinstall the hook script**

```bash
make run
```

Open Settings → copy the install prompt → run it in Claude Code to update `~/.agent-dev-pilot/hooks/notify.sh`. Or manually copy:

```bash
cp Resources/notify.sh ~/.agent-dev-pilot/hooks/notify.sh
chmod +x ~/.agent-dev-pilot/hooks/notify.sh
```

- [ ] **Step 3: Commit**

```bash
git add Resources/notify.sh
git commit -m "feat: inject tty and terminal_app into hook payload via jq"
```

---

## Task 10: Full test run + smoke test

- [ ] **Step 1: Run all tests**

```bash
swift test
```

Expected: all PASS (same count as before + new tests from Tasks 1–3).

- [ ] **Step 2: Build bundle**

```bash
make bundle
```

Expected: build succeeds.

- [ ] **Step 3: Launch and smoke test**

```bash
make run
```

Open two Ghostty windows in different project directories. Verify:
1. Popover shows both sessions with status capsule
2. Clicking a session header focuses the correct Ghostty window
3. Close one Ghostty window → click its session → NSAlert appears → "Open New Window" opens Ghostty at cwd
4. Session Panel rows for active sessions are clickable with `↗` hint
5. Completed/stale rows in Session Panel are not clickable
6. `EventCardView` has no "Open Terminal" button

- [ ] **Step 4: Commit if any fixes were needed**

```bash
git add -p
git commit -m "fix: address any issues from integration smoke test"
```

---

## Known limitations (v3 backlog)

- Two Claude sessions in the same `cwd`: Ghostty focuses the first matching tab. Rare in practice.
- `jq` not installed: terminal focus silently degrades, events still flow.
- Ghostty tab precision: will improve when Ghostty implements the IPC API from Discussion #3782.
- `openTerminal(at:)` fallback opens Terminal.app regardless of `terminalApp` value. Future: detect from session and open the correct app.
