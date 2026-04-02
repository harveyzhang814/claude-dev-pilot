import Foundation

public enum EventMapper {

    /// Maps a raw hook payload to an internal DevEvent.
    public static func map(_ payload: HookPayload) -> DevEvent {
        let eventType = inferEventType(payload)
        let tier = attentionTier(for: eventType)
        let rawJson = encodePayload(payload)

        return DevEvent(
            id: UUID().uuidString,
            sessionId: payload.sessionId,
            type: eventType,
            title: payload.title ?? messageTitle(payload.message, project: projectName(from: payload.cwd)),
            detail: payload.cwd,
            payload: rawJson,
            tokenCount: nil,
            durationSeconds: nil,
            timestamp: Date(),
            attentionTier: tier
        )
    }

    // MARK: - EventType Inference

    /// Driven by hookEventName first, then notification_type for Notification hooks.
    public static func inferEventType(_ payload: HookPayload) -> EventType {
        switch payload.hookEventName {
        case "UserPromptSubmit":
            return .promptSubmitted
        case "Stop":
            return .agentStopped
        case "Notification":
            switch payload.notificationType {
            case "permission_prompt", "elicitation_dialog":
                return .permissionNeeded
            case "auth_success":
                return .authSuccess
            default:
                // idle_prompt and unknown types: treat as agentStopped (enters stop window)
                return .agentStopped
            }
        default:
            return .agentStopped
        }
    }

    // MARK: - AttentionTier

    public static func attentionTier(for eventType: EventType) -> AttentionTier {
        switch eventType {
        case .permissionNeeded:
            return .action
        case .promptSubmitted, .agentStopped, .authSuccess:
            return .background
        }
    }

    // MARK: - Helpers

    public static func projectName(from cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func messageTitle(_ message: String, project: String) -> String {
        let prefix = "\(project): "
        let maxLen = 80 - prefix.count
        if message.count <= maxLen {
            return prefix + message
        }
        return prefix + message.prefix(maxLen - 1) + "…"
    }

    private static func encodePayload(_ payload: HookPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
