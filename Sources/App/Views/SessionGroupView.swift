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
            SessionHeaderRow(
                session: session,
                displayName: displayName,
                events: events,
                onFocusSession: onFocusSession
            )

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

// MARK: - Session Header Row

private struct SessionHeaderRow: View {
    let session: DevSession
    let displayName: String
    let events: [DevEvent]
    var onFocusSession: ((DevSession) -> Void)?

    @State private var isHovered = false
    @State private var pulseOpacity: Double = 1.0

    private var rowBackground: Color {
        switch session.status {
        case .waiting:
            return Color(red: 1, green: 0.271, blue: 0.227).opacity(0.09)
        case .idle:
            return Color(red: 1, green: 0.624, blue: 0.039).opacity(0.07)
        case .busy, .stale, .completed:
            return .clear
        }
    }

    private var lastActivityDate: Date {
        events.map(\.timestamp).max() ?? session.startedAt
    }

    var body: some View {
        Button {
            onFocusSession?(session)
        } label: {
            HStack(spacing: 8) {
                // Status dot with pulse for waiting
                ZStack {
                    Circle()
                        .fill(sessionStatusColor(session))
                        .frame(width: 8, height: 8)

                    if session.status == .waiting {
                        Circle()
                            .fill(sessionStatusColor(session))
                            .frame(width: 8, height: 8)
                            .opacity(pulseOpacity)
                    }
                }
                .frame(width: 8, height: 8)

                // Name + tool badge as a semantic unit
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let badge = sessionToolBadge(session) {
                        Text(badge)
                            .font(.system(size: 11))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(sessionStatusTag(session))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sessionStatusColor(session))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sessionStatusColor(session).opacity(0.12))
                    .clipShape(Capsule())

                Text(relativeTimeString(from: lastActivityDate))
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                ZStack {
                    rowBackground
                    if isHovered { Color.white.opacity(0.04) }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            if session.status == .waiting {
                withAnimation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                ) {
                    pulseOpacity = 0.3
                }
            }
        }
        .accessibilityLabel("\(displayName), \(sessionStatusTag(session)), tap to focus terminal")
        .padding(.bottom, events.isEmpty ? 0 : 4)
    }
}

// MARK: - Helpers

private func relativeTimeString(from date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h"
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

/// Returns a tool badge string for non-Claude Code sessions.
/// Returns nil for "claude-code" (no badge = clean default).
func sessionToolBadge(_ session: DevSession) -> String? {
    switch session.tool {
    case "cursor":      return "Cursor"
    case "claude-code": return "Claude"
    default:            return nil
    }
}
