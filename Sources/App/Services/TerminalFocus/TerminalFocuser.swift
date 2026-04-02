import Foundation

/// Abstraction for focusing a specific terminal window.
/// Implementations are per terminal app (Ghostty, Terminal.app, etc.).
protocol TerminalFocuser {
    /// Attempt to focus the terminal window matching the given cwd and tty.
    /// - Returns: `true` if a matching window was found and focused, `false` if not found.
    /// - Throws: `TerminalFocusError` on AppleScript execution failure.
    func focus(cwd: String, tty: String?) throws -> Bool
}

enum TerminalFocusError: Error {
    case appleScriptFailed(String)
}
