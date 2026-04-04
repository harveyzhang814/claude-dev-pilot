import Foundation

/// Raw JSON payload from Claude Code hooks (stdin).
/// Uses snake_case CodingKeys to match the wire format.
public struct HookPayload: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let message: String        // optional on wire, defaults to ""
    public let transcriptPath: String?
    public let title: String?
    public let notificationType: String?
    public let permissionMode: String?
    public let source: String?        // SessionStart: "startup"|"resume"|"clear"|"compact"
    public let model: String?         // SessionStart: e.g. "claude-sonnet-4-6"
    public let tty: String?           // e.g. "/dev/ttys003", injected by notify.sh
    public let terminalApp: String?   // e.g. "ghostty", "Apple_Terminal"
    public let tool: String?          // nil = "claude-code" (default); "cursor" injected by CursorNormalizer

    public enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case message
        case transcriptPath = "transcript_path"
        case title
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
        case source
        case model
        case tty
        case terminalApp = "terminal_app"
        case tool
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        message = (try c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tty = try c.decodeIfPresent(String.self, forKey: .tty)
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
    }

    public init(
        sessionId: String,
        cwd: String,
        hookEventName: String,
        message: String = "",
        transcriptPath: String? = nil,
        title: String? = nil,
        notificationType: String? = nil,
        permissionMode: String? = nil,
        source: String? = nil,
        model: String? = nil,
        tty: String? = nil,
        terminalApp: String? = nil,
        tool: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.message = message
        self.transcriptPath = transcriptPath
        self.title = title
        self.notificationType = notificationType
        self.permissionMode = permissionMode
        self.source = source
        self.model = model
        self.tty = tty
        self.terminalApp = terminalApp
        self.tool = tool
    }
}
