// Sources/Core/Models/HookEvent.swift
import Foundation

/// Typed representation of a Claude Code / Cursor hook payload.
/// `stopWindowExpired` is a virtual event injected by HookStreamCoordinator
/// when the 2-second Stop coalescing window elapses without a Notification.
public enum HookEvent: Equatable, Sendable {
    case sessionStart(sessionId: String, cwd: String, tty: String?,
                      terminalApp: String?, tool: String, source: String?)
    case sessionEnd(sessionId: String)
    case userPromptSubmit(sessionId: String)
    case preToolUse(sessionId: String, toolName: String)
    case postToolUse(sessionId: String, toolName: String)
    case notification(sessionId: String, kind: NotificationKind)
    case stop(sessionId: String)
    case stopWindowExpired(sessionId: String)  // virtual — injected by coordinator timer

    public var sessionId: String {
        switch self {
        case .sessionStart(let id, _, _, _, _, _): return id
        case .sessionEnd(let id):                  return id
        case .userPromptSubmit(let id):            return id
        case .preToolUse(let id, _):               return id
        case .postToolUse(let id, _):              return id
        case .notification(let id, _):             return id
        case .stop(let id):                        return id
        case .stopWindowExpired(let id):           return id
        }
    }
}

public enum NotificationKind: Equatable, Sendable {
    case permissionPrompt   // "permission_prompt" or "elicitation_dialog"
    case idlePrompt         // "idle_prompt"
    case other
}

/// Per-session state held in memory by HookStreamCoordinator.
/// Persisted fields (status, cwd, tool) are restored from DB on startup.
public struct SessionMachineState: Equatable, Sendable {
    public var status: SessionStatus
    public var stopWindowActive: Bool   // true = Stop received, 2s window running
    public var dbSessionExists: Bool    // false = no SessionStart received yet
    public var cwd: String?
    public var tool: String             // "claude-code" or "cursor"

    public static let initial = SessionMachineState(
        status: .idle, stopWindowActive: false,
        dbSessionExists: false, cwd: nil, tool: "claude-code"
    )

    public init(status: SessionStatus, stopWindowActive: Bool,
                dbSessionExists: Bool, cwd: String?, tool: String) {
        self.status = status
        self.stopWindowActive = stopWindowActive
        self.dbSessionExists = dbSessionExists
        self.cwd = cwd
        self.tool = tool
    }
}

/// Side-effect instructions produced by SessionStateReducer.
/// HookStreamCoordinator interprets and executes these.
public enum Action: Equatable, Sendable {
    case upsertSession(sessionId: String, status: SessionStatus,
                       cwd: String, tty: String?, terminalApp: String?,
                       tool: String, source: String?)
    case updateSessionStatus(sessionId: String, status: SessionStatus)
    case insertDevEvent(sessionId: String, type: EventType, title: String,
                        cwd: String?, attentionTier: AttentionTier)
    case dismissPriorEvents(sessionId: String)
    case startStopWindow(sessionId: String)
    case cancelStopWindow(sessionId: String)
}
