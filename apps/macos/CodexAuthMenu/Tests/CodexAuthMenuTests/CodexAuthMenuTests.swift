import Foundation
import XCTest

@testable import CodexAuthMenu

final class CodexAuthMenuTests: XCTestCase {
    func testResolveExecutablePathFindsPathEntry() throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let executable = binDir.appendingPathComponent("codex-auth")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let resolved = CLIClient.resolveExecutablePath(
            preferredPath: nil,
            environment: [
                "HOME": tempRoot.path,
                "PATH": binDir.path
            ],
            shellResolver: { _ in nil }
        )

        XCTAssertEqual(resolved, executable.path)
    }

    func testResolveExecutablePathPrefersBundledCLIOverPathEntry() throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundledExecutable = tempRoot.appendingPathComponent("bundled-codex-auth")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledExecutable.path
        )

        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let pathExecutable = binDir.appendingPathComponent("codex-auth")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pathExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: pathExecutable.path
        )

        let resolved = CLIClient.resolveExecutablePath(
            preferredPath: nil,
            bundledPath: bundledExecutable.path,
            environment: [
                "HOME": tempRoot.path,
                "PATH": binDir.path,
            ],
            shellResolver: { _ in nil }
        )

        XCTAssertEqual(resolved, bundledExecutable.path)
    }

    func testCLIClientMissingCLIReportsError() {
        let client = CLIClient(
            executablePath: nil,
            preferredPath: nil,
            environment: [:],
            isExecutable: { _ in false },
            shellResolver: { _ in nil }
        )

        XCTAssertThrowsError(try client.loadState(refreshScope: .none)) { error in
            XCTAssertEqual(error.localizedDescription, "未找到 codex-auth 命令。")
        }
    }

    func testCLIClientCommandFailurePreservesMessage() {
        let client = CLIClient(
            executablePath: "/mock/codex-auth",
            preferredPath: nil,
            environment: [:],
            commandRunner: { _, _, _ in
                CommandResult(stdout: Data(), stderr: Data("boom".utf8), status: 1)
            },
            shellResolver: { _ in nil }
        )

        XCTAssertThrowsError(try client.loadState(refreshScope: .none)) { error in
            XCTAssertEqual(error.localizedDescription, "codex-auth 执行失败：boom")
        }
    }

    func testCLIClientCurrentRefreshFallsBackToLegacyRefreshInLocalMode() throws {
        let client = CLIClient(
            executablePath: "/mock/codex-auth",
            preferredPath: nil,
            environment: [:],
            commandRunner: { _, args, _ in
                if args == ["list", "--json", "--refresh-active-usage"] {
                    return CommandResult(
                        stdout: Data(),
                        stderr: Data("error: unknown flag `--refresh-active-usage` for `list`".utf8),
                        status: 1
                    )
                }
                if args == ["list", "--json"] {
                    return Self.makeStateCommandResult(
                        activeKey: "acct-primary",
                        apiUsage: false,
                        usageRequested: false,
                        localOnlyMode: true
                    )
                }
                if args == ["list", "--json", "--refresh-usage"] {
                    return Self.makeStateCommandResult(
                        activeKey: "acct-primary",
                        apiUsage: false,
                        usageRequested: true,
                        localOnlyMode: true
                    )
                }
                return CommandResult(stdout: Data(), stderr: Data("unexpected".utf8), status: 1)
            },
            shellResolver: { _ in nil }
        )

        let state = try client.loadState(refreshScope: .activeOnly)
        XCTAssertFalse(state.api.usage)
        XCTAssertTrue(state.refresh.localOnlyMode)
    }

    func testLocalWebServerStateRefreshSwitchAndHealth() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = "CodexAuthMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "restartCodexAfterSwitch")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mock = MockCLI()
        let client = makeClient(home: tempRoot) { executablePath, args, environment in
            try mock.run(executablePath, args, environment)
        }
        let server = LocalWebServer(
            cliClient: client,
            userDefaults: defaults,
            codexAppRestarter: { .restarted }
        )
        defer { server.stop() }

        try server.start()
        let controlURL = try waitForControlURL(server)
        let token = try XCTUnwrap(Self.token(from: controlURL))

        let healthResponse = try await request(
            baseURL: controlURL,
            path: "/api/health",
            token: token
        )
        XCTAssertEqual(healthResponse.statusCode, 200)
        let health = try JSONDecoder().decode(HealthPayload.self, from: healthResponse.body)
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.cliPath, "/mock/codex-auth")
        XCTAssertEqual(health.version, "codex-auth 0.2.4")

        let stateResponse = try await request(
            baseURL: controlURL,
            path: "/api/state",
            token: token
        )
        XCTAssertEqual(stateResponse.statusCode, 200)
        let state = try JSONDecoder().decode(CodexState.self, from: stateResponse.body)
        XCTAssertEqual(state.activeAccountKey, "acct-primary")

        let activeRefreshResponse = try await request(
            baseURL: controlURL,
            path: "/api/refresh-active",
            token: token,
            method: "POST"
        )
        XCTAssertEqual(activeRefreshResponse.statusCode, 200)
        let activeRefreshed = try JSONDecoder().decode(CodexState.self, from: activeRefreshResponse.body)
        XCTAssertEqual(activeRefreshed.refresh.attempted, 1)
        XCTAssertEqual(activeRefreshed.refresh.updated, 1)

        let switchResponse = try await request(
            baseURL: controlURL,
            path: "/api/switch",
            token: token,
            method: "POST",
            body: Data(#"{"account_key":"acct-secondary"}"#.utf8)
        )
        XCTAssertEqual(switchResponse.statusCode, 200)
        let switched = try JSONDecoder().decode(CodexState.self, from: switchResponse.body)
        XCTAssertEqual(switched.activeAccountKey, "acct-secondary")

        let snapshot = mock.snapshot()
        XCTAssertEqual(snapshot.activeRefreshCalls, 1)
        XCTAssertEqual(snapshot.switchKeys, ["acct-secondary"])
        XCTAssertEqual(switchResponse.headers["x-codex-restart-result"], "disabled")
    }

    func testLocalWebServerRejectsMissingTokenAndReturnsCLIFailures() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = makeClient(home: tempRoot) { _, args, _ in
            if args == ["--version"] {
                return CommandResult(stdout: Data("codex-auth 0.2.4\n".utf8), stderr: Data(), status: 0)
            }
            return CommandResult(stdout: Data(), stderr: Data("boom".utf8), status: 1)
        }
        let server = LocalWebServer(cliClient: client)
        defer { server.stop() }

        try server.start()
        let controlURL = try waitForControlURL(server)
        let token = try XCTUnwrap(Self.token(from: controlURL))

        let unauthorized = try await request(
            baseURL: controlURL,
            path: "/api/state",
            token: nil
        )
        XCTAssertEqual(unauthorized.statusCode, 403)
        XCTAssertEqual(
            try JSONDecoder().decode(ErrorPayload.self, from: unauthorized.body).error,
            "未授权"
        )

        let failure = try await request(
            baseURL: controlURL,
            path: "/api/state",
            token: token
        )
        XCTAssertEqual(failure.statusCode, 500)
        XCTAssertEqual(
            try JSONDecoder().decode(ErrorPayload.self, from: failure.body).error,
            "codex-auth 执行失败：boom"
        )
    }

    func testLocalWebServerPreferencesLoginAndRestartHeader() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "CodexAuthMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mock = MockCLI()
        let actions = MockActionRecorder()
        let client = makeClient(home: tempRoot) { executablePath, args, environment in
            try mock.run(executablePath, args, environment)
        }
        let server = LocalWebServer(
            cliClient: client,
            userDefaults: defaults,
            loginLauncher: { _, deviceAuth in
                actions.recordLogin(deviceAuth)
            },
            importLauncher: { _, source in
                actions.recordImport(source)
                return source == .cpaDefault ? .cancelled : .launched
            },
            codexAppRestarter: {
                actions.recordRestart()
                return .restarted
            }
        )
        defer { server.stop() }

        var preferenceChangedCount = 0
        server.onPreferencesChanged = {
            preferenceChangedCount += 1
        }

        try server.start()
        let controlURL = try waitForControlURL(server)
        let token = try XCTUnwrap(Self.token(from: controlURL))

        let initialPreferences = try await request(
            baseURL: controlURL,
            path: "/api/preferences",
            token: token
        )
        XCTAssertEqual(initialPreferences.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(PreferencesPayload.self, from: initialPreferences.body).restartCodexAfterSwitch,
            true
        )

        let loginResponse = try await request(
            baseURL: controlURL,
            path: "/api/login",
            token: token,
            method: "POST",
            body: Data(#"{"device_auth":true}"#.utf8)
        )
        XCTAssertEqual(loginResponse.statusCode, 200)
        let loginPayload = try JSONDecoder().decode(ActionPayload.self, from: loginResponse.body)
        XCTAssertTrue(loginPayload.ok)
        XCTAssertEqual(actions.snapshot().loginCalls, [true])

        let standardImport = try await request(
            baseURL: controlURL,
            path: "/api/import",
            token: token,
            method: "POST",
            body: Data(#"{"source":"standard"}"#.utf8)
        )
        XCTAssertEqual(standardImport.statusCode, 200)
        let standardImportPayload = try JSONDecoder().decode(ActionPayload.self, from: standardImport.body)
        XCTAssertTrue(standardImportPayload.ok)
        XCTAssertEqual(actions.snapshot().importCalls, [.standard])

        let cancelledImport = try await request(
            baseURL: controlURL,
            path: "/api/import",
            token: token,
            method: "POST",
            body: Data(#"{"source":"cpa_default"}"#.utf8)
        )
        XCTAssertEqual(cancelledImport.statusCode, 200)
        let cancelledImportPayload = try JSONDecoder().decode(ActionPayload.self, from: cancelledImport.body)
        XCTAssertFalse(cancelledImportPayload.ok)
        XCTAssertEqual(actions.snapshot().importCalls, [.standard, .cpaDefault])

        let disabledPreferences = try await request(
            baseURL: controlURL,
            path: "/api/preferences",
            token: token,
            method: "POST",
            body: Data(#"{"restart_codex_after_switch":false}"#.utf8)
        )
        XCTAssertEqual(disabledPreferences.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(PreferencesPayload.self, from: disabledPreferences.body).restartCodexAfterSwitch,
            false
        )
        XCTAssertEqual(preferenceChangedCount, 1)

        let disabledSwitch = try await request(
            baseURL: controlURL,
            path: "/api/switch",
            token: token,
            method: "POST",
            body: Data(#"{"account_key":"acct-secondary"}"#.utf8)
        )
        XCTAssertEqual(disabledSwitch.statusCode, 200)
        XCTAssertEqual(disabledSwitch.headers["x-codex-restart-result"], "disabled")
        XCTAssertEqual(actions.snapshot().restartCalls, 0)

        let enabledPreferences = try await request(
            baseURL: controlURL,
            path: "/api/preferences",
            token: token,
            method: "POST",
            body: Data(#"{"restart_codex_after_switch":true}"#.utf8)
        )
        XCTAssertEqual(enabledPreferences.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(PreferencesPayload.self, from: enabledPreferences.body).restartCodexAfterSwitch,
            true
        )
        XCTAssertEqual(preferenceChangedCount, 2)

        let enabledSwitch = try await request(
            baseURL: controlURL,
            path: "/api/switch",
            token: token,
            method: "POST",
            body: Data(#"{"account_key":"acct-primary"}"#.utf8)
        )
        XCTAssertEqual(enabledSwitch.statusCode, 200)
        XCTAssertEqual(enabledSwitch.headers["x-codex-restart-result"], "restarted")
        XCTAssertEqual(actions.snapshot().restartCalls, 1)
    }

    func testHTTPRequestParserWaitsForCompleteBody() {
        let body = #"{"account_key":"acct-secondary"}"#
        let header =
            "POST /api/switch HTTP/1.1\r\n" +
            "Host: 127.0.0.1\r\n" +
            "Content-Type: application/json\r\n" +
            "X-Codex-Auth-Token: token\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "\r\n"

        if case .incomplete = HTTPRequest.parse(from: Data(header.utf8)) {
        } else {
            XCTFail("expected an incomplete request")
        }

        let request = HTTPRequest.parse(from: Data("\(header)\(body)".utf8))
        guard case .complete(let parsed) = request else {
            return XCTFail("expected a complete request")
        }

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/api/switch")
        XCTAssertEqual(parsed.headers["x-codex-auth-token"], "token")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), body)
    }

    private func makeClient(
        home: URL,
        runner: @escaping CLICommandRunner
    ) -> CLIClient {
        CLIClient(
            executablePath: "/mock/codex-auth",
            preferredPath: nil,
            environment: [
                "HOME": home.path
            ],
            commandRunner: runner,
            shellResolver: { _ in nil }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForControlURL(
        _ server: LocalWebServer,
        timeout: TimeInterval = 2
    ) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let url = server.controlURL {
                return url
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw TestError.timeout
    }

    private func request(
        baseURL: URL,
        path: String,
        token: String?,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> HTTPResponse {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil

        var request = URLRequest(url: try XCTUnwrap(components?.url))
        request.httpMethod = method
        request.httpBody = body
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Codex-Auth-Token")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            guard let key = name as? String else { continue }
            headers[key.lowercased()] = String(describing: value)
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }

    private static func token(from controlURL: URL) -> String? {
        URLComponents(url: controlURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value
    }
}

private final class MockCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRefreshCallCount = 0
    private var switchAccountKeys: [String] = []

    func run(_ executablePath: String, _ args: [String], _ environment: [String: String]) throws -> CommandResult {
        lock.lock()
        defer { lock.unlock() }

        if args == ["--version"] {
            return CommandResult(stdout: Data("codex-auth 0.2.4\n".utf8), stderr: Data(), status: 0)
        }
        if args == ["list", "--json"] {
            return state(activeKey: "acct-primary")
        }
        if args == ["list", "--json", "--refresh-active-usage"] {
            activeRefreshCallCount += 1
            return state(activeKey: "acct-primary", usageRequested: true, attempted: 1, updated: 1)
        }
        if args.count == 4,
           args[0] == "switch",
           args[1] == "--account-key",
           args[3] == "--json" {
            let accountKey = args[2]
            switchAccountKeys.append(accountKey)
            return state(activeKey: accountKey)
        }

        return CommandResult(
            stdout: Data(),
            stderr: Data("unexpected args: \(args.joined(separator: " "))".utf8),
            status: 1
        )
    }

    func snapshot() -> (activeRefreshCalls: Int, switchKeys: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (activeRefreshCallCount, switchAccountKeys)
    }

    private func state(
        activeKey: String,
        apiUsage: Bool = true,
        usageRequested: Bool = false,
        attempted: Int = 0,
        updated: Int = 0,
        localOnlyMode: Bool = false
    ) -> CommandResult {
        return CodexAuthMenuTests.makeStateCommandResult(
            activeKey: activeKey,
            apiUsage: apiUsage,
            usageRequested: usageRequested,
            attempted: attempted,
            updated: updated,
            localOnlyMode: localOnlyMode
        )
    }
}

private struct HealthPayload: Decodable {
    var ok: Bool
    var cliPath: String
    var version: String

    enum CodingKeys: String, CodingKey {
        case ok
        case cliPath = "cli_path"
        case version
    }
}

private struct ErrorPayload: Decodable {
    var error: String
}

private struct PreferencesPayload: Decodable {
    var restartCodexAfterSwitch: Bool

    enum CodingKeys: String, CodingKey {
        case restartCodexAfterSwitch = "restart_codex_after_switch"
    }
}

private struct ActionPayload: Decodable {
    var ok: Bool
    var message: String
}

private struct HTTPResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

private enum TestError: Error {
    case timeout
}

private extension CodexAuthMenuTests {
    static func makeStateCommandResult(
        activeKey: String,
        apiUsage: Bool = true,
        usageRequested: Bool = false,
        attempted: Int = 0,
        updated: Int = 0,
        localOnlyMode: Bool = false
    ) -> CommandResult {
        let primaryActive = activeKey == "acct-primary"
        let secondaryActive = activeKey == "acct-secondary"
        let json = """
        {
          "schema_version": 1,
          "codex_home": "/tmp/mock-codex",
          "active_account_key": "\(activeKey)",
          "api": {
            "usage": \(apiUsage),
            "account": true
          },
          "accounts": [
            {
              "account_key": "acct-primary",
              "label": "主账号",
              "email": "primary@example.com",
              "alias": "personal",
              "account_name": "Primary",
              "plan": "Plus",
              "auth_mode": "oauth",
              "active": \(primaryActive),
              "last_used_at": 1713200000,
              "last_usage_at": 1713200000,
              "usage": {
                "status": "ok",
                "five_hour": {
                  "used_percent": 10,
                  "remaining_percent": 90,
                  "window_minutes": 300,
                  "resets_at": 1713203600
                },
                "weekly": {
                  "used_percent": 20,
                  "remaining_percent": 80,
                  "window_minutes": 10080,
                  "resets_at": 1713800000
                },
                "credits": {
                  "has_credits": false,
                  "unlimited": true,
                  "balance": null
                }
              }
            },
            {
              "account_key": "acct-secondary",
              "label": "备用账号",
              "email": "secondary@example.com",
              "alias": "backup",
              "account_name": "Secondary",
              "plan": "Pro",
              "auth_mode": "oauth",
              "active": \(secondaryActive),
              "last_used_at": 1713100000,
              "last_usage_at": 1713100000,
              "usage": {
                "status": "ok",
                "five_hour": {
                  "used_percent": 30,
                  "remaining_percent": 70,
                  "window_minutes": 300,
                  "resets_at": 1713203600
                },
                "weekly": {
                  "used_percent": 40,
                  "remaining_percent": 60,
                  "window_minutes": 10080,
                  "resets_at": 1713800000
                },
                "credits": {
                  "has_credits": false,
                  "unlimited": true,
                  "balance": null
                }
              }
            }
          ],
          "refresh": {
            "usage_requested": \(usageRequested),
            "attempted": \(attempted),
            "updated": \(updated),
            "failed": 0,
            "unchanged": \(usageRequested && updated == 0 && attempted > 0 ? attempted : 0),
            "local_only_mode": \(localOnlyMode)
          }
        }
        """
        return CommandResult(stdout: Data(json.utf8), stderr: Data(), status: 0)
    }
}

private final class MockActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var loginDeviceAuthValues: [Bool] = []
    private var importSources: [CodexImportSource] = []
    private var restartCount = 0

    func recordLogin(_ deviceAuth: Bool) {
        lock.lock()
        defer { lock.unlock() }
        loginDeviceAuthValues.append(deviceAuth)
    }

    func recordImport(_ source: CodexImportSource) {
        lock.lock()
        defer { lock.unlock() }
        importSources.append(source)
    }

    func recordRestart() {
        lock.lock()
        defer { lock.unlock() }
        restartCount += 1
    }

    func snapshot() -> (loginCalls: [Bool], importCalls: [CodexImportSource], restartCalls: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loginDeviceAuthValues, importSources, restartCount)
    }
}
