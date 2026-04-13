import Testing
import Core

@Suite("HookInstallerTests")
struct HookInstallerTests {
    @Test("claudeCodePrompt includes all three hooks")
    func claudeCodePromptIncludesAllThreeHooks() {
        let prompt = HookInstaller.claudeCodePrompt()
        #expect(prompt.contains("Notification"))
        #expect(prompt.contains("SessionStart"))
        #expect(prompt.contains("SessionEnd"))
    }

    @Test("cursorAgentPrompt includes all three hooks")
    func cursorAgentPromptIncludesAllThreeHooks() {
        let prompt = HookInstaller.cursorAgentPrompt()
        #expect(prompt.contains("sessionStart"))
        #expect(prompt.contains("sessionEnd"))
        #expect(prompt.contains("stop"))
    }

    @Test("claudeCodeRemovePrompt includes notify.sh path and all hook event keys")
    func claudeCodeRemovePromptIncludesPathAndHooks() {
        let prompt = HookInstaller.claudeCodeRemovePrompt()
        #expect(!prompt.isEmpty)
        #expect(prompt.contains("notify.sh"))
        #expect(prompt.contains("SessionStart"))
        #expect(prompt.contains("SessionEnd"))
        #expect(prompt.contains("UserPromptSubmit"))
        #expect(prompt.contains("PreToolUse"))
        #expect(prompt.contains("PostToolUse"))
        #expect(prompt.contains("Stop"))
        #expect(prompt.contains("Notification"))
        #expect(prompt.contains("settings.json"))
        // Must be a remove prompt, not an install prompt
        #expect(!prompt.contains("\"matcher\""))
    }

    @Test("cursorAgentRemovePrompt includes cursor-notify.sh path and all hook event keys")
    func cursorAgentRemovePromptIncludesPathAndHooks() {
        let prompt = HookInstaller.cursorAgentRemovePrompt()
        #expect(!prompt.isEmpty)
        #expect(prompt.contains("cursor-notify.sh"))
        #expect(prompt.contains("sessionStart"))
        #expect(prompt.contains("sessionEnd"))
        #expect(prompt.contains("stop"))
        #expect(prompt.contains("hooks.json"))
        // Must be a remove prompt — should not add entries
        #expect(!prompt.contains("\"enabled\""))
    }
}
