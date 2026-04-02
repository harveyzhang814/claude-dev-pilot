import Foundation
import GRDB
import Core
import Server

@MainActor
@Observable
public final class AppState {
    // Database
    private(set) var db: DatabasePool?

    // Auth
    private(set) var authToken: String = ""

    // ViewModels
    let popoverViewModel = PopoverViewModel()
    let sessionPanelViewModel = SessionPanelViewModel()

    // NotificationBatcher
    private var batcher: NotificationBatcher?

    // State
    var serverRunning: Bool = false
    var notificationsAuthorized: Bool = false
    var showOnboarding: Bool = false
    var serverError: String? = nil

    // Stale timer
    private var staleTimer: Timer?
    private var lastPruneDate: Date = .distantPast

    // Server task
    private var serverTask: Task<Void, Never>?

    public init() {}

    public func start() async {
        // Set up database
        do {
            let dbPool = try DatabaseManager.openDatabase(at: DatabaseManager.defaultDatabasePath)
            self.db = dbPool

            // Start observing
            popoverViewModel.startObserving(db: dbPool)
            sessionPanelViewModel.startObserving(db: dbPool)
        } catch {
            serverError = "Database error: \(error.localizedDescription)"
            return
        }

        // Auth token
        do {
            authToken = try AuthTokenService.ensureToken()
        } catch {
            serverError = "Token error: \(error.localizedDescription)"
            return
        }

        // Install hook script (idempotent — no-op if already up to date)
        try? HookInstaller.installScript()

        // Request notification permission
        notificationsAuthorized = await NotificationService.shared.requestPermission()

        // Set up NotificationBatcher
        let notifService = NotificationService.shared
        let soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
        batcher = NotificationBatcher(onNotification: { notification in
            Task { @MainActor in
                notifService.post(notification, playSound: soundEnabled)
            }
        })

        // Check onboarding
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        showOnboarding = !hasCompletedOnboarding

        // Start stale session timer (60s)
        staleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markStaleSessions()
                self?.lazyPrune()
            }
        }

        // Start HTTP server
        await startServer()
    }

    private func startServer() async {
        guard let dbPool = db else { return }
        let token = authToken
        let port = UserDefaults.standard.integer(forKey: "serverPort")
        let resolvedPort = port > 0 ? port : 9876
        let batcher = self.batcher
        let stopWindow = StopWindowService(db: dbPool)

        serverTask = Task.detached(priority: .background) {
            do {
                let app = EventServer.start(
                    db: dbPool,
                    authToken: token,
                    port: resolvedPort,
                    stopWindow: stopWindow,
                    onEvent: { event in
                        batcher?.submit(event)
                        batcher?.flush()
                    }
                )
                try await app.run()
            } catch {
                await MainActor.run { [weak self] in
                    self?.serverError = "Server error: \(error.localizedDescription)"
                    self?.serverRunning = false
                }
            }
        }

        serverRunning = true
    }

    private func markStaleSessions() {
        guard let db else { return }
        do {
            let candidates = try SessionStore.fetchStaleCandidates(olderThan: 30 * 60, in: db)
            let toMark = candidates.filter { session in
                // If we have TTY info, only mark stale when the TTY is no longer alive.
                // This prevents killing a session that is still running a long task but
                // happens to be quiet (no hook events) for > 30 minutes.
                guard let tty = session.tty, !tty.isEmpty else { return true }
                return !isTTYAlive(tty)
            }
            try SessionStore.markStale(ids: toMark.map(\.id), in: db)
        } catch {
            print("[AgentDevPilot] markStaleSessions failed: \(error)")
        }
    }

    /// Returns true if any process still holds the given TTY device open.
    private func isTTYAlive(_ tty: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", tty]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public func lazyPrune() {
        guard let db = db else { return }
        let now = Date()
        // Only prune once per day
        if now.timeIntervalSince(lastPruneDate) < 86400 { return }
        lastPruneDate = now
        let days = UserDefaults.standard.integer(forKey: "retentionDays")
        let retentionDays = days > 0 ? days : 30
        try? EventStore.pruneOlderThan(days: retentionDays, in: db)
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        showOnboarding = false
    }
}
