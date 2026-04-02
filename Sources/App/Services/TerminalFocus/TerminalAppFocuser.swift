import Foundation

/// Focuses a Terminal.app tab by matching its `tty` property.
/// Terminal.app's AppleScript dictionary exposes `tty` on each tab natively.
struct TerminalAppFocuser: TerminalFocuser {
    func focus(cwd: String, tty: String?) throws -> Bool {
        guard let tty else { return false }  // tty required for Terminal.app matching
        let escapedTty = tty
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            set matchCount to 0
            repeat with w in every window
                repeat with t in every tab of w
                    if tty of t is equal to "\(escapedTty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        set matchCount to 1
                        exit repeat
                    end if
                end repeat
                if matchCount > 0 then exit repeat
            end repeat
            return matchCount
        end tell
        """
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw TerminalFocusError.appleScriptFailed("Failed to create NSAppleScript")
        }
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            throw TerminalFocusError.appleScriptFailed(errorDict.description)
        }
        return result.int32Value > 0
    }
}
