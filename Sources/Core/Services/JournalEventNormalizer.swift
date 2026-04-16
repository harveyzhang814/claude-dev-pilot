import Foundation

public enum JournalEventNormalizer {

    /// Maps a single parsed JSONL entry to a `HookPayload`, or returns nil if
    /// the entry carries no meaningful session-state signal.
    public static func normalize(_ entry: [String: Any]) -> HookPayload? {
        guard
            let type = entry["type"] as? String,
            let sessionId = entry["sessionId"] as? String, !sessionId.isEmpty,
            let cwd = entry["cwd"] as? String
        else { return nil }

        switch type {

        case "user":
            // Only plain-string user messages map to UserPromptSubmit.
            // Tool results (list content) are ignored.
            guard
                let message = entry["message"] as? [String: Any],
                let content = message["content"],
                content is String
            else { return nil }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: "UserPromptSubmit",
                eventSource: .fileWatcher
            )

        case "assistant":
            // Detect AskUserQuestion tool calls → approximate as permissionNeeded.
            guard
                let message = entry["message"] as? [String: Any],
                let contentList = message["content"] as? [[String: Any]],
                contentList.contains(where: {
                    $0["type"] as? String == "tool_use" &&
                    $0["name"] as? String == "AskUserQuestion"
                })
            else { return nil }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: "Notification",
                notificationType: "permissionNeeded",
                eventSource: .fileWatcher
            )

        case "system":
            // stop_hook_summary = session stopped (v2.1.92+, fires even with hookCount=0).
            // The subtype is a top-level field, not nested inside a message dict.
            guard entry["subtype"] as? String == "stop_hook_summary" else { return nil }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: "Stop",
                eventSource: .fileWatcher
            )

        case "progress":
            // Legacy hook recording (v≤2.1.81). Only map events relevant to state machine.
            guard
                let data = entry["data"] as? [String: Any],
                let hookEvent = data["hookEvent"] as? String
            else { return nil }
            let mapped: String
            switch hookEvent {
            case "SessionStart":     mapped = "SessionStart"
            case "Stop":             mapped = "Stop"
            case "UserPromptSubmit": mapped = "UserPromptSubmit"
            default:                 return nil
            }
            return HookPayload(
                sessionId: sessionId,
                cwd: cwd,
                hookEventName: mapped,
                eventSource: .fileWatcher
            )

        default:
            return nil
        }
    }
}
