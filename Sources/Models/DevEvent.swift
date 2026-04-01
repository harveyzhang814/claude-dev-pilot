import Foundation
import GRDB

enum EventType: String, Codable, Sendable, DatabaseValueConvertible {
    case taskCompleted
    case permissionNeeded
    case taskError
    case taskStarted
}

enum AttentionTier: String, Codable, Sendable, DatabaseValueConvertible {
    case action      // permissionNeeded → red badge, native notification
    case review      // taskCompleted, taskError → popover list, gray badge
    case background  // taskStarted → session panel only
}

struct DevEvent: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    let id: String              // UUID string
    let sessionId: String
    let type: EventType
    let title: String
    let detail: String?
    let payload: String         // raw JSON text for debug view
    let tokenCount: Int?
    let durationSeconds: Double?
    let timestamp: Date
    let attentionTier: AttentionTier

    static let databaseTableName = "events"

    enum Columns: String, ColumnExpression {
        case id, sessionId = "session_id", type, title, detail
        case payload, tokenCount = "token_count"
        case durationSeconds = "duration_seconds"
        case timestamp, attentionTier = "attention_tier"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case type, title, detail, payload
        case tokenCount = "token_count"
        case durationSeconds = "duration_seconds"
        case timestamp
        case attentionTier = "attention_tier"
    }
}
