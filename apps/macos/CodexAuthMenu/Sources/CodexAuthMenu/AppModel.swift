import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var state: CodexState?
    @Published var statusMessage = "正在加载"
    @Published var isBusy = false
    @Published var restartCodexAfterSwitch = CodexMenuPreferences.restartCodexAfterSwitch()

    let cliClient: CLIClient
    let webServer: LocalWebServer

    init() {
        let client = CLIClient()
        cliClient = client
        webServer = LocalWebServer(cliClient: client)
        webServer.onStateChanged = { [weak self] in
            Task { @MainActor in
                self?.load()
            }
        }
        webServer.onPreferencesChanged = { [weak self] in
            Task { @MainActor in
                self?.loadPreferences()
            }
        }

        do {
            try webServer.start()
        } catch {
            statusMessage = "网页控制台启动失败：\(error.localizedDescription)"
        }

        loadPreferences()
        load()
    }

    func load(refreshScope: UsageRefreshScope = .none) {
        isBusy = true
        statusMessage = loadingMessage(for: refreshScope)
        let client = cliClient
        Task.detached {
            do {
                let newState = try client.loadState(refreshScope: refreshScope)
                await MainActor.run {
                    self.state = newState
                    self.statusMessage = self.loadedMessage(for: refreshScope, state: newState)
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func switchAccount(_ account: Account) {
        guard !account.active else { return }
        isBusy = true
        statusMessage = "正在切换账号"
        let client = cliClient
        let shouldRestart = restartCodexAfterSwitch
        Task.detached {
            do {
                let newState = try client.switchAccount(accountKey: account.accountKey)
                let restartResult = shouldRestart
                    ? CodexDesktopController.restartRunningCodexApp()
                    : .disabled
                await MainActor.run {
                    self.state = newState
                    self.statusMessage = CodexDesktopController.switchStatusMessage(restartResult: restartResult)
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func startLogin(deviceAuth: Bool) {
        isBusy = true
        statusMessage = deviceAuth ? "正在打开设备码登录" : "正在打开账号登录"
        let client = cliClient
        Task.detached {
            do {
                try client.openLoginInTerminal(deviceAuth: deviceAuth)
                await MainActor.run {
                    self.statusMessage = CodexDesktopController.loginStatusMessage(deviceAuth: deviceAuth)
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func startImport(source: CodexImportSource) {
        isBusy = true
        statusMessage = "正在准备\(source.title)"
        let client = cliClient
        Task.detached {
            do {
                let result = try client.openImportInTerminal(source: source)
                await MainActor.run {
                    self.statusMessage = result == .launched
                        ? CodexDesktopController.importStatusMessage(source: source)
                        : CodexDesktopController.importCancelledMessage(source: source)
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func syncHistory() {
        isBusy = true
        statusMessage = "正在同步历史会话"
        let client = cliClient
        Task.detached {
            do {
                let summary = try client.syncHistory()
                await MainActor.run {
                    self.statusMessage = summary.mirroredThreads > 0
                        ? "历史会话同步完成：新增 \(summary.mirroredThreads) 个镜像会话"
                        : "历史会话已检查：没有需要补齐的镜像会话"
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    var sortedAccounts: [Account] {
        (state?.accounts ?? []).sorted(by: Self.compareAccounts)
    }

    var featuredAccounts: [Account] {
        Array(sortedAccounts.prefix(8))
    }

    var overflowAccounts: [Account] {
        Array(sortedAccounts.dropFirst(8))
    }

    var apiStatusSummary: String {
        guard let api = state?.api else { return "额度 API：读取中" }
        return "额度 API：\(api.usage ? "已开启" : "已关闭")"
    }

    var canRefreshAllUsage: Bool {
        state?.api.usage == true
    }

    func setRestartCodexAfterSwitch(_ enabled: Bool) {
        restartCodexAfterSwitch = enabled
        CodexMenuPreferences.setRestartCodexAfterSwitch(enabled)
    }

    func loadPreferences() {
        restartCodexAfterSwitch = CodexMenuPreferences.restartCodexAfterSwitch()
    }

    func openWebControl() {
        do {
            try webServer.start()
            if let url = webServer.controlURL {
                NSWorkspace.shared.open(url)
                statusMessage = "已打开网页控制台"
            } else {
                statusMessage = "网页控制台正在启动"
            }
        } catch {
            statusMessage = "网页控制台启动失败：\(error.localizedDescription)"
        }
    }

    func quit() {
        webServer.stop()
        NSApplication.shared.terminate(nil)
    }

    private func loadingMessage(for refreshScope: UsageRefreshScope) -> String {
        switch refreshScope {
        case .none:
            return "正在加载"
        case .activeOnly:
            return "正在同步本地额度"
        case .allAccounts:
            return "正在刷新全部账号额度"
        }
    }

    private func loadedMessage(for refreshScope: UsageRefreshScope, state: CodexState) -> String {
        switch refreshScope {
        case .none:
            return "已就绪"
        case .activeOnly:
            if state.refresh.localOnlyMode || !state.api.usage {
                if let active = state.activeAccount {
                    return "本地额度已同步：\(active.label)"
                }
                return "当前没有可同步的本地额度"
            }
            if let active = state.activeAccount, let failure = active.usageFailureSummary {
                return "当前账号额度刷新失败：\(failure)"
            }
            guard state.refresh.attempted > 0, let active = state.activeAccount else {
                return "当前没有可同步的本地额度"
            }
            if state.refresh.updated > 0 {
                return "本地额度已更新：\(active.label)"
            }
            return "本地额度已同步：\(active.label)"
        case .allAccounts:
            if !state.api.usage || state.refresh.localOnlyMode {
                return "全部额度刷新需要先开启额度 API"
            }
            if state.refresh.attempted == 0 {
                return "当前没有可刷新的账号额度"
            }
            if state.refresh.failed == state.refresh.attempted {
                return "全部额度刷新失败，请检查 Node.js 或账号登录态"
            }
            return "全部额度刷新完成：\(state.refresh.updated) 个已更新，\(state.refresh.failed) 个失败"
        }
    }

    private static func compareAccounts(lhs: Account, rhs: Account) -> Bool {
        if lhs.active != rhs.active {
            return lhs.active && !rhs.active
        }

        let lhsLastUsed = lhs.lastUsedAt ?? Int64.min
        let rhsLastUsed = rhs.lastUsedAt ?? Int64.min
        if lhsLastUsed != rhsLastUsed {
            return lhsLastUsed > rhsLastUsed
        }

        let lhsLabel = lhs.label.localizedLowercase
        let rhsLabel = rhs.label.localizedLowercase
        if lhsLabel != rhsLabel {
            return lhsLabel < rhsLabel
        }

        return lhs.email.localizedLowercase < rhs.email.localizedLowercase
    }
}
