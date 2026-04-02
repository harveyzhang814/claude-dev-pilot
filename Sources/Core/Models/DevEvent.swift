import Foundation
import GRDB

public enum EventType: String, Codable, Sendable, DatabaseValueConvertible {
    case promptSubmitted   // UserPromptSubmit hook → session goes busy
    case permissionNeeded  // permission_prompt / elicitation_dialog → session goes waiting
    case agentStopped      // Stop hook or idle_prompt → window resolves to idle/waiting
    case authSuccess       // auth_success notification → no state change
}

public enum AttentionTier: String, Codable, Sendable, DatabaseValueConvertible {
    case action      // permissionNeeded → red badge, native notification
    case review      // idle-ready → green card in popover, no badge
    case background  // all others → session panel only, no popover card
}

public struct DevEvent: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public let id: String              // UUID string
    public let sessionId: String
    public let type: EventType
    public let title: String
    public let detail: String?
    public let payload: String         // raw JSON text for debug view
    public let tokenCount: Int?
    public let durationSeconds: Double?
    public let timestamp: Date
    public let attentionTier: AttentionTier
    public let isDismissed: Bool

    /// Project name derived from the `detail` working-directory path.
    public var project: String {
        guard let cwd = detail, !cwd.isEmpty else { return "" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public static let databaseTableName = "events"

    public enum Columns: String, ColumnExpression {
        case id, sessionId = "session_id", type, title, detail
        case payload, tokenCount = "token_count"
        case durationSeconds = "duration_seconds"
        case timestamp, attentionTier = "attention_tier"
        case isDismissed = "is_dismissed"
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case type, title, detail, payload
        case tokenCount = "token_count"
        case durationSeconds = "duration_seconds"
        case timestamp
        case attentionTier = "attention_tier"
        case isDismissed = "is_dismissed"
    }

    public init(
        id: String,
        sessionId: String,
        type: EventType,
        title: String,
        detail: String?,
        payload: String,
        tokenCount: Int?,
        durationSeconds: Double?,
        timestamp: Date,
        attentionTier: AttentionTier,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.type = type
        self.title = title
        self.detail = detail
        self.payload = payload
        self.tokenCount = tokenCount
        self.durationSeconds = durationSeconds
        self.timestamp = timestamp
        self.attentionTier = attentionTier
        self.isDismissed = isDismissed
    }
}
