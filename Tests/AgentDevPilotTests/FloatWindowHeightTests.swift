import Testing
@testable import AgentDevPilot

struct FloatWindowHeightTests {
    @Test func clampedExpandedHeight_normalValue() {
        #expect(FloatWindowController.clampedExpandedHeight(300) == 300)
    }

    @Test func clampedExpandedHeight_atMin() {
        #expect(FloatWindowController.clampedExpandedHeight(150) == 150)
    }

    @Test func clampedExpandedHeight_belowMin() {
        #expect(FloatWindowController.clampedExpandedHeight(50) == 150)
    }

    @Test func clampedExpandedHeight_atMax() {
        #expect(FloatWindowController.clampedExpandedHeight(480) == 480)
    }

    @Test func clampedExpandedHeight_aboveMax() {
        #expect(FloatWindowController.clampedExpandedHeight(600) == 480)
    }

    @Test func clampedExpandedHeight_zero_fallsBackToMax() {
        // h == 0 means SwiftUI hasn't finished layout yet; fall back to max.
        #expect(FloatWindowController.clampedExpandedHeight(0) == 480)
    }

    @Test func clampedExpandedHeight_negative_fallsBackToMax() {
        #expect(FloatWindowController.clampedExpandedHeight(-10) == 480)
    }
}
