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

            ForEach(events) { event in
                EventCardView(
                    event: event,
                    sessionLabel: nil
                ) {
                    onDismiss(event.id)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    onFocusSession?(session)
                })
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// Internal so tests can reach without crossing module boundary.
func sessionStatusTag(_ session: DevSession) -> String {
    switch session.status {
    case .waiting:   return "Waiting"
    case .busy:      return "Running"
    case .idle:      return "Idle"
    case .stale:     return "Stale"
    case .completed: return "Done"
    }
}

func sessionStatusColor(_ session: DevSession) -> Color {
    switch session.status {
    case .waiting:   return Color(red: 1.0, green: 0.271, blue: 0.227)   // #FF453A red
    case .busy:      return Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158 green
    case .idle:      return Color(red: 1.0, green: 0.624, blue: 0.039)   // #FF9F0A amber
    case .stale:     return Color(red: 0.388, green: 0.388, blue: 0.392) // #636366 gray
    case .completed: return Color(red: 0.388, green: 0.388, blue: 0.392) // #636366 gray
    }
}
