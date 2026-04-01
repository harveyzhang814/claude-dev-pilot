import Testing
import Foundation
import GRDB
@testable import Core

@Suite("EventStore")
struct EventStoreTests {

    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        return dbQueue
    }

    private func makeSession(id: String = "session-1") -> DevSession {
        DevSession(
            id: id, project: "/Users/dev/project",
            tool: "claude-code", status: .running,
            startedAt: Date(), endedAt: nil,
            totalTokens: nil, lastEventTitle: nil
        )
    }

    private func makeEvent(
        id: String = UUID().uuidString,
        sessionId: String = "session-1",
        type: EventType = .taskCompleted,
        tier: AttentionTier = .review,
        timestamp: Date = Date()
    ) -> DevEvent {
        DevEvent(
            id: id, sessionId: sessionId, type: type,
            title: "Test event", detail: "/Users/dev/project", payload: "{}",
            tokenCount: 10, durationSeconds: 1.5,
            timestamp: timestamp, attentionTier: tier
        )
    }

    @Test("Insert and fetch event")
    func insertAndFetch() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        let event = makeEvent()
        try EventStore.insert(event, in: db)

        let fetched = try EventStore.fetch(id: event.id, in: db)
        #expect(fetched != nil)
        #expect(fetched?.id == event.id)
        #expect(fetched?.sessionId == event.sessionId)
        #expect(fetched?.type == event.type)
    }

    @Test("Fetch recent events ordered by timestamp descending")
    func fetchRecent() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        let now = Date()
        let older = now.addingTimeInterval(-3600)
        let newer = now.addingTimeInterval(3600)

        let e1 = makeEvent(id: "e1", timestamp: older)
        let e2 = makeEvent(id: "e2", timestamp: now)
        let e3 = makeEvent(id: "e3", timestamp: newer)

        try EventStore.insert(e1, in: db)
        try EventStore.insert(e2, in: db)
        try EventStore.insert(e3, in: db)

        let recent = try EventStore.fetchRecent(limit: 2, in: db)
        #expect(recent.count == 2)
        #expect(recent[0].id == "e3")
        #expect(recent[1].id == "e2")
    }

    @Test("Prune events older than retention days")
    func pruneOldEvents() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        let now = Date()
        let old = now.addingTimeInterval(-8 * 24 * 3600)  // 8 days ago

        let oldEvent = makeEvent(id: "old-event", timestamp: old)
        let newEvent = makeEvent(id: "new-event", timestamp: now)

        try EventStore.insert(oldEvent, in: db)
        try EventStore.insert(newEvent, in: db)

        let pruned = try EventStore.pruneOlderThan(days: 7, in: db)
        #expect(pruned == 1)

        let remaining = try EventStore.fetchRecent(limit: 10, in: db)
        #expect(remaining.count == 1)
        #expect(remaining[0].id == "new-event")
    }

    @Test("Count action-tier events")
    func countActionTier() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        let actionEvent1 = makeEvent(id: "a1", type: .permissionNeeded, tier: .action)
        let actionEvent2 = makeEvent(id: "a2", type: .permissionNeeded, tier: .action)
        let reviewEvent = makeEvent(id: "r1", type: .taskCompleted, tier: .review)

        try EventStore.insert(actionEvent1, in: db)
        try EventStore.insert(actionEvent2, in: db)
        try EventStore.insert(reviewEvent, in: db)

        let count = try EventStore.countActionTier(in: db)
        #expect(count == 2)
    }

    @Test("Fetch events for a specific session")
    func fetchForSession() throws {
        let db = try makeDB()
        var session1 = makeSession(id: "session-1")
        var session2 = makeSession(id: "session-2")
        try db.write { dbConn in
            try session1.insert(dbConn)
            try session2.insert(dbConn)
        }

        let e1 = makeEvent(id: "e1", sessionId: "session-1")
        let e2 = makeEvent(id: "e2", sessionId: "session-2")
        let e3 = makeEvent(id: "e3", sessionId: "session-1")

        try EventStore.insert(e1, in: db)
        try EventStore.insert(e2, in: db)
        try EventStore.insert(e3, in: db)

        let forSession1 = try EventStore.fetchForSession("session-1", in: db)
        #expect(forSession1.count == 2)
        let ids = forSession1.map(\.id)
        #expect(ids.contains("e1"))
        #expect(ids.contains("e3"))
    }
}
