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

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .idle)

        // agentStopped/review event should exist
        let events = try await db.read { try DevEvent.fetchAll($0) }
        #expect(events.contains { $0.type == .agentStopped && $0.attentionTier == .review })
    }

    // MARK: - Stop window: delayed Notification during window → no-op, session resolves to idle

    /// A Notification(permissionPrompt) arriving during the stop window is a delayed/stale
    /// delivery from an already-approved permission. It must NOT cancel the stop window or
    /// set status to waiting (the bug). The window should expire normally → idle.
    @Test func delayedNotificationDuringStopWindowResolvesToIdle() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))
        await coord.process(payload("Stop"))
        // Delayed notification arrives during the 100ms stop window — must be ignored
        await coord.process(payload("Notification", notificationType: "permission_prompt"))

        try await Task.sleep(for: .milliseconds(200))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .idle)  // window expired normally; NOT stuck at waiting
    }

    // MARK: - Stop window: genuine permission during ACTIVE task → Notification before Stop

    @Test func notificationBeforeStopSetsWaiting() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))
        // Notification arrives while still busy (no Stop yet) → genuine permission request
        await coord.process(payload("Notification", notificationType: "permission_prompt"))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .waiting)
    }

    // MARK: - SessionStart creates session in DB

    @Test func sessionStartCreatesSession() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)
        await coord.process(payload("SessionStart", cwd: "/my/project"))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
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

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
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
        let sessions = try await db.read { try DevSession.fetchAll($0) }
        await coord2.restoreStates(from: sessions)

        // Should continue from busy (Stop → window → idle)
        await coord2.process(payload("Stop"))
        try await Task.sleep(for: .milliseconds(200))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .idle)
    }

    // MARK: - Missed SessionStart: cwd captured from subsequent hooks

    /// Regression test: when SessionStart was missed (app was offline), the first
    /// non-SessionStart hook must create a session with the real cwd/project, not "unknown".
    @Test func missedSessionStartCapturesCwdFromFirstHook() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        // No SessionStart — simulate app starting after Claude Code was already running.
        // UserPromptSubmit arrives first with the real cwd.
        await coord.process(payload("UserPromptSubmit", cwd: "/Users/alice/Projects/my-app"))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session != nil)
        #expect(session?.project == "my-app")
        #expect(session?.cwd == "/Users/alice/Projects/my-app")
    }

    @Test func missedSessionStartCapturesCwdFromPreToolUse() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)

        // PreToolUse arrives first (SessionStart was missed)
        await coord.process(payload("PreToolUse", cwd: "/Users/alice/Projects/api-server", toolName: "Bash"))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session != nil)
        #expect(session?.project == "api-server")
        #expect(session?.cwd == "/Users/alice/Projects/api-server")
    }

    // MARK: - PreToolUse/AskUserQuestion produces permissionNeeded event

    @Test func preToolUseAskUserQuestionInsertsPermissionNeededEvent() async throws {
        let db = try makeDB()
        let coord = makeCoordinator(db: db)
        await coord.process(payload("SessionStart"))
        await coord.process(payload("UserPromptSubmit"))
        await coord.process(payload("PreToolUse", toolName: "AskUserQuestion"))

        let session = try await db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(session?.status == .waiting)

        let events = try await db.read { try DevEvent.fetchAll($0) }
        #expect(events.contains { $0.type == .permissionNeeded && $0.attentionTier == .action })
    }
}
