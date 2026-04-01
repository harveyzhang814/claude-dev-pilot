import Foundation

/// Raw JSON payload from Claude Code hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
struct HookPayload: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let hookEventName: String
    let message: String
    let transcriptPath: String?
    let title: String?
    let notificationType: String?
    let permissionMode: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case message
        case transcriptPath = "transcript_path"
        case title
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
    }
}
