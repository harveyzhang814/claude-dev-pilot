import Foundation
import GRDB

public enum SessionStore {
    public static func fetch(id: String, in db: any DatabaseReader) throws -> DevSession? {
        try db.read { db in try DevSession.fetchOne(db, key: id) }
    }

    public static func fetchActive(in db: any DatabaseReader) throws -> [DevSession] {
        try db.read { db in
            try DevSession
                .filter([SessionStatus.running.rawValue, SessionStatus.waiting.rawValue].contains(DevSession.Columns.status))
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
            try db.execute(sql: "UPDATE sessions SET status = 'running', ended_at = NULL WHERE id = ?", arguments: [id])
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
        return try db.write { db in
            try db.execute(sql: """
                UPDATE sessions SET status = 'stale'
                WHERE status IN ('running', 'waiting')
                AND started_at < ?
                AND id NOT IN (SELECT DISTINCT session_id FROM events WHERE timestamp > ?)
                """, arguments: [cutoff, cutoff])
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
