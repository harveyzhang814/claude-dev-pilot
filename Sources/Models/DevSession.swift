import Foundation
import GRDB

enum SessionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running, waiting, completed, error, stale
}

struct DevSession: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    let id: String
    var project: String
    var tool: String
    var status: SessionStatus
    var startedAt: Date
    var endedAt: Date?
    var totalTokens: Int?
    var lastEventTitle: String?

    static let databaseTableName = "sessions"

    enum Columns: String, ColumnExpression {
        case id, project, tool, status
        case startedAt = "started_at", endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    enum CodingKeys: String, CodingKey {
        case id, project, tool, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }
}
