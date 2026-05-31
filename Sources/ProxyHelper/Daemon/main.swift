import Darwin
import Foundation
import ProxyHelperShared
import Security
import SystemConfiguration

private enum ProxyHelperError: LocalizedError {
    case authenticationFailed
    case invalidHost
    case invalidPort
    case missingPreferences
    case missingCurrentSet
    case noEnabledNetworkServices
    case systemConfigurationFailure(action: String, code: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Authentication failed"
        case .invalidHost:
            "Invalid proxy host"
        case .invalidPort:
            "Invalid proxy port"
        case .missingPreferences:
            "Unable to access system network preferences"
        case .missingCurrentSet:
            "Unable to find current network set"
        case .noEnabledNetworkServices:
            "No enabled network services found"
        case let .systemConfigurationFailure(action, _, detail):
            "\(action) failed: \(detail)"
        }
    }
}

private final class SystemProxyConfigurator {
    private struct ProxyEntrySpec {
        let enableKey: String
        let hostKey: String
        let portKey: String
    }

    private static let proxyEntrySpecs: [ProxyEntrySpec] = [
        ProxyEntrySpec(
            enableKey: kSCPropNetProxiesHTTPEnable as String,
            hostKey: kSCPropNetProxiesHTTPProxy as String,
            portKey: kSCPropNetProxiesHTTPPort as String),
        ProxyEntrySpec(
            enableKey: kSCPropNetProxiesHTTPSEnable as String,
            hostKey: kSCPropNetProxiesHTTPSProxy as String,
            portKey: kSCPropNetProxiesHTTPSPort as String),
        ProxyEntrySpec(
            enableKey: kSCPropNetProxiesSOCKSEnable as String,
            hostKey: kSCPropNetProxiesSOCKSProxy as String,
            portKey: kSCPropNetProxiesSOCKSPort as String),
    ]

    func setSystemProxy(host: String, httpPort: Int, httpsPort: Int, socksPort: Int) throws {
        let normalizedHost = try self.normalizedHost(host)
        let ports = try validatedPorts(
            httpPort: httpPort,
            httpsPort: httpsPort,
            socksPort: socksPort,
            requiresEnabledProxy: true)

        try withMutableProxyProtocols { protocols in
            for proxyProtocol in protocols {
                var config = self.configuration(for: proxyProtocol)
                let portValues = [ports.httpPort, ports.httpsPort, ports.socksPort]
                for (spec, portValue) in zip(Self.proxyEntrySpecs, portValues) {
                    self.configureProxyEntry(
                        config: &config,
                        spec: spec,
                        host: normalizedHost,
                        port: portValue)
                }

                guard SCNetworkProtocolSetConfiguration(proxyProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Set proxy configuration")
                }
            }
        }
    }

    func clearSystemProxy() throws {
        try self.withMutableProxyProtocols { protocols in
            for proxyProtocol in protocols {
                var config = self.configuration(for: proxyProtocol)
                for spec in Self.proxyEntrySpecs {
                    self.configureProxyEntry(config: &config, spec: spec, host: "", port: 0)
                }

                guard SCNetworkProtocolSetConfiguration(proxyProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Clear proxy configuration")
                }
            }
        }
    }

    func isSystemProxyEnabled() throws -> Bool {
        let preferences = try makePreferences()
        let protocols = try proxyProtocols(from: preferences)

        for proxyProtocol in protocols {
            let config = self.configuration(for: proxyProtocol)
            if Self.proxyEntrySpecs.contains(where: { isEnabled(config: config, key: $0.enableKey) }) {
                return true
            }
        }

        return false
    }

    func isSystemProxyConfigured(host: String, httpPort: Int, httpsPort: Int, socksPort: Int) throws -> Bool {
        let normalizedHost = try self.normalizedHost(host)
        let ports = try validatedPorts(
            httpPort: httpPort,
            httpsPort: httpsPort,
            socksPort: socksPort,
            requiresEnabledProxy: true)

        let preferences = try makePreferences()
        let protocols = try proxyProtocols(from: preferences)
        let expectedPorts = [ports.httpPort, ports.httpsPort, ports.socksPort]

        for proxyProtocol in protocols {
            let config = self.configuration(for: proxyProtocol)
            for (spec, expectedPort) in zip(Self.proxyEntrySpecs, expectedPorts) {
                guard self.proxyMatchesExpectedState(
                    config: config,
                    spec: spec,
                    expectedHost: normalizedHost,
                    expectedPort: expectedPort)
                else {
                    return false
                }
            }
        }

        return true
    }

    func systemProxyActiveTarget() throws -> (host: String, port: Int)? {
        let preferences = try makePreferences()
        let protocols = try proxyProtocols(from: preferences)

        for proxyProtocol in protocols {
            let config = self.configuration(for: proxyProtocol)
            for spec in Self.proxyEntrySpecs {
                guard self.isEnabled(config: config, key: spec.enableKey) else {
                    continue
                }
                let host = (config[spec.hostKey] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !host.isEmpty else {
                    continue
                }
                guard let port = self.intValue(config[spec.portKey]), port > 0 else {
                    continue
                }
                return (host: host, port: port)
            }
        }

        return nil
    }

    func systemProxyExceptions() throws -> [String] {
        let preferences = try makePreferences()
        let protocols = try proxyProtocols(from: preferences)
        var aggregated: [String] = []
        var seen: Set<String> = []

        for proxyProtocol in protocols {
            let config = self.configuration(for: proxyProtocol)
            for value in self.exceptionsList(from: config) {
                let key = value.lowercased()
                guard seen.insert(key).inserted else { continue }
                aggregated.append(value)
            }
        }

        return aggregated
    }

    func setSystemProxyExceptions(_ exceptions: [String]) throws {
        let normalized = self.normalizedExceptions(exceptions)

        try self.withMutableProxyProtocols { protocols in
            for proxyProtocol in protocols {
                var config = self.configuration(for: proxyProtocol)
                config[kSCPropNetProxiesExceptionsList as String] = normalized
                config[kSCPropNetProxiesExcludeSimpleHostnames as String] = 0

                guard SCNetworkProtocolSetConfiguration(proxyProtocol, config as CFDictionary) else {
                    throw self.systemConfigurationError(action: "Set proxy exceptions")
                }
            }
        }
    }

    private func normalizedHost(_ host: String) throws -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ProxyHelperError.invalidHost
        }
        guard trimmedHost.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProxyHelperError.invalidHost
        }
        return trimmedHost
    }

    private func validatedPorts(
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        requiresEnabledProxy: Bool) throws -> (httpPort: Int, httpsPort: Int, socksPort: Int)
    {
        let httpPort = try validatedPort(httpPort)
        let httpsPort = try validatedPort(httpsPort)
        let socksPort = try validatedPort(socksPort)

        if requiresEnabledProxy, httpPort == 0, httpsPort == 0, socksPort == 0 {
            throw ProxyHelperError.invalidPort
        }

        return (httpPort: httpPort, httpsPort: httpsPort, socksPort: socksPort)
    }

    private func validatedPort(_ value: Int) throws -> Int {
        guard (0...65535).contains(value) else {
            throw ProxyHelperError.invalidPort
        }
        return value
    }

    private func configureProxyEntry(
        config: inout [String: Any],
        spec: ProxyEntrySpec,
        host: String,
        port: Int)
    {
        if port > 0 {
            config[spec.enableKey] = 1
            config[spec.hostKey] = host
            config[spec.portKey] = port
        } else {
            config[spec.enableKey] = 0
            config[spec.hostKey] = ""
            config[spec.portKey] = 0
        }
    }

    private func withMutableProxyProtocols(_ update: ([SCNetworkProtocol]) throws -> Void) throws {
        let preferences = try makePreferences()

        guard SCPreferencesLock(preferences, true) else {
            throw self.systemConfigurationError(action: "Lock system preferences")
        }
        defer { SCPreferencesUnlock(preferences) }

        let protocols = try proxyProtocols(from: preferences)
        try update(protocols)

        guard SCPreferencesCommitChanges(preferences) else {
            throw self.systemConfigurationError(action: "Commit proxy preferences")
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw self.systemConfigurationError(action: "Apply proxy preferences")
        }
    }

    private func makePreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, ProxyHelperConstants.machServiceName as CFString, nil) else {
            throw ProxyHelperError.missingPreferences
        }
        return preferences
    }

    private func proxyProtocols(from preferences: SCPreferences) throws -> [SCNetworkProtocol] {
        guard let currentSet = SCNetworkSetCopyCurrent(preferences) else {
            throw ProxyHelperError.missingCurrentSet
        }

        guard let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else {
            throw ProxyHelperError.noEnabledNetworkServices
        }

        let protocols = services.compactMap { service -> SCNetworkProtocol? in
            guard SCNetworkServiceGetEnabled(service) else {
                return nil
            }
            return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
        }

        guard !protocols.isEmpty else {
            throw ProxyHelperError.noEnabledNetworkServices
        }

        return protocols
    }

    private func configuration(for proxyProtocol: SCNetworkProtocol) -> [String: Any] {
        (SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]) ?? [:]
    }

    private func exceptionsList(from config: [String: Any]) -> [String] {
        let key = kSCPropNetProxiesExceptionsList as String

        if let values = config[key] as? [String] {
            return self.normalizedExceptions(values)
        }

        if let values = config[key] as? [NSString] {
            return self.normalizedExceptions(values.map(String.init))
        }

        if let values = config[key] as? [Any] {
            let strings = values.compactMap { value -> String? in
                if let string = value as? String {
                    return string
                }
                if let string = value as? NSString {
                    return String(string)
                }
                return nil
            }
            return self.normalizedExceptions(strings)
        }

        return []
    }

    private func normalizedExceptions(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }

        return result
    }

    private func isEnabled(config: [String: Any], key: String) -> Bool {
        if let value = config[key] as? NSNumber {
            return value.intValue != 0
        }
        if let value = config[key] as? Int {
            return value != 0
        }
        if let value = config[key] as? Bool {
            return value
        }
        return false
    }

    private func proxyHostAndPortMatch(
        config: [String: Any],
        spec: ProxyEntrySpec,
        expectedHost: String,
        expectedPort: Int) -> Bool
    {
        let currentHost = (config[spec.hostKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedExpectedHost = expectedHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard currentHost == normalizedExpectedHost else {
            return false
        }

        return self.intValue(config[spec.portKey]) == expectedPort
    }

    private func proxyMatchesExpectedState(
        config: [String: Any],
        spec: ProxyEntrySpec,
        expectedHost: String,
        expectedPort: Int) -> Bool
    {
        let enabled = self.isEnabled(config: config, key: spec.enableKey)
        if expectedPort == 0 {
            return !enabled
        }
        guard enabled else {
            return false
        }
        return self.proxyHostAndPortMatch(
            config: config,
            spec: spec,
            expectedHost: expectedHost,
            expectedPort: expectedPort)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func systemConfigurationError(action: String) -> ProxyHelperError {
        let code = SCError()
        let detail = String(cString: SCErrorString(code))
        return .systemConfigurationFailure(action: action, code: code, detail: detail)
    }
}

private final class ProxyHelperService: NSObject, ProxyHelperProtocol {
    private static let authenticationFailureMessage = "Authentication failed."

    private let configurator = SystemProxyConfigurator()
    private let authenticationLock = NSLock()
    private var isAuthenticated = false

    func authenticate(pairingToken: String, completion: @escaping (Bool, String?) -> Void) {
        let candidate = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= ProxyHelperConstants.maxPairingTokenLength
        else {
            completion(false, Self.authenticationFailureMessage)
            return
        }

        let expected = ProxyHelperPairingSecret.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty,
              expected.count <= ProxyHelperConstants.maxPairingTokenLength,
              Self.timingSafeEqual(candidate, expected)
        else {
            completion(false, Self.authenticationFailureMessage)
            return
        }

        self.authenticationLock.lock()
        self.isAuthenticated = true
        self.authenticationLock.unlock()
        completion(true, nil)
    }

    func ping(completion: @escaping (Bool, String?) -> Void) {
        guard self.hasAuthenticated else {
            completion(false, Self.authenticationFailureMessage)
            return
        }
        completion(true, nil)
    }

    func setSystemProxy(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        completion: @escaping (Bool, String?) -> Void)
    {
        guard self.hasAuthenticated else {
            completion(false, Self.authenticationFailureMessage)
            return
        }

        do {
            try self.configurator.setSystemProxy(
                host: host,
                httpPort: httpPort,
                httpsPort: httpsPort,
                socksPort: socksPort)
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func clearSystemProxy(completion: @escaping (Bool, String?) -> Void) {
        guard self.hasAuthenticated else {
            completion(false, Self.authenticationFailureMessage)
            return
        }

        do {
            try self.configurator.clearSystemProxy()
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func getSystemProxyState(completion: @escaping (Bool, Bool, String?) -> Void) {
        guard self.hasAuthenticated else {
            completion(false, false, Self.authenticationFailureMessage)
            return
        }

        do {
            let enabled = try configurator.isSystemProxyEnabled()
            completion(true, enabled, nil)
        } catch {
            completion(false, false, error.localizedDescription)
        }
    }

    func getSystemProxyActiveTarget(completion: @escaping (Bool, String?, Int, String?) -> Void) {
        guard self.hasAuthenticated else {
            completion(false, nil, 0, Self.authenticationFailureMessage)
            return
        }

        do {
            let target = try configurator.systemProxyActiveTarget()
            completion(true, target?.host, target?.port ?? 0, nil)
        } catch {
            completion(false, nil, 0, error.localizedDescription)
        }
    }

    func isSystemProxyConfigured(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        completion: @escaping (Bool, Bool, String?) -> Void)
    {
        guard self.hasAuthenticated else {
            completion(false, false, Self.authenticationFailureMessage)
            return
        }

        do {
            let configured = try configurator.isSystemProxyConfigured(
                host: host,
                httpPort: httpPort,
                httpsPort: httpsPort,
                socksPort: socksPort)
            completion(true, configured, nil)
        } catch {
            completion(false, false, error.localizedDescription)
        }
    }

    func getSystemProxyExceptions(completion: @escaping (Bool, String?, String?) -> Void) {
        guard self.hasAuthenticated else {
            completion(false, nil, Self.authenticationFailureMessage)
            return
        }

        do {
            let exceptions = try self.configurator.systemProxyExceptions()
            completion(true, exceptions.joined(separator: "\n"), nil)
        } catch {
            completion(false, nil, error.localizedDescription)
        }
    }

    func setSystemProxyExceptions(serializedExceptions: String, completion: @escaping (Bool, String?) -> Void) {
        guard self.hasAuthenticated else {
            completion(false, Self.authenticationFailureMessage)
            return
        }

        do {
            let exceptions = serializedExceptions.components(separatedBy: .newlines)
            try self.configurator.setSystemProxyExceptions(exceptions)
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    private var hasAuthenticated: Bool {
        self.authenticationLock.lock()
        defer { self.authenticationLock.unlock() }
        return self.isAuthenticated
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }

        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}

private final class HelperIdleExitController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clashbar.helper.idle-exit")
    private let idleTimeout: TimeInterval
    private var activeConnectionCount = 0
    private var idleExitWorkItem: DispatchWorkItem?

    init(idleTimeout: TimeInterval = 30) {
        self.idleTimeout = idleTimeout
    }

    func connectionOpened() -> ConnectionLifecycleToken {
        self.queue.sync {
            self.activeConnectionCount += 1
            self.idleExitWorkItem?.cancel()
            self.idleExitWorkItem = nil
        }

        return ConnectionLifecycleToken { [weak self] in
            self?.connectionClosed()
        }
    }

    func scheduleExitIfIdle() {
        self.queue.async {
            self.scheduleExitIfIdleLocked()
        }
    }

    private func connectionClosed() {
        self.queue.async {
            self.activeConnectionCount = max(0, self.activeConnectionCount - 1)
            self.scheduleExitIfIdleLocked()
        }
    }

    private func scheduleExitIfIdleLocked() {
        guard self.activeConnectionCount == 0 else { return }
        self.idleExitWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.exitIfStillIdle()
        }
        self.idleExitWorkItem = workItem
        self.queue.asyncAfter(deadline: .now() + self.idleTimeout, execute: workItem)
    }

    private func exitIfStillIdle() {
        guard self.activeConnectionCount == 0 else { return }
        exit(EXIT_SUCCESS)
    }
}

private final class ConnectionLifecycleToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func close() {
        self.lock.lock()
        guard !self.isClosed else {
            self.lock.unlock()
            return
        }
        self.isClosed = true
        self.lock.unlock()
        self.onClose()
    }
}

private final class ProxyHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let idleExitController: HelperIdleExitController

    init(idleExitController: HelperIdleExitController) {
        self.idleExitController = idleExitController
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let connectionLifecycle = self.idleExitController.connectionOpened()
        newConnection.invalidationHandler = {
            connectionLifecycle.close()
        }
        newConnection.interruptionHandler = {
            connectionLifecycle.close()
        }
        newConnection.exportedInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        newConnection.exportedObject = ProxyHelperService()
        newConnection.resume()
        return true
    }
}

@main
private struct ClashBarProxyHelperMain {
    static func main() {
        let idleExitController = HelperIdleExitController()
        let delegate = ProxyHelperListenerDelegate(idleExitController: idleExitController)
        let listener = NSXPCListener(machServiceName: ProxyHelperConstants.machServiceName)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(self.buildClientRequirement())
        listener.resume()
        idleExitController.scheduleExitIfIdle()
        dispatchMain()
    }

    private static func buildClientRequirement() -> String {
        let base = ProxyHelperConstants.allowedClientRequirement
        guard let teamID = selfTeamIdentifier(), !teamID.isEmpty else {
            return base
        }
        return "\(base) and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    private static func selfTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
