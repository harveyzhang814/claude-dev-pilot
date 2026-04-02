import Foundation
import GRDB

public enum HookLogStore {

    public static func insert(_ log: HookLog, in db: any DatabaseWriter) throws {
        try db.write { db in try log.insert(db) }
    }

    public static func fetchRecent(limit: Int, in db: any DatabaseReader) throws -> [HookLog] {
        try db.read { db in
            try HookLog
                .order(HookLog.Columns.receivedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public static func fetchForSession(_ sessionId: String, in db: any DatabaseReader) throws -> [HookLog] {
        try db.read { db in
            try HookLog
                .filter(HookLog.Columns.sessionId == sessionId)
                .order(HookLog.Columns.receivedAt.desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public static func pruneOlderThan(days: Int, in db: any DatabaseWriter) throws -> Int {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: cutoffDate)
        components.timeZone = TimeZone(identifier: "UTC")
        let cutoff = DatabaseDateComponents(components, format: .YMD_HMSS)
        return try db.write { db in
            try HookLog
                .filter(HookLog.Columns.receivedAt < cutoff.databaseValue)
                .deleteAll(db)
        }
    }
}
