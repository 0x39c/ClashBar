import AppKit
import Foundation
import UniformTypeIdentifiers

private final class ProxyProviderNameAutofillButton: NSButton {
    @MainActor var onTap: (() -> Void)?

    @MainActor
    @objc
    func handleTap(_ sender: NSButton) {
        self.onTap?()
    }
}

private struct ProxyProviderInput {
    let name: String
    let url: String
}

private struct LocalRuleInput {
    let rule: String
}

private enum LocalRuleFormOptions {
    static let ruleTypes = [
        "DOMAIN-SUFFIX",
        "DOMAIN",
        "DOMAIN-KEYWORD",
        "DOMAIN-REGEX",
        "IP-CIDR",
        "IP-CIDR6",
        "GEOIP",
        "GEOSITE",
        "RULE-SET",
        "PROCESS-NAME",
        "PROCESS-PATH",
        "SRC-IP-CIDR",
        "DST-PORT",
    ]

    static let policies = [
        "DIRECT",
        "REJECT",
        "REJECT-DROP",
        "PASS",
    ]
}

private final class ProxyProviderAutofillResultHandler: NSObject, @unchecked Sendable {
    weak var appViewModel: AppViewModel?
    weak var autofillButton: NSButton?
    weak var nameField: NSTextField?
    var suggestedName: String?

    init(appViewModel: AppViewModel?, autofillButton: NSButton?, nameField: NSTextField?) {
        self.appViewModel = appViewModel
        self.autofillButton = autofillButton
        self.nameField = nameField
    }

    @MainActor
    @objc
    func applyResult() {
        defer { self.autofillButton?.isEnabled = true }
        guard let suggestedName = self.suggestedName else {
            NSSound.beep()
            return
        }
        self.nameField?.stringValue = suggestedName
    }
}

private enum ProxyProviderNameResolver {
    static func suggestedName(from urlString: String, userAgent: String? = nil, completion: @escaping @Sendable (String?) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            completion(nil)
            return
        }

        self.remoteSuggestedName(from: url, userAgent: userAgent) { remoteName in
            if let remoteName {
                completion(remoteName)
                return
            }

            let fallback = self.fallbackSuggestedName(from: url)
            completion(fallback)
        }
    }

    private static func remoteSuggestedName(from url: URL, userAgent: String?, completion: @escaping @Sendable (String?) -> Void) {
        let session = URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 6,
            timeoutIntervalForResource: 10))

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let userAgent = userAgent?.trimmedNonEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let task = session.dataTask(with: request) { _, response, error in
            defer { session.finishTasksAndInvalidate() }

            if error != nil {
                completion(nil)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(nil)
                return
            }
            let resolved = self.name(from: http)
            completion(resolved)
        }
        task.resume()
    }

    private static func name(from http: HTTPURLResponse) -> String? {
        if let profileTitle = self.normalizedName(fromHeaderValue: http.value(forHTTPHeaderField: "profile-title")) {
            return profileTitle
        }
        if let subscriptionName = self.normalizedName(fromHeaderValue: http.value(forHTTPHeaderField: "subscription-name")) {
            return subscriptionName
        }
        if let contentDisposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let fileName = self.fileName(fromContentDisposition: contentDisposition)
        {
            return fileName
        }
        return nil
    }

    private static func normalizedName(fromHeaderValue rawValue: String?) -> String? {
        guard var candidate = rawValue?.trimmedNonEmpty else { return nil }
        if candidate.lowercased().hasPrefix("base64:") {
            let encoded = String(candidate.dropFirst("base64:".count))
            if let data = Data(base64Encoded: encoded),
               let decoded = String(data: data, encoding: .utf8)?.trimmedNonEmpty
            {
                candidate = decoded
            }
        }

        candidate = candidate.removingPercentEncoding?.trimmedNonEmpty ?? candidate
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let stem = URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent
        return stem.trimmedNonEmpty ?? candidate.trimmedNonEmpty
    }

    private static func fileName(fromContentDisposition contentDisposition: String) -> String? {
        let parts = contentDisposition.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let encodedPart = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
            var value = String(encodedPart.dropFirst("filename*=".count)).trimmed
            if let separatorRange = value.range(of: "''") {
                value = String(value[separatorRange.upperBound...])
            }
            return self.normalizedName(fromHeaderValue: value)
        }

        if let plainPart = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
            let value = String(plainPart.dropFirst("filename=".count)).trimmed
            return self.normalizedName(fromHeaderValue: value)
        }

        return nil
    }

    private static func fallbackSuggestedName(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for key in ["name", "title", "tag", "remark", "subscription-name", "subscription_name"] {
                if let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value?.trimmedNonEmpty {
                    return value.removingPercentEncoding?.trimmedNonEmpty ?? value
                }
            }
        }

        let rawName = url.lastPathComponent.removingPercentEncoding?.trimmedNonEmpty
        let stem = rawName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.flatMap(\.trimmedNonEmpty)
        if let stem, !Self.genericProviderNameTokens.contains(stem.lowercased()) {
            return stem
        }

        if let host = url.host?.trimmedNonEmpty {
            let parts = host.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                return parts[parts.count - 2]
            }
            return host
        }

        return nil
    }

    private static let genericProviderNameTokens: Set<String> = [
        "sub", "subscribe", "subscription", "proxy", "proxies", "clash", "mihomo", "config",
    ]
}

@MainActor
extension AppViewModel {
    private var localDefaultConfigFileName: String {
        "ClashBar.yaml"
    }

    private var localDefaultCommonProviderListName: String {
        "dailyProviders"
    }

    private var localDefaultDownloadProviderListName: String {
        "premiumProviders"
    }

    private var localDefaultLegacyCommonProviderListName: String {
        "commonProviders"
    }

    private var localDefaultLegacyDownloadProviderListName: String {
        "downloadProviders"
    }

    private var localDefaultProviderListNames: [String] {
        [
            self.localDefaultCommonProviderListName,
            self.localDefaultDownloadProviderListName,
            self.localDefaultLegacyCommonProviderListName,
            self.localDefaultLegacyDownloadProviderListName,
        ]
    }

    var isSelectedLocalDefaultConfig: Bool {
        guard !self.isRemoteTarget,
              let selectedURL = self.configRepository.selectedConfig
        else {
            return false
        }

        let defaultURL = self.workingDirectoryManager.configDirectoryURL
            .appendingPathComponent(self.localDefaultConfigFileName, isDirectory: false)
        return selectedURL.standardizedFileURL.resolvingSymlinksInPath().path == defaultURL.standardizedFileURL
            .resolvingSymlinksInPath().path
    }

    var canBindProviderToSelectedLocalDefaultConfig: Bool {
        self.isSelectedLocalDefaultConfig
    }

    var canEditRulesInSelectedLocalConfig: Bool {
        !self.isRemoteTarget && self.configRepository.selectedConfig != nil
    }

    func refreshSelectedProxyProviderName() {
        guard self.isSelectedLocalDefaultConfig,
              let selectedURL = self.configRepository.selectedConfig,
              let content = try? String(contentsOf: selectedURL, encoding: .utf8)
        else {
            self.selectedCommonProxyProviderName = nil
            self.selectedDownloadProxyProviderName = nil
            return
        }

        let mutator = LocalProxyProviderBindingMutator()
        self.selectedCommonProxyProviderName = self.selectedProviderName(
            using: mutator,
            primaryListName: self.localDefaultCommonProviderListName,
            legacyListName: self.localDefaultLegacyCommonProviderListName,
            content: content)
        self.selectedDownloadProxyProviderName = self.selectedProviderName(
            using: mutator,
            primaryListName: self.localDefaultDownloadProviderListName,
            legacyListName: self.localDefaultLegacyDownloadProviderListName,
            content: content)
    }

    func selectProxyProviderForLocalDefaultConfig(name: String) async {
        await self.selectProxyProviderForLocalDefaultConfig(
            name: name,
            providerListName: self.localDefaultCommonProviderListName)
    }

    func selectDownloadProxyProviderForLocalDefaultConfig(name: String) async {
        await self.selectProxyProviderForLocalDefaultConfig(
            name: name,
            providerListName: self.localDefaultDownloadProviderListName)
    }

    private func selectProxyProviderForLocalDefaultConfig(name: String, providerListName: String) async {
        guard self.canBindProviderToSelectedLocalDefaultConfig else {
            self.appendLog(level: "info", message: tr("app.provider.local_only"))
            return
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.provider.local_config_unresolved"))
            return
        }
        guard let providerName = name.trimmedNonEmpty else {
            self.appendLog(level: "error", message: tr("app.provider.name_empty"))
            return
        }

        do {
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let effectiveProviderListName = self.effectiveProviderListName(
                requestedListName: providerListName,
                content: content)
            let updatedContent = try LocalProxyProviderBindingMutator().bindProvider(
                named: providerName,
                toProviderListNamed: effectiveProviderListName,
                enablingProvidersFromListNames: self.localDefaultProviderListNames,
                in: content)
            guard updatedContent != content else {
                self.applySelectedProxyProviderName(providerName, providerListName: effectiveProviderListName)
                return
            }

            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            self.applySelectedProxyProviderName(providerName, providerListName: effectiveProviderListName)
            await self.reloadCurrentConfigAfterInternalFileMutation(updatedFileNames: [selectedURL.lastPathComponent])
            self.appendLog(
                level: "info",
                message: tr("app.provider.bind.success", effectiveProviderListName, providerName))
        } catch {
            self.appendLog(level: "error", message: tr("app.provider.bind.failed", providerName, error.localizedDescription))
        }
    }

    private func applySelectedProxyProviderName(_ providerName: String?, providerListName: String) {
        if providerListName == self.localDefaultDownloadProviderListName
            || providerListName == self.localDefaultLegacyDownloadProviderListName
        {
            self.selectedDownloadProxyProviderName = providerName
        } else {
            self.selectedCommonProxyProviderName = providerName
        }
    }

    private func selectedProviderName(
        using mutator: LocalProxyProviderBindingMutator,
        primaryListName: String,
        legacyListName: String,
        content: String) -> String?
    {
        mutator.selectedProviderName(inProviderListNamed: primaryListName, content: content)
            ?? mutator.selectedProviderName(inProviderListNamed: legacyListName, content: content)
    }

    private func effectiveProviderListName(requestedListName: String, content: String) -> String {
        let mutator = LocalProxyProviderBindingMutator()
        let primaryListName: String
        let legacyListName: String
        if requestedListName == self.localDefaultDownloadProviderListName
            || requestedListName == self.localDefaultLegacyDownloadProviderListName
        {
            primaryListName = self.localDefaultDownloadProviderListName
            legacyListName = self.localDefaultLegacyDownloadProviderListName
        } else {
            primaryListName = self.localDefaultCommonProviderListName
            legacyListName = self.localDefaultLegacyCommonProviderListName
        }

        if mutator.selectedProviderName(inProviderListNamed: primaryListName, content: content) != nil {
            return primaryListName
        }
        if mutator.selectedProviderName(inProviderListNamed: legacyListName, content: content) != nil {
            return legacyListName
        }
        return primaryListName
    }

    func deleteProxyProviderFromLocalDefaultConfig(name: String) async {
        guard self.canBindProviderToSelectedLocalDefaultConfig else {
            self.appendLog(level: "info", message: tr("app.provider.local_only"))
            return
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.provider.local_config_unresolved"))
            return
        }
        guard let providerName = name.trimmedNonEmpty else {
            self.appendLog(level: "error", message: tr("app.provider.name_empty"))
            return
        }
        guard self.confirmDeleteProxyProvider(named: providerName) else { return }

        do {
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let bindingMutator = LocalProxyProviderBindingMutator()
            let definitionMutator = LocalProxyProviderDefinitionMutator()
            let effectiveCommonProviderListName = self.effectiveProviderListName(
                requestedListName: self.localDefaultCommonProviderListName,
                content: content)
            let effectiveDownloadProviderListName = self.effectiveProviderListName(
                requestedListName: self.localDefaultDownloadProviderListName,
                content: content)
            let currentCommonProvider = bindingMutator.selectedProviderName(
                inProviderListNamed: effectiveCommonProviderListName,
                content: content)
            let currentDownloadProvider = bindingMutator.selectedProviderName(
                inProviderListNamed: effectiveDownloadProviderListName,
                content: content)
            let providers = try definitionMutator.providerNames(in: content)
            let remainingProviders = providers.filter { $0 != providerName }

            guard !remainingProviders.isEmpty else {
                self.appendLog(level: "error", message: tr("app.provider.delete.last_provider", providerName))
                return
            }

            var updatedContent = try definitionMutator.removeProvider(named: providerName, from: content)
            var reboundListNames: [String] = []
            if currentCommonProvider == providerName,
               let fallbackProvider = remainingProviders.first
            {
                updatedContent = try bindingMutator.bindProvider(
                    named: fallbackProvider,
                    toProviderListNamed: effectiveCommonProviderListName,
                    enablingProvidersFromListNames: self.localDefaultProviderListNames,
                    in: updatedContent)
                self.selectedCommonProxyProviderName = fallbackProvider
                reboundListNames.append(effectiveCommonProviderListName)
            } else if currentCommonProvider != providerName {
                self.selectedCommonProxyProviderName = currentCommonProvider
            }
            if currentDownloadProvider == providerName,
               let fallbackProvider = remainingProviders.first
            {
                updatedContent = try bindingMutator.bindProvider(
                    named: fallbackProvider,
                    toProviderListNamed: effectiveDownloadProviderListName,
                    enablingProvidersFromListNames: self.localDefaultProviderListNames,
                    in: updatedContent)
                self.selectedDownloadProxyProviderName = fallbackProvider
                reboundListNames.append(effectiveDownloadProviderListName)
            } else if currentDownloadProvider != providerName {
                self.selectedDownloadProxyProviderName = currentDownloadProvider
            }

            if let fallbackProvider = remainingProviders.first, !reboundListNames.isEmpty {
                self.appendLog(
                    level: "info",
                    message: tr("app.provider.delete.rebound", providerName, reboundListNames.joined(separator: ", "), fallbackProvider))
            } else {
                self.appendLog(level: "info", message: tr("app.provider.delete.success", providerName))
            }

            guard updatedContent != content else { return }
            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            await self.reloadCurrentConfigAfterInternalFileMutation(updatedFileNames: [selectedURL.lastPathComponent])
        } catch {
            self.appendLog(level: "error", message: tr("app.provider.delete.failed", providerName, error.localizedDescription))
        }
    }

    func addProxyProviderToLocalDefaultConfig() async {
        guard let input = self.promptProxyProviderInput() else { return }
        await self.addProxyProviderToLocalDefaultConfig(name: input.name, url: input.url)
    }

    func addProxyProviderToLocalDefaultConfig(name: String, url: String) async {
        guard self.canBindProviderToSelectedLocalDefaultConfig else {
            self.appendLog(level: "info", message: tr("app.provider.local_only"))
            return
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.provider.local_config_unresolved"))
            return
        }

        let providerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerName.isEmpty else {
            self.presentProxyProviderMutationAlert(success: false, message: tr("app.provider.add.invalid_name"))
            return
        }
        guard let remoteURL = URL(string: urlText), self.isSupportedRemoteConfigURL(remoteURL) else {
            self.presentProxyProviderMutationAlert(success: false, message: tr("log.config.remote.invalid_url", urlText))
            return
        }

        do {
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let path = "./proxy/\(self.proxyProviderStorageFileName(for: providerName))"
            let definitionMutator = LocalProxyProviderDefinitionMutator()
            let updatedContent = try definitionMutator.addProvider(
                named: providerName,
                url: remoteURL.absoluteString,
                path: path,
                to: content)
            guard updatedContent != content else { return }

            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            await self.reloadCurrentConfigAfterInternalFileMutation(updatedFileNames: [selectedURL.lastPathComponent])
            self.appendLog(
                level: "info",
                message: tr("app.provider.add.success", providerName))
        } catch {
            self.presentProxyProviderMutationAlert(
                success: false,
                message: tr("app.provider.add.failed", providerName, error.localizedDescription))
        }
    }

    func addRuleToSelectedLocalConfig() async {
        guard let input = self.promptLocalRuleInput() else { return }
        await self.addRuleToSelectedLocalConfig(ruleText: input.rule)
    }

    @discardableResult
    func addRuleToSelectedLocalConfig(ruleText rawRuleText: String) async -> Bool {
        guard self.canEditRulesInSelectedLocalConfig else {
            self.appendLog(level: "info", message: tr("app.rule.local_only"))
            return false
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.rule.local_config_unresolved"))
            return false
        }
        let ruleText = rawRuleText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let mutator = LocalRuleMutator()
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let input = try mutator.input(fromRawRule: ruleText)
            let updatedContent = try mutator.addRule(ruleText, to: content)
            guard updatedContent != content else { return false }

            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            self.markInternalConfigFileMutationHandled()
            self.insertLocalRulePresentation(input)
            self.scheduleRuleConfigApplyAfterLocalMutation()
            self.appendLog(level: "info", message: tr("app.rule.add.success", ruleText))
            return true
        } catch {
            self.presentRuleMutationAlert(
                success: false,
                message: tr("app.rule.add.failed", ruleText, error.localizedDescription))
            return false
        }
    }

    func deleteRuleFromSelectedLocalConfig(_ rule: RuleItem) async {
        guard self.canEditRulesInSelectedLocalConfig else {
            self.appendLog(level: "info", message: tr("app.rule.local_only"))
            return
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.rule.local_config_unresolved"))
            return
        }
        guard let input = self.localRuleMutationInput(from: rule) else {
            self.presentRuleMutationAlert(success: false, message: tr("app.rule.error.invalid"))
            return
        }
        let ruleText = [input.type, input.payload, input.policy].joined(separator: ",")

        do {
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let updatedContent = try LocalRuleMutator().removeRule(matching: input, from: content)
            guard updatedContent != content else { return }

            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            self.markInternalConfigFileMutationHandled()
            self.removeLocalRulePresentation(matching: input)
            self.scheduleRuleConfigApplyAfterLocalMutation()
            self.appendLog(level: "info", message: tr("app.rule.delete.success", ruleText))
        } catch {
            self.presentRuleMutationAlert(
                success: false,
                message: tr("app.rule.delete.failed", ruleText, error.localizedDescription))
        }
    }

    func moveRuleInSelectedLocalConfig(_ sourceRule: RuleItem, before targetRule: RuleItem) async {
        guard self.canEditRulesInSelectedLocalConfig else {
            self.appendLog(level: "info", message: tr("app.rule.local_only"))
            return
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.rule.local_config_unresolved"))
            return
        }
        guard let source = self.localRuleMutationInput(from: sourceRule),
              let target = self.localRuleMutationInput(from: targetRule)
        else {
            self.presentRuleMutationAlert(success: false, message: tr("app.rule.error.invalid"))
            return
        }
        do {
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let updatedContent = try LocalRuleMutator().moveRule(matching: source, before: target, in: content)
            guard updatedContent != content else { return }

            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            self.markInternalConfigFileMutationHandled()
            self.moveLocalRulePresentation(source: source, before: target)
            self.scheduleRuleConfigApplyAfterLocalMutation()
            self.appendLog(level: "info", message: tr("app.rule.move.success"))
        } catch {
            self.presentRuleMutationAlert(
                success: false,
                message: tr("app.rule.move.failed", error.localizedDescription))
        }
    }

    func moveRuleInSelectedLocalConfig(_ sourceRule: RuleItem, after targetRule: RuleItem) async {
        guard self.canEditRulesInSelectedLocalConfig else {
            self.appendLog(level: "info", message: tr("app.rule.local_only"))
            return
        }
        guard let selectedURL = self.configRepository.selectedConfig else {
            self.appendLog(level: "error", message: tr("app.rule.local_config_unresolved"))
            return
        }
        guard let source = self.localRuleMutationInput(from: sourceRule),
              let target = self.localRuleMutationInput(from: targetRule)
        else {
            self.presentRuleMutationAlert(success: false, message: tr("app.rule.error.invalid"))
            return
        }
        do {
            let content = try String(contentsOf: selectedURL, encoding: .utf8)
            let updatedContent = try LocalRuleMutator().moveRule(matching: source, after: target, in: content)
            guard updatedContent != content else { return }

            try self.writeConfigData(Data(updatedContent.utf8), to: selectedURL)
            self.markInternalConfigFileMutationHandled()
            self.moveLocalRulePresentation(source: source, after: target)
            self.scheduleRuleConfigApplyAfterLocalMutation()
            self.appendLog(level: "info", message: tr("app.rule.move.success"))
        } catch {
            self.presentRuleMutationAlert(
                success: false,
                message: tr("app.rule.move.failed", error.localizedDescription))
        }
    }

    private func localRuleMutationInput(from rule: RuleItem) -> LocalRuleMutationInput? {
        guard let type = rule.type.trimmedNonEmpty,
              let payload = rule.payload.trimmedNonEmpty,
              let policy = rule.proxy.trimmedNonEmpty
        else {
            return nil
        }
        return LocalRuleMutationInput(type: type, payload: payload, policy: policy)
    }

    private func scheduleRuleConfigApplyAfterLocalMutation() {
        self.pendingRuleConfigApplyTask?.cancel()
        self.pendingRuleConfigApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.ruleConfigApplyDebounceNanoseconds ?? 5_000_000_000)
            } catch {
                return
            }
            await self?.applyPendingRuleConfigMutation()
        }
    }

    private func applyPendingRuleConfigMutation() async {
        self.pendingRuleConfigApplyTask = nil
        guard !self.isRemoteTarget, self.isRuntimeRunning else { return }
        guard !self.isCoreActionProcessing else {
            self.scheduleRuleConfigApplyAfterLocalMutation()
            return
        }

        self.cancelProviderRefresh(reason: "rule config apply requested")
        await self.reloadConfig()
        await self.refreshFromAPI(includeSlowCalls: false)
    }

    private func insertLocalRulePresentation(_ input: LocalRuleMutationInput) {
        let mutator = LocalRuleMutator()
        let normalizedInput = mutator.normalizedInput(input)
        guard !self.ruleItems.contains(where: { self.localRule($0, matches: normalizedInput, mutator: mutator) }) else {
            return
        }

        self.ruleItems.insert(
            RuleItem(
                type: normalizedInput.type,
                payload: normalizedInput.payload,
                proxy: normalizedInput.policy,
                extra: nil),
            at: 0)
        if self.ruleItems.count > RulesSummary.retainedRuleLimit {
            self.ruleItems.removeLast(self.ruleItems.count - RulesSummary.retainedRuleLimit)
        }
        self.rulesCount += 1
    }

    private func removeLocalRulePresentation(matching input: LocalRuleMutationInput) {
        let mutator = LocalRuleMutator()
        let normalizedInput = mutator.normalizedInput(input)
        let previousCount = self.ruleItems.count
        self.ruleItems.removeAll { self.localRule($0, matches: normalizedInput, mutator: mutator) }
        if self.ruleItems.count != previousCount {
            self.rulesCount = max(0, self.rulesCount - 1)
        }
    }

    private func moveLocalRulePresentation(source: LocalRuleMutationInput, before target: LocalRuleMutationInput) {
        let mutator = LocalRuleMutator()
        let normalizedSource = mutator.normalizedInput(source)
        let normalizedTarget = mutator.normalizedInput(target)
        guard let sourceIndex = self.ruleItems.firstIndex(where: {
            self.localRule($0, matches: normalizedSource, mutator: mutator)
        }),
            var targetIndex = self.ruleItems.firstIndex(where: {
                self.localRule($0, matches: normalizedTarget, mutator: mutator)
            })
        else {
            return
        }

        let item = self.ruleItems.remove(at: sourceIndex)
        if sourceIndex < targetIndex {
            targetIndex -= 1
        }
        self.ruleItems.insert(item, at: targetIndex)
    }

    private func moveLocalRulePresentation(source: LocalRuleMutationInput, after target: LocalRuleMutationInput) {
        let mutator = LocalRuleMutator()
        let normalizedSource = mutator.normalizedInput(source)
        let normalizedTarget = mutator.normalizedInput(target)
        guard let sourceIndex = self.ruleItems.firstIndex(where: {
            self.localRule($0, matches: normalizedSource, mutator: mutator)
        }),
            var targetIndex = self.ruleItems.firstIndex(where: {
                self.localRule($0, matches: normalizedTarget, mutator: mutator)
            })
        else {
            return
        }

        let item = self.ruleItems.remove(at: sourceIndex)
        if sourceIndex < targetIndex {
            targetIndex -= 1
        }
        self.ruleItems.insert(item, at: min(targetIndex + 1, self.ruleItems.count))
    }

    private func localRule(
        _ rule: RuleItem,
        matches input: LocalRuleMutationInput,
        mutator: LocalRuleMutator) -> Bool
    {
        guard let candidate = self.localRuleMutationInput(from: rule) else { return false }
        return mutator.normalizedInput(candidate) == input
    }

    private func promptLocalRuleInput() -> LocalRuleInput? {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))

        let labelY: CGFloat = 38
        let fieldY: CGFloat = 8
        let typeWidth: CGFloat = 132
        let payloadWidth: CGFloat = 160
        let policyWidth: CGFloat = 112
        let gap: CGFloat = 8

        let typeLabel = NSTextField(labelWithString: tr("app.rule.add.type_label"))
        typeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        typeLabel.frame = NSRect(x: 0, y: labelY, width: typeWidth, height: 16)

        let payloadLabel = NSTextField(labelWithString: tr("app.rule.add.payload_label"))
        payloadLabel.font = .systemFont(ofSize: 12, weight: .medium)
        payloadLabel.frame = NSRect(x: typeWidth + gap, y: labelY, width: payloadWidth, height: 16)

        let policyLabel = NSTextField(labelWithString: tr("app.rule.add.policy_label"))
        policyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        policyLabel.frame = NSRect(x: typeWidth + payloadWidth + (gap * 2), y: labelY, width: policyWidth, height: 16)

        let typeCombo = NSComboBox(frame: NSRect(x: 0, y: fieldY, width: typeWidth, height: 24))
        typeCombo.addItems(withObjectValues: LocalRuleFormOptions.ruleTypes)
        typeCombo.completes = true
        typeCombo.numberOfVisibleItems = min(8, LocalRuleFormOptions.ruleTypes.count)
        typeCombo.selectItem(at: 0)

        let payloadField = NSTextField(frame: NSRect(x: typeWidth + gap, y: fieldY, width: payloadWidth, height: 24))
        payloadField.placeholderString = tr("app.rule.add.payload_placeholder")

        let policyOptions = self.localRulePolicyOptions()
        let policyCombo = NSComboBox(frame: NSRect(x: typeWidth + payloadWidth + (gap * 2), y: fieldY, width: policyWidth, height: 24))
        policyCombo.addItems(withObjectValues: policyOptions)
        policyCombo.completes = true
        policyCombo.numberOfVisibleItems = min(10, policyOptions.count)
        policyCombo.stringValue = policyOptions.first ?? "DIRECT"

        container.addSubview(typeLabel)
        container.addSubview(payloadLabel)
        container.addSubview(policyLabel)
        container.addSubview(typeCombo)
        container.addSubview(payloadField)
        container.addSubview(policyCombo)

        let response = self.runModalAlert(
            style: .informational,
            message: tr("ui.action.add_rule"),
            informative: tr("app.rule.add.prompt"),
            buttons: [tr("ui.action.add_exception"), tr("ui.action.cancel")]) {
                $0.accessoryView = container
                $0.window.initialFirstResponder = payloadField
            }
        guard response == .alertFirstButtonReturn else { return nil }

        let type = typeCombo.stringValue.trimmed
        let payload = payloadField.stringValue.trimmed
        let policy = policyCombo.stringValue.trimmed
        return LocalRuleInput(rule: [type, payload, policy].joined(separator: ","))
    }

    private func localRulePolicyOptions() -> [String] {
        var options: [String] = []
        var seen: Set<String> = []
        for policy in LocalRuleFormOptions.policies + self.proxyGroups.map(\.name).sorted() {
            guard let normalized = policy.trimmedNonEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            options.append(normalized)
        }
        return options
    }

    private func confirmDeleteRule(_ rule: String) -> Bool {
        self.runModalAlert(
            style: .warning,
            message: tr("app.rule.delete.confirm.title"),
            informative: tr("app.rule.delete.confirm.message", rule),
            buttons: [tr("ui.action.delete"), tr("ui.action.cancel")]) == .alertFirstButtonReturn
    }

    private func presentRuleMutationAlert(success: Bool, message: String) {
        self.appendLog(level: success ? "info" : "error", message: message)
        self.runModalAlert(
            style: success ? .informational : .warning,
            message: tr("ui.tab.rules"),
            informative: message,
            buttons: [tr("ui.action.ok")])
    }

    private func promptProxyProviderInput() -> ProxyProviderInput? {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 94))

        let urlLabel = NSTextField(labelWithString: tr("app.provider.add.url_label"))
        urlLabel.font = .systemFont(ofSize: 12, weight: .medium)
        urlLabel.frame = NSRect(x: 0, y: 76, width: 340, height: 16)

        let urlField = NSTextField(frame: NSRect(x: 0, y: 50, width: 340, height: 24))
        urlField.placeholderString = tr("app.provider.add.url_placeholder")

        let nameLabel = NSTextField(labelWithString: tr("app.provider.add.name_label"))
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.frame = NSRect(x: 0, y: 28, width: 340, height: 16)

        let nameField = NSTextField(frame: NSRect(x: 0, y: 2, width: 258, height: 24))
        nameField.placeholderString = tr("app.provider.add.name_placeholder")

        let autofillButton = ProxyProviderNameAutofillButton(title: tr("app.provider.add.fetch_name"), target: nil, action: nil)
        autofillButton.bezelStyle = .rounded
        autofillButton.frame = NSRect(x: 266, y: 1, width: 74, height: 26)
        autofillButton.onTap = { [weak self, weak urlField, weak nameField, weak autofillButton] in
            guard let urlString = urlField?.stringValue.trimmedNonEmpty else {
                NSSound.beep()
                return
            }

            let userAgent = self?.proxyProviderAutofillUserAgent()
            autofillButton?.isEnabled = false
            let resultHandler = ProxyProviderAutofillResultHandler(
                appViewModel: self,
                autofillButton: autofillButton,
                nameField: nameField)
            ProxyProviderNameResolver.suggestedName(from: urlString, userAgent: userAgent) { suggested in
                resultHandler.suggestedName = suggested
                resultHandler.perform(
                    #selector(ProxyProviderAutofillResultHandler.applyResult),
                    on: Thread.main,
                    with: nil,
                    waitUntilDone: false,
                    modes: [RunLoop.Mode.default.rawValue, RunLoop.Mode.modalPanel.rawValue])
            }
        }
        autofillButton.target = autofillButton
        autofillButton.action = #selector(ProxyProviderNameAutofillButton.handleTap(_:))

        container.addSubview(urlLabel)
        container.addSubview(urlField)
        container.addSubview(autofillButton)
        container.addSubview(nameLabel)
        container.addSubview(nameField)

        let response = self.runModalAlert(
            style: .informational,
            message: tr("ui.action.add_proxy_provider"),
            informative: tr("app.provider.add.prompt"),
            buttons: [tr("ui.action.add_exception"), tr("ui.action.cancel")]) {
                $0.accessoryView = container
                $0.window.initialFirstResponder = urlField
            }
        guard response == .alertFirstButtonReturn else { return nil }
        return ProxyProviderInput(name: nameField.stringValue, url: urlField.stringValue)
    }

    private func proxyProviderStorageFileName(for providerName: String) -> String {
        let raw = self.normalizedConfigFileName(providerName, fallback: providerName) ?? "provider.yaml"
        let stem = URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
        let ext = (raw as NSString).pathExtension.nonEmpty ?? "yaml"
        let safeStem = stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let finalStem = safeStem.trimmedNonEmpty ?? "provider"
        return "\(finalStem).\(ext)"
    }

    private static let genericProviderNameTokens: Set<String> = [
        "sub", "subscribe", "subscription", "proxy", "proxies", "clash", "mihomo", "config",
    ]

    private func presentProxyProviderMutationAlert(success: Bool, message: String) {
        self.appendLog(level: success ? "info" : "error", message: message)
        self.runModalAlert(
            style: success ? .informational : .warning,
            message: tr("ui.action.add_proxy_provider"),
            informative: message,
            buttons: [tr("ui.action.ok")])
    }

    fileprivate func proxyProviderAutofillUserAgent() -> String {
        let normalizedVersion = self.version.trimmedNonEmpty
            .flatMap { $0 == "-" || $0.caseInsensitiveCompare("unknown") == .orderedSame ? nil : $0 }
            ?? "unknown"
        return "clash-verge/\(normalizedVersion)"
    }

    func suggestedProxyProviderName(from urlString: String) async -> String? {
        await withCheckedContinuation { continuation in
            ProxyProviderNameResolver.suggestedName(
                from: urlString,
                userAgent: self.proxyProviderAutofillUserAgent())
            {
                continuation.resume(returning: $0)
            }
        }
    }

    private func confirmDeleteProxyProvider(named providerName: String) -> Bool {
        self.runModalAlert(
            style: .warning,
            message: tr("app.provider.delete.confirm.title", providerName),
            informative: tr("app.provider.delete.confirm.message"),
            buttons: [tr("ui.action.delete"), tr("ui.action.cancel")]) == .alertFirstButtonReturn
    }

    func seedBundledConfigIfNeeded() {
        let fileManager = FileManager.default
        let targetURL = workingDirectoryManager.configDirectoryURL
            .appendingPathComponent("ClashBar.yaml", isDirectory: false)

        if fileManager.fileExists(atPath: targetURL.path) {
            return
        }

        guard let bundledConfigURL = bundledDefaultConfigURL(fileManager: fileManager) else {
            return
        }

        do {
            let data = try Data(contentsOf: bundledConfigURL)
            try writeConfigData(data, to: targetURL)
        } catch {
            appendLog(
                level: "error",
                message: tr("log.config.import_local.failed", "ClashBar.yaml", error.localizedDescription))
        }
    }

    private func bundledDefaultConfigURL(fileManager: FileManager = .default) -> URL? {
        FindBundledConfigTemplateUseCase().execute(
            resourceRoots: AppResourceBundleLocator.candidateResourceRoots(),
            fileManager: fileManager)
    }

    func selectConfig() async {
        let previousSelectedURL = configRepository.selectedConfig
        let previousSelectedPath = configRepository.selectedConfig?.path
        guard configRepository.chooseConfigDirectory() != nil else { return }

        let nextSelectedURL = configRepository.selectedConfig
        let previousCanonicalPath = previousSelectedURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let nextCanonicalPath = nextSelectedURL?.standardizedFileURL.resolvingSymlinksInPath().path

        if coreRepository.isRunning,
           let nextSelectedURL,
           previousCanonicalPath != nextCanonicalPath
        {
            let validationFailure = self.coreRepository.isRunning
                ? nil
                : await self.configValidationFailureDetails(configPath: nextSelectedURL.path)
            let currentCanonicalPath = self.configRepository.selectedConfig?.standardizedFileURL
                .resolvingSymlinksInPath().path
            guard currentCanonicalPath == nextCanonicalPath else { return }
            if let validationFailure {
                self.handleConfigValidationFailure(configPath: nextSelectedURL.path, details: validationFailure)
                if let previousSelectedURL {
                    configRepository.selectConfig(previousSelectedURL)
                }
                _ = self.syncSelectedConfigSelection(configRepository.selectedConfig)
                syncConfigDisplayState()
                return
            }
        }

        let nextSelectedPath = self.syncSelectedConfigSelection(configRepository.selectedConfig)
        syncConfigDisplayState()

        appendLog(level: "info", message: tr("log.config.loaded_count", configRepository.availableConfigs.count))
        await restartCoreIfNeededForConfigSwitch(previousPath: previousSelectedPath, nextPath: nextSelectedPath)
    }

    func selectConfigFile(named fileName: String) async {
        let previousSelectedURL = configRepository.selectedConfig
        let previousSelectedPath = configRepository.selectedConfig?.path
        guard let matched = configRepository.availableConfigs.first(where: { $0.lastPathComponent == fileName }) else {
            appendLog(level: "error", message: tr("log.config.not_found", fileName))
            return
        }

        let previousCanonicalPath = previousSelectedURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let targetCanonicalPath = matched.standardizedFileURL.resolvingSymlinksInPath().path

        if previousCanonicalPath == targetCanonicalPath {
            _ = self.syncSelectedConfigSelection(matched)
            syncConfigDisplayState()
            return
        }

        if coreRepository.isRunning,
           previousCanonicalPath != targetCanonicalPath
        {
            let validationFailure = self.coreRepository.isRunning
                ? nil
                : await self.configValidationFailureDetails(configPath: matched.path)
            let currentCanonicalPath = self.configRepository.selectedConfig?.standardizedFileURL
                .resolvingSymlinksInPath().path
            // Validation runs before selecting `matched`, so stale-check against the original selection.
            guard currentCanonicalPath == previousCanonicalPath else { return }
            if let validationFailure {
                self.handleConfigValidationFailure(configPath: matched.path, details: validationFailure)
                if let previousSelectedURL {
                    configRepository.selectConfig(previousSelectedURL)
                }
                _ = self.syncSelectedConfigSelection(configRepository.selectedConfig)
                syncConfigDisplayState()
                return
            }
        }

        configRepository.selectConfig(matched)
        let nextSelectedPath = self.syncSelectedConfigSelection(matched)
        syncConfigDisplayState()
        appendLog(level: "info", message: tr("log.config.selected", fileName))
        await restartCoreIfNeededForConfigSwitch(previousPath: previousSelectedPath, nextPath: nextSelectedPath)
    }

    func importLocalConfigFile() {
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }

        self.prepareModalWindowPresentation()
        let panel = NSOpenPanel()
        self.configureModalWindow(panel)
        panel.title = tr("ui.quick.import_local_config")
        panel.directoryURL = configDirectory
        var allowedTypes: [UTType] = []
        if let yamlType = UTType(filenameExtension: "yaml") {
            allowedTypes.append(yamlType)
        }
        if let ymlType = UTType(filenameExtension: "yml"), !allowedTypes.contains(ymlType) {
            allowedTypes.append(ymlType)
        }
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        guard let fileName = normalizedConfigFileName(sourceURL.lastPathComponent) else {
            appendLog(level: "error", message: tr("log.config.import.invalid_filename", sourceURL.lastPathComponent))
            return
        }

        let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        let isOverwrite = FileManager.default.fileExists(atPath: targetURL.path)
        guard !isOverwrite || self.confirmOverwriteConfig(named: fileName) else {
            appendLog(level: "info", message: tr("log.config.import.cancelled", fileName))
            return
        }

        do {
            let data = try Data(contentsOf: sourceURL)
            try writeConfigData(data, to: targetURL)

            self.removeRemoteConfigSubscription(for: fileName)
            appendLog(level: "info", message: tr("log.config.import_local.success", fileName))

            if isOverwrite, self.shouldAutoReloadCurrentConfig(updatedFileNames: [fileName]) {
                Task { [weak self] in await self?.reloadConfig() }
            }
        } catch {
            appendLog(
                level: "error",
                message: tr("log.config.import_local.failed", fileName, error.localizedDescription))
        }
    }
}
