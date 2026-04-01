import Testing
import Foundation
import GRDB
@testable import Core

@Suite("SessionStore")
struct SessionStoreTests {

    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        return dbQueue
    }

    private func makeSession(
        id: String = "session-1",
        status: SessionStatus = .running,
        startedAt: Date = Date()
    ) -> DevSession {
        DevSession(
            id: id, project: "/Users/dev/project",
            tool: "claude-code", status: status,
            startedAt: startedAt, endedAt: nil,
            totalTokens: nil, lastEventTitle: nil
        )
    }

    @Test("Insert and fetch session")
    func insertAndFetch() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        let fetched = try SessionStore.fetch(id: session.id, in: db)
        #expect(fetched != nil)
        #expect(fetched?.id == session.id)
        #expect(fetched?.project == session.project)
        #expect(fetched?.status == .running)
    }

    @Test("Update session status")
    func updateStatus() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        try SessionStore.updateStatus(id: session.id, to: .waiting, in: db)

        let fetched = try SessionStore.fetch(id: session.id, in: db)
        #expect(fetched?.status == .waiting)
    }

    @Test("Close session sets endedAt")
    func closeSession() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        try SessionStore.close(id: session.id, status: .completed, in: db)

        let fetched = try SessionStore.fetch(id: session.id, in: db)
        #expect(fetched?.status == .completed)
        #expect(fetched?.endedAt != nil)
    }

    @Test("Reopen completed session clears endedAt")
    func reopenSession() throws {
        let db = try makeDB()
        var session = makeSession()
        try db.write { dbConn in try session.insert(dbConn) }

        try SessionStore.close(id: session.id, status: .completed, in: db)
        let closed = try SessionStore.fetch(id: session.id, in: db)
        #expect(closed?.endedAt != nil)

        try SessionStore.reopen(id: session.id, in: db)
        let reopened = try SessionStore.fetch(id: session.id, in: db)
        #expect(reopened?.status == .running)
        #expect(reopened?.endedAt == nil)
    }

    @Test("Mark stale sessions")
    func markStaleSessions() throws {
        let db = try makeDB()
        let oldDate = Date(timeIntervalSinceNow: -7200)  // 2 hours ago
        var oldSession = makeSession(id: "old-session", startedAt: oldDate)
        var newSession = makeSession(id: "new-session", startedAt: Date())
        try db.write { dbConn in
            try oldSession.insert(dbConn)
            try newSession.insert(dbConn)
        }

        let markedCount = try SessionStore.markStaleSessions(olderThan: 3600, in: db)
        #expect(markedCount >= 1)

        let oldFetched = try SessionStore.fetch(id: "old-session", in: db)
        #expect(oldFetched?.status == .stale)

        let newFetched = try SessionStore.fetch(id: "new-session", in: db)
        #expect(newFetched?.status == .running)
    }

    @Test("Fetch active sessions returns only running and waiting")
    func fetchActiveSessions() throws {
        let db = try makeDB()
        var running = makeSession(id: "s-running", status: .running)
        var waiting = makeSession(id: "s-waiting", status: .waiting)
        var completed = makeSession(id: "s-completed", status: .completed)
        var stale = makeSession(id: "s-stale", status: .stale)
        try db.write { dbConn in
            try running.insert(dbConn)
            try waiting.insert(dbConn)
            try completed.insert(dbConn)
            try stale.insert(dbConn)
        }

        let active = try SessionStore.fetchActive(in: db)
        let activeIds = active.map(\.id)
        #expect(activeIds.contains("s-running"))
        #expect(activeIds.contains("s-waiting"))
        #expect(!activeIds.contains("s-completed"))
        #expect(!activeIds.contains("s-stale"))
    }
}
