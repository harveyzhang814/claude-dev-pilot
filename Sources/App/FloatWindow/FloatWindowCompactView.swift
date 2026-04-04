// Sources/App/FloatWindow/FloatWindowCompactView.swift
import SwiftUI
import Core

/// Compact float window: a small dot-per-session status pill.
/// Dots for waiting sessions pulse slowly to draw peripheral attention.
struct FloatWindowCompactView: View {
    let sessions: [DevSession]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(sessions.prefix(5))) { session in
                StatusDot(color: sessionStatusColor(session),
                          isPulsing: session.status == .waiting)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

private struct StatusDot: View {
    let color: Color
    let isPulsing: Bool
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isPulsing ? (animating ? 0.2 : 1.0) : 1.0)
            .onAppear {
                guard isPulsing else { return }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}
