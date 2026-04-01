import SwiftUI
import Core

struct EventCardView: View {
    let event: DevEvent
    var onOpenTerminal: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // Status color bar (3px)
            Rectangle()
                .fill(tierColor)
                .frame(width: 3)

            HStack(spacing: 8) {
                // SF Symbol icon
                Image(systemName: tierIcon)
                    .foregroundColor(tierColor)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    // Project name from detail
                    if let detail = event.detail, !detail.isEmpty {
                        Text(URL(fileURLWithPath: detail).lastPathComponent)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Title
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(2)

                    // Relative timestamp
                    Text(event.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Open Terminal button for action/error events
                if event.attentionTier == .action || event.type == .taskError {
                    Button("Open Terminal") {
                        onOpenTerminal?(event.detail ?? "")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("Open terminal for \(event.title)")
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
        case .action: return .red
        case .review: return .orange
        case .background: return .gray
        }
    }

    private var tierIcon: String {
        switch event.type {
        case .permissionNeeded: return "exclamationmark.triangle.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .taskError: return "xmark.circle.fill"
        case .taskStarted: return "arrow.clockwise"
        }
    }

    private var accessibilityDescription: String {
        let project = event.detail.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let time = RelativeDateTimeFormatter().localizedString(for: event.timestamp, relativeTo: Date())
        return "\(event.title), \(project), \(time)"
    }
}
