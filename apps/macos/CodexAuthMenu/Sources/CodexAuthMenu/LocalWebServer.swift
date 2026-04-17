import Foundation
import Network
import Security

typealias WebLoginLauncher = @Sendable (_ cliClient: CLIClient, _ deviceAuth: Bool) throws -> Void
typealias WebImportLauncher = @Sendable (_ cliClient: CLIClient, _ source: CodexImportSource) throws -> TerminalLaunchResult
typealias WebCodexAppRestarter = @Sendable () -> CodexAppRestartResult

final class LocalWebServer {
    private let cliClient: CLIClient
    private let userDefaults: UserDefaults
    private let loginLauncher: WebLoginLauncher
    private let importLauncher: WebImportLauncher
    private let codexAppRestarter: WebCodexAppRestarter
    private let queue = DispatchQueue(label: "CodexAuthMenu.LocalWebServer")
    private let token = LocalWebServer.randomToken()
    private let maxRequestBytes = 256 * 1024
    private var listener: NWListener?
    private var port: UInt16?

    var onStateChanged: (() -> Void)?
    var onPreferencesChanged: (() -> Void)?

    init(
        cliClient: CLIClient,
        userDefaults: UserDefaults = .standard,
        loginLauncher: @escaping WebLoginLauncher = { client, deviceAuth in
            try client.openLoginInTerminal(deviceAuth: deviceAuth)
        },
        importLauncher: @escaping WebImportLauncher = { client, source in
            try client.openImportInTerminal(source: source)
        },
        codexAppRestarter: @escaping WebCodexAppRestarter = {
            CodexDesktopController.restartRunningCodexApp()
        }
    ) {
        self.cliClient = cliClient
        self.userDefaults = userDefaults
        self.loginLauncher = loginLauncher
        self.importLauncher = importLauncher
        self.codexAppRestarter = codexAppRestarter
    }

    var controlURL: URL? {
        queue.sync {
            guard let port else { return nil }
            return URL(string: "http://127.0.0.1:\(port)/?token=\(token)")
        }
    }

    func start() throws {
        if listener != nil {
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            if case .ready = state, let rawPort = listener.port?.rawValue {
                self.queue.async {
                    self.port = rawPort
                }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            port = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            switch HTTPRequest.parse(from: nextBuffer) {
            case .complete(let request):
                self.route(request, on: connection)
            case .invalid:
                self.sendError(status: 400, message: "请求无效", on: connection)
            case .incomplete:
                if isComplete || nextBuffer.count > self.maxRequestBytes {
                    self.sendError(status: 400, message: "请求无效", on: connection)
                    return
                }
                self.receiveRequest(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "GET", request.path == "/favicon.ico" {
            sendIcon(on: connection)
            return
        }

        guard isAuthorized(request) else {
            sendError(status: 403, message: "未授权", on: connection)
            return
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/"):
                send(status: 200, contentType: "text/html; charset=utf-8", body: WebControlPage.html, on: connection)
            case ("GET", "/app-icon.png"):
                sendIcon(on: connection)
            case ("GET", "/api/health"):
                let health = HealthResponse(
                    ok: true,
                    cliPath: cliClient.displayPath,
                    version: cliClient.versionText()
                )
                let body = try jsonData(health)
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("GET", "/api/preferences"):
                let body = try jsonData(PreferencesResponse(
                    restartCodexAfterSwitch: CodexMenuPreferences.restartCodexAfterSwitch(userDefaults: userDefaults)
                ))
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("GET", "/api/api-config"):
                let state = try cliClient.loadState(refreshScope: .none)
                let body = try jsonData(state.api)
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("GET", "/api/state"):
                let state = try cliClient.loadState(refreshScope: .none)
                let body = try jsonData(state)
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/refresh-active"):
                let state = try cliClient.loadState(refreshScope: .activeOnly)
                onStateChanged?()
                let body = try jsonData(state)
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/refresh-all"):
                let state = try cliClient.loadState(refreshScope: .allAccounts)
                onStateChanged?()
                let body = try jsonData(state)
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/sync-history"):
                let summary = try cliClient.syncHistory()
                let body = try jsonData(HistorySyncResponse(
                    ok: true,
                    mirroredThreads: summary.mirroredThreads,
                    message: summary.mirroredThreads > 0
                        ? "历史会话同步完成：新增 \(summary.mirroredThreads) 个镜像会话。"
                        : "历史会话已检查：没有需要补齐的镜像会话。"
                ))
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/login"):
                let request = try JSONDecoder().decode(LoginRequest.self, from: request.body)
                try loginLauncher(cliClient, request.deviceAuth)
                let body = try jsonData(ActionResponse(
                    ok: true,
                    message: CodexDesktopController.loginStatusMessage(deviceAuth: request.deviceAuth)
                ))
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/import"):
                let request = try JSONDecoder().decode(ImportRequest.self, from: request.body)
                let result = try importLauncher(cliClient, request.source)
                let body = try jsonData(ActionResponse(
                    ok: result == .launched,
                    message: result == .launched
                        ? CodexDesktopController.importStatusMessage(source: request.source)
                        : CodexDesktopController.importCancelledMessage(source: request.source)
                ))
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/preferences"):
                let request = try JSONDecoder().decode(PreferencesRequest.self, from: request.body)
                CodexMenuPreferences.setRestartCodexAfterSwitch(
                    request.restartCodexAfterSwitch,
                    userDefaults: userDefaults
                )
                onPreferencesChanged?()
                let body = try jsonData(PreferencesResponse(
                    restartCodexAfterSwitch: request.restartCodexAfterSwitch
                ))
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/api-config"):
                let request = try JSONDecoder().decode(APIConfigRequest.self, from: request.body)
                let api = try cliClient.setAPIConfig(
                    usageAccountEnabled: request.usageAccountEnabled
                )
                onStateChanged?()
                let body = try jsonData(api)
                send(status: 200, contentType: "application/json", body: body, on: connection)
            case ("POST", "/api/renewal/set"):
                let body = try JSONDecoder().decode(RenewalSetRequest.self, from: request.body)
                let state = try cliClient.setRenewal(accountKey: body.accountKey, date: body.date)
                onStateChanged?()
                let response = try jsonData(state)
                send(status: 200, contentType: "application/json", body: response, on: connection)
            case ("POST", "/api/renewal/clear"):
                let body = try JSONDecoder().decode(RenewalClearRequest.self, from: request.body)
                let state = try cliClient.clearRenewal(accountKey: body.accountKey)
                onStateChanged?()
                let response = try jsonData(state)
                send(status: 200, contentType: "application/json", body: response, on: connection)
            case ("POST", "/api/switch"):
                let body = try JSONDecoder().decode(SwitchRequest.self, from: request.body)
                let state = try cliClient.switchAccount(accountKey: body.accountKey)
                let restartResult = CodexMenuPreferences.restartCodexAfterSwitch(userDefaults: userDefaults)
                    ? codexAppRestarter()
                    : .disabled
                onStateChanged?()
                let response = try jsonData(state)
                send(
                    status: 200,
                    contentType: "application/json",
                    body: response,
                    headers: ["X-Codex-Restart-Result": restartResult.rawValue],
                    on: connection
                )
            default:
                sendError(status: 404, message: "未找到", on: connection)
            }
        } catch {
            sendError(status: 500, message: error.localizedDescription, on: connection)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        if request.query["token"] == token {
            return true
        }
        if request.headers["x-codex-auth-token"] == token {
            return true
        }
        return false
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func sendIcon(on connection: NWConnection) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let body = try? Data(contentsOf: iconURL) {
            send(status: 200, contentType: "image/png", body: body, on: connection)
        } else {
            sendError(status: 404, message: "未找到图标", on: connection)
        }
    }

    private func sendError(status: Int, message: String, on connection: NWConnection) {
        if let body = try? jsonData(ErrorResponse(error: message)) {
            send(status: status, contentType: "application/json; charset=utf-8", body: body, on: connection)
            return
        }
        send(status: status, contentType: "application/json; charset=utf-8", body: #"{"error":"服务器错误"}"#, on: connection)
    }

    private func send(status: Int, contentType: String, body: String, on connection: NWConnection) {
        send(status: status, contentType: contentType, body: Data(body.utf8), on: connection)
    }

    private func send(
        status: Int,
        contentType: String,
        body: Data,
        headers: [String: String] = [:],
        on connection: NWConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Internal Server Error"
        }
        var header = ""
        header += "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Content-Length: \(body.count)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    static func parse(from data: Data) -> HTTPRequestParseResult {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let marker = data.range(of: delimiter) else {
            return .incomplete
        }
        let headerData = data[..<marker.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .invalid
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return .invalid
        }
        let method = String(requestParts[0])

        let target = String(requestParts[1])
        var components = URLComponents(string: target)
        if components == nil {
            components = URLComponents(string: "http://127.0.0.1\(target)")
        }
        let path = components?.path.isEmpty == false ? components?.path ?? "/" : "/"
        var queryValues: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            queryValues[item.name] = item.value ?? ""
        }

        var headerValues: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headerValues[name] = value
        }

        let contentLength: Int
        if let rawContentLength = headerValues["content-length"], !rawContentLength.isEmpty {
            guard let parsedLength = Int(rawContentLength), parsedLength >= 0 else {
                return .invalid
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        let bodyData = data[marker.upperBound...]
        guard bodyData.count >= contentLength else {
            return .incomplete
        }

        return .complete(
            HTTPRequest(
                method: method,
                path: path,
                query: queryValues,
                headers: headerValues,
                body: Data(bodyData.prefix(contentLength))
            )
        )
    }
}

enum HTTPRequestParseResult {
    case complete(HTTPRequest)
    case incomplete
    case invalid
}

private struct SwitchRequest: Codable {
    var accountKey: String

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
    }
}

private struct LoginRequest: Codable {
    var deviceAuth: Bool

    enum CodingKeys: String, CodingKey {
        case deviceAuth = "device_auth"
    }
}

private struct ImportRequest: Codable {
    var source: CodexImportSource
}

private struct PreferencesRequest: Codable {
    var restartCodexAfterSwitch: Bool

    enum CodingKeys: String, CodingKey {
        case restartCodexAfterSwitch = "restart_codex_after_switch"
    }
}

private struct APIConfigRequest: Codable {
    var usageAccountEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case usageAccountEnabled = "usage_account_enabled"
    }
}

private struct RenewalSetRequest: Codable {
    var accountKey: String
    var date: String

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case date
    }
}

private struct RenewalClearRequest: Codable {
    var accountKey: String

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
    }
}

private struct PreferencesResponse: Codable {
    var restartCodexAfterSwitch: Bool

    enum CodingKeys: String, CodingKey {
        case restartCodexAfterSwitch = "restart_codex_after_switch"
    }
}

private struct HealthResponse: Codable {
    var ok: Bool
    var cliPath: String
    var version: String

    enum CodingKeys: String, CodingKey {
        case ok
        case cliPath = "cli_path"
        case version
    }
}

private struct ErrorResponse: Codable {
    var error: String
}

private struct ActionResponse: Codable {
    var ok: Bool
    var message: String
}

private struct HistorySyncResponse: Codable {
    var ok: Bool
    var mirroredThreads: Int
    var message: String

    enum CodingKeys: String, CodingKey {
        case ok
        case mirroredThreads = "mirrored_threads"
        case message
    }
}
