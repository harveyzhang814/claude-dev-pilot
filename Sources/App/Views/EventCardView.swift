import SwiftUI
import Core

struct EventCardView: View {
    let event: DevEvent
    var sessionLabel: String? = nil
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // Status color bar (3px)
            Rectangle()
                .fill(tierColor)
                .frame(width: 3)

            HStack(alignment: .top, spacing: 8) {
                // SF Symbol icon
                Image(systemName: tierIcon)
                    .foregroundColor(tierColor)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    // Project name — only shown when non-empty, truncated by SwiftUI
                    if !event.project.isEmpty {
                        HStack(spacing: 4) {
                            Text(event.project)
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let label = sessionLabel {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(label)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    // Event title
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(2)
                }

                Spacer()

                // Relative timestamp — right-aligned
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(relativeTime(event.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
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

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        switch seconds {
        case ..<60:    return "just now"
        case ..<3600:  return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default:       return "\(seconds / 86400)d ago"
        }
    }

    private var accessibilityDescription: String {
        let time = RelativeDateTimeFormatter().localizedString(for: event.timestamp, relativeTo: Date())
        return "\(event.title), \(event.project), \(time)"
    }
}
