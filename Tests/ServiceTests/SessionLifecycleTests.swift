import Testing
import Foundation
import GRDB
@testable import Core

@Suite("SessionLifecycle")
struct SessionLifecycleTests {

    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        return dbQueue
    }

    private func makeEvent(
        sessionId: String = "session-1",
        type: EventType = .agentStopped,
        tier: AttentionTier = .background,
        cwd: String = "/Users/dev/project"
    ) -> DevEvent {
        DevEvent(
            id: UUID().uuidString, sessionId: sessionId, type: type,
            title: "Test event", detail: cwd, payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: Date(), attentionTier: tier
        )
    }

    @Test("First event creates new session as idle")
    func firstEventCreatesSession() throws {
        let db = try makeDB()
        let event = makeEvent(type: .agentStopped)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session != nil)
        #expect(session?.status == .idle)
        #expect(session?.id == event.sessionId)
    }

    @Test("promptSubmitted event sets status to busy")
    func promptSubmittedSetsBusy() throws {
        let db = try makeDB()
        // Create session first
        let firstEvent = makeEvent(type: .agentStopped)
        try SessionLifecycleService.processEvent(firstEvent, in: db)

        let event = makeEvent(type: .promptSubmitted, tier: .background)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .busy)
    }

    @Test("permissionNeeded event sets status to waiting")
    func permissionNeededSetsWaiting() throws {
        let db = try makeDB()
        let event = makeEvent(type: .permissionNeeded, tier: .action)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .waiting)
    }

    @Test("agentStopped event does not change session state")
    func agentStoppedNoStateChange() throws {
        let db = try makeDB()
        // Create session in busy state
        let submitEvent = makeEvent(type: .promptSubmitted, tier: .background)
        try SessionLifecycleService.processEvent(submitEvent, in: db)
        try SessionStore.updateStatus(id: submitEvent.sessionId, to: .busy, in: db)

        let stopEvent = makeEvent(type: .agentStopped, tier: .background)
        try SessionLifecycleService.processEvent(stopEvent, in: db)

        // agentStopped alone doesn't change state — StopWindowService resolves idle/waiting
        let session = try SessionStore.fetch(id: stopEvent.sessionId, in: db)
        #expect(session?.status == .busy)
    }

    @Test("Event for completed session reopens it to idle")
    func eventReopensCompletedSession() throws {
        let db = try makeDB()
        // Create session then close it manually
        let firstEvent = makeEvent(type: .agentStopped)
        try SessionLifecycleService.processEvent(firstEvent, in: db)
        try SessionStore.close(id: firstEvent.sessionId, status: .completed, in: db)

        let closed = try SessionStore.fetch(id: firstEvent.sessionId, in: db)
        #expect(closed?.status == .completed)

        // New event reopens to idle
        let newEvent = makeEvent(sessionId: firstEvent.sessionId, type: .agentStopped)
        try SessionLifecycleService.processEvent(newEvent, in: db)

        let reopened = try SessionStore.fetch(id: firstEvent.sessionId, in: db)
        #expect(reopened?.status == .idle)
        #expect(reopened?.endedAt == nil)
    }

    @Test("Subsequent event updates lastEventTitle")
    func subsequentEventUpdatesTitle() throws {
        let db = try makeDB()
        let firstEvent = makeEvent(type: .agentStopped)
        try SessionLifecycleService.processEvent(firstEvent, in: db)

        let secondEvent = DevEvent(
            id: UUID().uuidString,
            sessionId: firstEvent.sessionId,
            type: .agentStopped,
            title: "Updated title",
            detail: "/Users/dev/project",
            payload: "{}",
            tokenCount: nil,
            durationSeconds: nil,
            timestamp: Date(),
            attentionTier: .background
        )
        try SessionLifecycleService.processEvent(secondEvent, in: db)

        let session = try SessionStore.fetch(id: firstEvent.sessionId, in: db)
        #expect(session?.lastEventTitle == "Updated title")
    }

    // MARK: - handleSessionLifecycle tests

    @Test("SessionStart creates a new idle session")
    func testSessionStartCreatesSession() throws {
        let db = try makeDB()
        let payload = HookPayload(
            sessionId: "s-start",
            cwd: "/Users/me/Projects/myapp",
            hookEventName: "SessionStart",
            source: "startup"
        )
        try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

        let session = try db.read { db in try DevSession.fetchOne(db, key: "s-start") }
        #expect(session?.status == .idle)
        #expect(session?.project == "myapp")
        #expect(session?.cwd == "/Users/me/Projects/myapp")
        #expect(session?.endedAt == nil)
    }

    @Test("SessionStart reopens a completed session")
    func testSessionStartReopensCompletedSession() throws {
        let db = try makeDB()
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
        #expect(session?.status == .idle)
        #expect(session?.endedAt == nil)
    }

    @Test("SessionEnd closes an idle session")
    func testSessionEndClosesSession() throws {
        let db = try makeDB()
        try db.write { db in
            var s = DevSession(id: "s-end", project: "myapp", cwd: "/Users/me/Projects/myapp",
                               tool: "claude-code", status: .idle,
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
        #expect(session?.status == .completed)
        #expect(session?.endedAt != nil)
    }

    @Test("SessionStart does not create DevEvent records")
    func testSessionStartDoesNotCreateDevEvent() throws {
        let db = try makeDB()
        let payload = HookPayload(
            sessionId: "s-no-event",
            cwd: "/Users/me/Projects/myapp",
            hookEventName: "SessionStart"
        )
        try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

        let eventCount = try db.read { db in try DevEvent.fetchCount(db) }
        #expect(eventCount == 0, "SessionStart must not create DevEvent records")
    }

    @Test("SessionEnd does not create DevEvent records")
    func testSessionEndDoesNotCreateDevEvent() throws {
        let db = try makeDB()
        try db.write { db in
            var s = DevSession(id: "s-end2", project: "myapp", cwd: nil,
                               tool: "claude-code", status: .idle,
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
        #expect(eventCount == 0, "SessionEnd must not create DevEvent records")
    }

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

    @Test("SessionStart on already-idle session updates tty")
    func sessionStartOnIdleUpdatesTty() throws {
        let db = try makeDB()
        try db.write { db in
            var s = DevSession(
                id: "idle-tty", project: "myapp", cwd: "/Users/dev/myapp",
                tty: "/dev/ttys001", terminalApp: "ghostty",
                tool: "claude-code", status: .idle,
                startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
            )
            try s.insert(db)
        }
        let payload = HookPayload(
            sessionId: "idle-tty",
            cwd: "/Users/dev/myapp",
            hookEventName: "SessionStart",
            tty: "/dev/ttys009",
            terminalApp: "ghostty"
        )
        try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)

        let session = try db.read { db in try DevSession.fetchOne(db, key: "idle-tty") }
        #expect(session?.status == .idle)
        #expect(session?.tty == "/dev/ttys009")
    }

    @Test("SessionStart updates tty and terminalApp on reopen")
    func sessionStartUpdatesTtyOnReopen() throws {
        let db = try makeDB()
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
        #expect(session?.status == .idle)
        #expect(session?.tty == "/dev/ttys007")
        #expect(session?.terminalApp == "Apple_Terminal")
    }

    @Test("promptSubmitted auto-dismisses all prior notifications for the session")
    func promptSubmittedDismissesAllPriorNotifications() throws {
        let db = try makeDB()
        try db.write { db in
            var s = DevSession(
                id: "s1", project: "proj", cwd: "/p", tool: "claude-code",
                status: .idle, startedAt: Date(), endedAt: nil,
                totalTokens: nil, lastEventTitle: nil
            )
            try s.insert(db)
            // A review-tier "ready" card
            var readyCard = DevEvent(
                id: "e-ready", sessionId: "s1", type: .agentStopped,
                title: "Claude is ready", detail: "/p", payload: "{}",
                tokenCount: nil, durationSeconds: nil,
                timestamp: Date(), attentionTier: .review
            )
            try readyCard.insert(db)
            // An action-tier permission card still undismissed
            var permCard = DevEvent(
                id: "e-perm", sessionId: "s1", type: .permissionNeeded,
                title: "Allow bash", detail: "/p", payload: "{}",
                tokenCount: nil, durationSeconds: nil,
                timestamp: Date(), attentionTier: .action
            )
            try permCard.insert(db)
        }

        let event = makeEvent(sessionId: "s1", type: .promptSubmitted, tier: .background)
        try SessionLifecycleService.processEvent(event, in: db)

        let undismissed = try db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.sessionId == "s1")
                .filter(DevEvent.Columns.isDismissed == false)
                .fetchCount(db)
        }
        #expect(undismissed == 0)
    }
}
