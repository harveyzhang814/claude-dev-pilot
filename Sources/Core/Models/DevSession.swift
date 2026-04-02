import Foundation
import GRDB

public enum SessionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case idle       // active session, no task running
    case busy       // Claude is executing (UserPromptSubmit received)
    case waiting    // needs user intervention
    case completed  // session ended via SessionEnd hook
    case stale      // inactive too long (no activity for 30 min)
}

public struct DevSession: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public let id: String
    public var project: String    // lastPathComponent of cwd
    public var customName: String?    // set via `claude /rename` or `-n` flag
    public var cwd: String?       // full path (added v3)
    public var tty: String?           // TTY device path, e.g. "/dev/ttys003"
    public var terminalApp: String?   // "ghostty" or "Apple_Terminal"
    public var tool: String
    public var status: SessionStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var totalTokens: Int?
    public var lastEventTitle: String?

    /// Display name: custom name if set, otherwise the cwd-derived project name.
    /// Deduplication (appending tty suffix) for sessions sharing the same project name
    /// is handled at the call site (PopoverViewModel).
    public var displayName: String { customName ?? project }

    public static let databaseTableName = "sessions"

    public enum Columns: String, ColumnExpression {
        case id, project, customName = "custom_name", cwd, tty
        case terminalApp = "terminal_app"
        case tool, status
        case startedAt = "started_at", endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    public enum CodingKeys: String, CodingKey {
        case id, project, customName = "custom_name", cwd, tty
        case terminalApp = "terminal_app"
        case tool, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case totalTokens = "total_tokens"
        case lastEventTitle = "last_event_title"
    }

    public init(
        id: String,
        project: String,
        customName: String? = nil,
        cwd: String? = nil,
        tty: String? = nil,
        terminalApp: String? = nil,
        tool: String,
        status: SessionStatus,
        startedAt: Date,
        endedAt: Date?,
        totalTokens: Int?,
        lastEventTitle: String?
    ) {
        self.id = id
        self.project = project
        self.customName = customName
        self.cwd = cwd
        self.tty = tty
        self.terminalApp = terminalApp
        self.tool = tool
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalTokens = totalTokens
        self.lastEventTitle = lastEventTitle
    }
}
