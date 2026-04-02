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
        let db = try makeDB()
        let event = makeEvent(type: .taskStarted)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session != nil)
        #expect(session?.status == .running)
        #expect(session?.id == event.sessionId)
    }

    @Test("permissionNeeded event sets status to waiting")
    func permissionNeededSetsWaiting() throws {
        let db = try makeDB()
        let event = makeEvent(type: .permissionNeeded, tier: .action)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .waiting)
    }

    @Test("taskCompleted event closes session")
    func taskCompletedClosesSession() throws {
        let db = try makeDB()
        let event = makeEvent(type: .taskCompleted)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .completed)
        #expect(session?.endedAt != nil)
    }

    @Test("taskError event closes session")
    func taskErrorClosesSession() throws {
        let db = try makeDB()
        let event = makeEvent(type: .taskError, tier: .review)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .error)
        #expect(session?.endedAt != nil)
    }

    @Test("Event for completed session reopens it")
    func eventReopensCompletedSession() throws {
        let db = try makeDB()
        // First: create and complete the session
        let completedEvent = makeEvent(type: .taskCompleted)
        try SessionLifecycleService.processEvent(completedEvent, in: db)

        let closed = try SessionStore.fetch(id: completedEvent.sessionId, in: db)
        #expect(closed?.status == .completed)

        // Then: send a new event for the same session
        let newEvent = makeEvent(sessionId: completedEvent.sessionId, type: .taskStarted)
        try SessionLifecycleService.processEvent(newEvent, in: db)

        let reopened = try SessionStore.fetch(id: completedEvent.sessionId, in: db)
        #expect(reopened?.status == .running)
        #expect(reopened?.endedAt == nil)
    }

    @Test("Subsequent event updates lastEventTitle")
    func subsequentEventUpdatesTitle() throws {
        let db = try makeDB()
        let firstEvent = makeEvent(type: .taskStarted)
        try SessionLifecycleService.processEvent(firstEvent, in: db)

        let secondEvent = DevEvent(
            id: UUID().uuidString,
            sessionId: firstEvent.sessionId,
            type: .taskStarted,
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

    @Test("SessionStart creates a new running session")
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
        #expect(session?.status == .running)
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
        #expect(session?.status == .running)
        #expect(session?.endedAt == nil)
    }

    @Test("SessionEnd closes a running session")
    func testSessionEndClosesSession() throws {
        let db = try makeDB()
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
}
