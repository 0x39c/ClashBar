import Foundation

@MainActor
extension AppViewModel {
    private var configDirectoryMonitorIntervalNanoseconds: UInt64 {
        configRepository.availableConfigs.count <= 1 ? 5_000_000_000 : 1_000_000_000
    }

    private var configDirectoryFullRescanTickLimit: Int {
        12
    }

    func startConfigDirectoryMonitoringIfNeeded(duration: TimeInterval = 600) {
        guard self.ensureConfigDirectoryAvailable() != nil else { return }

        _ = self.configRepository.reloadConfigs()
        self.configFileSignatureSnapshot = self.currentConfigFileSignatureSnapshot()
        self.configDirectoryFullRescanTick = 0
        self.pendingConfigChangeRestart = false
        self.configDirectoryMonitorExpiresAt = Date().addingTimeInterval(duration)

        guard self.configDirectoryMonitorTask == nil else { return }

        self.configDirectoryMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.configDirectoryMonitorIntervalNanoseconds)
                } catch {
                    return
                }
                await self.handleConfigDirectoryChangesIfNeeded()
            }
        }
    }

    func stopConfigDirectoryMonitoring() {
        self.configDirectoryMonitorTask?.cancel()
        self.configDirectoryMonitorTask = nil
        self.configFileSignatureSnapshot = [:]
        self.configDirectoryFullRescanTick = 0
        self.pendingConfigChangeRestart = false
        self.configDirectoryMonitorExpiresAt = nil
    }

    func markInternalConfigFileMutationHandled() {
        guard !self.isRemoteTarget else { return }
        _ = self.ensureConfigDirectoryAvailable()
        self.configFileSignatureSnapshot = self.currentConfigFileSignatureSnapshot()
        self.pendingConfigChangeRestart = false
    }

    private func handleConfigDirectoryChangesIfNeeded() async {
        guard !self.isRemoteTarget else { return }
        if let expiresAt = self.configDirectoryMonitorExpiresAt, Date() >= expiresAt {
            self.stopConfigDirectoryMonitoring()
            return
        }

        if self.pendingConfigChangeRestart,
           self.isRuntimeRunning,
           !self.isCoreActionProcessing
        {
            self.pendingConfigChangeRestart = false
            await self.reloadConfigAfterFileChange()
            return
        }

        guard self.ensureConfigDirectoryAvailable() != nil else { return }

        if await self.handleSingleConfigFileChangeIfPossible() {
            return
        }

        let previousSelectedPath = self.configRepository.selectedConfig?.path
        _ = self.configRepository.reloadConfigs()
        self.configDirectoryFullRescanTick = 0
        let currentSnapshot = self.currentConfigFileSignatureSnapshot()

        if self.configFileSignatureSnapshot.isEmpty {
            self.configFileSignatureSnapshot = currentSnapshot
            return
        }

        let changedFileNames = self.changedConfigFileNames(
            previous: self.configFileSignatureSnapshot,
            current: currentSnapshot)
        guard !changedFileNames.isEmpty else { return }

        self.configFileSignatureSnapshot = currentSnapshot
        let nextSelectedPath = self.syncSelectedConfigStateForMonitoring()
        self.syncConfigDisplayState()

        let involvedSelectedFileNames = Set([
            self.configFileName(fromPath: previousSelectedPath),
            self.configFileName(fromPath: nextSelectedPath),
        ].compactMap(\.self))
        guard !involvedSelectedFileNames.isDisjoint(with: changedFileNames) else { return }
        guard self.isRuntimeRunning else { return }

        if self.isCoreActionProcessing {
            if !self.isTunSyncing {
                self.pendingConfigChangeRestart = true
            }
            return
        }

        await self.reloadConfigAfterFileChange()
    }

    private func handleSingleConfigFileChangeIfPossible() async -> Bool {
        guard self.configRepository.availableConfigs.count <= 1,
              let selectedConfig = self.configRepository.selectedConfig
        else {
            self.configDirectoryFullRescanTick = 0
            return false
        }

        self.configDirectoryFullRescanTick += 1
        if self.configDirectoryFullRescanTick >= self.configDirectoryFullRescanTickLimit {
            self.configDirectoryFullRescanTick = 0
            return false
        }

        guard FileManager.default.fileExists(atPath: selectedConfig.path) else { return false }

        let currentSnapshot = self.currentConfigFileSignatureSnapshot()
        guard !currentSnapshot.isEmpty else { return false }

        if self.configFileSignatureSnapshot.isEmpty {
            self.configFileSignatureSnapshot = currentSnapshot
            return true
        }

        let changedFileNames = self.changedConfigFileNames(
            previous: self.configFileSignatureSnapshot,
            current: currentSnapshot)
        guard !changedFileNames.isEmpty else { return true }

        self.configFileSignatureSnapshot = currentSnapshot
        guard changedFileNames.contains(selectedConfig.lastPathComponent), self.isRuntimeRunning else { return true }

        if self.isCoreActionProcessing {
            if !self.isTunSyncing {
                self.pendingConfigChangeRestart = true
            }
            return true
        }

        await self.reloadConfigAfterFileChange()
        return true
    }

    private func reloadConfigAfterFileChange() async {
        self.appendLog(level: "info", message: self.tr("log.config.changed_restart"))
        cancelProviderRefresh(reason: "config switch requested")
        await self.reloadConfig()
        await self.refreshFromAPI(includeSlowCalls: true)
    }

    private func currentConfigFileSignatureSnapshot() -> [String: String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var snapshot: [String: String] = [:]

        for fileURL in self.configRepository.availableConfigs {
            let values = try? fileURL.resourceValues(forKeys: keys)
            let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? -1
            snapshot[fileURL.lastPathComponent] = "\(modifiedAt)-\(size)"
        }

        return snapshot
    }

    private func changedConfigFileNames(
        previous: [String: String],
        current: [String: String]) -> Set<String>
    {
        let allNames = Set(previous.keys).union(current.keys)
        return Set(allNames.filter { previous[$0] != current[$0] })
    }

    private func configFileName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    @discardableResult
    private func syncSelectedConfigStateForMonitoring() -> String? {
        guard let selected = self.configRepository.selectedConfig else {
            self.selectedConfigName = "-"
            self.defaults.removeObject(forKey: self.selectedConfigKey)
            return nil
        }

        self.selectedConfigName = selected.lastPathComponent
        self.defaults.set(selected.lastPathComponent, forKey: self.selectedConfigKey)
        return selected.path
    }
}
