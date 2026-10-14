import Foundation

struct WebDAVConfigSyncSettings: Codable, Equatable {
    var endpoint: String = ""
    var username: String = ""
    var password: String = ""
    var remoteFileName: String = ""

    enum CodingKeys: String, CodingKey {
        case endpoint
        case username
        case password
        case remoteFileName
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.remoteFileName = try container.decodeIfPresent(String.self, forKey: .remoteFileName) ?? ""
    }
}

struct WebDAVConfigSyncService {
    enum SyncDirection {
        case upload
        case download
    }

    enum SyncError: LocalizedError {
        case invalidEndpoint
        case invalidRemoteFileName
        case emptyResponse
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "Invalid WebDAV URL."
            case .invalidRemoteFileName:
                "Invalid remote file name."
            case .emptyResponse:
                "WebDAV response is empty."
            case let .httpStatus(status, body):
                body.isEmpty ? "WebDAV HTTP \(status)." : "WebDAV HTTP \(status): \(body)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(data: Data, settings: WebDAVConfigSyncSettings, fallbackFileName: String) async throws {
        try await self.ensureRemoteDirectoryIfNeeded(settings: settings)
        var request = try self.request(settings: settings, fallbackFileName: fallbackFileName, method: "PUT")
        request.httpBody = data
        request.setValue("application/x-yaml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let (responseData, response) = try await self.session.data(for: request)
        try self.validate(response: response, data: responseData, acceptedStatuses: 200...299)
    }

    func download(settings: WebDAVConfigSyncSettings, fallbackFileName: String) async throws -> Data {
        let request = try self.request(settings: settings, fallbackFileName: fallbackFileName, method: "GET")
        let (data, response) = try await self.session.data(for: request)
        try self.validate(response: response, data: data, acceptedStatuses: 200...299)
        guard !data.isEmpty else { throw SyncError.emptyResponse }
        return data
    }

    private func request(
        settings: WebDAVConfigSyncSettings,
        fallbackFileName: String,
        method: String) throws -> URLRequest
    {
        guard let baseURL = URL(string: settings.endpoint.trimmed), let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw SyncError.invalidEndpoint
        }
        guard !self.isConfigFileURL(baseURL) else { throw SyncError.invalidEndpoint }

        let remoteFileName = settings.remoteFileName.trimmedNonEmpty ?? fallbackFileName
        guard !remoteFileName.contains("/") && !remoteFileName.contains("\\") else {
            throw SyncError.invalidRemoteFileName
        }

        let targetURL = try self.targetURL(baseURL: baseURL, settings: settings, remoteFileName: remoteFileName)

        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        self.applyAuthorization(settings: settings, request: &request)

        return request
    }

    private func ensureRemoteDirectoryIfNeeded(settings: WebDAVConfigSyncSettings) async throws {
        let directoryURLs = try self.remoteDirectoryURLs(settings: settings)
        guard !directoryURLs.isEmpty else { return }

        for directoryURL in directoryURLs {
            var request = URLRequest(url: directoryURL)
            request.httpMethod = "MKCOL"
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.applyAuthorization(settings: settings, request: &request)

            let (data, response) = try await self.session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 405 {
                continue
            }
            try self.validate(response: response, data: data, acceptedStatuses: 200...299)
        }
    }

    private func targetURL(
        baseURL: URL,
        settings: WebDAVConfigSyncSettings,
        remoteFileName: String) throws -> URL
    {
        var targetURL = baseURL
        for component in self.remoteDirectoryComponents() {
            targetURL.appendPathComponent(component, isDirectory: true)
        }
        return targetURL.appendingPathComponent(remoteFileName, isDirectory: false)
    }

    private func remoteDirectoryURLs(settings: WebDAVConfigSyncSettings) throws -> [URL] {
        guard let baseURL = URL(string: settings.endpoint.trimmed), let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw SyncError.invalidEndpoint
        }
        guard !self.isConfigFileURL(baseURL) else { throw SyncError.invalidEndpoint }

        let components = self.remoteDirectoryComponents()
        guard !components.isEmpty else { return [] }

        var directoryURL = baseURL
        var directoryURLs: [URL] = []
        for component in components {
            directoryURL.appendPathComponent(component, isDirectory: true)
            directoryURLs.append(directoryURL)
        }
        return directoryURLs
    }

    private func applyAuthorization(settings: WebDAVConfigSyncSettings, request: inout URLRequest) {
        guard let username = settings.username.trimmedNonEmpty else { return }
        let credentials = "\(username):\(settings.password)"
        if let data = credentials.data(using: .utf8) {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
    }

    private func remoteDirectoryComponents() -> [String] {
        ["ClashBar"]
    }

    private func isConfigFileURL(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        return extensionName == "yaml" || extensionName == "yml"
    }

    private func validate(response: URLResponse, data: Data, acceptedStatuses: ClosedRange<Int>) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard acceptedStatuses.contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmed ?? ""
            throw SyncError.httpStatus(httpResponse.statusCode, body)
        }
    }
}
