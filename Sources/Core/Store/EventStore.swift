import Foundation
import GRDB

public enum EventStore {
    public static func insert(_ event: DevEvent, in db: any DatabaseWriter) throws {
        try db.write { db in try event.insert(db) }
    }

    public static func fetch(id: String, in db: any DatabaseReader) throws -> DevEvent? {
        try db.read { db in try DevEvent.fetchOne(db, key: id) }
    }

    public static func fetchRecent(limit: Int, in db: any DatabaseReader) throws -> [DevEvent] {
        try db.read { db in
            try DevEvent.order(DevEvent.Columns.timestamp.desc).limit(limit).fetchAll(db)
        }
    }

    public static func fetchForSession(_ sessionId: String, in db: any DatabaseReader) throws -> [DevEvent] {
        try db.read { db in
            try DevEvent.filter(DevEvent.Columns.sessionId == sessionId)
                .order(DevEvent.Columns.timestamp.desc).fetchAll(db)
        }
    }

    public static func countActionTier(in db: any DatabaseReader) throws -> Int {
        try db.read { db in
            try DevEvent.filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue).fetchCount(db)
        }
    }

    public static func dismiss(id: String, in db: any DatabaseWriter) throws {
        try db.write { db in
            guard let event = try DevEvent.fetchOne(db, key: id) else { return }

            try DevEvent
                .filter(DevEvent.Columns.id == id)
                .updateAll(db, DevEvent.Columns.isDismissed.set(to: true))

            // If this was an action-tier event, check whether the session still has
            // any undismissed action events. If not, move it back to running so the
            // header status reflects reality.
            if event.attentionTier == .action {
                let remaining = try DevEvent
                    .filter(DevEvent.Columns.sessionId == event.sessionId)
                    .filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue)
                    .filter(DevEvent.Columns.isDismissed == false)
                    .fetchCount(db)
                if remaining == 0 {
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'running' WHERE id = ? AND status = 'waiting'",
                        arguments: [event.sessionId]
                    )
                }
            }
        }
    }

    /// Undismissed, non-background events grouped by session ID.
    /// Results within each group are timestamp-descending, capped at `limit`.
    /// Designed for use inside a `ValueObservation.tracking` closure.
    public static func fetchGroupedBySession(
        sessionIds: [String],
        limit: Int = 5,
        in db: Database
    ) throws -> [String: [DevEvent]] {
        // Always read events table so GRDB tracks it in ValueObservation
        guard !sessionIds.isEmpty else {
            _ = try DevEvent.fetchCount(db)  // register table access
            return [:]
        }
        let events = try DevEvent
            .filter(sessionIds.contains(DevEvent.Columns.sessionId))
            .filter(DevEvent.Columns.attentionTier != AttentionTier.background.rawValue)
            .filter(DevEvent.Columns.isDismissed == false)
            .order(DevEvent.Columns.timestamp.desc)
            .fetchAll(db)
        return Dictionary(grouping: events, by: \.sessionId)
            .mapValues { Array($0.prefix(limit)) }
    }

    @discardableResult
    public static func pruneOlderThan(days: Int, in db: any DatabaseWriter) throws -> Int {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        // GRDB stores dates in "YYYY-MM-DD HH:MM:SS.SSS" format; use DatabaseDateComponents for correct comparison.
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: cutoffDate)
        components.timeZone = TimeZone(identifier: "UTC")
        let cutoff = DatabaseDateComponents(components, format: .YMD_HMSS)
        return try db.write { db in
            try DevEvent.filter(DevEvent.Columns.timestamp < cutoff.databaseValue).deleteAll(db)
        }
    }
}
