import Foundation
import Testing
@testable import AgentPilot

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

    // MARK: - isHoverLocked persistence

    @Test @MainActor func isHoverLocked_defaultsFalse() {
        UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
        let state = FloatWindowDisplayState()
        #expect(state.isHoverLocked == false)
    }

    @Test @MainActor func isHoverLocked_loadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: "floatWindowHoverLocked")
        let state = FloatWindowDisplayState()
        #expect(state.isHoverLocked == true)
        UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
    }

    @Test @MainActor func isHoverLocked_persistsOnSet() {
        UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
        let state = FloatWindowDisplayState()
        state.isHoverLocked = true
        #expect(UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") == true)
        UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
    }
}
