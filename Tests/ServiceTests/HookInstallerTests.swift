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
}
