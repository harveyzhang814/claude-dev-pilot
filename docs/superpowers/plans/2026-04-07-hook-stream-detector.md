# HookStreamDetector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace EventMapper + SessionLifecycleService + StopWindowService with a pure-reducer + actor-coordinator pipeline that correctly handles AskUserQuestion, PostToolUse, and Stop-window coalescing.

**Architecture:** `HookPayload → HookEventClassifier (pure) → SessionStateReducer (pure function, all rules) → HookStreamCoordinator (actor, executes DB writes + timers)`. The reducer is a pure `(SessionMachineState, HookEvent) -> (SessionMachineState, [Action])` function — zero side effects, exhaustively testable.

**Tech Stack:** Swift, GRDB, Swift Testing (`@Suite`/`@Test`/`#expect`), Swift Concurrency (actor, Task.sleep)

---

## File Structure

```
Sources/Core/
  Models/
    HookEvent.swift           CREATE  — HookEvent enum, NotificationKind, SessionMachineState, Action
    HookPayload.swift         MODIFY  — add toolName: String? (CodingKey: tool_name)
    EventMapper.swift         DELETE  — after Task 10
  Services/
    HookEventClassifier.swift CREATE  — pure func classify(_ payload: HookPayload) -> HookEvent?
    SessionStateReducer.swift CREATE  — pure func reduce(_ state:, _ event:) -> (state, [Action])
    HookStreamCoordinator.swift CREATE — actor, executes Actions, manages 2s timer
    SessionLifecycleService.swift DELETE — after Task 10
    StopWindowService.swift   DELETE  — after Task 10
Sources/Server/
  EventHandler.swift          MODIFY  — replace old pipeline with coordinator.process()
Sources/App/
  AppState.swift              MODIFY  — instantiate HookStreamCoordinator, remove old services

Tests/ServiceTests/
  HookEventClassifierTests.swift  CREATE
  SessionStateReducerTests.swift  CREATE
  HookStreamCoordinatorTests.swift CREATE
```

---

## Task 1: Add toolName to HookPayload

**Files:**
- Modify: `Sources/Core/Models/HookPayload.swift`

PreToolUse and PostToolUse hooks carry a `tool_name` field that the current code never reads. We need it to distinguish AskUserQuestion from other tools.

- [ ] **Step 1: Add toolName field to HookPayload**

In `Sources/Core/Models/HookPayload.swift`, add after the `tool` property:

```swift
public let toolName: String?          // PreToolUse/PostToolUse: e.g. "AskUserQuestion", "Bash"
```

In the `CodingKeys` enum, add after `.tool`:

```swift
case toolName = "tool_name"
```

In `init(from decoder:)`, add after `tool = try c.decodeIfPresent(...)`:

```swift
toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
```

In the memberwise `init(...)`, add `toolName: String? = nil` parameter after `tool:`, and `self.toolName = toolName` in the body.

- [ ] **Step 2: Build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Run existing tests**

```bash
swift test --filter AgentDevPilotTests 2>&1 | tail -10
```

Expected: all existing tests pass. No new failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/Models/HookPayload.swift
git commit -m "feat: add toolName field to HookPayload (tool_name from PreToolUse/PostToolUse)"
```

---

## Task 2: Define HookEvent, SessionMachineState, Action types

**Files:**
- Create: `Sources/Core/Models/HookEvent.swift`

- [ ] **Step 1: Create HookEvent.swift**

```swift
// Sources/Core/Models/HookEvent.swift
import Foundation

/// Typed representation of a Claude Code / Cursor hook payload.
/// `stopWindowExpired` is a virtual event injected by HookStreamCoordinator
/// when the 2-second Stop coalescing window elapses without a Notification.
public enum HookEvent: Equatable, Sendable {
    case sessionStart(sessionId: String, cwd: String, tty: String?,
                      terminalApp: String?, tool: String, source: String?)
    case sessionEnd(sessionId: String)
    case userPromptSubmit(sessionId: String)
    case preToolUse(sessionId: String, toolName: String)
    case postToolUse(sessionId: String, toolName: String)
    case notification(sessionId: String, kind: NotificationKind)
    case stop(sessionId: String)
    case stopWindowExpired(sessionId: String)  // virtual — injected by coordinator timer

    public var sessionId: String {
        switch self {
        case .sessionStart(let id, _, _, _, _, _): return id
        case .sessionEnd(let id):                  return id
        case .userPromptSubmit(let id):            return id
        case .preToolUse(let id, _):               return id
        case .postToolUse(let id, _):              return id
        case .notification(let id, _):             return id
        case .stop(let id):                        return id
        case .stopWindowExpired(let id):           return id
        }
    }
}

public enum NotificationKind: Equatable, Sendable {
    case permissionPrompt   // "permission_prompt" or "elicitation_dialog"
    case idlePrompt         // "idle_prompt"
    case other
}

/// Per-session state held in memory by HookStreamCoordinator.
/// Persisted fields (status, cwd, tool) are restored from DB on startup.
public struct SessionMachineState: Equatable, Sendable {
    public var status: SessionStatus
    public var stopWindowActive: Bool   // true = Stop received, 2s window running
    public var dbSessionExists: Bool    // false = no SessionStart received yet
    public var cwd: String?
    public var tool: String             // "claude-code" or "cursor"

    public static let initial = SessionMachineState(
        status: .idle, stopWindowActive: false,
        dbSessionExists: false, cwd: nil, tool: "claude-code"
    )

    public init(status: SessionStatus, stopWindowActive: Bool,
                dbSessionExists: Bool, cwd: String?, tool: String) {
        self.status = status
        self.stopWindowActive = stopWindowActive
        self.dbSessionExists = dbSessionExists
        self.cwd = cwd
        self.tool = tool
    }
}

/// Side-effect instructions produced by SessionStateReducer.
/// HookStreamCoordinator interprets and executes these.
public enum Action: Equatable, Sendable {
    case upsertSession(sessionId: String, status: SessionStatus,
                       cwd: String, tty: String?, terminalApp: String?,
                       tool: String, source: String?)
    case updateSessionStatus(sessionId: String, status: SessionStatus)
    case insertDevEvent(sessionId: String, type: EventType, title: String,
                        cwd: String?, attentionTier: AttentionTier)
    case dismissPriorEvents(sessionId: String)
    case startStopWindow(sessionId: String)
    case cancelStopWindow(sessionId: String)
}
```

- [ ] **Step 2: Build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/Models/HookEvent.swift
git commit -m "feat: add HookEvent, SessionMachineState, Action type definitions"
```

---

## Task 3: HookEventClassifier (TDD)

**Files:**
- Create: `Tests/ServiceTests/HookEventClassifierTests.swift`
- Create: `Sources/Core/Services/HookEventClassifier.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/ServiceTests/HookEventClassifierTests.swift
import Testing
import Foundation
@testable import Core

@Suite("HookEventClassifier")
struct HookEventClassifierTests {

    private func payload(
        hookEventName: String,
        sessionId: String = "sid-1",
        cwd: String = "/proj",
        notificationType: String? = nil,
        toolName: String? = nil,
        tool: String? = nil,
        tty: String? = nil,
        terminalApp: String? = nil,
        source: String? = nil
    ) -> HookPayload {
        HookPayload(sessionId: sessionId, cwd: cwd, hookEventName: hookEventName,
                    notificationType: notificationType, tty: tty,
                    terminalApp: terminalApp, tool: tool, source: source,
                    toolName: toolName)
    }

    @Test func sessionStart() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "SessionStart", tty: "/dev/ttys001",
                    terminalApp: "ghostty", tool: "cursor", source: "startup"))
        #expect(event == .sessionStart(sessionId: "sid-1", cwd: "/proj",
                                       tty: "/dev/ttys001", terminalApp: "ghostty",
                                       tool: "cursor", source: "startup"))
    }

    @Test func sessionStartDefaultsTool() {
        let event = HookEventClassifier.classify(payload(hookEventName: "SessionStart"))
        guard case .sessionStart(_, _, _, _, let tool, _) = event! else {
            Issue.record("Expected sessionStart"); return
        }
        #expect(tool == "claude-code")
    }

    @Test func sessionEnd() {
        let event = HookEventClassifier.classify(payload(hookEventName: "SessionEnd"))
        #expect(event == .sessionEnd(sessionId: "sid-1"))
    }

    @Test func userPromptSubmit() {
        let event = HookEventClassifier.classify(payload(hookEventName: "UserPromptSubmit"))
        #expect(event == .userPromptSubmit(sessionId: "sid-1"))
    }

    @Test func preToolUse() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "PreToolUse", toolName: "Bash"))
        #expect(event == .preToolUse(sessionId: "sid-1", toolName: "Bash"))
    }

    @Test func preToolUseWithoutToolNameReturnsNil() {
        let event = HookEventClassifier.classify(payload(hookEventName: "PreToolUse"))
        #expect(event == nil)
    }

    @Test func postToolUse() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "PostToolUse", toolName: "AskUserQuestion"))
        #expect(event == .postToolUse(sessionId: "sid-1", toolName: "AskUserQuestion"))
    }

    @Test func notificationPermissionPrompt() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "permission_prompt"))
        #expect(event == .notification(sessionId: "sid-1", kind: .permissionPrompt))
    }

    @Test func notificationElicitationDialog() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "elicitation_dialog"))
        #expect(event == .notification(sessionId: "sid-1", kind: .permissionPrompt))
    }

    @Test func notificationIdlePrompt() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "idle_prompt"))
        #expect(event == .notification(sessionId: "sid-1", kind: .idlePrompt))
    }

    @Test func notificationOther() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "unknown_type"))
        #expect(event == .notification(sessionId: "sid-1", kind: .other))
    }

    @Test func stop() {
        let event = HookEventClassifier.classify(payload(hookEventName: "Stop"))
        #expect(event == .stop(sessionId: "sid-1"))
    }

    @Test func unknownHookEventNameReturnsNil() {
        let event = HookEventClassifier.classify(payload(hookEventName: "UnknownHook"))
        #expect(event == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter HookEventClassifierTests 2>&1 | tail -5
```

Expected: FAIL — `HookEventClassifier` not found.

- [ ] **Step 3: Implement HookEventClassifier**

```swift
// Sources/Core/Services/HookEventClassifier.swift
import Foundation

public enum HookEventClassifier {
    /// Convert a raw HookPayload into a typed HookEvent.
    /// Returns nil for unrecognised hookEventName values (caller silently ignores).
    public static func classify(_ payload: HookPayload) -> HookEvent? {
        let sid = payload.sessionId
        switch payload.hookEventName {
        case "SessionStart":
            return .sessionStart(
                sessionId: sid,
                cwd: payload.cwd,
                tty: payload.tty,
                terminalApp: payload.terminalApp,
                tool: payload.tool ?? "claude-code",
                source: payload.source
            )
        case "SessionEnd":
            return .sessionEnd(sessionId: sid)
        case "UserPromptSubmit":
            return .userPromptSubmit(sessionId: sid)
        case "PreToolUse":
            guard let toolName = payload.toolName else { return nil }
            return .preToolUse(sessionId: sid, toolName: toolName)
        case "PostToolUse":
            guard let toolName = payload.toolName else { return nil }
            return .postToolUse(sessionId: sid, toolName: toolName)
        case "Notification":
            let kind: NotificationKind
            switch payload.notificationType {
            case "permission_prompt", "elicitation_dialog":
                kind = .permissionPrompt
            case "idle_prompt":
                kind = .idlePrompt
            default:
                kind = .other
            }
            return .notification(sessionId: sid, kind: kind)
        case "Stop":
            return .stop(sessionId: sid)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
swift test --filter HookEventClassifierTests 2>&1 | tail -5
```

Expected: `Test run with 13 tests passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/HookEventClassifier.swift \
        Tests/ServiceTests/HookEventClassifierTests.swift
git commit -m "feat: HookEventClassifier — pure HookPayload → HookEvent classifier"
```

---

## Task 4: SessionStateReducer — lifecycle rules (Rules 1–2)

**Files:**
- Create: `Tests/ServiceTests/SessionStateReducerTests.swift`
- Create: `Sources/Core/Services/SessionStateReducer.swift`

- [ ] **Step 1: Write failing tests for Rules 1–2**

```swift
// Tests/ServiceTests/SessionStateReducerTests.swift
import Testing
import Foundation
@testable import Core

@Suite("SessionStateReducer")
struct SessionStateReducerTests {

    private let sid = "session-abc"
    private func reduce(_ state: SessionMachineState,
                        _ event: HookEvent) -> (SessionMachineState, [Action]) {
        SessionStateReducer.reduce(state, event)
    }

    // MARK: - Rule 1: SessionStart → idle

    @Test func sessionStartFromInitialCreatesUpsert() {
        let (next, actions) = reduce(.initial, .sessionStart(
            sessionId: sid, cwd: "/proj", tty: "/dev/ttys001",
            terminalApp: "ghostty", tool: "claude-code", source: "startup"))
        #expect(next.status == .idle)
        #expect(next.stopWindowActive == false)
        #expect(next.dbSessionExists == true)
        #expect(next.cwd == "/proj")
        #expect(next.tool == "claude-code")
        #expect(actions.contains(.upsertSession(
            sessionId: sid, status: .idle, cwd: "/proj",
            tty: "/dev/ttys001", terminalApp: "ghostty",
            tool: "claude-code", source: "startup")))
    }

    @Test func sessionStartResetsCompletedSession() {
        var state = SessionMachineState.initial
        state.status = .completed
        let (next, actions) = reduce(state, .sessionStart(
            sessionId: sid, cwd: "/proj", tty: nil,
            terminalApp: nil, tool: "claude-code", source: "resume"))
        #expect(next.status == .idle)
        #expect(actions.contains(.upsertSession(
            sessionId: sid, status: .idle, cwd: "/proj",
            tty: nil, terminalApp: nil, tool: "claude-code", source: "resume")))
    }

    @Test func sessionStartCancelsStopWindow() {
        var state = SessionMachineState.initial
        state.stopWindowActive = true
        let (next, actions) = reduce(state, .sessionStart(
            sessionId: sid, cwd: "/proj", tty: nil,
            terminalApp: nil, tool: "claude-code", source: nil))
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
    }

    // MARK: - Rule 2: SessionEnd → completed

    @Test func sessionEndSetsCompleted() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .sessionEnd(sessionId: sid))
        #expect(next.status == .completed)
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .completed)))
    }

    @Test func sessionEndCancelsActiveStopWindow() {
        var state = SessionMachineState.initial
        state.stopWindowActive = true
        let (next, actions) = reduce(state, .sessionEnd(sessionId: sid))
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
    }
}
```

- [ ] **Step 2: Run tests — expect fail**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -5
```

Expected: FAIL — `SessionStateReducer` not found.

- [ ] **Step 3: Implement Rules 1–2**

```swift
// Sources/Core/Services/SessionStateReducer.swift
import Foundation

public enum SessionStateReducer {
    public static func reduce(
        _ state: SessionMachineState,
        _ event: HookEvent
    ) -> (SessionMachineState, [Action]) {
        var s = state
        let sid = event.sessionId

        switch event {

        // Rule 1: SessionStart → idle (reopen if completed/stale)
        case .sessionStart(_, let cwd, let tty, let terminalApp, let tool, let source):
            s.status = .idle
            s.stopWindowActive = false
            s.cwd = cwd
            s.tool = tool
            s.dbSessionExists = true
            var actions: [Action] = [
                .upsertSession(sessionId: sid, status: .idle, cwd: cwd,
                               tty: tty, terminalApp: terminalApp,
                               tool: tool, source: source)
            ]
            if state.stopWindowActive {
                actions.insert(.cancelStopWindow(sessionId: sid), at: 0)
            }
            return (s, actions)

        // Rule 2: SessionEnd → completed
        case .sessionEnd(_):
            s.status = .completed
            s.stopWindowActive = false
            return (s, [
                .cancelStopWindow(sessionId: sid),
                .updateSessionStatus(sessionId: sid, status: .completed)
            ])

        default:
            return (s, [])
        }
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -5
```

Expected: all SessionStateReducerTests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/SessionStateReducer.swift \
        Tests/ServiceTests/SessionStateReducerTests.swift
git commit -m "feat: SessionStateReducer skeleton + Rules 1-2 (lifecycle)"
```

---

## Task 5: SessionStateReducer — busy rules (Rules 3, 11)

**Files:**
- Modify: `Tests/ServiceTests/SessionStateReducerTests.swift`
- Modify: `Sources/Core/Services/SessionStateReducer.swift`

- [ ] **Step 1: Add tests for Rules 3 and 11**

Append inside the `SessionStateReducerTests` struct (before the closing `}`):

```swift
    // MARK: - Rule 3: UserPromptSubmit → busy

    @Test func userPromptSubmitSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .userPromptSubmit(sessionId: sid))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
        #expect(actions.contains(.dismissPriorEvents(sessionId: sid)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .promptSubmitted,
            title: "Prompt submitted", cwd: nil, attentionTier: .background)))
    }

    @Test func userPromptSubmitFromIdleSetsBusy() {
        let (next, _) = reduce(.initial, .userPromptSubmit(sessionId: sid))
        #expect(next.status == .busy)
    }

    // MARK: - Rule 11: PreToolUse (non-AQU) when idle/waiting → busy

    @Test func preToolUseFromIdleSetsBusy() {
        let (next, actions) = reduce(.initial, .preToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
    }

    @Test func preToolUseFromWaitingSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "Read"))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
    }

    @Test func preToolUseFromBusyIsNoop() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
        #expect(actions.isEmpty)
    }
```

- [ ] **Step 2: Run tests — expect new tests to fail**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -10
```

Expected: Rules 3 and 11 tests fail.

- [ ] **Step 3: Add Rules 3 and 11 to reducer**

In `SessionStateReducer.swift`, add before the `default:` case:

```swift
        // Rule 3: UserPromptSubmit → busy + dismiss prior events
        case .userPromptSubmit(_):
            s.status = .busy
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .busy),
                .dismissPriorEvents(sessionId: sid),
                .insertDevEvent(sessionId: sid, type: .promptSubmitted,
                                title: "Prompt submitted",
                                cwd: s.cwd, attentionTier: .background)
            ])

        // Rule 11: PreToolUse (non-AskUserQuestion) when idle or waiting → busy
        case .preToolUse(_, let toolName)
                where toolName != "AskUserQuestion"
                   && (s.status == .idle || s.status == .waiting):
            s.status = .busy
            return (s, [.updateSessionStatus(sessionId: sid, status: .busy)])
```

- [ ] **Step 4: Run tests — expect pass**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/SessionStateReducer.swift \
        Tests/ServiceTests/SessionStateReducerTests.swift
git commit -m "feat: SessionStateReducer Rules 3+11 (UserPromptSubmit→busy, PreToolUse idle/waiting→busy)"
```

---

## Task 6: SessionStateReducer — waiting rules (Rules 4–7)

**Files:**
- Modify: `Tests/ServiceTests/SessionStateReducerTests.swift`
- Modify: `Sources/Core/Services/SessionStateReducer.swift`

- [ ] **Step 1: Add tests for Rules 4–7**

```swift
    // MARK: - Rule 4: PreToolUse/AskUserQuestion → waiting

    @Test func preToolUseAskUserQuestionSetsWaiting() {
        var state = SessionMachineState.initial
        state.status = .busy
        state.cwd = "/proj"
        let (next, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(next.status == .waiting)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .waiting)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: "/proj", attentionTier: .action)))
    }

    // Rule 4 fires from any state (including idle — missed UserPromptSubmit)
    @Test func preToolUseAskUserQuestionFromIdleSetsWaiting() {
        let (next, _) = reduce(.initial, .preToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(next.status == .waiting)
    }

    // MARK: - Rule 5: Notification(permissionPrompt) during stop window → cancel + waiting

    @Test func notificationPermissionPromptDuringStopWindowCancelsAndSetsWaiting() {
        var state = SessionMachineState.initial
        state.status = .idle
        state.stopWindowActive = true
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(next.status == .waiting)
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .waiting)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: nil, attentionTier: .action)))
    }

    // MARK: - Rule 6: Notification(permissionPrompt) when not waiting → waiting

    @Test func notificationPermissionPromptFromBusySetsWaiting() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(next.status == .waiting)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .waiting)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: nil, attentionTier: .action)))
    }

    // MARK: - Rule 7: Notification(permissionPrompt) already waiting → no-op (idempotent)

    @Test func notificationPermissionPromptWhenAlreadyWaitingIsNoop() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(next.status == .waiting)
        #expect(actions.isEmpty)
    }
```

- [ ] **Step 2: Run tests — expect new tests fail**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -10
```

- [ ] **Step 3: Add Rules 4–7 to reducer**

Add before Rule 11 (the `preToolUse where toolName != "AskUserQuestion"` case):

```swift
        // Rule 4: PreToolUse/AskUserQuestion → waiting (any current state)
        case .preToolUse(_, "AskUserQuestion"):
            s.status = .waiting
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .waiting),
                .insertDevEvent(sessionId: sid, type: .permissionNeeded,
                                title: "Claude Code needs your attention",
                                cwd: s.cwd, attentionTier: .action)
            ])

        // Rule 5: Notification(permissionPrompt) during stop window → cancel window + waiting
        case .notification(_, .permissionPrompt) where s.stopWindowActive:
            s.status = .waiting
            s.stopWindowActive = false
            return (s, [
                .cancelStopWindow(sessionId: sid),
                .updateSessionStatus(sessionId: sid, status: .waiting),
                .insertDevEvent(sessionId: sid, type: .permissionNeeded,
                                title: "Claude Code needs your attention",
                                cwd: s.cwd, attentionTier: .action)
            ])

        // Rule 6: Notification(permissionPrompt) → waiting (not already waiting)
        case .notification(_, .permissionPrompt) where s.status != .waiting:
            s.status = .waiting
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .waiting),
                .insertDevEvent(sessionId: sid, type: .permissionNeeded,
                                title: "Claude Code needs your attention",
                                cwd: s.cwd, attentionTier: .action)
            ])

        // Rule 7: Notification(permissionPrompt) already waiting → no-op (idempotent)
        case .notification(_, .permissionPrompt):
            return (s, [])
```

- [ ] **Step 4: Run tests — expect pass**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/SessionStateReducer.swift \
        Tests/ServiceTests/SessionStateReducerTests.swift
git commit -m "feat: SessionStateReducer Rules 4-7 (AskUserQuestion→waiting, permissionPrompt handling)"
```

---

## Task 7: SessionStateReducer — PostToolUse + Stop window (Rules 8–10) + no-ops

**Files:**
- Modify: `Tests/ServiceTests/SessionStateReducerTests.swift`
- Modify: `Sources/Core/Services/SessionStateReducer.swift`

- [ ] **Step 1: Add tests for Rules 8–10 and no-ops**

```swift
    // MARK: - Rule 8: PostToolUse when waiting → busy

    @Test func postToolUseWhenWaitingSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
    }

    @Test func postToolUseAnyToolWhenWaitingSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, _) = reduce(state, .postToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
    }

    @Test func postToolUseWhenBusyIsNoop() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
        #expect(actions.isEmpty)
    }

    // MARK: - Rule 9: Stop → start window

    @Test func stopStartsStopWindow() {
        let (next, actions) = reduce(.initial, .stop(sessionId: sid))
        #expect(next.stopWindowActive == true)
        #expect(next.status == .idle)   // status unchanged from initial
        #expect(actions.contains(.startStopWindow(sessionId: sid)))
    }

    @Test func stopFromBusyStartsWindow() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .stop(sessionId: sid))
        #expect(next.status == .busy)   // status unchanged by Stop alone
        #expect(next.stopWindowActive == true)
        #expect(actions == [.startStopWindow(sessionId: sid)])
    }

    // MARK: - Rule 10: stopWindowExpired → idle + agentStopped

    @Test func stopWindowExpiredSetsIdleAndInsertsReadyEvent() {
        var state = SessionMachineState.initial
        state.status = .busy
        state.stopWindowActive = true
        state.cwd = "/proj"
        state.tool = "claude-code"
        let (next, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(next.status == .idle)
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .idle)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Claude is ready", cwd: "/proj", attentionTier: .review)))
    }

    @Test func stopWindowExpiredCursorUsesCursorTitle() {
        var state = SessionMachineState.initial
        state.stopWindowActive = true
        state.tool = "cursor"
        let (_, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Cursor is ready", cwd: nil, attentionTier: .review)))
    }

    // MARK: - No-ops (Rules 12–13)

    @Test func notificationIdlePromptIsNoop() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .idlePrompt))
        #expect(next.status == .busy)
        #expect(actions.isEmpty)
    }

    @Test func notificationOtherIsNoop() {
        let (next, actions) = reduce(.initial, .notification(sessionId: sid, kind: .other))
        #expect(next == .initial)
        #expect(actions.isEmpty)
    }

    // MARK: - Full path integration tests

    @Test func askUserQuestionFullPath() {
        var state = SessionMachineState.initial
        state.cwd = "/proj"
        var actions: [Action]

        // UserPromptSubmit → busy
        (state, actions) = reduce(state, .userPromptSubmit(sessionId: sid))
        #expect(state.status == .busy)

        // PreToolUse/AskUserQuestion → waiting + permissionNeeded event
        (state, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(state.status == .waiting)
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: "/proj", attentionTier: .action)))

        // Notification(permissionPrompt) → no-op (idempotent, already waiting)
        (state, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(state.status == .waiting)
        #expect(actions.isEmpty)

        // PostToolUse/AskUserQuestion → busy
        (state, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(state.status == .busy)

        // Stop → window active
        (state, actions) = reduce(state, .stop(sessionId: sid))
        #expect(state.stopWindowActive == true)
        #expect(actions.contains(.startStopWindow(sessionId: sid)))

        // stopWindowExpired → idle + agentStopped
        (state, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(state.status == .idle)
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Claude is ready", cwd: "/proj", attentionTier: .review)))
    }

    @Test func permissionApprovalFullPath() {
        var state = SessionMachineState.initial
        var actions: [Action]

        (state, _) = reduce(state, .userPromptSubmit(sessionId: sid))
        (state, _) = reduce(state, .preToolUse(sessionId: sid, toolName: "Bash"))
        #expect(state.status == .busy)   // PreToolUse/Bash when busy → no-op

        (state, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(state.status == .waiting)

        (state, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "Bash"))
        #expect(state.status == .busy)

        (state, _) = reduce(state, .stop(sessionId: sid))
        (state, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(state.status == .idle)
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Claude is ready", cwd: nil, attentionTier: .review)))
    }
```

- [ ] **Step 2: Run tests — expect new tests fail**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -10
```

- [ ] **Step 3: Add Rules 8–10 and default to reducer**

Add after Rule 7 and before the `default:`:

```swift
        // Rule 8: PostToolUse (any tool) when waiting → busy
        case .postToolUse(_, _) where s.status == .waiting:
            s.status = .busy
            return (s, [.updateSessionStatus(sessionId: sid, status: .busy)])

        // Rule 9: Stop → start 2s coalescing window (status unchanged)
        case .stop(_):
            s.stopWindowActive = true
            return (s, [.startStopWindow(sessionId: sid)])

        // Rule 10: stopWindowExpired → idle + "ready" review event
        case .stopWindowExpired(_):
            s.status = .idle
            s.stopWindowActive = false
            let readyTitle = s.tool == "cursor" ? "Cursor is ready" : "Claude is ready"
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .idle),
                .insertDevEvent(sessionId: sid, type: .agentStopped,
                                title: readyTitle,
                                cwd: s.cwd, attentionTier: .review)
            ])

        // Rules 12–13: idle_prompt and everything else → no-op
        default:
            return (s, [])
```

- [ ] **Step 4: Run all reducer tests — expect pass**

```bash
swift test --filter SessionStateReducerTests 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Services/SessionStateReducer.swift \
        Tests/ServiceTests/SessionStateReducerTests.swift
git commit -m "feat: SessionStateReducer Rules 8-13 complete — all paths tested"
```

---

## Task 8: HookStreamCoordinator actor

**Files:**
- Create: `Tests/ServiceTests/HookStreamCoordinatorTests.swift`
- Create: `Sources/Core/Services/HookStreamCoordinator.swift`

- [ ] **Step 1: Write integration tests**

```swift
// Tests/ServiceTests/HookStreamCoordinatorTests.swift
import Testing
import Foundation
import GRDB
@testable import Core

@Suite("HookStreamCoordinator")
struct HookStreamCoordinatorTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        return db
    }

    private func makeCoordinator(db: DatabaseQueue,
                                  windowMs: Int = 100) -> HookStreamCoordinator {
        HookStreamCoordinator(
            db: db,
            stopWindowDuration: .milliseconds(windowMs)
        )
    }

    private func payload(_ name: String, sid: String = "s1",
                          cwd: String = "/proj",
                          notificationType: String? = nil,
                          toolName: String? = nil) -> HookPayload {
        HookPayload(sessionId: sid, cwd: cwd, hookEventName: name,
                    notificationType: notificationType, toolName: toolName)
    }

    // MARK: - Stop window: no Notification → idle

    @Test func stopWithoutNotificationResolvesToIdle() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))
        await coord.process(payload("Stop"))

        // Wait for 200ms (window = 100ms)
        try await Task.sleep(for: .milliseconds(200))

        let session = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .idle)

        // agentStopped/review event should exist
        let events = try db.read { try DevEvent.fetchAll($0) }
        #expect(events.contains { $0.type == .agentStopped && $0.attentionTier == .review })
    }

    // MARK: - Stop window: Notification arrives → waiting

    @Test func stopFollowedByNotificationResolvesToWaiting() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))
        await coord.process(payload("Stop"))
        await coord.process(payload("Notification", notificationType: "permission_prompt"))

        try await Task.sleep(for: .milliseconds(200))

        let session = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .waiting)
    }

    // MARK: - SessionStart creates session in DB

    @Test func sessionStartCreatesSession() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)
        await coord.process(payload("SessionStart", cwd: "/my/project"))

        let session = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session != nil)
        #expect(session?.status == .idle)
        #expect(session?.project == "project")
    }

    // MARK: - SessionEnd sets completed

    @Test func sessionEndSetsCompleted() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)
        await coord.process(payload("SessionStart"))
        await coord.process(payload("SessionEnd"))

        let session = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .completed)
    }

    // MARK: - restoreStates recovers in-memory state

    @Test func restoreStatesResumesKnownStatus() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        // Simulate a session that was busy before crash
        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))

        // Create a new coordinator (simulating app restart)
        let coord2 = makeCoordinator(db: db)
        let sessions = try db.read { try DevSession.fetchAll($0) }
        await coord2.restoreStates(from: sessions)

        // Should continue from busy (Stop → window → idle, not create orphan session)
        await coord2.process(payload("Stop"))
        try await Task.sleep(for: .milliseconds(200))

        let session = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .idle)
    }

    // MARK: - PreToolUse/AskUserQuestion produces permissionNeeded event

    @Test func preToolUseAskUserQuestionInsertsPermissionNeededEvent() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)
        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))
        await coord.process(payload("PreToolUse", toolName: "AskUserQuestion"))

        let session = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .waiting)

        let events = try db.read { try DevEvent.fetchAll($0) }
        #expect(events.contains { $0.type == .permissionNeeded && $0.attentionTier == .action })
    }
}
```

- [ ] **Step 2: Run tests — expect fail**

```bash
swift test --filter HookStreamCoordinatorTests 2>&1 | tail -5
```

Expected: FAIL — `HookStreamCoordinator` not found.

- [ ] **Step 3: Implement HookStreamCoordinator**

```swift
// Sources/Core/Services/HookStreamCoordinator.swift
import Foundation
import GRDB

public actor HookStreamCoordinator {
    private var states: [String: SessionMachineState] = [:]
    private var stopWindowTasks: [String: Task<Void, Never>] = [:]
    private let db: any DatabaseWriter & Sendable
    private let stopWindowDuration: Duration
    private let onIdleResolved: (@Sendable (String) -> Void)?

    public init(
        db: any DatabaseWriter & Sendable,
        stopWindowDuration: Duration = .seconds(2),
        onIdleResolved: (@Sendable (String) -> Void)? = nil
    ) {
        self.db = db
        self.stopWindowDuration = stopWindowDuration
        self.onIdleResolved = onIdleResolved
    }

    /// Main entry point — call this for every incoming HookPayload.
    public func process(_ payload: HookPayload) async {
        guard let event = HookEventClassifier.classify(payload) else { return }
        let sid = event.sessionId
        let current = states[sid] ?? .initial
        let (next, actions) = SessionStateReducer.reduce(current, event)
        states[sid] = next
        await execute(actions)
    }

    /// Restore in-memory state from DB on app startup.
    public func restoreStates(from sessions: [DevSession]) {
        for session in sessions where session.status != .completed && session.status != .stale {
            states[session.id] = SessionMachineState(
                status: session.status,
                stopWindowActive: false,
                dbSessionExists: true,
                cwd: session.cwd,
                tool: session.tool
            )
        }
    }

    // MARK: - Private

    private func execute(_ actions: [Action]) async {
        for action in actions {
            switch action {

            case .startStopWindow(let sid):
                stopWindowTasks[sid]?.cancel()
                let duration = stopWindowDuration
                stopWindowTasks[sid] = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    await self?.injectExpired(sessionId: sid)
                }

            case .cancelStopWindow(let sid):
                stopWindowTasks[sid]?.cancel()
                stopWindowTasks[sid] = nil

            case .upsertSession(let sid, let status, let cwd, let tty, let terminalApp, let tool, _):
                let project = URL(fileURLWithPath: cwd).lastPathComponent
                try? await db.write { db in
                    if var existing = try DevSession.fetchOne(db, key: sid) {
                        existing.cwd = cwd
                        existing.tty = tty
                        existing.terminalApp = terminalApp
                        existing.tool = tool
                        existing.project = project
                        if existing.status == .completed || existing.status == .stale {
                            existing.status = .idle
                            existing.endedAt = nil
                        }
                        try existing.update(db)
                    } else {
                        var session = DevSession(
                            id: sid, project: project, customName: nil,
                            cwd: cwd, tty: tty, terminalApp: terminalApp,
                            tool: tool, status: status, startedAt: Date(),
                            endedAt: nil, totalTokens: nil, lastEventTitle: nil
                        )
                        try session.insert(db)
                    }
                }

            case .updateSessionStatus(let sid, let status):
                let fallbackCwd = states[sid]?.cwd
                let fallbackTool = states[sid]?.tool ?? "claude-code"
                try? await db.write { db in
                    if (try DevSession.fetchOne(db, key: sid)) != nil {
                        try db.execute(
                            sql: """
                                UPDATE sessions SET status = ?
                                WHERE id = ? AND status NOT IN ('completed', 'stale')
                                """,
                            arguments: [status.rawValue, sid]
                        )
                    } else {
                        // SessionStart was missed — create a minimal session
                        let project = fallbackCwd.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        } ?? "unknown"
                        var session = DevSession(
                            id: sid, project: project, customName: nil,
                            cwd: fallbackCwd, tty: nil, terminalApp: nil,
                            tool: fallbackTool, status: status, startedAt: Date(),
                            endedAt: nil, totalTokens: nil, lastEventTitle: nil
                        )
                        try session.insert(db)
                    }
                }

            case .insertDevEvent(let sid, let type, let title, let cwd, let tier):
                let event = DevEvent(
                    id: UUID().uuidString,
                    sessionId: sid,
                    type: type,
                    title: title,
                    detail: cwd,
                    payload: "{}",
                    tokenCount: nil,
                    durationSeconds: nil,
                    timestamp: Date(),
                    attentionTier: tier
                )
                try? await db.write { db in try event.insert(db) }

            case .dismissPriorEvents(let sid):
                try? await db.write { db in
                    try db.execute(
                        sql: "UPDATE events SET is_dismissed = 1 WHERE session_id = ? AND is_dismissed = 0",
                        arguments: [sid]
                    )
                }
            }
        }
    }

    private func injectExpired(sessionId: String) async {
        stopWindowTasks[sessionId] = nil
        let current = states[sessionId] ?? .initial
        let (next, actions) = SessionStateReducer.reduce(
            current, .stopWindowExpired(sessionId: sessionId)
        )
        states[sessionId] = next
        await execute(actions)
        if next.status == .idle {
            onIdleResolved?(sessionId)
        }
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
swift test --filter HookStreamCoordinatorTests 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Run all tests**

```bash
swift test 2>&1 | tail -10
```

Expected: all existing + new tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Services/HookStreamCoordinator.swift \
        Tests/ServiceTests/HookStreamCoordinatorTests.swift
git commit -m "feat: HookStreamCoordinator actor — executes Actions, manages 2s stop window"
```

---

## Task 9: Wire up EventHandler + AppState

**Files:**
- Modify: `Sources/Server/EventHandler.swift`
- Modify: `Sources/App/AppState.swift`

The coordinator becomes the single entry point for all hook processing. Both `/event` (Claude Code) and `/cursor-event` (Cursor, after normalization) call `coordinator.process()`.

- [ ] **Step 1: Update EventHandler.swift**

In `EventHandler.swift`, change the `postEvent` function signature to accept `coordinator: HookStreamCoordinator` instead of `stopWindow: StopWindowService`:

```swift
static func postEvent(
    db: any DatabaseWriter & Sendable,
    coordinator: HookStreamCoordinator,      // ← replaces stopWindow
    onEvent: @Sendable @escaping (DevEvent) -> Void
) -> @Sendable (Request, BasicRequestContext) async throws -> Response {
```

Replace the entire block starting from `if decoded.hookEventName == "SessionStart"` to the end of the switch on `decoded.hookEventName` with:

```swift
            await coordinator.process(decoded)

            // Notify the app of any new events (for NotificationBatcher)
            if let latest = try db.read({ db in
                try DevEvent
                    .filter(DevEvent.Columns.sessionId == decoded.sessionId)
                    .order(DevEvent.Columns.timestamp.desc)
                    .fetchOne(db)
            }) {
                onEvent(latest)
            }

            return Response(status: .ok, headers: [:], body: .init())
```

Do the same for `postCursorEvent`: after `CursorNormalizer.normalize(cursor)` produces `decoded`, replace the old pipeline with:

```swift
            await coordinator.process(decoded)
```

Remove the `import` of any types that no longer exist (build will tell you which).

- [ ] **Step 2: Update AppState.swift**

Find where `StopWindowService` is instantiated (search for `StopWindowService(`). Replace it with:

```swift
private let coordinator: HookStreamCoordinator
```

In `start()`, before starting the HTTP server, add:

```swift
let activeSessions = try await db.read { db in try DevSession.fetchAll(db) }
await coordinator.restoreStates(from: activeSessions)
```

In the `HookStreamCoordinator` init (in `AppState.init` or `start()`):

```swift
coordinator = HookStreamCoordinator(
    db: db.pool,
    stopWindowDuration: .seconds(2),
    onIdleResolved: { [weak self] sessionId in
        self?.notificationBatcher.scheduleIdleNotification(for: sessionId)
    }
)
```

Pass `coordinator` to `EventHandler.buildApp(coordinator:...)` instead of the old `stopWindow`.

- [ ] **Step 3: Build**

```bash
swift build -c debug 2>&1
```

Fix any remaining compiler errors. Common issues:
- `StopWindowService` still referenced somewhere → replace with `coordinator`
- `SessionLifecycleService` still referenced → remove those call sites

- [ ] **Step 4: Run all tests**

```bash
swift test 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Server/EventHandler.swift Sources/App/AppState.swift
git commit -m "feat: wire HookStreamCoordinator into EventHandler and AppState"
```

---

## Task 10: Delete old files + final cleanup

**Files:**
- Delete: `Sources/Core/Models/EventMapper.swift`
- Delete: `Sources/Core/Services/SessionLifecycleService.swift`
- Delete: `Sources/Core/Services/StopWindowService.swift`
- Delete: `Tests/ServiceTests/StopWindowServiceTests.swift` (replaced by HookStreamCoordinatorTests)

Old tests that tested the deleted services should be removed. Tests that tested `EventMapper` behavior are now covered by `SessionStateReducerTests`.

- [ ] **Step 1: Delete old implementation files**

```bash
git rm Sources/Core/Models/EventMapper.swift \
       Sources/Core/Services/SessionLifecycleService.swift \
       Sources/Core/Services/StopWindowService.swift
```

- [ ] **Step 2: Delete superseded test files**

```bash
git rm Tests/ServiceTests/StopWindowServiceTests.swift
```

Check `Tests/ServiceTests/SessionLifecycleTests.swift` — its behavior is now covered by `SessionStateReducerTests` and `HookStreamCoordinatorTests`. Remove it:

```bash
git rm Tests/ServiceTests/SessionLifecycleTests.swift
```

Check `Tests/AgentDevPilotTests/EventMapperTests.swift` — remove if it exists:

```bash
git rm Tests/AgentDevPilotTests/EventMapperTests.swift 2>/dev/null || true
```

- [ ] **Step 3: Build**

```bash
swift build -c debug 2>&1
```

Fix any remaining references to deleted types.

- [ ] **Step 4: Run full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass, no references to deleted types.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: remove EventMapper, SessionLifecycleService, StopWindowService — replaced by HookStreamDetector pipeline"
```

---

## Self-Review Notes

**Spec coverage check:**
- ✅ HookEvent enum with all 8 cases including virtual `stopWindowExpired`
- ✅ SessionMachineState with cwd/tool for ready-event title
- ✅ All 13 reducer rules implemented and tested
- ✅ HookStreamCoordinator manages timer + DB writes
- ✅ `restoreStates()` for app restart recovery
- ✅ EventHandler + AppState wired up
- ✅ Old files deleted

**No placeholders:** Every step has exact code. No "add appropriate handling" phrases.

**Type consistency:** `Action.insertDevEvent` signature used identically across reducer (Task 4-7) and coordinator (Task 8). `SessionMachineState.initial` is a static let defined once in Task 2, used in all tests.
