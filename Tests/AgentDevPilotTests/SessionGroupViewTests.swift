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

    @Test("statusTag for running session")
    func statusTagRunning() {
        #expect(sessionStatusTag(makeSession(status: .running)) == "running")
    }

    @Test("statusTag for waiting session")
    func statusTagWaiting() {
        #expect(sessionStatusTag(makeSession(status: .waiting)) == "needs input")
    }
}
