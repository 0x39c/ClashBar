import Foundation

@MainActor
extension AppViewModel {
    func effectiveMixedPort() -> Int {
        ResolveEffectiveMixedPortUseCase().execute(
            runtimeMixedPort: mixedPort,
            settingsMixedPort: settingsMixedPort)
    }

    func applyEditableSettingsSnapshotToUI(_ snapshot: EditableSettingsSnapshot) {
        suppressSettingsPersistence = true
        currentMode = snapshot.mode
        settingsAllowLan = snapshot.allowLan
        settingsIPv6 = snapshot.ipv6
        settingsTCPConcurrent = snapshot.tcpConcurrent
        isTunEnabled = snapshot.tunEnabled
        settingsLogLevel = snapshot.logLevel
        settingsPort = snapshot.port
        settingsSocksPort = snapshot.socksPort
        settingsMixedPort = snapshot.mixedPort
        settingsRedirPort = snapshot.redirPort
        settingsTProxyPort = snapshot.tproxyPort
        suppressSettingsPersistence = false
    }

    func applySettingBool(key: String, value: Bool) async {
        await self.patchSingleConfig(key, value: .bool(value))
    }

    func patchSingleConfig(_ key: String, value: ConfigPatchValue) async {
        _ = await self.patchConfigBody(
            [key: value],
            syncingKey: key,
            successMessage: tr("app.settings.saved.single_key", key))
    }

    @discardableResult
    func patchConfigBody(
        _ body: [String: ConfigPatchValue],
        syncingKey: String,
        successMessage: String,
        syncSystemProxyPort: Bool = true) async -> Bool
    {
        guard self.isControllerAccessEnabled || self.isRemoteTarget else { return false }
        self.cancelProxyPortsAutoSave()
        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = nil
        settingsSyncingKey = syncingKey
        settingsErrorMessage = nil
        settingsSavedMessage = nil
        defer { settingsSyncingKey = nil }
        let shouldSyncSystemProxyPort = syncSystemProxyPort && !self.isRemoteTarget && body.keys.contains { key in
            key == "mixed-port" || key == "port" || key == "socks-port"
        }
        let previousSystemProxyPorts =
            await previousSystemProxyPortsForSyncIfNeeded(shouldSync: shouldSyncSystemProxyPort)

        let patchKeysDescription = body.keys.sorted().joined(separator: ", ")
        do {
            ensureAPIClient()
            appendLog(level: "info", message: "PATCH /configs [\(patchKeysDescription)]")
            try await self.settingsPatchTransport().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
            appendLog(level: "info", message: "PATCH /configs succeeded [\(patchKeysDescription)]")
            await refreshFromAPI(includeSlowCalls: false)
            await self.reconcileEditableSettingsWithRuntimeConfig()
            settingsSavedMessage = successMessage
            self.scheduleSettingsFeedbackAutoClearIfNeeded(message: successMessage)
            await self.syncSystemProxyPortIfNeeded(
                shouldSync: shouldSyncSystemProxyPort,
                previousPorts: previousSystemProxyPorts)
            return true
        } catch {
            appendLog(
                level: "error",
                message: "PATCH /configs failed [\(patchKeysDescription)]: \(error.localizedDescription)")
            let message = tr("app.settings.error.save_failed", syncingKey, error.localizedDescription)
            if self.isOverlaySyncingKey(syncingKey) {
                appendLog(level: "error", message: message)
            } else {
                settingsErrorMessage = message
            }
            settingsSavedMessage = nil
            await refreshFromAPI(includeSlowCalls: false)
            await self.reconcileEditableSettingsWithRuntimeConfig()
            return false
        }
    }

    func isOverlaySyncingKey(_ syncingKey: String) -> Bool {
        syncingKey.hasSuffix("-overlay")
    }

    func scheduleDeferredEditableSettingsOverlaySync() {
        self.deferredEditableSettingsOverlayTask?.cancel()
        self.deferredEditableSettingsOverlayTask = Task { [weak self] in
            guard let self else { return }

            _ = await self.syncDeferredEditableSettingsOverlayUntilApplied()
            self.deferredEditableSettingsOverlayTask = nil
        }
    }

    func syncDeferredEditableSettingsOverlayUntilApplied(
        maxAttempts: Int = 120,
        sleepNanoseconds: UInt64 = 250_000_000) async -> Bool
    {
        self.seedDeferredEditableSettingsOverlayIfNeeded()
        guard self.deferredEditableSettingsOverlay != nil else { return true }

        for _ in 0..<maxAttempts {
            if Task.isCancelled { return false }
            guard self.isRuntimeRunning else { return false }
            if await self.applyDeferredEditableSettingsOverlayIfPossible() {
                return true
            }

            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return false
            }
        }

        return false
    }

    func applyDeferredEditableSettingsOverlayIfPossible() async -> Bool {
        guard let deferred = self.deferredEditableSettingsOverlay else { return true }
        guard await self.isCoreAPIReachableForOverlaySync() else { return false }

        let applied = await self.applyEditableSettingsOverlay(
            deferred.snapshot,
            syncingKey: deferred.syncingKey,
            successMessage: "",
            includeMode: deferred.includeMode)
        if applied {
            switch deferred.syncingKey {
            case "app-launch-overlay":
                self.pendingAppLaunchOverlaySettings = nil
            case "config-switch-overlay":
                self.pendingConfigSwitchOverlaySettings = nil
            default:
                break
            }
            self.deferredEditableSettingsOverlay = nil
        }
        return applied
    }

    func applyPendingEditableSettingsOverlayBeforeRefreshIfNeeded() async {
        _ = await self.syncDeferredEditableSettingsOverlayUntilApplied()
    }

    private func seedDeferredEditableSettingsOverlayIfNeeded() {
        guard self.deferredEditableSettingsOverlay == nil else { return }
        if let overlay = self.pendingAppLaunchOverlaySettings {
            self.deferredEditableSettingsOverlay = (snapshot: overlay, syncingKey: "app-launch-overlay", includeMode: false)
            return
        }
        if let overlay = self.pendingConfigSwitchOverlaySettings {
            self.deferredEditableSettingsOverlay = (snapshot: overlay, syncingKey: "config-switch-overlay", includeMode: false)
        }
    }

    private func isCoreAPIReachableForOverlaySync() async -> Bool {
        do {
            let client = try self.clientOrThrow()
            let _: VersionInfo = try await client.request(.version)
            return true
        } catch {
            return false
        }
    }

    func scheduleSettingsFeedbackAutoClearIfNeeded(message: String) {
        guard message.trimmedNonEmpty != nil else { return }

        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if self.settingsSavedMessage == message {
                self.settingsSavedMessage = nil
            }
        }
    }

    func clientOrThrow() throws -> MihomoAPIService {
        if apiClient == nil {
            ensureAPIClient()
        }
        if let apiClient {
            return apiClient
        }
        throw APIError.invalidURL
    }

    func modeSwitchTransport() throws -> MihomoAPITransporting {
        try self.resolvedTransport(override: modeSwitchTransportOverride)
    }

    func settingsPatchTransport() throws -> MihomoAPITransporting {
        try self.resolvedTransport(override: settingsPatchTransportOverride)
    }

    private func previousSystemProxyPortsForSyncIfNeeded(shouldSync: Bool) async -> SystemProxyPorts? {
        guard shouldSync, isSystemProxyEnabled else { return nil }
        do {
            let config: ConfigSnapshot = try await self.clientOrThrow().request(.getConfigs)
            return systemProxyPorts(from: config)
        } catch {
            return currentSystemProxyPortsFromState()
        }
    }

    private func syncSystemProxyPortIfNeeded(shouldSync: Bool, previousPorts: SystemProxyPorts?) async {
        guard shouldSync, isSystemProxyEnabled else { return }

        do {
            let target = try await resolveSystemProxyTargetFromRuntimeConfig()
            try await applySystemProxy(enabled: true, host: target.host, ports: target.ports)
            try await self.applyCurrentSystemProxyExceptionsIfNeeded()
            systemProxyActiveDisplay = buildSystemProxyDisplayString(host: target.host, ports: target.ports)
            appendLog(level: "info", message: tr("log.system_proxy.port_synced", target.ports.primaryPort ?? 0))

            if let previousPorts, previousPorts != target.ports {
                await closeAllConnections()
            }
        } catch {
            appendLog(level: "error", message: tr("log.system_proxy.port_sync_failed", systemProxyErrorMessage(error)))
            await self.refreshSystemProxyHelperStatus()
        }
    }

    func applyBooleanSetting(
        _ keyPath: ReferenceWritableKeyPath<AppViewModel, Bool>,
        configKey: String,
        value: Bool) async
    {
        await self.applySettingBool(key: configKey, value: value)
    }

    func reconcileEditableSettingsWithRuntimeConfig() async {
        do {
            let config = try await self.fetchRuntimeConfigSnapshot()
            let incoming = EditableSettingsSnapshot(config: config)
            self.applyEditableSettingsSnapshotToUI(incoming)
            self.lastSyncedEditableSettings = incoming
            self.persistEditableSettingsSnapshot()
        } catch {
            appendLog(level: "error", message: "Settings reconciliation failed: \(error.localizedDescription)")
        }
    }

    var proxyPortFields: [SettingsPortField] {
        [
            SettingsPortField(key: "port", value: settingsPort),
            SettingsPortField(key: "socks-port", value: settingsSocksPort),
            SettingsPortField(key: "mixed-port", value: settingsMixedPort),
            SettingsPortField(key: "redir-port", value: settingsRedirPort),
            SettingsPortField(key: "tproxy-port", value: settingsTProxyPort),
        ]
    }

    func tunOverlayPatchBody(enabled: Bool) async -> [String: ConfigPatchValue] {
        var tunBody: [String: ConfigPatchValue] = ["enable": .bool(enabled)]
        if enabled {
            let hasConfiguredStack = await self.selectedConfigDeclaresTunStack()
            if !hasConfiguredStack {
                tunBody["stack"] = .string("mixed")
            }
        }
        return tunBody
    }

    func validatedPortPatchBody(
        fields: [SettingsPortField],
        errorMessageKey: String,
        skipEmptyValues: Bool) -> [String: ConfigPatchValue]?
    {
        do {
            return try self.buildPortPatchBodyUseCase.execute(fields: fields, skipEmptyValues: skipEmptyValues)
        } catch let BuildPortPatchBodyError.invalidPort(key) {
            settingsErrorMessage = tr(errorMessageKey, key)
            settingsSavedMessage = nil
            return nil
        } catch {
            settingsErrorMessage = tr(errorMessageKey, "unknown")
            settingsSavedMessage = nil
            return nil
        }
    }

    func syncEditableFields<Value: Equatable>(
        from previous: EditableSettingsSnapshot,
        to incoming: EditableSettingsSnapshot,
        fields: [(ReferenceWritableKeyPath<AppViewModel, Value>, KeyPath<EditableSettingsSnapshot, Value>)])
    {
        for (stateKeyPath, snapshotKeyPath) in fields {
            guard self[keyPath: stateKeyPath] == previous[keyPath: snapshotKeyPath] else { continue }
            self[keyPath: stateKeyPath] = incoming[keyPath: snapshotKeyPath]
        }
    }

    func resolvedTransport(override: MihomoAPITransporting?) throws -> MihomoAPITransporting {
        if let override {
            return override
        }
        return try self.clientOrThrow()
    }
}
