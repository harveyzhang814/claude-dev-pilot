import Foundation

/// Focuses a Ghostty window by matching its tab's `working directory` to the session's cwd.
/// Uses Ghostty's AppleScript API (proven by the `haunt` tool: github.com/janpaepke/haunt).
struct GhosttyFocuser: TerminalFocuser {
    func focus(cwd: String, tty: String?) throws -> Bool {
        let escapedCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            set matchCount to 0
            repeat with w in every window
                repeat with t in every tab of w
                    set wd to working directory of (focused terminal of t)
                    if wd is equal to "\(escapedCwd)" then
                        select tab t
                        activate window w
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
