import Foundation
import Combine
import GRDB
import Core

@MainActor
@Observable
public final class PopoverViewModel {
    public var actionEvents: [DevEvent] = []
    public var recentEvents: [DevEvent] = []
    public var actionCount: Int = 0

    private var cancellables: Set<AnyCancellable> = []

    public init() {}

    public func startObserving(db: any DatabaseReader & DatabaseWriter) {
        // Observe action-tier events
        let actionObservation = ValueObservation.tracking { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(50)
                .fetchAll(db)
        }

        actionObservation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] events in
                    guard let self else { return }
                    self.actionEvents = events
                    self.actionCount = events.count
                }
            )
            .store(in: &cancellables)

        // Observe non-background events (action + review tiers)
        let recentObservation = ValueObservation.tracking { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier != AttentionTier.background.rawValue)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(100)
                .fetchAll(db)
        }

        recentObservation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] events in
                    self?.recentEvents = events
                }
            )
            .store(in: &cancellables)
    }

    public func resetBadge() {
        actionCount = 0
    }

    public func stopObserving() {
        cancellables.removeAll()
    }
}
