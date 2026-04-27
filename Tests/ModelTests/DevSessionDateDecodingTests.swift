import Testing
import Foundation
import GRDB
@testable import Core

@Suite("DevSession date decoding")
struct DevSessionDateDecodingTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        return db
    }

    // Insert a valid session via GRDB (correct Double encoding), then patch ended_at via raw SQL.
    private func insertSession(db: DatabaseQueue, id: String, endedAt: String?) throws {
        var session = DevSession(
            id: id, project: "proj", tool: "claude-code", status: .stale,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
        try db.write { try session.insert($0) }
        if let endedAt {
            try db.write { conn in
                try conn.execute(
                    sql: "UPDATE sessions SET ended_at = ? WHERE id = ?",
                    arguments: [endedAt, id]
                )
            }
        }
    }

    @Test("ended_at stored as Double decodes correctly")
    func decodeDouble() throws {
        let db = try makeDB()
        let expected = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var session = DevSession(
            id: "s1", project: "proj", tool: "claude-code", status: .stale,
            startedAt: Date(), endedAt: expected, totalTokens: nil, lastEventTitle: nil
        )
        try db.write { try session.insert($0) }

        let fetched = try db.read { try DevSession.fetchOne($0, key: "s1") }
        #expect(fetched != nil)
        let delta = abs(fetched!.endedAt!.timeIntervalSinceReferenceDate - expected.timeIntervalSinceReferenceDate)
        #expect(delta < 1)
    }

    @Test("ended_at stored as ISO 8601 text (legacy format) decodes correctly")
    func decodeLegacyISO8601() throws {
        let db = try makeDB()
        try insertSession(db: db, id: "s2", endedAt: "2026-04-27T06:22:26Z")

        let fetched = try db.read { try DevSession.fetchOne($0, key: "s2") }
        #expect(fetched != nil)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: fetched!.endedAt!)
        #expect(components.year == 2026)
        #expect(components.month == 4)
        #expect(components.day == 27)
        #expect(components.hour == 6)
        #expect(components.minute == 22)
        #expect(components.second == 26)
    }

    @Test("ended_at stored as NULL decodes as nil")
    func decodeNull() throws {
        let db = try makeDB()
        try insertSession(db: db, id: "s3", endedAt: nil)

        let fetched = try db.read { try DevSession.fetchOne($0, key: "s3") }
        #expect(fetched != nil)
        #expect(fetched!.endedAt == nil)
    }

    @Test("stale session with legacy ended_at can be fetched and status updated")
    func updateLegacyStaleSession() throws {
        let db = try makeDB()
        try insertSession(db: db, id: "s4", endedAt: "2026-04-27T06:22:26Z")

        // Simulate what updateSessionStatus does when reopening a stale session.
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE sessions SET status = 'busy', ended_at = NULL WHERE id = 's4'"
            )
        }

        let fetched = try db.read { try DevSession.fetchOne($0, key: "s4") }
        #expect(fetched?.status == .busy)
        #expect(fetched?.endedAt == nil)
    }
}
