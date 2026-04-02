import Foundation
import GRDB

public enum SessionStore {
    public static func fetch(id: String, in db: any DatabaseReader) throws -> DevSession? {
        try db.read { db in try DevSession.fetchOne(db, key: id) }
    }

    public static func fetchActive(in db: any DatabaseReader) throws -> [DevSession] {
        try db.read { db in
            try DevSession
                .filter([SessionStatus.idle.rawValue, SessionStatus.busy.rawValue, SessionStatus.waiting.rawValue].contains(DevSession.Columns.status))
                .order(DevSession.Columns.startedAt.desc).fetchAll(db)
        }
    }

    public static func fetchAll(in db: any DatabaseReader) throws -> [DevSession] {
        try db.read { db in try DevSession.order(DevSession.Columns.startedAt.desc).fetchAll(db) }
    }

    public static func updateStatus(id: String, to status: SessionStatus, in db: any DatabaseWriter) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    public static func close(id: String, status: SessionStatus, in db: any DatabaseWriter) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET status = ?, ended_at = ? WHERE id = ?",
                           arguments: [status.rawValue, now, id])
        }
    }

    public static func reopen(id: String, in db: any DatabaseWriter) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET status = 'idle', ended_at = NULL WHERE id = ?", arguments: [id])
        }
    }

    /// Returns idle/waiting sessions that have had no event activity in the last `seconds`.
    /// Callers can inspect each session's `tty` before deciding whether to mark stale.
    public static func fetchStaleCandidates(olderThan seconds: TimeInterval, in db: any DatabaseReader) throws -> [DevSession] {
        let cutoffDate = Date(timeIntervalSinceNow: -seconds)
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: cutoffDate)
        components.timeZone = TimeZone(identifier: "UTC")
        let cutoff = DatabaseDateComponents(components, format: .YMD_HMSS)
        return try db.read { db in
            try DevSession.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE status IN ('idle', 'busy', 'waiting')
                AND started_at < ?
                AND id NOT IN (SELECT DISTINCT session_id FROM events WHERE timestamp > ?)
                """, arguments: [cutoff, cutoff])
        }
    }

    /// Marks specific sessions as stale (used after TTY-liveness filtering).
    public static func markStale(ids: [String], in db: any DatabaseWriter) throws {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let placeholders = repeatElement("?", count: ids.count).joined(separator: ", ")
        try db.write { db in
            var arguments = StatementArguments([now])
            for id in ids { arguments += [id] }
            try db.execute(
                sql: "UPDATE sessions SET status = 'stale', ended_at = ? WHERE id IN (\(placeholders))",
                arguments: arguments
            )
        }
    }

    @discardableResult
    public static func markStaleSessions(olderThan seconds: TimeInterval, in db: any DatabaseWriter) throws -> Int {
        // GRDB stores dates in "YYYY-MM-DD HH:MM:SS.SSS" format (no T separator).
        // Use the same format for SQL comparison to ensure correct ordering.
        let cutoffDate = Date(timeIntervalSinceNow: -seconds)
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: cutoffDate)
        components.timeZone = TimeZone(identifier: "UTC")
        let cutoff = DatabaseDateComponents(components, format: .YMD_HMSS)
        let now = ISO8601DateFormatter().string(from: Date())
        return try db.write { db in
            try db.execute(sql: """
                UPDATE sessions SET status = 'stale', ended_at = ?
                WHERE status IN ('idle', 'busy', 'waiting')
                AND started_at < ?
                AND id NOT IN (SELECT DISTINCT session_id FROM events WHERE timestamp > ?)
                """, arguments: [now, cutoff, cutoff])
            return db.changesCount
        }
    }

    public static func updateLastEvent(id: String, title: String, tokens: Int?, in db: any DatabaseWriter) throws {
        try db.write { db in
            if let tokens = tokens {
                try db.execute(sql: """
                    UPDATE sessions SET last_event_title = ?, total_tokens = COALESCE(total_tokens, 0) + ? WHERE id = ?
                    """, arguments: [title, tokens, id])
            } else {
                try db.execute(sql: "UPDATE sessions SET last_event_title = ? WHERE id = ?", arguments: [title, id])
            }
        }
    }
}
