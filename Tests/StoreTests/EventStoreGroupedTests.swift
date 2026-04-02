import Testing
import Foundation
import GRDB
@testable import Core

@Suite("EventStore.fetchGroupedBySession")
struct EventStoreGroupedTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        return db
    }

    private func makeSession(id: String, status: SessionStatus = .running) -> DevSession {
        DevSession(
            id: id, project: id, cwd: "/Users/dev/\(id)",
            tool: "claude-code", status: status,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
    }

    private func makeEvent(
        id: String, sessionId: String,
        tier: AttentionTier = .review,
        timestamp: Date = Date(),
        isDismissed: Bool = false
    ) -> DevEvent {
        DevEvent(
            id: id, sessionId: sessionId, type: .taskCompleted,
            title: "Test", detail: nil, payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: timestamp, attentionTier: tier,
            isDismissed: isDismissed
        )
    }

    @Test("groups events by session")
    func groupsBySession() throws {
        let db = try makeDB()
        try db.write { dbConn in
            var s1 = makeSession(id: "s1")
            var s2 = makeSession(id: "s2")
            try s1.insert(dbConn)
            try s2.insert(dbConn)
            try makeEvent(id: "e1", sessionId: "s1").insert(dbConn)
            try makeEvent(id: "e2", sessionId: "s1").insert(dbConn)
            try makeEvent(id: "e3", sessionId: "s2").insert(dbConn)
        }
        let grouped = try db.read { dbConn in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1", "s2"], in: dbConn)
        }
        #expect(grouped["s1"]?.count == 2)
        #expect(grouped["s2"]?.count == 1)
    }

    @Test("limits to 5 events per session")
    func limitsToFive() throws {
        let db = try makeDB()
        try db.write { dbConn in
            var s1 = makeSession(id: "s1")
            try s1.insert(dbConn)
            for i in 1...7 {
                try makeEvent(id: "e\(i)", sessionId: "s1").insert(dbConn)
            }
        }
        let grouped = try db.read { dbConn in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: dbConn)
        }
        #expect(grouped["s1"]?.count == 5)
    }

    @Test("excludes background tier events")
    func excludesBackground() throws {
        let db = try makeDB()
        try db.write { dbConn in
            var s1 = makeSession(id: "s1")
            try s1.insert(dbConn)
            try makeEvent(id: "e1", sessionId: "s1", tier: .background).insert(dbConn)
            try makeEvent(id: "e2", sessionId: "s1", tier: .review).insert(dbConn)
        }
        let grouped = try db.read { dbConn in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: dbConn)
        }
        #expect(grouped["s1"]?.count == 1)
        #expect(grouped["s1"]?.first?.id == "e2")
    }

    @Test("excludes dismissed events")
    func excludesDismissed() throws {
        let db = try makeDB()
        try db.write { dbConn in
            var s1 = makeSession(id: "s1")
            try s1.insert(dbConn)
            try makeEvent(id: "e1", sessionId: "s1", isDismissed: true).insert(dbConn)
            try makeEvent(id: "e2", sessionId: "s1", isDismissed: false).insert(dbConn)
        }
        let grouped = try db.read { dbConn in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: dbConn)
        }
        #expect(grouped["s1"]?.count == 1)
        #expect(grouped["s1"]?.first?.id == "e2")
    }

    @Test("excludes events for sessions not in sessionIds")
    func excludesOtherSessions() throws {
        let db = try makeDB()
        var s1 = makeSession(id: "s1")
        var s3 = makeSession(id: "s3")
        try db.write { db in
            try s1.insert(db)
            try s3.insert(db)
            try makeEvent(id: "e1", sessionId: "s1").insert(db)
            try makeEvent(id: "e3", sessionId: "s3").insert(db)
        }
        let grouped = try db.read { db in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: db)
        }
        #expect(grouped["s1"]?.count == 1)
        #expect(grouped["s3"] == nil)
    }

    @Test("returns empty dict for empty sessionIds")
    func emptySessionIds() throws {
        let db = try makeDB()
        let grouped = try db.read { dbConn in
            try EventStore.fetchGroupedBySession(sessionIds: [], in: dbConn)
        }
        #expect(grouped.isEmpty)
    }

    @Test("orders events by timestamp descending within group")
    func orderedDescending() throws {
        let db = try makeDB()
        let now = Date()
        try db.write { dbConn in
            var s1 = makeSession(id: "s1")
            try s1.insert(dbConn)
            try makeEvent(id: "older", sessionId: "s1",
                          timestamp: now.addingTimeInterval(-60)).insert(dbConn)
            try makeEvent(id: "newer", sessionId: "s1",
                          timestamp: now).insert(dbConn)
        }
        let grouped = try db.read { dbConn in
            try EventStore.fetchGroupedBySession(sessionIds: ["s1"], in: dbConn)
        }
        #expect(grouped["s1"]?.first?.id == "newer")
    }
}
