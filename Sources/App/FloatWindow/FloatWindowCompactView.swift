// Sources/App/FloatWindow/FloatWindowCompactView.swift
import SwiftUI
import Core

/// Compact float window content: shows up to 5 unread action/review events.
/// Read-only — no dismiss gesture. Tap anywhere to expand.
struct FloatWindowCompactView: View {
    let events: [DevEvent]
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.prefix(5))) { event in
                CompactEventRow(event: event)
                if event.id != events.prefix(5).last?.id {
                    Divider().padding(.leading, 13)
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

private struct CompactEventRow: View {
    let event: DevEvent

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tierColor)
                .frame(width: 3)
            HStack(spacing: 8) {
                Image(systemName: tierIcon)
                    .foregroundColor(tierColor)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if !event.project.isEmpty {
                        Text(event.project)
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var tierColor: Color {
        switch event.attentionTier {
        case .action:     return .red
        case .review:     return Color(red: 0.4, green: 0.8, blue: 0.4)
        case .background: return .gray
        }
    }

    private var tierIcon: String {
        switch event.type {
        case .permissionNeeded: return "exclamationmark.triangle.fill"
        case .promptSubmitted:  return "arrow.up.circle"
        case .agentStopped:     return "checkmark.circle.fill"
        case .authSuccess:      return "lock.open.fill"
        }
    }
}
