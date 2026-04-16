import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var state: CodexState?
    @Published var statusMessage = "正在加载"
    @Published var isBusy = false

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

        do {
            try webServer.start()
        } catch {
            statusMessage = "网页控制台启动失败：\(error.localizedDescription)"
        }

        load()
    }

    func load(refreshUsage: Bool = false) {
        isBusy = true
        statusMessage = refreshUsage ? "正在刷新额度" : "正在加载"
        let client = cliClient
        Task.detached {
            do {
                let newState = try client.loadState(refreshUsage: refreshUsage)
                await MainActor.run {
                    self.state = newState
                    self.statusMessage = refreshUsage
                        ? "额度刷新完成：\(newState.refresh.updated) 个已更新，\(newState.refresh.failed) 个失败"
                        : "已就绪"
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
        Task.detached {
            do {
                let newState = try client.switchAccount(accountKey: account.accountKey)
                await MainActor.run {
                    self.state = newState
                    self.statusMessage = "已切换。请重启 Codex CLI 或 Codex App 让新账号生效。"
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
}
