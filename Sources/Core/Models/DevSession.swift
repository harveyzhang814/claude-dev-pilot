import Foundation
import GRDB

public enum SessionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running, waiting, completed, error, stale
}

public struct DevSession: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public let id: String
    public var project: String    // lastPathComponent of cwd
    public var cwd: String?       // full path (added v3)
    public var tool: String
    public var status: SessionStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var totalTokens: Int?
    public var lastEventTitle: String?

    public static let databaseTableName = "sessions"

    public enum Columns: String, ColumnExpression {
        case id, project, cwd, tool, status
        case startedAt = "started_at", endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    public enum CodingKeys: String, CodingKey {
        case id, project, cwd, tool, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    public init(
        id: String,
        project: String,
        cwd: String? = nil,
        tool: String,
        status: SessionStatus,
        startedAt: Date,
        endedAt: Date?,
        totalTokens: Int?,
        lastEventTitle: String?
    ) {
        self.id = id
        self.project = project
        self.cwd = cwd
        self.tool = tool
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalTokens = totalTokens
        self.lastEventTitle = lastEventTitle
    }
}
