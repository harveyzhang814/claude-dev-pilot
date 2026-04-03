import Foundation

/// Raw JSON payload from Cursor hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
/// Cursor sends camelCase hook_event_name values (e.g. "sessionStart", "stop").
public struct CursorHookPayload: Codable, Sendable {
    public let sessionId: String
    public let conversationId: String
    public let hookEventName: String
    /// workspace_roots may be absent in older Cursor versions or background agents; defaults to [].
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

// MARK: - Decodable (extension preserves the synthesized memberwise init)

extension CursorHookPayload {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        // Default to [] if key is absent (forward compat with older Cursor versions)
        workspaceRoots = (try? c.decode([String].self, forKey: .workspaceRoots)) ?? []
        cursorVersion = try c.decodeIfPresent(String.self, forKey: .cursorVersion)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        isBackgroundAgent = try c.decodeIfPresent(Bool.self, forKey: .isBackgroundAgent)
        composerMode = try c.decodeIfPresent(String.self, forKey: .composerMode)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens)
        command = try c.decodeIfPresent(String.self, forKey: .command)
    }
}
