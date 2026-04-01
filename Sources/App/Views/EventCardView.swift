import SwiftUI
import Core

struct EventCardView: View {
    let event: DevEvent
    var onOpenTerminal: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false

    var body: some View {
        ZStack(alignment: .trailing) {
            // Red "Done" background revealed on swipe
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red)
                .overlay(
                    Image(systemName: "checkmark")
                        .foregroundColor(.white)
                        .padding(.trailing, 16),
                    alignment: .trailing
                )

            cardContent
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onChanged { value in
                            guard !isDismissing else { return }
                            // Only allow leftward drag
                            let x = min(0, value.translation.width)
                            dragOffset = x
                        }
                        .onEnded { value in
                            guard !isDismissing else { return }
                            if value.translation.width < -80 {
                                // Commit dismiss
                                isDismissing = true
                                withAnimation(.easeIn(duration: 0.2)) {
                                    dragOffset = -360
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    onDismiss?()
                                }
                            } else {
                                withAnimation(.spring(response: 0.3)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
    }

    private var cardContent: some View {
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
                        Text(event.project)
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // Event title
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(2)

                    // Action button below title for permission/error events
                    if event.attentionTier == .action || event.type == .taskError {
                        Button("Open Terminal") {
                            onOpenTerminal?(event.detail ?? "")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("Open terminal for \(event.title)")
                        .padding(.top, 2)
                    }
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
