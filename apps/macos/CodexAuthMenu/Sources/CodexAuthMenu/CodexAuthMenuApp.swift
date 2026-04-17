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
            Text("已保存 \(model.sortedAccounts.count) 个账号")
        } else {
            Text("未选择账号")
            Text("已保存 \(model.sortedAccounts.count) 个账号")
        }

        Text(model.statusMessage)
            .lineLimit(3)
        Divider()

        Button("打开网页控制台") {
            model.openWebControl()
        }

        Text("已有账号快照可直接导入")
        Text("首次登录新账号仍需官方 Codex CLI")

        Menu("添加账号") {
            Button("账号登录") {
                model.startLogin(deviceAuth: false)
            }
            .disabled(model.isBusy)

            Button("设备码登录") {
                model.startLogin(deviceAuth: true)
            }
            .disabled(model.isBusy)

            Divider()

            Button("导入 auth.json 或文件夹") {
                model.startImport(source: .standard)
            }
            .disabled(model.isBusy)

            Button("导入 CPA 文件或目录") {
                model.startImport(source: .cpa)
            }
            .disabled(model.isBusy)

            Button("扫描默认 CPA 目录") {
                model.startImport(source: .cpaDefault)
            }
            .disabled(model.isBusy)
        }

        Toggle(
            "切换后自动重启 Codex App",
            isOn: Binding(
                get: { model.restartCodexAfterSwitch },
                set: { model.setRestartCodexAfterSwitch($0) }
            )
        )

        Button("重新加载") {
            model.load()
        }
        .disabled(model.isBusy)

        Button("同步本地额度") {
            model.load(refreshScope: .activeOnly)
        }
        .disabled(model.isBusy)

        Divider()

        if !model.sortedAccounts.isEmpty {
            Menu("切换账号（\(model.sortedAccounts.count)）") {
                ForEach(model.featuredAccounts) { account in
                    accountButton(account)
                }

                if !model.overflowAccounts.isEmpty {
                    Divider()

                    Menu("更多账号（\(model.overflowAccounts.count)）") {
                        ForEach(model.overflowAccounts) { account in
                            accountButton(account)
                        }
                    }
                }

                Divider()

                Button("在网页中查看全部账号") {
                    model.openWebControl()
                }
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

    @ViewBuilder
    private func accountButton(_ account: Account) -> some View {
        Button {
            model.switchAccount(account)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.active ? "当前 · \(account.label)" : account.label)
                Text(account.email)
                    .font(.caption)
                if !account.active {
                    Text(account.usageLine)
                        .font(.caption2)
                }
            }
        }
        .disabled(account.active || model.isBusy)
    }
}
