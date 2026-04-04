import Testing
import Foundation
import Core
@testable import AgentDevPilot

@Suite("SessionGroupView helpers")
struct SessionGroupViewTests {

    private func makeSession(status: SessionStatus) -> DevSession {
        DevSession(
            id: "s1", project: "my-project", cwd: "/Users/dev/my-project",
            tool: "claude-code", status: status,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
    }

    @Test("statusTag for idle session")
    func statusTagIdle() {
        #expect(sessionStatusTag(makeSession(status: .idle)) == "Idle")
    }

    @Test("statusTag for busy session")
    func statusTagBusy() {
        #expect(sessionStatusTag(makeSession(status: .busy)) == "Running")
    }

    @Test("statusTag for waiting session")
    func statusTagWaiting() {
        #expect(sessionStatusTag(makeSession(status: .waiting)) == "Waiting")
    }

    // MARK: - Tool badge

    private func makeSessionWithTool(_ tool: String) -> DevSession {
        DevSession(
            id: "s2", project: "my-project", cwd: "/Users/dev/my-project",
            tool: tool, status: .idle,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
    }

    @Test("toolBadge for cursor session returns 'Cursor'")
    func toolBadgeCursor() {
        #expect(sessionToolBadge(makeSessionWithTool("cursor")) == "Cursor")
    }

    @Test("toolBadge for claude-code session returns 'Claude'")
    func toolBadgeClaudeCode() {
        #expect(sessionToolBadge(makeSessionWithTool("claude-code")) == "Claude")
    }

    @Test("toolBadge for unknown tool returns nil")
    func toolBadgeUnknown() {
        #expect(sessionToolBadge(makeSessionWithTool("some-future-tool")) == nil)
    }
}
