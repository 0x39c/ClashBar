import Foundation
import SwiftUI

@MainActor
final class ProxyGroupsViewModel: ObservableObject {
    @Published var currentTab: RootTab = .proxy
    @Published private(set) var filteredProxyGroups: [ProxyGroup] = []
    private(set) var hiddenGroupNames: Set<String> = []

    func syncCurrentTab(_ tab: RootTab) {
        self.currentTab = tab
    }

    func updateFilteredProxyGroups(from groups: [ProxyGroup], hideHiddenGroups: Bool, currentMode: CoreMode) {
        var hidden = Set<String>()
        let nextGroups = groups.filter { group in
            guard currentMode == .global || group.name.caseInsensitiveCompare("GLOBAL") != .orderedSame else {
                hidden.insert(group.name)
                return false
            }
            if group.all.isEmpty {
                hidden.insert(group.name)
                return false
            }
            if group.all.count == 1,
               group.all[0].caseInsensitiveCompare("COMPATIBLE") == .orderedSame
            {
                hidden.insert(group.name)
                return false
            }
            if hideHiddenGroups, group.hidden == true {
                hidden.insert(group.name)
                return false
            }
            return true
        }
        self.hiddenGroupNames = hidden
        guard nextGroups != self.filteredProxyGroups else { return }
        self.filteredProxyGroups = nextGroups
    }
}
