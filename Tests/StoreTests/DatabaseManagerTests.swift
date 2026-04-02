import Testing
import Foundation
import GRDB
@testable import Core

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    @Test("Creates tables on first run")
    func createsTables() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        let hasSessions = try dbQueue.read { db in try db.tableExists("sessions") }
        let hasEvents = try dbQueue.read { db in try db.tableExists("events") }
        #expect(hasSessions)
        #expect(hasEvents)
    }

    @Test("WAL mode is enabled")
    func walMode() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let dbPool = try DatabaseManager.openDatabase(at: dbPath)
        let journalMode = try dbPool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(journalMode == "wal")
    }

    @Test("Sessions table has expected columns")
    func sessionsColumns() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        let columns = try dbQueue.read { db in try db.columns(in: "sessions").map(\.name) }
        #expect(columns.contains("id"))
        #expect(columns.contains("project"))
        #expect(columns.contains("tool"))
        #expect(columns.contains("status"))
        #expect(columns.contains("started_at"))
        #expect(columns.contains("ended_at"))
        #expect(columns.contains("total_tokens"))
        #expect(columns.contains("last_event_title"))
    }

    @Test("Events table has expected columns")
    func eventsColumns() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        let columns = try dbQueue.read { db in try db.columns(in: "events").map(\.name) }
        #expect(columns.contains("id"))
        #expect(columns.contains("session_id"))
        #expect(columns.contains("type"))
        #expect(columns.contains("title"))
        #expect(columns.contains("attention_tier"))
    }

    @Test("Migration is idempotent")
    func idempotent() throws {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        try DatabaseManager.migrate(dbQueue)
    }

    @Test("v4 migration adds tty and terminal_app columns")
    func v4MigrationAddsTtyColumns() throws {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        let columns = try db.read { db in
            try db.columns(in: "sessions").map(\.name)
        }
        #expect(columns.contains("tty"))
        #expect(columns.contains("terminal_app"))
    }
}
