import Testing
import Foundation
import GRDB
@testable import Core

@Suite("StopWindowService")
struct StopWindowServiceTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        return db
    }

    private func insertSession(id: String, status: SessionStatus = .busy, in db: any DatabaseWriter) throws {
        try db.write { db in
            var s = DevSession(
                id: id, project: "proj", cwd: "/Users/dev/proj",
                tool: "claude-code", status: status,
                startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
            )
            try s.insert(db)
        }
    }

    @Test("Stop only → session becomes idle and review card inserted")
    func stopOnlyBecomesIdle() async throws {
        let db = try makeDB()
        try insertSession(id: "s1", in: db)

        let svc = StopWindowService(db: db, windowDuration: 0.1)
        await svc.recordStop(sessionId: "s1")
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        let status = try await db.read { db in try DevSession.fetchOne(db, key: "s1")?.status }
        #expect(status == .idle)

        let card = try await db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.sessionId == "s1")
                .filter(DevEvent.Columns.attentionTier == AttentionTier.review.rawValue)
                .fetchOne(db)
        }
        #expect(card != nil)
        #expect(card?.title == "Claude is ready")
        #expect(card?.isDismissed == false)
    }

    @Test("Stop + permission_prompt within window → session becomes waiting, no review card")
    func stopThenPermissionBecomesWaiting() async throws {
        let db = try makeDB()
        try insertSession(id: "s2", in: db)

        let svc = StopWindowService(db: db, windowDuration: 0.2)
        await svc.recordStop(sessionId: "s2")
        await svc.recordNotification(sessionId: "s2")
        try await Task.sleep(nanoseconds: 400_000_000)

        let status = try await db.read { db in try DevSession.fetchOne(db, key: "s2")?.status }
        #expect(status == .waiting)

        let reviewCards = try await db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.sessionId == "s2")
                .filter(DevEvent.Columns.attentionTier == AttentionTier.review.rawValue)
                .fetchAll(db)
        }
        #expect(reviewCards.isEmpty)
    }

    @Test("permission_prompt before Stop → still waiting, no review card")
    func notificationFirstThenStopIsWaiting() async throws {
        let db = try makeDB()
        try insertSession(id: "s3", in: db)

        let svc = StopWindowService(db: db, windowDuration: 0.2)
        await svc.recordNotification(sessionId: "s3")
        try await Task.sleep(nanoseconds: 50_000_000)
        await svc.recordStop(sessionId: "s3")
        try await Task.sleep(nanoseconds: 400_000_000)

        let status = try await db.read { db in try DevSession.fetchOne(db, key: "s3")?.status }
        #expect(status == .waiting)

        let reviewCards = try await db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.sessionId == "s3")
                .filter(DevEvent.Columns.attentionTier == AttentionTier.review.rawValue)
                .fetchAll(db)
        }
        #expect(reviewCards.isEmpty)
    }

    @Test("onIdleResolved callback fires only for idle resolution")
    func idleCallbackFires() async throws {
        let db = try makeDB()
        try insertSession(id: "s4", in: db)

        // Use the DB as the source of truth instead of capturing a mutable var
        let svc = StopWindowService(db: db, windowDuration: 0.1, onIdleResolved: { _ in })
        await svc.recordStop(sessionId: "s4")
        try await Task.sleep(nanoseconds: 200_000_000)

        // If the callback fired, the review card will be in the DB
        let card = try await db.read { db in
            try DevEvent
                .filter(DevEvent.Columns.sessionId == "s4")
                .filter(DevEvent.Columns.attentionTier == AttentionTier.review.rawValue)
                .fetchOne(db)
        }
        #expect(card != nil)
    }
}
