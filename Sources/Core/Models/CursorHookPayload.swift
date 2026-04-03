import Foundation

/// Raw JSON payload from Cursor hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
/// Cursor sends camelCase hook_event_name values (e.g. "sessionStart", "stop").
public struct CursorHookPayload: Codable, Sendable {
    public let sessionId: String
    public let conversationId: String
    public let hookEventName: String
    public let workspaceRoots: [String]
    public let cursorVersion: String?
    public let model: String?
    public let isBackgroundAgent: Bool?
    public let composerMode: String?
    public let transcriptPath: String?
    // stop-specific
    public let status: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    // beforeShellExecution-specific (declared for forward compat; not handled in MVP)
    public let command: String?

    public enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case conversationId = "conversation_id"
        case hookEventName = "hook_event_name"
        case workspaceRoots = "workspace_roots"
        case cursorVersion = "cursor_version"
        case model
        case isBackgroundAgent = "is_background_agent"
        case composerMode = "composer_mode"
        case transcriptPath = "transcript_path"
        case status
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case command
    }
}
