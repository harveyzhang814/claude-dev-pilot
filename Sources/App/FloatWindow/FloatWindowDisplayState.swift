// Sources/App/FloatWindow/FloatWindowDisplayState.swift
import Foundation

/// @Observable bridge owned by FloatWindowController.
/// SwiftUI views read this to know what to render.
@MainActor
@Observable
final class FloatWindowDisplayState {
    enum Mode { case hidden, compact, hover, expanded }
    var mode: Mode = .hidden
    /// Reported by the SwiftUI content via GeometryReader after each render.
    var contentHeight: CGFloat = 0
    /// When true, the window stays in hover state and never auto-collapses to compact.
    var isHoverLocked: Bool = UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") {
        didSet { UserDefaults.standard.set(isHoverLocked, forKey: "floatWindowHoverLocked") }
    }
    /// Set to true by FloatWindowController when the menubar icon is tapped while
    /// the window is already visible. Drives a one-shot border pulse animation in
    /// FloatWindowRootView to hint the user to the window's current location.
    var isBorderPulsing: Bool = false
}
