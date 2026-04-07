// Sources/Core/Services/HookEventClassifier.swift
import Foundation

public enum HookEventClassifier {
    /// Convert a raw HookPayload into a typed HookEvent.
    /// Returns nil for unrecognised hookEventName values (caller silently ignores).
    public static func classify(_ payload: HookPayload) -> HookEvent? {
        let sid = payload.sessionId
        switch payload.hookEventName {
        case "SessionStart":
            return .sessionStart(
                sessionId: sid,
                cwd: payload.cwd,
                tty: payload.tty,
                terminalApp: payload.terminalApp,
                tool: payload.tool ?? "claude-code",
                source: payload.source
            )
        case "SessionEnd":
            return .sessionEnd(sessionId: sid)
        case "UserPromptSubmit":
            return .userPromptSubmit(sessionId: sid)
        case "PreToolUse":
            guard let toolName = payload.toolName else { return nil }
            return .preToolUse(sessionId: sid, toolName: toolName)
        case "PostToolUse":
            guard let toolName = payload.toolName else { return nil }
            return .postToolUse(sessionId: sid, toolName: toolName)
        case "Notification":
            let kind: NotificationKind
            switch payload.notificationType {
            case "permission_prompt", "elicitation_dialog":
                kind = .permissionPrompt
            case "idle_prompt":
                kind = .idlePrompt
            default:
                kind = .other
            }
            return .notification(sessionId: sid, kind: kind)
        case "Stop":
            return .stop(sessionId: sid)
        default:
            return nil
        }
    }
}
