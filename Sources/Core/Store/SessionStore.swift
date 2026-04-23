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
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET status = ?, ended_at = ? WHERE id = ?",
                           arguments: [status.rawValue, Date(), id])
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
            // Step 1: sessions with no recent DevEvent.
            let candidates = try DevSession.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE status IN ('idle', 'busy', 'waiting')
                AND started_at < ?
                AND id NOT IN (SELECT DISTINCT session_id FROM events WHERE timestamp > ?)
                """, arguments: [cutoff, cutoff])
            guard !candidates.isEmpty else { return [] }

            // Step 2: exclude sessions that have had recent hook activity.
            // hook_logs.received_at is stored as a Double (Date.timeIntervalSinceReferenceDate).
            // Using GRDB's typed filter avoids raw-SQL type-coercion issues.
            let recentLogs = try HookLog
                .filter(HookLog.Columns.receivedAt > cutoffDate)
                .filter(HookLog.Columns.sessionId != "")
                .fetchAll(db)
            let recentSessionIds = Set(recentLogs.map(\.sessionId))

            return candidates.filter { !recentSessionIds.contains($0.id) }
        }
    }

    /// Marks specific sessions as stale (used after TTY-liveness filtering).
    public static func markStale(ids: [String], in db: any DatabaseWriter) throws {
        guard !ids.isEmpty else { return }
        let placeholders = repeatElement("?", count: ids.count).joined(separator: ", ")
        try db.write { db in
            // Pass Date() directly so GRDB stores it as a Double (timeIntervalSinceReferenceDate),
            // which it can decode back correctly. ISO8601DateFormatter produces a "Z"-suffixed
            // string that GRDB cannot decode as Date, breaking future DevSession.fetchOne calls.
            var arguments = StatementArguments([Date()])
            for id in ids { arguments += [id] }
            try db.execute(
                sql: "UPDATE sessions SET status = 'stale', ended_at = ? WHERE id IN (\(placeholders))",
                arguments: arguments
            )
        }
    }

    @discardableResult
    public static func markStaleSessions(olderThan seconds: TimeInterval, in db: any DatabaseWriter) throws -> Int {
        let cutoffDate = Date(timeIntervalSinceNow: -seconds)
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: cutoffDate)
        components.timeZone = TimeZone(identifier: "UTC")
        let cutoff = DatabaseDateComponents(components, format: .YMD_HMSS)
        return try db.write { db in
            try db.execute(sql: """
                UPDATE sessions SET status = 'stale', ended_at = ?
                WHERE status IN ('idle', 'busy', 'waiting')
                AND started_at < ?
                AND id NOT IN (SELECT DISTINCT session_id FROM events WHERE timestamp > ?)
                """, arguments: [Date(), cutoff, cutoff])
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
