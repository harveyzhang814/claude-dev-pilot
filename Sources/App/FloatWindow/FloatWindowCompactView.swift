// Sources/App/FloatWindow/FloatWindowCompactView.swift
import SwiftUI
import Core

/// Compact float window content: shows one row per active session with status.
/// Read-only — tap anywhere to expand.
struct FloatWindowCompactView: View {
    let sessions: [DevSession]
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                CompactSessionRow(session: session)
                if session.id != sessions.last?.id {
                    Divider().padding(.horizontal, 12)
                }
            }
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }
}

private struct CompactSessionRow: View {
    let session: DevSession

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(sessionStatusColor(session))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(session.project)
                .font(.callout)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Text(sessionStatusTag(session))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(sessionStatusColor(session))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sessionStatusColor(session).opacity(0.12))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
