import AppKit
import Foundation

enum CodexImportSource: String, Codable, Sendable, Equatable {
    case standard
    case cpa
    case cpaDefault = "cpa_default"

    var title: String {
        switch self {
        case .standard:
            return "导入 auth.json 或文件夹"
        case .cpa:
            return "导入 CPA 文件或目录"
        case .cpaDefault:
            return "扫描默认 CPA 目录"
        }
    }

    var terminalStatusMessage: String {
        switch self {
        case .standard:
            return "已在终端打开 auth 导入。完成后回到这里点“重新加载”即可。"
        case .cpa:
            return "已在终端打开 CPA 导入。完成后回到这里点“重新加载”即可。"
        case .cpaDefault:
            return "已在终端开始扫描默认 CPA 目录。完成后回到这里点“重新加载”即可。"
        }
    }

    var cancelledMessage: String {
        switch self {
        case .standard, .cpa:
            return "已取消导入。"
        case .cpaDefault:
            return "已取消扫描默认 CPA 目录。"
        }
    }

    var shellArguments: [String] {
        switch self {
        case .standard:
            return ["import"]
        case .cpa:
            return ["import", "--cpa"]
        case .cpaDefault:
            return ["import", "--cpa"]
        }
    }

    var requiresPathSelection: Bool {
        switch self {
        case .standard, .cpa:
            return true
        case .cpaDefault:
            return false
        }
    }
}

enum TerminalLaunchResult: Sendable, Equatable {
    case launched
    case cancelled
}

enum CodexMenuPreferences {
    private static let restartCodexAfterSwitchKey = "restartCodexAfterSwitch"
    private static let restartCodexAfterSyncKey = "restartCodexAfterSync"
    private static let syncHistoryDuringSwitchKey = "syncHistoryDuringSwitch"
    private static let restartCodexAfterSwitchDefault = true
    private static let restartCodexAfterSyncDefault = true
    private static let syncHistoryDuringSwitchDefault = true

    static func restartCodexAfterSwitch(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: restartCodexAfterSwitchKey) != nil else {
            return restartCodexAfterSwitchDefault
        }
        return userDefaults.bool(forKey: restartCodexAfterSwitchKey)
    }

    static func restartCodexAfterSync(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: restartCodexAfterSyncKey) != nil else {
            return restartCodexAfterSyncDefault
        }
        return userDefaults.bool(forKey: restartCodexAfterSyncKey)
    }

    static func syncHistoryDuringSwitch(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: syncHistoryDuringSwitchKey) != nil else {
            return syncHistoryDuringSwitchDefault
        }
        return userDefaults.bool(forKey: syncHistoryDuringSwitchKey)
    }

    static func setRestartCodexAfterSwitch(_ value: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(value, forKey: restartCodexAfterSwitchKey)
    }

    static func setRestartCodexAfterSync(_ value: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(value, forKey: restartCodexAfterSyncKey)
    }

    static func setSyncHistoryDuringSwitch(_ value: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(value, forKey: syncHistoryDuringSwitchKey)
    }
}

enum CodexAppRestartResult: String {
    case disabled
    case restarted = "restarted"
    case notRunning = "not_running"
    case notInstalled = "not_installed"
    case failed = "failed"
}

enum CodexDesktopControllerError: LocalizedError {
    case failedToLaunchTerminal(String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunchTerminal(let message):
            return "无法在终端中打开操作：\(message)"
        }
    }
}

enum CodexDesktopController {
    static let codexBundleIdentifier = "com.openai.codex"
    private static let terminalBundleIdentifier = "com.apple.Terminal"
    private static let codexAppURL = URL(fileURLWithPath: "/Applications/Codex.app")

    static func launchLoginInTerminal(shellCommand: String) throws {
        let script = """
        tell application id "\(terminalBundleIdentifier)"
            activate
            do script \(appleScriptQuoted(shellCommand))
        end tell
        """

        let result = try runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script]
        )
        guard result.status == 0 else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexDesktopControllerError.failedToLaunchTerminal(message.isEmpty ? "未知错误" : message)
        }
    }

    static func restartRunningCodexApp() -> CodexAppRestartResult {
        guard let appURL = onMain({ codexAppURLOrNil() }) else {
            return .notInstalled
        }

        let runningApps = onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)
        }
        guard !runningApps.isEmpty else {
            return .notRunning
        }

        onMain {
            for app in runningApps {
                _ = app.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let remainingApps = onMain {
                NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)
            }
            if remainingApps.isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let lingeringApps = onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)
        }
        if !lingeringApps.isEmpty {
            onMain {
                for app in lingeringApps {
                    _ = app.forceTerminate()
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let opened = onMain {
            NSWorkspace.shared.open(appURL)
        }
        guard opened else {
            return .failed
        }
        return .restarted
    }

    static func loginStatusMessage(deviceAuth: Bool) -> String {
        if deviceAuth {
            return "已在终端打开设备码登录。若终端提示找不到 codex，请先安装官方 Codex CLI。完成后回到这里点“重新加载”即可。"
        }
        return "已在终端打开账号登录。若终端提示找不到 codex，请先安装官方 Codex CLI。完成后回到这里点“重新加载”即可。"
    }

    static func importStatusMessage(source: CodexImportSource) -> String {
        source.terminalStatusMessage
    }

    static func importCancelledMessage(source: CodexImportSource) -> String {
        source.cancelledMessage
    }

    static func chooseImportURL(for source: CodexImportSource) -> URL? {
        guard source.requiresPathSelection else { return nil }

        return onMain {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            panel.title = source.title
            panel.message = "选择一个文件或文件夹，然后在终端完成导入。"
            panel.prompt = "继续"
            NSApp.activate(ignoringOtherApps: true)
            let response = panel.runModal()
            return response == .OK ? panel.url : nil
        }
    }

    static func switchStatusMessage(restartResult: CodexAppRestartResult) -> String {
        switch restartResult {
        case .disabled:
            return "已切换。当前未开启自动重启 Codex App；终端里的 Codex CLI 会话仍需手动重新进入。"
        case .restarted:
            return "已切换，并已自动重启 Codex App。终端里的 Codex CLI 会话仍需手动重新进入。"
        case .notRunning:
            return "已切换。Codex App 当前未打开，下次启动时会使用新账号；终端里的 Codex CLI 会话仍需手动重新进入。"
        case .notInstalled:
            return "已切换，但未找到 Codex App；终端里的 Codex CLI 会话仍需手动重新进入。"
        case .failed:
            return "已切换，但自动重启 Codex App 失败；终端里的 Codex CLI 会话仍需手动重新进入。"
        }
    }

    static func historySyncStatusMessage(
        summary: HistorySyncSummary,
        restartResult: CodexAppRestartResult
    ) -> String {
        let syncMessage: String
        if summary.providerUpdatedThreads > 0 || summary.indexedThreads > 0 {
            syncMessage = "历史会话同步完成：更新 \(summary.providerUpdatedThreads) 条会话归属，补齐 \(summary.indexedThreads) 条历史索引。"
        } else {
            syncMessage = "历史会话已检查：没有需要更新的会话归属或历史索引。"
        }

        let restartMessage: String
        switch restartResult {
        case .disabled:
            restartMessage = "当前未开启同步后自动重启 Codex App。"
        case .restarted:
            restartMessage = "Codex App 已自动重启，侧边栏会重新读取历史。"
        case .notRunning:
            restartMessage = "Codex App 当前未打开，下次启动时会读取这套历史。"
        case .notInstalled:
            restartMessage = "未找到 Codex App，无法自动重启。"
        case .failed:
            restartMessage = "自动重启 Codex App 失败，可以手动重启一次。"
        }
        return "\(syncMessage)\(restartMessage)"
    }

    private static func codexAppURLOrNil() -> URL? {
        if let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleIdentifier) {
            return resolved
        }
        return FileManager.default.fileExists(atPath: codexAppURL.path) ? codexAppURL : nil
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = nil

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
            status: process.terminationStatus
        )
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}
