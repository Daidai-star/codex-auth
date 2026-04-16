import Foundation

typealias CLICommandRunner = @Sendable (_ executablePath: String, _ args: [String], _ environment: [String: String]) throws -> CommandResult
typealias CLIExecutableChecker = @Sendable (_ path: String) -> Bool
typealias CLIShellResolver = @Sendable (_ environment: [String: String]) -> String?

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

struct CLIClient: Sendable {
    let executablePath: String?
    private let commandRunner: CLICommandRunner
    private let codexEnvironment: [String: String]

    init(
        executablePath: String? = nil,
        preferredPath: String? = UserDefaults.standard.string(forKey: "codexAuthCLIPath"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: @escaping CLICommandRunner = { executablePath, args, environment in
            try CLIClient.runExecutable(executablePath, args: args, environment: environment)
        },
        isExecutable: @escaping CLIExecutableChecker = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping CLIShellResolver = { environment in
            CLIClient.resolveViaShell(environment: environment)
        }
    ) {
        let resolvedShellEnvironment = CLIClient.makeShellEnvironment(from: environment)
        codexEnvironment = CLIClient.makeCodexEnvironment(from: resolvedShellEnvironment)
        self.commandRunner = commandRunner
        self.executablePath = executablePath ?? CLIClient.resolveExecutablePath(
            preferredPath: preferredPath,
            environment: resolvedShellEnvironment,
            isExecutable: isExecutable,
            shellResolver: shellResolver
        )
    }

    var displayPath: String {
        executablePath ?? "未找到"
    }

    func loadState(refreshUsage: Bool) throws -> CodexState {
        var args = ["list", "--json"]
        if refreshUsage {
            args.append("--refresh-usage")
        }
        let result = try run(args)
        return try decodeState(result.stdout)
    }

    func switchAccount(accountKey: String) throws -> CodexState {
        let result = try run(["switch", "--account-key", accountKey, "--json"])
        return try decodeState(result.stdout)
    }

    func versionText() -> String {
        guard let result = try? run(["--version"]) else {
            return "不可用"
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func run(_ args: [String]) throws -> CommandResult {
        guard let executablePath else {
            throw CLIClientError.missingCLI
        }
        let result = try commandRunner(executablePath, args, codexEnvironment)
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

    static func resolveExecutablePath(
        preferredPath: String?,
        environment: [String: String],
        isExecutable: @escaping CLIExecutableChecker = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping CLIShellResolver = { environment in
            CLIClient.resolveViaShell(environment: environment)
        }
    ) -> String? {
        var seen = Set<String>()
        var candidates: [String] = []

        func appendCandidate(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

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

        if let path = shellResolver(environment), isExecutable(path) {
            return path
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

    private static func resolveViaShell(environment: [String: String]) -> String? {
        guard let result = try? runExecutable("/bin/zsh", args: ["-lc", "command -v codex-auth"], environment: environment),
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

    private static func makeCodexEnvironment(from shellEnvironment: [String: String]) -> [String: String] {
        var env = shellEnvironment
        env["CODEX_AUTH_SKIP_SERVICE_RECONCILE"] = "1"
        return env
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

    private static let defaultPathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
}
