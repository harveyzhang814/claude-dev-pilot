import SwiftUI
import Core

struct SessionGroupView: View {
    let session: DevSession
    let displayName: String
    let events: [DevEvent]
    var onFocusSession: ((DevSession) -> Void)?
    var onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header row — entire row is a tap target for terminal focus
            Button {
                onFocusSession?(session)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(sessionStatusColor(session))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)

                    Text(displayName)
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

                    Text("↗")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 5)
            .accessibilityLabel("\(displayName), \(sessionStatusTag(session)), tap to focus terminal")

            if events.isEmpty {
                Text("Working...")
                    .font(.caption)
                    .italic()
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ForEach(events) { event in
                    EventCardView(
                        event: event,
                        sessionLabel: nil
                    ) {
                        onDismiss(event.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// Internal so tests can reach without crossing module boundary.
func sessionStatusTag(_ session: DevSession) -> String {
    switch session.status {
    case .waiting: return "needs input"
    case .busy:    return "busy"
    case .idle:    return "idle"
    default:
        assertionFailure("SessionGroupView received unexpected status: \(session.status)")
        return "idle"
    }
}

func sessionStatusColor(_ session: DevSession) -> Color {
    switch session.status {
    case .waiting: return Color(red: 1.0, green: 0.271, blue: 0.227)  // #FF453A red
    case .busy:    return Color(red: 1.0, green: 0.624, blue: 0.039)  // #FF9F0A orange
    case .idle:    return Color(red: 0.4, green: 0.8,   blue: 0.4)    // muted green
    default:
        assertionFailure("SessionGroupView received unexpected status: \(session.status)")
        return Color(red: 0.4, green: 0.8, blue: 0.4)
    }
}
