import Foundation
import Combine
import GRDB
import Core

@MainActor
@Observable
public final class SessionPanelViewModel {
    public var activeSessions: [DevSession] = []
    public var completedSessions: [DevSession] = []
    public var staleSessions: [DevSession] = []

    private var cancellables: Set<AnyCancellable> = []

    public init() {}

    public func startObserving(db: any DatabaseReader & DatabaseWriter) {
        let observation = ValueObservation.tracking { db in
            try DevSession.order(DevSession.Columns.startedAt.desc).fetchAll(db)
        }

        observation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] sessions in
                    guard let self else { return }
                    self.activeSessions = sessions.filter {
                        $0.status == .idle || $0.status == .busy || $0.status == .waiting
                    }
                    self.completedSessions = sessions.filter {
                        $0.status == .completed
                    }
                    self.staleSessions = sessions.filter {
                        $0.status == .stale
                    }
                }
            )
            .store(in: &cancellables)
    }

    public func stopObserving() {
        cancellables.removeAll()
    }
}
