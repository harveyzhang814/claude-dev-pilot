import Core

public enum FocusResult: Equatable {
    case success
    case notFound
}

/// Routes focus requests to the correct TerminalFocuser based on the session's terminalApp.
/// Catches all errors internally and maps them to FocusResult.notFound.
enum TerminalFocusService {
    static func focus(session: DevSession) -> FocusResult {
        guard let cwd = session.cwd, !cwd.isEmpty else { return .notFound }

        let focuser: TerminalFocuser = switch session.terminalApp {
            case "Apple_Terminal": TerminalAppFocuser()
            default: GhosttyFocuser()  // "ghostty" + nil + unknown → Ghostty
        }

        do {
            let found = try focuser.focus(cwd: cwd, tty: session.tty)
            return found ? .success : .notFound
        } catch {
            return .notFound
        }
    }
}
