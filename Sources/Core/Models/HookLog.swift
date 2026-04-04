import Foundation
import GRDB

public struct HookLog: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public let id: String
    public let receivedAt: Date
    public let hookEventName: String
    public let sessionId: String
    public let notificationType: String?
    public let rawPayload: String
    /// Which HTTP endpoint received this request: "/event" or "/cursor-event".
    /// Nil for rows written before v9 migration.
    public let endpoint: String?

    public static let databaseTableName = "hook_logs"

    public enum Columns: String, ColumnExpression {
        case id
        case receivedAt = "received_at"
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case rawPayload = "raw_payload"
        case endpoint
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case receivedAt = "received_at"
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case rawPayload = "raw_payload"
        case endpoint
    }

    public init(
        id: String = UUID().uuidString,
        receivedAt: Date,
        hookEventName: String,
        sessionId: String,
        notificationType: String?,
        rawPayload: String,
        endpoint: String? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.notificationType = notificationType
        self.rawPayload = rawPayload
        self.endpoint = endpoint
    }
}
