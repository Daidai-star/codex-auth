import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var state: CodexState?
    @Published var statusMessage = "正在加载"
    @Published var isBusy = false
    @Published var restartCodexAfterSwitch = CodexMenuPreferences.restartCodexAfterSwitch()
    @Published var restartCodexAfterSync = CodexMenuPreferences.restartCodexAfterSync()
    @Published var syncHistoryDuringSwitch = CodexMenuPreferences.syncHistoryDuringSwitch()

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
        statusMessage = syncHistoryDuringSwitch ? "正在切换账号并同步历史会话" : "正在切换账号"
        let client = cliClient
        let shouldRestart = restartCodexAfterSwitch
        let shouldSyncHistory = syncHistoryDuringSwitch
        Task.detached {
            do {
                let newState = try client.switchAccount(
                    accountKey: account.accountKey,
                    syncHistory: shouldSyncHistory
                )
                let restartResult = shouldRestart
                    ? CodexDesktopController.restartRunningCodexApp()
                    : .disabled
                await MainActor.run {
                    self.state = newState
                    let historyNote = shouldSyncHistory
                        ? "历史会话已随切换同步。"
                        : "切换时历史同步已关闭。"
                    self.statusMessage = "\(CodexDesktopController.switchStatusMessage(restartResult: restartResult))\(historyNote)"
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

    func switchAPIProfile(_ profile: APIProfile) {
        guard !profile.active else { return }
        isBusy = true
        statusMessage = syncHistoryDuringSwitch ? "正在切换 API 配置并同步历史会话" : "正在切换 API 配置"
        let client = cliClient
        let shouldRestart = restartCodexAfterSwitch
        let shouldSyncHistory = syncHistoryDuringSwitch
        Task.detached {
            do {
                let newState = try client.switchAPIProfile(
                    profileKey: profile.profileKey,
                    syncHistory: shouldSyncHistory
                )
                let restartResult = shouldRestart
                    ? CodexDesktopController.restartRunningCodexApp()
                    : .disabled
                await MainActor.run {
                    self.state = newState
                    let historyNote = shouldSyncHistory
                        ? "历史会话已随切换同步。"
                        : "切换时历史同步已关闭。"
                    self.statusMessage = "\(CodexDesktopController.switchStatusMessage(restartResult: restartResult))\(historyNote)"
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

    func captureCurrentAPIProfile(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请先填写一个 API 配置名称"
            return
        }
        isBusy = true
        statusMessage = "正在保存当前 API 配置"
        let client = cliClient
        Task.detached {
            do {
                let newState = try client.captureCurrentAPIProfile(label: trimmed)
                await MainActor.run {
                    self.state = newState
                    self.statusMessage = "当前 API 配置已保存：\(trimmed)"
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

    func importCCSwitchProfiles() {
        isBusy = true
        statusMessage = "正在从 cc switch 导入 API 配置"
        let client = cliClient
        Task.detached {
            do {
                let newState = try client.importCCSwitchProfiles(scope: .all)
                await MainActor.run {
                    self.state = newState
                    self.statusMessage = "已从 cc switch 导入 API 配置"
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
        let shouldRestart = restartCodexAfterSync
        Task.detached {
            do {
                let summary = try client.syncHistory()
                let restartResult = shouldRestart
                    ? CodexDesktopController.restartRunningCodexApp()
                    : .disabled
                await MainActor.run {
                    self.statusMessage = CodexDesktopController.historySyncStatusMessage(
                        summary: summary,
                        restartResult: restartResult
                    )
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

    var sortedAPIProfiles: [APIProfile] {
        (state?.apiProfiles ?? []).sorted(by: Self.compareAPIProfiles)
    }

    var featuredAccounts: [Account] {
        Array(sortedAccounts.prefix(8))
    }

    var overflowAccounts: [Account] {
        Array(sortedAccounts.dropFirst(8))
    }

    var apiStatusSummary: String {
        guard let state else { return "正在读取" }
        let mode = state.isAPIKeyMode ? "API 密钥" : "账号"
        let apiUsage = state.api.usage ? "已开启" : "已关闭"
        return "\(mode)模式 · 额度 API：\(apiUsage)"
    }

    var canRefreshAllUsage: Bool {
        state?.api.usage == true
    }

    var canCaptureCurrentAPIProfile: Bool {
        state?.isAPIKeyMode == true
    }

    func setRestartCodexAfterSwitch(_ enabled: Bool) {
        restartCodexAfterSwitch = enabled
        CodexMenuPreferences.setRestartCodexAfterSwitch(enabled)
    }

    func setRestartCodexAfterSync(_ enabled: Bool) {
        restartCodexAfterSync = enabled
        CodexMenuPreferences.setRestartCodexAfterSync(enabled)
    }

    func setSyncHistoryDuringSwitch(_ enabled: Bool) {
        syncHistoryDuringSwitch = enabled
        CodexMenuPreferences.setSyncHistoryDuringSwitch(enabled)
    }

    func loadPreferences() {
        restartCodexAfterSwitch = CodexMenuPreferences.restartCodexAfterSwitch()
        restartCodexAfterSync = CodexMenuPreferences.restartCodexAfterSync()
        syncHistoryDuringSwitch = CodexMenuPreferences.syncHistoryDuringSwitch()
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
            if state.isAPIKeyMode {
                return state.activeAPIProfile.map { "已就绪：\($0.label)" } ?? "已就绪：API 密钥模式"
            }
            return "已就绪"
        case .activeOnly:
            if state.isAPIKeyMode {
                return "当前是 API 密钥模式，没有可同步的账号额度"
            }
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

    private static func compareAPIProfiles(lhs: APIProfile, rhs: APIProfile) -> Bool {
        if lhs.active != rhs.active {
            return lhs.active && !rhs.active
        }

        let lhsLastUsed = lhs.lastUsedAt ?? Int64.min
        let rhsLastUsed = rhs.lastUsedAt ?? Int64.min
        if lhsLastUsed != rhsLastUsed {
            return lhsLastUsed > rhsLastUsed
        }

        return lhs.label.localizedLowercase < rhs.label.localizedLowercase
    }
}
