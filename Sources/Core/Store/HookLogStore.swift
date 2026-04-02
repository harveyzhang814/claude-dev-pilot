import Foundation
import GRDB

public enum HookLogStore {
    public static func insert(_ log: HookLog, in db: any DatabaseWriter) throws {
        try db.write { db in try log.insert(db) }
    }

    public static func fetchForSession(_ sessionId: String, in db: any DatabaseReader) throws -> [HookLog] {
        try db.read { db in
            try HookLog
                .filter(HookLog.Columns.sessionId == sessionId)
                .order(HookLog.Columns.receivedAt.desc)
                .fetchAll(db)
        }
    }
}
