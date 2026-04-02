import SwiftUI
import Core

struct SessionGroupView: View {
    let session: DevSession
    let events: [DevEvent]
    var onOpenTerminal: ((String) -> Void)?
    var onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header row
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

                Text(sessionStatusTag(session))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sessionStatusColor(session))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sessionStatusColor(session).opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 5)

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
                        sessionLabel: nil,
                        onOpenTerminal: onOpenTerminal
                    ) {
                        onDismiss(event.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.project), \(sessionStatusTag(session))")
    }
}

// Internal so tests can reach without crossing module boundary.
func sessionStatusTag(_ session: DevSession) -> String {
    session.status == .waiting ? "needs input" : "running"
}

func sessionStatusColor(_ session: DevSession) -> Color {
    session.status == .waiting
        ? Color(red: 1.0,  green: 0.271, blue: 0.227)  // #FF453A
        : Color(red: 1.0,  green: 0.624, blue: 0.039)  // #FF9F0A
}
