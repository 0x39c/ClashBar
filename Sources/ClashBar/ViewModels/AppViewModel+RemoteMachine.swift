import Foundation

@MainActor
extension AppViewModel {
    func switchToMachineTarget(_ target: MachineTarget) async {
        if case let .remote(machine) = target {
            let status = await self.remoteMachineStore.refreshConnectivity(for: machine)
            guard status.isConnected else { return }
        }

        self.remoteMachineStore.selectTarget(target)

        self.cancelPolling()
        self.resetTrafficPresentation()
        self.clearAllLogs()
        self.proxyGroups = []
        self.ruleItems = []
        self.connectionsStore.connections = []
        self.connectionsStore.connectionsCount = 0

        switch target {
        case .local:
            self.appendLog(level: "info", message: self.tr("log.remote.switched_to_local"))
            self.controller = self.localExternalControllerDisplay
            self.controllerSecret = self.localControllerSecret
            self.externalControllerDisplay = self.localExternalControllerDisplay
            self.apiClient = nil

            if let snapshot = self.loadPersistedEditableSettingsSnapshot() {
                self.applyEditableSettingsSnapshotToUI(snapshot)
                self.preserveLocalSettingsOnNextSync = true
                self.pendingAppLaunchOverlaySettings = snapshot
            }
            self.lastSyncedEditableSettings = nil
            if !self.isControllerAccessEnabled {
                self.apiStatus = .unknown
            }

        case let .remote(machine):
            self.appendLog(
                level: "info",
                message: self.tr("log.remote.switched_to_remote", machine.name, machine.displayAddress))
            self.localExternalControllerDisplay = self.controller
            self.localControllerSecret = self.controllerSecret
            self.controller = machine.controllerAddress
            self.controllerSecret = machine.secret
            self.externalControllerDisplay = machine.displayAddress
            self.applyExternalUIConfiguration(hasURL: false, name: nil)
            self.ensureAPIClient()
            self.lastSyncedEditableSettings = nil
            self.preserveLocalSettingsOnNextSync = false
        }

        await self.refreshFromAPI(includeSlowCalls: true)

        if self.lastSyncedEditableSettings == nil {
            _ = try? await self.fetchRuntimeConfigSnapshot()
        }

        if case .local = target {
            await self.applyPendingAppLaunchSettingsOverlayIfNeeded(syncSystemProxyPort: false)
            self.refreshSSIDStrategyState(requestAuthorizationIfNeeded: self.ssidStrategyEnabled)
            await self.applySSIDStrategyForCurrentSSIDIfNeeded()
        }

        // Sync statusText so isRuntimeRunning reflects the active target.
        // Remote targets have no local process, so coreRepository.isRunning is
        // always false; statusText is the only signal menuBarSpeedLines uses.
        switch target {
        case .remote:
            self.statusText = (self.apiStatus == .healthy || self.apiStatus == .degraded)
                ? "Running" : "Stopped"
        case .local:
            if !self.coreRepository.isRunning {
                self.statusText = "Stopped"
            }
        }

        if self.apiStatus == .healthy || self.apiStatus == .degraded {
            self.startPolling()
        }
    }
}
