// Sources/App/FloatWindow/FloatWindowDisplayState.swift
import Foundation

/// @Observable bridge owned by FloatWindowController.
/// SwiftUI views read this to know what to render.
@MainActor
@Observable
final class FloatWindowDisplayState {
    enum Mode { case hidden, compact, hover, expanded }
    var mode: Mode = .hidden
}
