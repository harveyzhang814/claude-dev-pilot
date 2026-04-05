import SwiftUI
import Core

struct OnboardingView: View {
    @State private var currentStep: Int = 0
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var scriptInstalled: Bool = false
    @State private var scriptError: String? = nil
    @State private var cursorScriptInstalled: Bool = false
    @State private var cursorScriptError: String? = nil
    var onComplete: (() -> Void)?

    enum ConnectionStatus: Equatable {
        case idle, testing, success, failure(String)
    }

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
            Label("Step 1: Install Hook Script", systemImage: "1.circle.fill")
                .font(.headline)

            // Script install status
            HStack(spacing: 8) {
                if scriptInstalled {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Hook script installed at ~/.agent-dev-pilot/hooks/notify.sh")
                        .foregroundColor(.green)
                } else if let err = scriptError {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(err).foregroundColor(.red)
                } else {
                    Image(systemName: "circle").foregroundColor(.secondary)
                    Text("Not yet installed").foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            if !scriptInstalled {
                Button {
                    installScript()
                } label: {
                    Label("Install Hook Script", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            // Claude Code settings prompt
            Text("Step 1b: Register with Claude Code")
                .font(.subheadline).fontWeight(.medium)

            Text("Paste this into any Claude Code session to safely register the hook using Claude's own settings mechanism:")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(HookInstaller.claudeCodePrompt())
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(height: 120)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(HookInstaller.claudeCodePrompt(), forType: .string)
            } label: {
                Label("Copy Prompt", systemImage: "doc.on.doc")
            }
            .accessibilityLabel("Copy Claude Code hook install prompt")

            Divider()

            // Cursor integration
            Text("Step 1c: Set Up Cursor Integration (Optional)")
                .font(.subheadline).fontWeight(.medium)

            HStack(spacing: 8) {
                if cursorScriptInstalled {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Cursor hook script installed at ~/.agent-dev-pilot/hooks/cursor-notify.sh")
                        .foregroundColor(.green)
                } else if let err = cursorScriptError {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(err).foregroundColor(.red)
                } else {
                    Image(systemName: "circle").foregroundColor(.secondary)
                    Text("Not yet installed").foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            if !cursorScriptInstalled {
                Button {
                    installCursorScript()
                } label: {
                    Label("Install Cursor Hook Script", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Paste this into Cursor Agent to register the sessionStart, sessionEnd, and stop hooks:")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(HookInstaller.cursorAgentPrompt())
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(height: 120)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(HookInstaller.cursorAgentPrompt(), forType: .string)
            } label: {
                Label("Copy Cursor Prompt", systemImage: "doc.on.doc")
            }
            .accessibilityLabel("Copy Cursor hook install prompt")
        }
        .onAppear { checkScriptStatus() }
    }

    private func checkScriptStatus() {
        scriptInstalled = HookInstaller.isScriptInstalled()
        cursorScriptInstalled = HookInstaller.isCursorScriptInstalled()
    }

    private func installScript() {
        do {
            try HookInstaller.installScript()
            scriptInstalled = true
            scriptError = nil
        } catch {
            scriptError = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installCursorScript() {
        do {
            try HookInstaller.installCursorScript()
            cursorScriptInstalled = true
            cursorScriptError = nil
        } catch {
            cursorScriptError = "Install failed: \(error.localizedDescription)"
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
