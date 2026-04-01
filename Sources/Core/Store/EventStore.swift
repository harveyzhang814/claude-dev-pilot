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
            try db.execute(
                sql: "UPDATE events SET is_dismissed = 1 WHERE id = ?",
                arguments: [id]
            )
        }
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
