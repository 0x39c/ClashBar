import Combine
import Foundation

@MainActor
final class StatusBarViewModel: ObservableObject {
    @Published private(set) var display: MenuBarDisplay

    private let session: AppViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(session: AppViewModel) {
        self.session = session
        self.display = Self.display(
            from: session.menuBarDisplaySnapshot,
            pendingCount: session.connectionsStore.largeTrafficCandidates.count)
        Publishers.CombineLatest(
            session.$menuBarDisplaySnapshot.removeDuplicates(),
            session.connectionsStore.$largeTrafficCandidates
                .map(\.count)
                .removeDuplicates())
            .map { display, pendingCount in
                Self.display(from: display, pendingCount: pendingCount)
            }
            .removeDuplicates()
            .sink { [weak self] display in
                self?.display = display
            }
            .store(in: &self.cancellables)
    }

    var connectionsStore: ConnectionsStore {
        self.session.connectionsStore
    }

    func setPanelPresented(_ presented: Bool) {
        self.session.setPanelVisibility(presented)
    }

    private static func display(from base: MenuBarDisplay, pendingCount: Int) -> MenuBarDisplay {
        MenuBarDisplay(
            mode: base.mode,
            symbolName: base.symbolName,
            speedLines: base.speedLines,
            isRunning: base.isRunning,
            pendingCount: pendingCount)
    }
}
