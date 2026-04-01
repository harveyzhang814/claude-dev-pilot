import Foundation

enum EventMapper {

    /// Maps a raw hook payload to an internal DevEvent.
    static func map(_ payload: HookPayload) -> DevEvent {
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

    /// Priority: notification_type (deterministic) > text matching (fallback) > .taskCompleted (safe default)
    static func inferEventType(_ payload: HookPayload) -> EventType {
        if let notifType = payload.notificationType {
            switch notifType {
            case "permission_prompt", "elicitation_dialog":
                return .permissionNeeded
            case "idle_prompt":
                return inferFromMessage(payload.message) ?? .taskCompleted
            case "auth_success":
                return .taskStarted
            default:
                break
            }
        }

        return inferFromMessage(payload.message) ?? .taskCompleted
    }

    /// Text-match priority: error > permission > completed.
    private static func inferFromMessage(_ message: String) -> EventType? {
        let lowered = message.lowercased()

        let errorPatterns = ["error", "failed", "failure"]
        if errorPatterns.contains(where: { lowered.contains($0) }) {
            return .taskError
        }

        let permissionPatterns = ["permission", "approve", "allow"]
        if permissionPatterns.contains(where: { lowered.contains($0) }) {
            return .permissionNeeded
        }

        let completionPatterns = ["completed", "finished", "done"]
        if completionPatterns.contains(where: { lowered.contains($0) }) {
            return .taskCompleted
        }

        return nil
    }

    // MARK: - AttentionTier

    static func attentionTier(for eventType: EventType) -> AttentionTier {
        switch eventType {
        case .permissionNeeded:
            return .action
        case .taskCompleted, .taskError:
            return .review
        case .taskStarted:
            return .background
        }
    }

    // MARK: - Helpers

    static func projectName(from cwd: String) -> String {
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
