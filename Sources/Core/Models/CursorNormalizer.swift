import Foundation

/// Converts a Cursor hook payload into a HookPayload for the shared processing pipeline.
///
/// Normalization rules:
///   - workspace_roots[0] → cwd ("unknown" if array is empty — avoids blank project name in UI)
///   - camelCase hook names → PascalCase (sessionStart → SessionStart, etc.)
///   - injects tool = "cursor" so downstream services tag the session correctly
public enum CursorNormalizer {

    public static func normalize(_ cursor: CursorHookPayload) -> HookPayload {
        HookPayload(
            sessionId: cursor.sessionId,
            cwd: cursor.workspaceRoots.first ?? "unknown",
            hookEventName: normalizeEventName(cursor.hookEventName),
            message: "",
            transcriptPath: cursor.transcriptPath,
            title: nil,
            notificationType: nil,
            permissionMode: nil,
            source: nil,
            model: cursor.model,
            tty: nil,
            terminalApp: nil,
            tool: "cursor"
        )
    }

    // MARK: - Internal (accessible for testing)

    /// Maps Cursor camelCase event names to the PascalCase convention used internally.
    /// Unknown names are passed through unchanged for forward compatibility.
    static func normalizeEventName(_ name: String) -> String {
        switch name {
        case "sessionStart": return "SessionStart"
        case "sessionEnd":   return "SessionEnd"
        case "stop":         return "Stop"
        default:             return name
        }
    }
}
