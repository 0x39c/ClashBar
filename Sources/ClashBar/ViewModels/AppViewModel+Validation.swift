import Foundation

@MainActor
extension AppViewModel {
    private func isValidExternalController(_ value: String) -> Bool {
        guard let components = parsedControllerComponents(from: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty
        else {
            return false
        }
        guard scheme == "http" || scheme == "https" else {
            return false
        }
        if let port = components.port {
            return (1...65535).contains(port)
        }
        return true
    }

    func controllerHost(from value: String) -> String? {
        self.parsedControllerComponents(from: value)?.host
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    private func appendExternalControllerWarningOnce(key: String, message: String) {
        if externalControllerWarningKeys.insert(key).inserted {
            appendLog(level: "warning", message: message)
        }
    }

    func normalizedControllerAddress(_ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }
        return "http://\(value)"
    }

    private func parsedControllerComponents(from value: String) -> URLComponents? {
        URLComponents(string: self.normalizedControllerAddress(value))
    }

    func applyExternalUIConfiguration(hasURL: Bool, name: String?) {
        self.hasConfiguredExternalUI = hasURL
        self.configuredExternalUIName = hasURL ? self.normalizedExternalUIName(name) : nil
        self.refreshControllerUIURL()
    }

    func refreshControllerUIURL() {
        guard self.isControllerAccessEnabled else {
            if self.controllerUIURL.isEmpty == false {
                self.controllerUIURL = ""
            }
            return
        }

        let nextURL = self.makeControllerUIURL(
            self.controller,
            secret: self.controllerSecret,
            hasConfiguredExternalUI: self.hasConfiguredExternalUI,
            externalUIName: self.configuredExternalUIName)
        if self.controllerUIURL != nextURL {
            self.controllerUIURL = nextURL
        }
    }

    private func parseYAMLScalarValue(forKey key: String, fromConfigContent raw: String) -> String? {
        var topLevelIndent: Int?
        for line in raw.split(whereSeparator: \.isNewline) {
            let lineText = String(line)
            let indent = self.leadingWhitespaceCount(in: lineText)
            let content = String(lineText.dropFirst(indent))
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedContent.isEmpty || trimmedContent.hasPrefix("#") {
                continue
            }

            if topLevelIndent == nil {
                topLevelIndent = indent
            }
            guard indent == topLevelIndent else {
                continue
            }

            guard let value = extractYAMLScalarValue(key: key, fromYAMLLineContent: content) else {
                continue
            }
            return value
        }
        return nil
    }

    private func extractYAMLScalarValue(key: String, fromYAMLLineContent line: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let linePattern = #"^\#(escapedKey)\s*:\s*(.*)$"#
        guard let range = line.range(
            of: linePattern,
            options: [.regularExpression])
        else {
            return nil
        }

        let prefixPattern = #"^\#(escapedKey)\s*:\s*"#
        var value = String(line[range]).replacingOccurrences(
            of: prefixPattern,
            with: "",
            options: [.regularExpression])

        value = self.stripYAMLInlineComment(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !value.isEmpty else { return nil }
        if value == "~" || value.lowercased() == "null" {
            return nil
        }
        return value
    }

    private func normalizedControllerSecret(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" || trimmed.lowercased() == "null" {
            return nil
        }
        return trimmed
    }

    func prepareLocalControllerCredentialsForLaunch() -> String {
        let port = self.randomLocalControllerPort()
        let controller = "127.0.0.1:\(port)"
        let secret = self.generateControllerSecret()
        self.controller = controller
        self.externalControllerDisplay = controller
        self.localExternalControllerDisplay = controller
        self.localControllerSecret = secret
        self.controllerSecret = secret
        self.refreshControllerUIURL()
        return controller
    }

    func generateControllerSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func randomLocalControllerPort() -> Int {
        Int.random(in: 49_152...65_535)
    }

    private func normalizedExternalUIName(_ value: String?) -> String? {
        guard var trimmed = value?.trimmedNonEmpty else { return nil }

        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        return trimmed.trimmedNonEmpty
    }

    private func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private func stripYAMLInlineComment(_ value: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var result = ""

        for char in value {
            if isEscaped {
                result.append(char)
                isEscaped = false
                continue
            }

            if char == "\\", inDoubleQuote {
                result.append(char)
                isEscaped = true
                continue
            }

            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(char)
                continue
            }

            if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(char)
                continue
            }

            if char == "#", !inSingleQuote, !inDoubleQuote {
                break
            }

            result.append(char)
        }

        return result
    }

    private func normalizedControllerForClientAccess(_ value: String) -> String {
        guard var components = parsedControllerComponents(from: value),
              let host = components.host
        else {
            return value
        }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacementHost: String
        switch normalizedHost {
        case "0.0.0.0":
            replacementHost = "127.0.0.1"
        case "::", "0:0:0:0:0:0:0:0":
            replacementHost = "::1"
        default:
            return value
        }

        components.host = replacementHost
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return components.string ?? value
        }

        guard let hostPort = hostPortString(from: components) else {
            return value
        }
        return hostPort
    }

    private func hostPortString(from components: URLComponents) -> String? {
        guard let host = components.host, !host.isEmpty else {
            return nil
        }
        let hostSegment = host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            return "\(hostSegment):\(port)"
        }
        return hostSegment
    }
}
