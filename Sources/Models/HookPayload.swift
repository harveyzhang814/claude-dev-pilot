import Foundation

/// Raw JSON payload from Claude Code hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
public struct HookPayload: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let message: String
    public let transcriptPath: String?
    public let title: String?
    public let notificationType: String?
    public let permissionMode: String?

    public enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case message
        case transcriptPath = "transcript_path"
        case title
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
    }

    public init(
        sessionId: String,
        cwd: String,
        hookEventName: String,
        message: String,
        transcriptPath: String? = nil,
        title: String? = nil,
        notificationType: String? = nil,
        permissionMode: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.message = message
        self.transcriptPath = transcriptPath
        self.title = title
        self.notificationType = notificationType
        self.permissionMode = permissionMode
    }
}
