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

    // MARK: - Stop window: no Notification → idle

    @Test func stopWithoutNotificationResolvesToIdle() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "f3d1b290-a4c7-4e8f-9d2a-1b5c6e7f8a09"
        let cwd   = "/Users/alice/Projects/my-app"

        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys003", terminalApp: "ghostty"
        ))
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))
        await coord.process(HookPayload(sessionId: sid, cwd: cwd, hookEventName: "Stop"))

        try await Task.sleep(for: .milliseconds(200))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .idle)

        let events = try await db.read { try DevEvent.fetchAll($0) }
        #expect(events.contains { $0.type == .agentStopped && $0.attentionTier == .review })
    }

    // MARK: - Stop window: delayed Notification during window → no-op, session resolves to idle

    /// A Notification(permissionPrompt) arriving during the stop window is a delayed/stale
    /// delivery from an already-approved permission. It must NOT cancel the stop window or
    /// set status to waiting (the bug). The window should expire normally → idle.
    @Test func delayedNotificationDuringStopWindowResolvesToIdle() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "b8e2f4a6-c0d2-4e8f-a2b4-c6d8e0f2a4b6"
        let cwd   = "/Users/alice/Projects/my-app"

        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys003", terminalApp: "ghostty"
        ))
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))
        await coord.process(HookPayload(sessionId: sid, cwd: cwd, hookEventName: "Stop"))
        // Delayed/stale notification arrives during the 100ms stop window — must be ignored
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "Notification",
            message: "Claude Code wants to run a bash command: npm install",
            title: "Claude Code",
            notificationType: "permission_prompt"
        ))

        try await Task.sleep(for: .milliseconds(200))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .idle)  // window expired normally; NOT stuck at waiting
    }

    // MARK: - Stop window: genuine permission during ACTIVE task → Notification before Stop

    @Test func notificationBeforeStopSetsWaiting() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "a6b8c0d2-e4f6-4a6b-8c0d-2e4f6a8b0c2d"
        let cwd   = "/Users/alice/Projects/my-app"

        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys003", terminalApp: "ghostty"
        ))
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))
        // Notification arrives while still busy (no Stop yet) → genuine permission request
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "Notification",
            message: "Claude Code wants to run a bash command: rm -rf /tmp/build",
            title: "Claude Code",
            notificationType: "permission_prompt"
        ))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .waiting)
    }

    // MARK: - SessionStart creates session in DB

    @Test func sessionStartCreatesSession() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "d2e4f6a8-b0c2-4d2e-4f6a-8b0c2d4e6f8a"

        await coord.process(HookPayload(
            sessionId: sid,
            cwd: "/Users/alice/Projects/my-project",
            hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys004", terminalApp: "ghostty"
        ))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session != nil)
        #expect(session?.status == .idle)
        #expect(session?.project == "my-project")
        #expect(session?.tty == "/dev/ttys004")
        #expect(session?.terminalApp == "ghostty")
    }

    // MARK: - SessionEnd sets completed

    @Test func sessionEndSetsCompleted() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "e4f6a8b0-c2d4-4e6a-8b0c-2d4e6f8a0b2c"
        let cwd   = "/Users/alice/Projects/my-app"

        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys003", terminalApp: "ghostty"
        ))
        await coord.process(HookPayload(sessionId: sid, cwd: cwd, hookEventName: "SessionEnd"))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .completed)
    }

    // MARK: - restoreStates recovers in-memory state

    @Test func restoreStatesResumesKnownStatus() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "c0d2e4f6-a8b0-4c2d-4e6f-8a0b2c4d6e8f"
        let cwd   = "/Users/alice/Projects/my-app"

        // Simulate a session that was busy before the app crashed
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys003", terminalApp: "ghostty"
        ))
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))

        // New coordinator simulates app restart; restore from DB
        let coord2 = makeCoordinator(db: db)
        let sessions = try await db.read { try DevSession.fetchAll($0) }
        await coord2.restoreStates(from: sessions)

        // Should continue from busy (Stop → window → idle)
        await coord2.process(HookPayload(sessionId: sid, cwd: cwd, hookEventName: "Stop"))
        try await Task.sleep(for: .milliseconds(200))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .idle)
    }

    // MARK: - Missed SessionStart: cwd captured from subsequent hooks

    /// Regression test: when SessionStart was missed (app was offline), the first
    /// non-SessionStart hook must create a session with the real cwd/project, not "unknown".
    @Test func missedSessionStartCapturesCwdFromFirstHook() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "f6a8b0c2-d4e6-4f8a-0b2c-4d6e8f0a2b4c"

        // No SessionStart — simulate app starting after Claude Code was already running.
        // UserPromptSubmit arrives first with the real cwd.
        await coord.process(HookPayload(
            sessionId: sid,
            cwd: "/Users/alice/Projects/my-app",
            hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session != nil)
        #expect(session?.project == "my-app")
        #expect(session?.cwd == "/Users/alice/Projects/my-app")
    }

    @Test func missedSessionStartCapturesCwdFromPreToolUse() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "a8b0c2d4-e6f8-4a0b-2c4d-6e8f0a2b4c6d"

        // PreToolUse arrives first (SessionStart was missed)
        await coord.process(HookPayload(
            sessionId: sid,
            cwd: "/Users/alice/Projects/api-server",
            hookEventName: "PreToolUse",
            toolName: "Bash"
        ))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session != nil)
        #expect(session?.project == "api-server")
        #expect(session?.cwd == "/Users/alice/Projects/api-server")
    }

    // MARK: - Missed SessionStart + SessionEnd: ghost idle session must NOT be created

    /// Regression test: when SessionStart was missed and SessionEnd is the first
    /// hook received, the fallback must not create a ghost "idle" session.
    /// Before the fix, updateSessionStatus's else-branch created a new session
    /// with status:.idle regardless of the requested status.
    @Test func missedSessionStartSessionEndDoesNotCreateGhostSession() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "b0c2d4e6-f8a0-4b2c-4d6e-8f0a2b4c6d8e"

        // No SessionStart — app was offline. SessionEnd arrives first.
        await coord.process(HookPayload(
            sessionId: sid,
            cwd: "/Users/alice/Projects/my-app",
            hookEventName: "SessionEnd"
        ))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        // Session should either not exist in DB, or be completed — never idle.
        if let session {
            #expect(session.status == .completed,
                    "SessionEnd for unknown session must not create an idle ghost session")
        }
        // Preferred outcome: no session created at all
        // (both nil and .completed are acceptable; .idle is the bug)
    }

    /// When SessionStart was missed but some hooks DID fire (creating a session),
    /// SessionEnd should still close it to .completed.
    @Test func missedSessionStartSessionEndClosesTrackedSession() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "c2d4e6f8-a0b2-4c4d-6e8f-0a2b4c6d8e0f"
        let cwd   = "/Users/alice/Projects/my-app"

        // First hook creates session via missed-SessionStart fallback
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))
        // Then Claude exits
        await coord.process(HookPayload(sessionId: sid, cwd: cwd, hookEventName: "SessionEnd"))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .completed,
                "SessionEnd must close a previously tracked session to .completed")
    }

    // MARK: - Pre-existing session: full lifecycle without SessionStart

    /// End-to-end lifecycle test for a session that was already running when the app started.
    ///
    /// Scenario: Claude Code was launched before the app, so SessionStart was never received.
    /// All payloads use field values that match real Claude Code wire data.
    ///
    ///   [missed SessionStart]
    ///       → UserPromptSubmit  (session created, idle in DB / busy in memory)
    ///       → Notification      (permission prompt → waiting)
    ///       → PostToolUse       (permission granted → busy)
    ///       → Stop + window     (busy during window)
    ///       → window expires    (idle + agentStopped event)
    ///       → UserPromptSubmit  (busy again — same session reused)
    ///       → SessionEnd        (completed — disappears from popover)
    @Test func preExistingSessionFullLifecycle() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db, windowMs: 100)

        // Real-world values: UUID session_id, absolute project path,
        // transcript path as Claude Code generates it.
        let sid            = "c8a72f3b-1d4e-4a9c-8b5f-2e6d7a0c3f91"
        let cwd            = "/Users/alice/Projects/agent-dev-pilot"
        let transcriptPath = "/Users/alice/.claude/projects/-Users-alice-Projects-agent-dev-pilot/transcript.jsonl"

        // ── Phase 1: first hook creates the session (SessionStart was missed) ──
        // Claude Code was already running; app just started and caught this first.
        await coord.process(HookPayload(
            sessionId:      sid,
            cwd:            cwd,
            hookEventName:  "UserPromptSubmit",
            transcriptPath: transcriptPath
        ))

        var session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session != nil,                           "session must be created from first hook even without SessionStart")
        #expect(session?.cwd     == cwd,                  "cwd must be captured from first hook")
        #expect(session?.project == "agent-dev-pilot",    "project must be derived from last path component")
        #expect(session?.status  != .completed && session?.status != .stale,
                "session must be active, not terminal")

        // ── Phase 2: permission prompt arrives → waiting ───────────────────────
        // In-memory state is .busy → Rule 6 fires → DB updated to .waiting.
        await coord.process(HookPayload(
            sessionId:        sid,
            cwd:              cwd,
            hookEventName:    "Notification",
            message:          "Claude Code wants to run a bash command: rm -rf /tmp/build",
            title:            "Claude Code",
            notificationType: "permission_prompt"
        ))

        session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .waiting, "permission_prompt during active task must set .waiting")

        // ── Phase 3: user grants permission → busy ─────────────────────────────
        // tool_name matches Claude Code's PostToolUse payload for a Bash invocation.
        await coord.process(HookPayload(
            sessionId:     sid,
            cwd:           cwd,
            hookEventName: "PostToolUse",
            toolName:      "Bash"
        ))

        session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .busy, "PostToolUse must clear .waiting → .busy")

        // ── Phase 4: agent finishes its turn → stop window opens ──────────────
        await coord.process(HookPayload(
            sessionId:     sid,
            cwd:           cwd,
            hookEventName: "Stop"
        ))

        // Status unchanged while the coalescing window is active.
        session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .busy, "status must stay .busy while stop window is active")

        // ── Phase 5: stop window expires → idle + ready event ─────────────────
        try await Task.sleep(for: .milliseconds(200))

        session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .idle, "session must be .idle after stop window expires")

        let afterStopEvents = try await db.read {
            try DevEvent.filter(DevEvent.Columns.sessionId == sid).fetchAll($0)
        }
        #expect(
            afterStopEvents.contains { $0.type == .agentStopped && $0.attentionTier == .review },
            "agentStopped/review event must be inserted after stop window expires"
        )

        // ── Phase 6: another prompt → session reused as busy ──────────────────
        await coord.process(HookPayload(
            sessionId:      sid,
            cwd:            cwd,
            hookEventName:  "UserPromptSubmit",
            transcriptPath: transcriptPath
        ))

        session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .busy, "new UserPromptSubmit must set existing session back to .busy")

        // ── Phase 7: Claude exits → completed (disappears from popover) ────────
        await coord.process(HookPayload(
            sessionId:     sid,
            cwd:           cwd,
            hookEventName: "SessionEnd"
        ))

        session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .completed,
                "SessionEnd must close the session to .completed so it leaves the popover")
    }

    // MARK: - PreToolUse/AskUserQuestion produces permissionNeeded event

    @Test func preToolUseAskUserQuestionInsertsPermissionNeededEvent() async throws {
        let db    = try makeDB()
        let coord = makeCoordinator(db: db)
        let sid   = "d4e6f8a0-b2c4-4d6e-8f0a-2b4c6d8e0f2a"
        let cwd   = "/Users/alice/Projects/my-app"

        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "SessionStart",
            source: "startup", model: "claude-sonnet-4-6",
            tty: "/dev/ttys003", terminalApp: "ghostty"
        ))
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "UserPromptSubmit",
            transcriptPath: "/Users/alice/.claude/projects/-Users-alice-Projects-my-app/transcript.jsonl"
        ))
        await coord.process(HookPayload(
            sessionId: sid, cwd: cwd, hookEventName: "PreToolUse",
            toolName: "AskUserQuestion"
        ))

        let session = try await db.read { try DevSession.fetchOne($0, key: sid) }
        #expect(session?.status == .waiting)

        let events = try await db.read { try DevEvent.fetchAll($0) }
        #expect(events.contains { $0.type == .permissionNeeded && $0.attentionTier == .action })
    }
}
