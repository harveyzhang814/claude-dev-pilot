import Foundation
import GRDB

public struct HookLog: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public let id: String
    public let receivedAt: Date
    public let hookEventName: String
    public let sessionId: String
    public let notificationType: String?
    public let rawPayload: String

    public static let databaseTableName = "hook_logs"

    public enum Columns: String, ColumnExpression {
        case id
        case receivedAt = "received_at"
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case rawPayload = "raw_payload"
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case receivedAt = "received_at"
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case rawPayload = "raw_payload"
    }

    public init(
        id: String,
        receivedAt: Date,
        hookEventName: String,
        sessionId: String,
        notificationType: String?,
        rawPayload: String
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.notificationType = notificationType
        self.rawPayload = rawPayload
    }
}
