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

        migrator.registerMigration("v6_event_types") { db in
            // Migrate legacy event types removed in the idle/busy/waiting state machine redesign:
            //   taskStarted   → promptSubmitted  (session became busy)
            //   taskCompleted → agentStopped     (task ended cleanly)
            //   taskError     → agentStopped     (task ended with error)
            // Migrate legacy attention tiers:
            //   review → background  (taskCompleted/taskError were review; now all non-action are background)
            try db.execute(sql: "UPDATE events SET type = 'promptSubmitted' WHERE type = 'taskStarted'")
            try db.execute(sql: "UPDATE events SET type = 'agentStopped' WHERE type IN ('taskCompleted', 'taskError')")
            try db.execute(sql: "UPDATE events SET attention_tier = 'background' WHERE attention_tier = 'review'")
        }

        migrator.registerMigration("v7_session_custom_name") { db in
            // Remove orphan events whose session_id has no matching session row.
            // Such rows can exist if test data was accidentally inserted directly into
            // the production database, bypassing GRDB's FK enforcement. They cause the
            // deferred foreign-key check at transaction commit to fail, preventing the
            // migration from completing and the app from starting.
            try db.execute(sql: "DELETE FROM events WHERE session_id NOT IN (SELECT id FROM sessions)")
            try db.alter(table: "sessions") { t in
                t.add(column: "custom_name", .text)
            }
        }

        migrator.registerMigration("v8_hook_logs") { db in
            try db.create(table: "hook_logs", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("received_at", .text).notNull()
                t.column("hook_event_name", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("notification_type", .text)
                t.column("raw_payload", .text).notNull()
            }
            try db.create(index: "idx_hook_logs_session", on: "hook_logs",
                          columns: ["session_id"], ifNotExists: true)
            try db.create(index: "idx_hook_logs_received_at", on: "hook_logs",
                          columns: ["received_at"], ifNotExists: true)
        }

        migrator.registerMigration("v9_hook_log_endpoint") { db in
            try db.alter(table: "hook_logs") { t in
                t.add(column: "endpoint", .text)
            }
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
