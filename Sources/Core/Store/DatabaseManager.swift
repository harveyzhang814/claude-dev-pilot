import Foundation
import GRDB

public enum DatabaseManager {

    public static func openDatabase(at path: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        let dbPool = try DatabasePool(path: path, configuration: config)
        try migrate(dbPool)
        return dbPool
    }

    public static func openInMemoryDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try migrate(dbQueue)
        return dbQueue
    }

    public static func migrate(_ db: any DatabaseWriter) throws {
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

        migrator.registerMigration("v2_dismissed") { db in
            try db.alter(table: "events") { t in
                t.add(column: "is_dismissed", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3_session_cwd") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "cwd", .text)
            }
        }

        migrator.registerMigration("v4_session_terminal") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "tty", .text)
                t.add(column: "terminal_app", .text)
            }
        }

        migrator.registerMigration("v5_session_status") { db in
            // Migrate status values to new state machine:
            //   running → idle  (we don't know if it was actually busy; idle is safe)
            //   error   → completed  (terminal state, merge into completed)
            try db.execute(sql: "UPDATE sessions SET status = 'idle' WHERE status = 'running'")
            try db.execute(sql: "UPDATE sessions SET status = 'completed' WHERE status = 'error'")
        }

        try migrator.migrate(db)
    }

    public static var defaultDatabasePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AgentDevPilot")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("db.sqlite").path
    }
}
