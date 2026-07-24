import Foundation

struct WebDAVConfigSyncFeedback: Equatable {
    enum Kind: Equatable {
        case success
        case error
    }

    let kind: Kind
    let message: String
}

@MainActor
extension AppViewModel {
    private static let webDAVConfigSyncSettingsKey = "clashbar.webdav.config_sync.settings"

    func upgradeCore() async {
        guard !self.isCoreUpgradeInFlight else { return }

        self.coreUpgradeFeedbackClearTask?.cancel()
        self.coreUpgradeFeedbackClearTask = nil
        self.coreUpgradeState = .running

        do {
            let response: CoreUpgradeResponse = try await self.clientOrThrow().request(.upgradeCore)
            self.applyCoreUpgradeState(self.coreUpgradeState(from: response))
        } catch {
            self.applyCoreUpgradeState(self.coreUpgradeState(from: error))
        }
    }

    func flushFakeIPCache() async {
        await runNoResponseAction(tr("log.action_name.flush_fakeip_cache")) {
            try await self.clientOrThrow().requestNoResponse(.flushFakeIPCache)
        }
    }

    func flushDNSCache() async {
        await runNoResponseAction(tr("log.action_name.flush_dns_cache")) {
            try await self.clientOrThrow().requestNoResponse(.flushDNSCache)
        }
    }

    func refreshActiveTab() async {
        await refreshForActivatedTab(activeMenuTab)
    }

    var canSyncSelectedConfigWithWebDAV: Bool {
        !self.isRemoteTarget &&
            self.configRepository.selectedConfig != nil &&
            self.webDAVConfigSyncSettings.endpoint.trimmedNonEmpty != nil &&
            self.webDAVConfigSyncInFlight == nil
    }

    func persistWebDAVConfigSyncSettings() {
        self.webDAVConfigSyncSettings.endpoint = self.webDAVConfigSyncSettings.endpoint.trimmed
        self.webDAVConfigSyncSettings.username = self.webDAVConfigSyncSettings.username.trimmed
        self.webDAVConfigSyncSettings.remoteFileName = self.webDAVConfigSyncSettings.remoteFileName.trimmed
        do {
            let data = try JSONEncoder().encode(self.webDAVConfigSyncSettings)
            self.defaults.set(data, forKey: Self.webDAVConfigSyncSettingsKey)
        } catch {
            self.appendLog(level: "error", message: tr("log.webdav.settings_save_failed", error.localizedDescription))
        }
    }

    func uploadSelectedConfigToWebDAV() async {
        guard self.canSyncSelectedConfigWithWebDAV, let selectedConfig = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("log.webdav.config_unavailable"))
            self.applyWebDAVConfigSyncFeedback(kind: .error, message: tr("log.webdav.config_unavailable"))
            return
        }

        self.persistWebDAVConfigSyncSettings()
        self.webDAVConfigSyncFeedback = nil
        self.webDAVConfigSyncInFlight = .upload
        defer { self.webDAVConfigSyncInFlight = nil }

        do {
            let data = try Data(contentsOf: selectedConfig)
            try await WebDAVConfigSyncService().upload(
                data: data,
                settings: self.webDAVConfigSyncSettings,
                fallbackFileName: selectedConfig.lastPathComponent)
            let message = tr("log.webdav.upload_success", selectedConfig.lastPathComponent)
            self.appendLog(level: "info", message: message)
            self.applyWebDAVConfigSyncFeedback(kind: .success, message: message)
        } catch {
            let message = tr("log.webdav.upload_failed", error.localizedDescription)
            self.appendLog(level: "error", message: message)
            self.applyWebDAVConfigSyncFeedback(kind: .error, message: message)
        }
    }

    func downloadSelectedConfigFromWebDAV() async {
        guard self.canSyncSelectedConfigWithWebDAV, let selectedConfig = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("log.webdav.config_unavailable"))
            self.applyWebDAVConfigSyncFeedback(kind: .error, message: tr("log.webdav.config_unavailable"))
            return
        }

        self.persistWebDAVConfigSyncSettings()
        self.webDAVConfigSyncFeedback = nil
        self.webDAVConfigSyncInFlight = .download
        defer { self.webDAVConfigSyncInFlight = nil }

        do {
            let data = try await WebDAVConfigSyncService().download(
                settings: self.webDAVConfigSyncSettings,
                fallbackFileName: selectedConfig.lastPathComponent)
            try self.writeConfigData(data, to: selectedConfig)
            self.markInternalConfigFileMutationHandled()
            _ = self.configRepository.reloadConfigs()
            self.syncConfigDisplayState()
            let message = tr("log.webdav.download_success", selectedConfig.lastPathComponent)
            self.appendLog(level: "info", message: message)
            self.applyWebDAVConfigSyncFeedback(kind: .success, message: message)
        } catch {
            let message = tr("log.webdav.download_failed", error.localizedDescription)
            self.appendLog(level: "error", message: message)
            self.applyWebDAVConfigSyncFeedback(kind: .error, message: message)
        }
    }

    func loadPersistedWebDAVConfigSyncSettings() -> WebDAVConfigSyncSettings {
        guard let data = self.defaults.data(forKey: Self.webDAVConfigSyncSettingsKey),
              let settings = try? JSONDecoder().decode(WebDAVConfigSyncSettings.self, from: data)
        else {
            return WebDAVConfigSyncSettings()
        }
        return settings
    }

    private func applyWebDAVConfigSyncFeedback(kind: WebDAVConfigSyncFeedback.Kind, message: String) {
        self.webDAVConfigSyncFeedback = WebDAVConfigSyncFeedback(kind: kind, message: message)
    }

    var isCoreUpgradeInFlight: Bool {
        if case .running = self.coreUpgradeState {
            return true
        }
        return false
    }

    private func applyCoreUpgradeState(_ state: CoreUpgradeState) {
        self.coreUpgradeState = state

        switch state {
        case .idle, .running:
            return
        case .succeeded:
            self.appendLog(level: "info", message: tr("log.core_upgrade.updated"))
            Task { [weak self] in
                await self?.refreshCoreVersionAfterUpgradeIfPossible()
            }
        case let .alreadyLatest(version):
            if let version, !version.isEmpty {
                self.version = AppSemanticVersion.normalizedDisplayVersion(from: version)
                self.appendLog(level: "info", message: tr("log.core_upgrade.latest_version", self.version))
            } else {
                self.appendLog(level: "info", message: tr("log.core_upgrade.latest"))
            }
        case let .failed(message):
            self.appendLog(level: "error", message: tr("log.core_upgrade.failed", message))
        }

        self.scheduleCoreUpgradeFeedbackAutoClear()
    }

    private func scheduleCoreUpgradeFeedbackAutoClear() {
        self.coreUpgradeFeedbackClearTask?.cancel()
        self.coreUpgradeFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            guard !self.isCoreUpgradeInFlight else { return }
            self.coreUpgradeState = .idle
        }
    }

    private func refreshCoreVersionAfterUpgradeIfPossible() async {
        do {
            try await Task.sleep(nanoseconds: 750_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }

        do {
            let versionInfo: VersionInfo = try await self.clientOrThrow().request(.version)
            guard !Task.isCancelled else { return }
            self.version = versionInfo.version
        } catch {
            // Best effort only. The core may be restarting briefly after an upgrade request.
        }
    }

    private func coreUpgradeState(from response: CoreUpgradeResponse) -> CoreUpgradeState {
        if let status = response.status?.trimmedNonEmpty,
           status.caseInsensitiveCompare("ok") == .orderedSame
        {
            return .succeeded
        }

        if let message = response.message?.trimmedNonEmpty {
            return self.coreUpgradeState(fromMessage: message)
        }

        return .failed(message: tr("ui.common.unknown"))
    }

    private func coreUpgradeState(from error: Error) -> CoreUpgradeState {
        if let apiError = error as? APIError,
           case let .statusCode(_, responseBody) = apiError
        {
            if let data = responseBody.data(using: .utf8),
               let response = try? JSONDecoder().decode(CoreUpgradeResponse.self, from: data)
            {
                let state = self.coreUpgradeState(from: response)
                if case let .failed(message) = state, message == tr("ui.common.unknown") {
                    return self.coreUpgradeState(fromMessage: responseBody)
                }
                return state
            }

            return self.coreUpgradeState(fromMessage: responseBody)
        }

        return self.coreUpgradeState(fromMessage: error.localizedDescription)
    }

    private func coreUpgradeState(fromMessage message: String) -> CoreUpgradeState {
        let trimmedMessage = message.trimmed
        guard !trimmedMessage.isEmpty else {
            return .failed(message: tr("ui.common.unknown"))
        }

        if self.isAlreadyLatestCoreUpgradeMessage(trimmedMessage) {
            return .alreadyLatest(version: self.latestVersion(in: trimmedMessage))
        }

        return .failed(message: trimmedMessage)
    }

    private func isAlreadyLatestCoreUpgradeMessage(_ message: String) -> Bool {
        message.range(
            of: "already using latest version",
            options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func latestVersion(in message: String) -> String? {
        let pattern = #"v?\d+(?:\.\d+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.matches(in: message, range: range).last,
              let swiftRange = Range(match.range, in: message)
        else {
            return nil
        }

        let raw = String(message[swiftRange])
        return AppSemanticVersion.normalizedDisplayVersion(from: raw)
    }
}

// MARK: - App Release (from +AppRelease)

extension AppViewModel {
    var currentAppVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, !short.isEmpty { return short }
        if let build, !build.isEmpty { return build }
        return "0.0.1"
    }

    var availableAppUpdate: AppReleaseInfo? {
        guard let latestAppReleaseInfo else { return nil }
        guard !latestAppReleaseInfo.isDraft, !latestAppReleaseInfo.isPrerelease else { return nil }
        guard AppSemanticVersion.isNewerRelease(
            tagName: latestAppReleaseInfo.tagName,
            than: self.currentAppVersionText)
        else {
            return nil
        }
        return latestAppReleaseInfo
    }

    var appReleaseIndexURL: URL? {
        URL(string: "https://github.com/Sitoi/ClashBar/releases")
    }

    func refreshLatestAppRelease() async {
    }
}
