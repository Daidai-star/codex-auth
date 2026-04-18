import Foundation

typealias CLICommandRunner = @Sendable (_ executablePath: String, _ args: [String], _ environment: [String: String]) throws -> CommandResult
typealias CLIExecutableChecker = @Sendable (_ path: String) -> Bool
typealias CLIShellResolver = @Sendable (_ command: String, _ environment: [String: String]) -> String?

enum CLIClientError: LocalizedError {
    case missingCLI
    case failed(status: Int32, stderr: String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return "未找到 codex-auth 命令。"
        case .failed(let status, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "codex-auth 退出状态：\(status)。"
            }
            return "codex-auth 执行失败：\(message)"
        case .invalidOutput(let message):
            return message
        }
    }
}

struct CommandResult: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32

    var stdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrText: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

struct HistorySyncSummary: Sendable {
    var providerUpdatedThreads: Int
    var indexedThreads: Int
}

enum APIProfileImportScope: Sendable {
    case current
    case all
    case provider(String)
}

struct CLIClient: Sendable {
    private static let skipHistorySyncEnvironmentKey = "CODEX_AUTH_SKIP_HISTORY_SYNC"

    let executablePath: String?
    private let commandRunner: CLICommandRunner
    private let codexEnvironment: [String: String]
    private let shellEnvironment: [String: String]

    init(
        executablePath: String? = nil,
        preferredPath: String? = nil,
        bundledPath: String? = CLIClient.bundledExecutablePath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: @escaping CLICommandRunner = { executablePath, args, environment in
            try CLIClient.runExecutable(executablePath, args: args, environment: environment)
        },
        isExecutable: @escaping CLIExecutableChecker = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping CLIShellResolver = { command, environment in
            CLIClient.resolveViaShell(command: command, environment: environment)
        }
    ) {
        let resolvedShellEnvironment = CLIClient.makeShellEnvironment(from: environment)
        shellEnvironment = resolvedShellEnvironment
        codexEnvironment = CLIClient.makeCodexEnvironment(
            from: resolvedShellEnvironment,
            isExecutable: isExecutable,
            shellResolver: shellResolver
        )
        self.commandRunner = commandRunner
        self.executablePath = executablePath ?? CLIClient.resolveExecutablePath(
            preferredPath: preferredPath,
            bundledPath: bundledPath,
            environment: resolvedShellEnvironment,
            isExecutable: isExecutable,
            shellResolver: shellResolver
        )
    }

    var displayPath: String {
        executablePath ?? "未找到"
    }

    func loadState(refreshScope: UsageRefreshScope) throws -> CodexState {
        switch refreshScope {
        case .none:
            return try loadState(args: ["list", "--json"])
        case .activeOnly:
            return try loadStateRefreshingActiveAccount()
        case .allAccounts:
            return try loadState(args: ["list", "--json", "--refresh-usage"])
        }
    }

    func switchAccount(accountKey: String, syncHistory: Bool = true) throws -> CodexState {
        let result = try run(
            ["switch", "--account-key", accountKey, "--json"],
            additionalEnvironment: syncHistory ? [:] : [Self.skipHistorySyncEnvironmentKey: "1"]
        )
        return try decodeState(result.stdout)
    }

    func captureCurrentAPIProfile(label: String) throws -> CodexState {
        let result = try run([
            "api-profile",
            "capture",
            "--label",
            label,
            "--json",
        ])
        return try decodeState(result.stdout)
    }

    func switchAPIProfile(profileKey: String, syncHistory: Bool = true) throws -> CodexState {
        let result = try run([
            "api-profile",
            "switch",
            "--profile-key",
            profileKey,
            "--json",
        ], additionalEnvironment: syncHistory ? [:] : [Self.skipHistorySyncEnvironmentKey: "1"])
        return try decodeState(result.stdout)
    }

    func importCCSwitchProfiles(scope: APIProfileImportScope = .all) throws -> CodexState {
        var args = ["api-profile", "import-cc-switch"]
        switch scope {
        case .current:
            args.append("--current")
        case .all:
            args.append("--all")
        case .provider(let providerID):
            args.append(contentsOf: ["--provider-id", providerID])
        }
        args.append("--json")
        let result = try run(args)
        return try decodeState(result.stdout)
    }

    func setAPIConfig(usageAccountEnabled: Bool? = nil) throws -> ApiConfig {
        if let usageAccountEnabled {
            _ = try run(["config", "api", usageAccountEnabled ? "enable" : "disable"])
        }
        return try loadState(refreshScope: .none).api
    }

    func setRenewal(accountKey: String, date: String) throws -> CodexState {
        let result = try run([
            "renewal",
            "set",
            "--account-key",
            accountKey,
            "--date",
            date,
            "--json",
        ])
        return try decodeState(result.stdout)
    }

    func clearRenewal(accountKey: String) throws -> CodexState {
        let result = try run([
            "renewal",
            "clear",
            "--account-key",
            accountKey,
            "--json",
        ])
        return try decodeState(result.stdout)
    }

    func versionText() -> String {
        guard let result = try? run(["--version"]) else {
            return "不可用"
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func syncHistory() throws -> HistorySyncSummary {
        let result = try run(["sync-history"])
        return try decodeHistorySyncSummary(result.stdoutText)
    }

    func openLoginInTerminal(deviceAuth: Bool) throws {
        guard let executablePath else {
            throw CLIClientError.missingCLI
        }
        let command = Self.loginShellCommand(
            executablePath: executablePath,
            environment: shellEnvironment,
            deviceAuth: deviceAuth
        )
        try CodexDesktopController.launchLoginInTerminal(shellCommand: command)
    }

    func openImportInTerminal(source: CodexImportSource) throws -> TerminalLaunchResult {
        guard let executablePath else {
            throw CLIClientError.missingCLI
        }

        let selectedPath: String?
        if source.requiresPathSelection {
            guard let selectedURL = CodexDesktopController.chooseImportURL(for: source) else {
                return .cancelled
            }
            selectedPath = selectedURL.path
        } else {
            selectedPath = nil
        }

        let command = Self.importShellCommand(
            executablePath: executablePath,
            environment: shellEnvironment,
            source: source,
            selectedPath: selectedPath
        )
        try CodexDesktopController.launchLoginInTerminal(shellCommand: command)
        return .launched
    }

    func run(_ args: [String]) throws -> CommandResult {
        try run(args, additionalEnvironment: [:])
    }

    private func run(_ args: [String], additionalEnvironment: [String: String]) throws -> CommandResult {
        guard let executablePath else {
            throw CLIClientError.missingCLI
        }
        var environment = codexEnvironment
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        let result = try commandRunner(executablePath, args, environment)
        if result.status != 0 {
            throw CLIClientError.failed(status: result.status, stderr: result.stderrText)
        }
        return result
    }

    private func decodeState(_ data: Data) throws -> CodexState {
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(CodexState.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CLIClientError.invalidOutput("codex-auth 返回的 JSON 无法解析：\(text)")
        }
    }

    private func loadState(args: [String]) throws -> CodexState {
        let result = try run(args)
        return try decodeState(result.stdout)
    }

    private func decodeHistorySyncSummary(_ text: String) throws -> HistorySyncSummary {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let providerUpdatedThreads = parseHistoryMetric("provider_updated_threads", from: trimmed) else {
            throw CLIClientError.invalidOutput("codex-auth 返回了无法识别的历史同步结果：\(trimmed)")
        }
        let indexedThreads = parseHistoryMetric("indexed_threads", from: trimmed) ?? 0
        return HistorySyncSummary(providerUpdatedThreads: providerUpdatedThreads, indexedThreads: indexedThreads)
    }

    private func parseHistoryMetric(_ name: String, from text: String) -> Int? {
        guard let range = text.range(of: "\(name)=") else {
            return nil
        }
        let numberText = text[range.upperBound...].prefix { $0.isNumber }
        return Int(numberText)
    }

    private func loadStateRefreshingActiveAccount() throws -> CodexState {
        do {
            return try loadState(args: ["list", "--json", "--refresh-active-usage"])
        } catch CLIClientError.failed(_, let stderr) where Self.isUnknownRefreshActiveFlagError(stderr) {
            let state = try loadState(args: ["list", "--json"])
            if state.api.usage {
                throw CLIClientError.invalidOutput("当前 codex-auth 版本不支持“刷新当前账号额度”。请重新打开最新版 Codex 账号，或升级 codex-auth 后重试。")
            }
            return try loadState(args: ["list", "--json", "--refresh-usage"])
        }
    }

    static func resolveExecutablePath(
        preferredPath: String?,
        bundledPath: String? = nil,
        environment: [String: String],
        isExecutable: @escaping CLIExecutableChecker = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping CLIShellResolver = { command, environment in
            CLIClient.resolveViaShell(command: command, environment: environment)
        }
    ) -> String? {
        var seen = Set<String>()
        var candidates: [String] = []

        func appendCandidate(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        appendCandidate(bundledPath)
        appendCandidate(preferredPath)
        appendCandidate(environment["CODEX_AUTH_CLI_PATH"])
        if let nvmBin = environment["NVM_BIN"], !nvmBin.isEmpty {
            appendCandidate((nvmBin as NSString).appendingPathComponent("codex-auth"))
        }
        for entry in pathEntries(from: environment["PATH"]) {
            appendCandidate((entry as NSString).appendingPathComponent("codex-auth"))
        }

        for path in candidates where isExecutable(path) {
            return path
        }

        if let path = shellResolver("codex-auth", environment), isExecutable(path) {
            return path
        }

        return nil
    }

    private static func bundledExecutablePath(bundle: Bundle = .main) -> String? {
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("codex-auth").path,
            bundle.resourceURL?.appendingPathComponent("bin/codex-auth").path,
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func runExecutable(
        _ executablePath: String,
        args: [String],
        environment: [String: String]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = nil

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(stdout: stdoutData, stderr: stderrData, status: process.terminationStatus)
    }

    private static func resolveNodeExecutablePath(
        environment: [String: String],
        isExecutable: @escaping CLIExecutableChecker = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping CLIShellResolver = { command, environment in
            CLIClient.resolveViaShell(command: command, environment: environment)
        }
    ) -> String? {
        var seen = Set<String>()
        var candidates: [String] = []

        func appendCandidate(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        appendCandidate(environment["CODEX_AUTH_NODE_EXECUTABLE"])
        if let nvmBin = environment["NVM_BIN"], !nvmBin.isEmpty {
            appendCandidate((nvmBin as NSString).appendingPathComponent("node"))
        }
        for entry in pathEntries(from: environment["PATH"]) {
            appendCandidate((entry as NSString).appendingPathComponent("node"))
        }
        if let home = firstNonEmpty(environment["HOME"], environment["USERPROFILE"]) {
            for candidate in discoverUserNodeCandidates(home: home) {
                appendCandidate(candidate)
            }
        }

        for path in candidates where isExecutable(path) {
            return path
        }

        if let path = shellResolver("node", environment), isExecutable(path) {
            return path
        }

        return nil
    }

    private static func resolveViaShell(command: String, environment: [String: String]) -> String? {
        guard let result = try? runExecutable("/bin/zsh", args: ["-lc", "command -v \(shellQuoted(command))"], environment: environment),
              result.status == 0 else {
            return nil
        }
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func makeShellEnvironment(from environment: [String: String]) -> [String: String] {
        var env = environment
        let home = firstNonEmpty(environment["HOME"], environment["USERPROFILE"]) ?? NSHomeDirectory()
        let mergedPath = uniquePathEntries(pathEntries(from: environment["PATH"]) + defaultPathEntries)
        env["PATH"] = mergedPath.joined(separator: ":")
        env["HOME"] = home
        env["USERPROFILE"] = home
        return env
    }

    private static func makeCodexEnvironment(
        from shellEnvironment: [String: String],
        isExecutable: @escaping CLIExecutableChecker = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping CLIShellResolver = { command, environment in
            CLIClient.resolveViaShell(command: command, environment: environment)
        }
    ) -> [String: String] {
        var env = shellEnvironment
        env["CODEX_AUTH_SKIP_SERVICE_RECONCILE"] = "1"
        env["CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH"] = "1"
        if let nodePath = resolveNodeExecutablePath(
            environment: shellEnvironment,
            isExecutable: isExecutable,
            shellResolver: shellResolver
        ) {
            env["CODEX_AUTH_NODE_EXECUTABLE"] = nodePath
            let nodeDir = (nodePath as NSString).deletingLastPathComponent
            let mergedPath = uniquePathEntries([nodeDir] + pathEntries(from: env["PATH"]))
            env["PATH"] = mergedPath.joined(separator: ":")
        }
        return env
    }

    private static func loginShellCommand(
        executablePath: String,
        environment: [String: String],
        deviceAuth: Bool
    ) -> String {
        let exportedKeys = ["PATH", "HOME", "USERPROFILE", "CODEX_HOME"]
        let exports = exportedKeys.compactMap { key -> String? in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return "export \(key)=\(shellQuoted(value))"
        }

        var parts = exports
        parts.append("\(shellQuoted(executablePath)) login\(deviceAuth ? " --device-auth" : "")")
        parts.append("status=$?")
        parts.append("echo")
        parts.append("if [ $status -eq 0 ]; then echo \(shellQuoted("登录流程已结束，回到 Codex 账号 点“重新加载”即可。")); else echo \(shellQuoted("登录流程退出码："))$status; fi")
        parts.append("echo")
        parts.append("echo \(shellQuoted("按回车关闭此窗口"))")
        parts.append("read _")
        return parts.joined(separator: "; ")
    }

    private static func importShellCommand(
        executablePath: String,
        environment: [String: String],
        source: CodexImportSource,
        selectedPath: String?
    ) -> String {
        let exportedKeys = ["PATH", "HOME", "USERPROFILE", "CODEX_HOME"]
        let exports = exportedKeys.compactMap { key -> String? in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return "export \(key)=\(shellQuoted(value))"
        }

        var commandParts = [shellQuoted(executablePath)]
        commandParts.append(contentsOf: source.shellArguments.map(shellQuoted))
        if let selectedPath, !selectedPath.isEmpty {
            commandParts.append(shellQuoted(selectedPath))
        }

        var parts = exports
        parts.append(commandParts.joined(separator: " "))
        parts.append("status=$?")
        parts.append("echo")
        parts.append("if [ $status -eq 0 ]; then echo \(shellQuoted("导入流程已结束，回到 Codex 账号 点“重新加载”即可。")); else echo \(shellQuoted("导入流程退出码："))$status; fi")
        parts.append("echo")
        parts.append("echo \(shellQuoted("按回车关闭此窗口"))")
        parts.append("read _")
        return parts.joined(separator: "; ")
    }

    private static func pathEntries(from rawPath: String?) -> [String] {
        guard let rawPath, !rawPath.isEmpty else { return [] }
        return rawPath
            .split(separator: ":")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func uniquePathEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { entry in
            guard !entry.isEmpty else { return false }
            return seen.insert(entry).inserted
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.isEmpty
        } ?? nil
    }

    private static func discoverUserNodeCandidates(home: String) -> [String] {
        let fileManager = FileManager.default
        var candidates = [
            (home as NSString).appendingPathComponent(".nvm/current/bin/node"),
            (home as NSString).appendingPathComponent(".nodenv/shims/node"),
        ]

        let nvmVersionsRoot = (home as NSString).appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmVersionsRoot) {
            let sortedVersions = versions.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            for version in sortedVersions.reversed() {
                candidates.append(
                    (nvmVersionsRoot as NSString).appendingPathComponent("\(version)/bin/node")
                )
            }
        }

        return candidates
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func isUnknownRefreshActiveFlagError(_ stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("unknown flag `--refresh-active-usage`") ||
            normalized.contains("unknown flag '--refresh-active-usage'") ||
            normalized.contains("unexpected argument `--refresh-active-usage`")
    }

    private static let defaultPathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
}
