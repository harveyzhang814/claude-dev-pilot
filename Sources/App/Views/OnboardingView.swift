import SwiftUI

struct OnboardingView: View {
    @State private var currentStep: Int = 0
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var authToken: String = ""
    var onComplete: (() -> Void)?

    enum ConnectionStatus: Equatable {
        case idle, testing, success, failure(String)
    }

    private let hooksJSON = """
    {
      "hooks": {
        "PostToolUse": [{
          "matcher": ".*",
          "hooks": [{
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:9876/event -H 'Authorization: Bearer $AGENT_DEV_PILOT_TOKEN' -H 'Content-Type: application/json' -d @-"
          }]
        }]
      }
    }
    """

    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("Welcome to Agent Dev Pilot")
                .font(.title2)
                .fontWeight(.semibold)

            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<3) { step in
                    Circle()
                        .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            // Step content
            Group {
                switch currentStep {
                case 0:
                    stepOne
                case 1:
                    stepTwo
                case 2:
                    stepThree
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                    .keyboardShortcut(.escape)
                }

                Spacer()

                if currentStep < 2 {
                    Button(currentStep == 1 ? "Test Connection" : "Next") {
                        if currentStep == 1 {
                            testConnection()
                        } else {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 1 && connectionStatus == .testing)
                } else {
                    Button("Get Started") {
                        onComplete?()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .frame(width: 480)
    }

    // MARK: - Steps

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Step 1: Configure Claude Hooks", systemImage: "1.circle.fill")
                .font(.headline)

            Text("Add this JSON to your Claude configuration to enable event forwarding:")
                .foregroundColor(.secondary)

            ScrollView {
                Text(hooksJSON)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(height: 140)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hooksJSON, forType: .string)
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc")
            }
            .accessibilityLabel("Copy hooks JSON to clipboard")
        }
    }

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Step 2: Test Connection", systemImage: "2.circle.fill")
                .font(.headline)

            Text("Let's verify that the server is running and can receive events.")
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                switch connectionStatus {
                case .idle:
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                    Text("Click 'Test Connection' to verify")
                        .foregroundColor(.secondary)
                case .testing:
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Testing...")
                        .foregroundColor(.secondary)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Connection successful!")
                        .foregroundColor(.green)
                case .failure(let message):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(message)
                        .foregroundColor(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private var stepThree: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Label("Step 3: All Set!", systemImage: "3.circle.fill")
                .font(.headline)

            Text("Agent Dev Pilot is ready. It will monitor your Claude sessions and notify you when action is needed.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Connection Test

    private func testConnection() {
        connectionStatus = .testing
        Task {
            do {
                // Test /health endpoint
                let healthURL = URL(string: "http://127.0.0.1:9876/health")!
                let (_, healthResponse) = try await URLSession.shared.data(from: healthURL)
                guard let http = healthResponse as? HTTPURLResponse, http.statusCode == 200 else {
                    await MainActor.run {
                        connectionStatus = .failure("Health check failed — is the server running?")
                    }
                    return
                }

                await MainActor.run {
                    connectionStatus = .success
                    // Auto-advance after a short delay
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        currentStep = 2
                    }
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .failure("Could not connect: \(error.localizedDescription)")
                }
            }
        }
    }
}
