import Foundation
import GRDB

enum DatabaseManager {

    static func openDatabase(at path: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        let dbPool = try DatabasePool(path: path, configuration: config)
        try migrate(dbPool)
        return dbPool
    }

    static func openInMemoryDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try migrate(dbQueue)
        return dbQueue
    }

    static func migrate(_ db: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "sessions", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("project", .text).notNull()
                t.column("tool", .text).notNull().defaults(to: "claude-code")
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("started_at", .text).notNull()
                t.column("ended_at", .text)
                t.column("total_tokens", .integer)
                t.column("last_event_title", .text)
            }

            try db.create(table: "events", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("payload", .text).notNull()
                t.column("token_count", .integer)
                t.column("duration_seconds", .double)
                t.column("timestamp", .text).notNull()
                t.column("attention_tier", .text).notNull().defaults(to: "review")
            }

            try db.create(index: "idx_events_session", on: "events", columns: ["session_id"], ifNotExists: true)
            try db.create(index: "idx_events_timestamp", on: "events", columns: ["timestamp"], ifNotExists: true)
            try db.create(index: "idx_sessions_status", on: "sessions", columns: ["status"], ifNotExists: true)
        }

        try migrator.migrate(db)
    }

    static var defaultDatabasePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AgentDevPilot")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("db.sqlite").path
    }
}
