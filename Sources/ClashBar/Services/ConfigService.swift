import Foundation

struct WorkingDirectoryManager {
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    var rootDirectoryURL: URL {
        self.homeDirectory.appendingPathComponent("Library/Application Support/clashbar", isDirectory: true)
    }

    var configDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("config", isDirectory: true)
    }

    var logsDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("logs", isDirectory: true)
    }

    var stateDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("state", isDirectory: true)
    }

    var coreDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("core", isDirectory: true)
    }

    var managedMihomoBinaryURL: URL {
        self.coreDirectoryURL.appendingPathComponent("mihomo", isDirectory: false)
    }

    func bootstrapDirectories(fileManager: FileManager = .default) throws {
        try self.createDirectoryIfNeeded(self.rootDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.configDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.logsDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.stateDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.coreDirectoryURL, fileManager: fileManager)
    }

    func normalizeAndValidateWithinRoot(_ url: URL, mustBeDirectory: Bool? = nil) throws -> URL {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = self.rootDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard self.isDescendantOrEqual(standardized, parent: root) else {
            throw NSError(
                domain: "ClashBar.PathSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Path escapes ClashBar working directory: \(standardized.path)"])
        }

        if let mustBeDirectory {
            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory != mustBeDirectory {
                throw NSError(
                    domain: "ClashBar.PathSecurity",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: mustBeDirectory
                        ? "Expected directory path: \(standardized.path)"
                        : "Expected file path: \(standardized.path)"])
            }
        }

        return standardized
    }

    private func createDirectoryIfNeeded(_ url: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw NSError(
                    domain: "ClashBar.PathSecurity",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Expected directory but found file: \(url.path)"])
            }
            return
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func isDescendantOrEqual(_ child: URL, parent: URL) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents

        guard parentComponents.count <= childComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy { $0 == $1 }
    }
}

// MARK: -

@MainActor
final class ConfigDirectoryManager {
    private let fm = FileManager.default
    private let workingDirectoryManager: WorkingDirectoryManager

    private(set) var configDirectory: URL?
    private(set) var availableConfigs: [URL] = []
    private(set) var selectedConfig: URL?

    init(workingDirectoryManager: WorkingDirectoryManager = WorkingDirectoryManager()) {
        self.workingDirectoryManager = workingDirectoryManager
    }

    func chooseConfigDirectory() -> URL? {
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
            let target = try workingDirectoryManager.normalizeAndValidateWithinRoot(
                self.workingDirectoryManager.configDirectoryURL,
                mustBeDirectory: true)
            self.configDirectory = target
            self.reloadConfigs()
            return target
        } catch {
            return nil
        }
    }

    func setConfigDirectory(_ url: URL) {
        guard let safeURL = try? workingDirectoryManager.normalizeAndValidateWithinRoot(url, mustBeDirectory: true),
              safeURL == workingDirectoryManager.configDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        else {
            return
        }
        self.configDirectory = safeURL
        self.reloadConfigs()
    }

    func selectConfig(_ url: URL) {
        guard let configDirectory else { return }
        let safeConfig = try? self.workingDirectoryManager.normalizeAndValidateWithinRoot(url, mustBeDirectory: false)
        guard let safeConfig,
              safeConfig.deletingLastPathComponent() == configDirectory,
              ["yaml", "yml"].contains(safeConfig.pathExtension.lowercased())
        else {
            return
        }
        self.selectedConfig = safeConfig
    }

    @discardableResult
    func reloadConfigs() -> [URL] {
        guard let configDirectory else {
            self.availableConfigs = []
            selectedConfig = nil
            return []
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        let children = (try? self.fm.contentsOfDirectory(
            at: configDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        var files: [URL] = []
        for fileURL in children {
            let isRegularFile = (try? fileURL.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false
            guard isRegularFile else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml" else { continue }
            files.append(fileURL)
        }

        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        self.availableConfigs = files

        if let selectedConfig, files.contains(selectedConfig) {
            return files
        }
        selectedConfig = files.first
        return files
    }
}

// MARK: -

struct ConfigImportService {
    private let maxRemoteConfigBytes = 5 * 1024 * 1024

    func writeConfigData(_ data: Data, to targetURL: URL) throws {
        guard !data.isEmpty else {
            throw NSError(
                domain: "ClashBar.ConfigImport",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Remote config response is empty"])
        }
        try data.write(to: targetURL, options: .atomic)
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? (fallback ?? "") : trimmed
        let candidate = URL(fileURLWithPath: baseName).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else { return nil }

        let ext = (candidate as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            return "\(candidate).yaml"
        }
        guard ext == "yaml" || ext == "yml" else { return nil }
        return candidate
    }

    func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        let rawName = remoteURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return "remote-config.yaml" }

        let ext = (rawName as NSString).pathExtension.lowercased()
        if ext == "yaml" || ext == "yml" {
            return rawName
        }

        if ext.isEmpty {
            return "\(rawName).yaml"
        }

        let stem = (rawName as NSString).deletingPathExtension
        let base = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "remote-config.yaml" : "\(base).yaml"
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        let session = URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 15,
            timeoutIntervalForResource: 30))
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: remoteURL)
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                request.setValue(trimmed, forHTTPHeaderField: "User-Agent")
            }
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw APIError.statusCode(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        if http.expectedContentLength > Int64(self.maxRemoteConfigBytes) {
            throw self.remoteConfigTooLargeError(limit: self.maxRemoteConfigBytes)
        }

        var data = Data()
        data.reserveCapacity(min(self.maxRemoteConfigBytes, 64 * 1024))
        for try await byte in bytes {
            if data.count >= self.maxRemoteConfigBytes {
                throw self.remoteConfigTooLargeError(limit: self.maxRemoteConfigBytes)
            }
            data.append(byte)
        }
        return data
    }

    private func remoteConfigTooLargeError(limit: Int) -> NSError {
        NSError(
            domain: "ClashBar.ConfigImport",
            code: 413,
            userInfo: [NSLocalizedDescriptionKey: "Remote config exceeds size limit (\(limit) bytes)"])
    }
}

// MARK: -

private func providerMutationText(_ key: String, _ args: CVarArg...) -> String {
    let rawLanguage = UserDefaults.standard.string(forKey: "clashbar.ui.language")
    let language = rawLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .zhHans
    return L10n.t(key, language: language, args: args)
}

struct LocalProxyProviderBindingMutator {
    enum MutationError: LocalizedError {
        case providerListNotFound(String)
        case providerListEmpty(String)

        var errorDescription: String? {
            switch self {
            case let .providerListNotFound(name):
                providerMutationText("app.provider.error.provider_list_not_found", name)
            case let .providerListEmpty(name):
                providerMutationText("app.provider.error.provider_list_empty", name)
            }
        }
    }

    func bindProvider(named providerName: String, toProviderListNamed listName: String, in content: String) throws -> String {
        let originalNewline = content.contains("\r\n") ? "\r\n" : "\n"
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalizedContent.components(separatedBy: "\n")

        let binding = try self.providerListBinding(listName: listName, lines: lines)
        let replacementLine = "\(String(repeating: " ", count: binding.itemIndent))- \(self.yamlDoubleQuoted(providerName))"
        let firstItemIndex = binding.itemIndices[0]
        lines[firstItemIndex] = replacementLine

        for removalIndex in binding.itemIndices.dropFirst().reversed() {
            lines.remove(at: removalIndex)
        }

        let updated = lines.joined(separator: "\n")
        return originalNewline == "\n"
            ? updated
            : updated.replacingOccurrences(of: "\n", with: originalNewline)
    }

    func selectedProviderName(inProviderListNamed listName: String, content: String) -> String? {
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedContent.components(separatedBy: "\n")
        guard let binding = try? self.providerListBinding(listName: listName, lines: lines),
              let firstItemIndex = binding.itemIndices.first
        else {
            return nil
        }
        return self.providerName(fromProviderListLine: lines[firstItemIndex])
    }

    private func providerListBinding(listName: String, lines: [String]) throws -> (itemIndent: Int, itemIndices: [Int]) {
        guard let headerIndex = lines.firstIndex(where: { self.isProviderListHeader($0, listName: listName) }) else {
            throw MutationError.providerListNotFound(listName)
        }

        let headerIndent = LocalProxyProviderBindingMutator.leadingWhitespaceCount(of: lines[headerIndex])
        let itemIndent = headerIndent + 2
        var index = headerIndex + 1
        var itemIndices: [Int] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            let indent = LocalProxyProviderBindingMutator.leadingWhitespaceCount(of: line)
            if indent <= headerIndent, !trimmed.hasPrefix("#") {
                break
            }

            if indent == itemIndent, self.isProviderListItemLine(line) {
                itemIndices.append(index)
            }
            index += 1
        }

        guard !itemIndices.isEmpty else {
            throw MutationError.providerListEmpty(listName)
        }
        return (itemIndent, itemIndices)
    }

    private func isProviderListHeader(_ line: String, listName: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separatorIndex = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespaces)
        guard key == listName else { return false }
        let suffix = trimmed[trimmed.index(after: separatorIndex)...]
        return Self.stripInlineComment(from: String(suffix)).trimmingCharacters(in: .whitespaces).hasPrefix("&")
    }

    private func isProviderListItemLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("-") || trimmed.hasPrefix("# -")
    }

    private func providerName(fromProviderListLine line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.hasPrefix("-") else { return nil }
        trimmed.removeFirst()
        trimmed = Self.stripInlineComment(from: trimmed).trimmingCharacters(in: .whitespaces)
        return Self.unquoted(trimmed)
    }

    private func yamlDoubleQuoted(_ value: String) -> String {
        Self.yamlDoubleQuoted(value)
    }
}

struct LocalProxyProviderDefinitionMutator {
    enum MutationError: LocalizedError {
        case providersSectionNotFound
        case providerNotFound(String)
        case providerAlreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .providersSectionNotFound:
                providerMutationText("app.provider.error.providers_section_not_found")
            case let .providerNotFound(name):
                providerMutationText("app.provider.error.provider_not_found", name)
            case let .providerAlreadyExists(name):
                providerMutationText("app.provider.error.provider_already_exists", name)
            }
        }
    }

    func providerNames(in content: String) throws -> [String] {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let section = try self.providersSection(in: lines)
        return section.itemHeaders.compactMap { LocalProxyProviderBindingMutator.mappingKey(from: lines[$0], allowCommented: false) }
    }

    func addProvider(named providerName: String, url: String, path: String, to content: String) throws -> String {
        let originalNewline = content.contains("\r\n") ? "\r\n" : "\n"
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalizedContent.components(separatedBy: "\n")
        let section = try self.providersSection(in: lines)

        if section.itemHeaders.contains(where: {
            LocalProxyProviderBindingMutator.mappingKey(from: lines[$0], allowCommented: false) == providerName
        }) {
            throw MutationError.providerAlreadyExists(providerName)
        }

        let indent = String(repeating: " ", count: section.itemIndent)
        let nestedIndent = String(repeating: " ", count: section.itemIndent + 2)
        let newBlock = [
            "\(indent)\(LocalProxyProviderBindingMutator.yamlDoubleQuoted(providerName)):",
            "\(nestedIndent)<<: *a1",
            "\(nestedIndent)url: \(LocalProxyProviderBindingMutator.yamlDoubleQuoted(url))",
            "\(nestedIndent)path: \(path)",
        ]

        lines.insert(contentsOf: newBlock, at: section.sectionEndIndex)
        let updated = lines.joined(separator: "\n")
        return originalNewline == "\n"
            ? updated
            : updated.replacingOccurrences(of: "\n", with: originalNewline)
    }

    func removeProvider(named providerName: String, from content: String) throws -> String {
        let originalNewline = content.contains("\r\n") ? "\r\n" : "\n"
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalizedContent.components(separatedBy: "\n")
        let section = try self.providersSection(in: lines)

        guard let startIndex = section.itemHeaders.first(where: {
            LocalProxyProviderBindingMutator.mappingKey(from: lines[$0], allowCommented: false) == providerName
        }) else {
            throw MutationError.providerNotFound(providerName)
        }

        let followingHeaders = section.itemHeaders.filter { $0 > startIndex }
        let endIndex = followingHeaders.first ?? section.sectionEndIndex
        lines.removeSubrange(startIndex..<endIndex)

        let updated = lines.joined(separator: "\n")
        return originalNewline == "\n"
            ? updated
            : updated.replacingOccurrences(of: "\n", with: originalNewline)
    }

    private func providersSection(in lines: [String]) throws -> (itemIndent: Int, itemHeaders: [Int], sectionEndIndex: Int) {
        guard let headerIndex = lines.firstIndex(where: { LocalProxyProviderBindingMutator.isProxyProvidersHeader($0) }) else {
            throw MutationError.providersSectionNotFound
        }

        let headerIndent = LocalProxyProviderBindingMutator.leadingWhitespaceCount(of: lines[headerIndex])
        let itemIndent = headerIndent + 2
        var index = headerIndex + 1
        var itemHeaders: [Int] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            let indent = LocalProxyProviderBindingMutator.leadingWhitespaceCount(of: line)
            if indent <= headerIndent, !trimmed.hasPrefix("#") {
                break
            }

            if indent == itemIndent,
               LocalProxyProviderBindingMutator.mappingKey(from: line, allowCommented: false) != nil
            {
                itemHeaders.append(index)
            }
            index += 1
        }

        return (itemIndent: itemIndent, itemHeaders: itemHeaders, sectionEndIndex: index)
    }
}

private extension LocalProxyProviderBindingMutator {
    static func leadingWhitespaceCount(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    static func stripInlineComment(from text: String) -> String {
        var result = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var previousCharacter: Character?

        for character in text {
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
            } else if character == "\"", !inSingleQuote, previousCharacter != "\\" {
                inDoubleQuote.toggle()
            } else if character == "#", !inSingleQuote, !inDoubleQuote {
                break
            }

            result.append(character)
            previousCharacter = character
        }

        return result
    }

    static func unquoted(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2,
           ((trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")))
        {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func yamlDoubleQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func mappingKey(from line: String, allowCommented: Bool) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if allowCommented, trimmed.hasPrefix("#") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"),
              let separatorIndex = trimmed.firstIndex(of: ":")
        else {
            return nil
        }

        let key = stripInlineComment(from: String(trimmed[..<separatorIndex])).trimmingCharacters(in: .whitespaces)
        return unquoted(key)
    }

    static func isProxyProvidersHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separatorIndex = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespaces)
        return key == "proxy-providers"
    }
}

@MainActor
final class DefaultConfigRepository: ConfigRepository {
    private let configManager: ConfigDirectoryManager
    private let configImportService: ConfigImportService

    init(
        configManager: ConfigDirectoryManager,
        configImportService: ConfigImportService)
    {
        self.configManager = configManager
        self.configImportService = configImportService
    }

    var configDirectory: URL? {
        self.configManager.configDirectory
    }

    var availableConfigs: [URL] {
        self.configManager.availableConfigs
    }

    var selectedConfig: URL? {
        self.configManager.selectedConfig
    }

    func chooseConfigDirectory() -> URL? {
        self.configManager.chooseConfigDirectory()
    }

    func setConfigDirectory(_ url: URL) {
        self.configManager.setConfigDirectory(url)
    }

    func selectConfig(_ url: URL) {
        self.configManager.selectConfig(url)
    }

    @discardableResult
    func reloadConfigs() -> [URL] {
        self.configManager.reloadConfigs()
    }

    func writeConfigData(_ data: Data, to targetURL: URL) throws {
        try self.configImportService.writeConfigData(data, to: targetURL)
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        self.configImportService.normalizedConfigFileName(fileName, fallback: fallback)
    }

    func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        self.configImportService.inferredRemoteConfigFileName(from: remoteURL)
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        self.configImportService.isSupportedRemoteConfigURL(url)
    }

    func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        try await self.configImportService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
    }
}
