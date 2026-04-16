import AppKit
import SwiftUI

@main
struct CodexAuthMenuApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Codex 账号", systemImage: "person.crop.circle.badge.checkmark") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let active = model.state?.activeAccount {
            Text("当前账号：\(active.label)")
            Text(active.email)
        } else {
            Text("未选择账号")
        }

        Text(model.statusMessage)
        Divider()

        Button("打开网页控制台") {
            model.openWebControl()
        }

        Button("重新加载") {
            model.load()
        }
        .disabled(model.isBusy)

        Button("刷新额度") {
            model.load(refreshUsage: true)
        }
        .disabled(model.isBusy)

        Divider()

        if let accounts = model.state?.accounts, !accounts.isEmpty {
            ForEach(accounts) { account in
                Button {
                    model.switchAccount(account)
                } label: {
                    VStack(alignment: .leading) {
                        Text(account.active ? "当前 · \(account.label)" : account.label)
                        Text(account.usageLine)
                    }
                }
                .disabled(account.active || model.isBusy)
            }
        } else {
            Text("暂无账号")
        }

        Divider()

        Text("命令行：\(model.cliClient.displayPath)")

        Button("退出") {
            model.quit()
        }
    }
}
