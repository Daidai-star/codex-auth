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
            MenuDashboard(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader(model: model)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if let active = model.state?.activeAccount {
                        CurrentAccountCard(account: active, accountCount: model.sortedAccounts.count)
                        UsageDashboardCard(account: active)
                        RenewalReminderCard(account: active)
                    } else {
                        EmptyAccountCard(accountCount: model.sortedAccounts.count)
                    }

                    QuickActionsCard(model: model)
                    AccountListCard(model: model)
                    AccountToolsCard(model: model)
                }
                .padding(14)
            }
            .frame(height: 486)

            Divider()

            FixedFooterBar(model: model)
        }
        .frame(width: 392, height: 640)
        .background(.regularMaterial)
    }
}

private struct MenuHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 42, height: 42)

                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating, value: model.isBusy)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 账号控制台")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                model.load()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新加载")
            .disabled(model.isBusy)

            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("退出 Codex 账号")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct CurrentAccountCard: View {
    let account: Account
    let accountCount: Int

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前账号")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(account.displayTitle)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 8)

                    CapsuleTag(text: account.planLabel, style: .warm)
                }

                Text(account.email)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    InfoPill(icon: "person.2", text: "\(accountCount) 个账号")
                    InfoPill(icon: "clock", text: account.lastUsageText)
                }
            }
        }
    }
}

private struct UsageDashboardCard: View {
    let account: Account

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("额度概览")
                        .font(.headline)

                    Spacer()

                    if let failure = account.usageFailureSummary {
                        CapsuleTag(text: failure, style: .danger)
                    } else {
                        CapsuleTag(text: account.usage == nil ? "未同步" : "已同步", style: account.usage == nil ? .neutral : .success)
                    }
                }

                HStack(spacing: 12) {
                    UsageMetricView(
                        title: "5 小时",
                        percent: account.fiveHourRemainingPercent,
                        tint: .green
                    )

                    UsageMetricView(
                        title: "每周",
                        percent: account.weeklyRemainingPercent,
                        tint: .blue
                    )
                }

                Text(account.menuUsageDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct UsageMetricView: View {
    let title: String
    let percent: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            UsageRing(percent: percent, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(percent.map { "\($0)%" } ?? "待同步")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct UsageRing: View {
    let percent: Int?
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 6)

            Circle()
                .trim(from: 0, to: CGFloat(clampedPercent) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(percent.map { "\($0)" } ?? "-")
                .font(.caption.weight(.bold))
                .foregroundStyle(percent == nil ? .secondary : tint)
        }
        .frame(width: 44, height: 44)
    }

    private var clampedPercent: Int {
        min(max(percent ?? 0, 0), 100)
    }
}

private struct RenewalReminderCard: View {
    let account: Account

    var body: some View {
        SectionCard {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(account.renewalTone.color.opacity(0.14))
                        .frame(width: 38, height: 38)

                    Image(systemName: account.renewalTone.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(account.renewalTone.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.renewalSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(account.renewalTone.summaryColor)
                        .lineLimit(2)

                    Text(account.renewalDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct EmptyAccountCard: View {
    let accountCount: Int

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有选择账号")
                    .font(.headline)

                Text(accountCount == 0 ? "先添加或导入一个账号，然后就能在这里快速切换。" : "已保存账号，但当前没有激活项。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct QuickActionsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("快捷操作")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ActionTile(title: "网页控制台", icon: "safari") {
                        model.openWebControl()
                    }

                    ActionTile(title: "同步当前", icon: "gauge.with.dots.needle.67percent") {
                        model.load(refreshScope: .activeOnly)
                    }
                    .disabled(model.isBusy)

                    ActionTile(title: "刷新全部", icon: "arrow.triangle.2.circlepath") {
                        model.load(refreshScope: .allAccounts)
                    }
                    .disabled(model.isBusy || !model.canRefreshAllUsage)

                    ActionTile(title: "重新加载", icon: "arrow.clockwise") {
                        model.load()
                    }
                    .disabled(model.isBusy)
                }

                if !model.canRefreshAllUsage {
                    Text("刷新全部额度需要先在网页控制台开启额度 API。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(
                    "切换后自动重启 Codex App",
                    isOn: Binding(
                        get: { model.restartCodexAfterSwitch },
                        set: { model.setRestartCodexAfterSwitch($0) }
                    )
                )
                .toggleStyle(.switch)
            }
        }
    }
}

private struct AccountListCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("切换账号")
                        .font(.headline)

                    Spacer()

                    CapsuleTag(text: "\(model.sortedAccounts.count)", style: .neutral)
                }

                if model.sortedAccounts.isEmpty {
                    Text("暂无账号")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.sortedAccounts) { account in
                            AccountSwitchRow(account: account, isBusy: model.isBusy) {
                                model.switchAccount(account)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AccountSwitchRow: View {
    let account: Account
    let isBusy: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(account.active ? Color.green : Color.secondary.opacity(0.26))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.active {
                        CapsuleTag(text: "当前", style: .success)
                    }
                }

                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    MiniUsageBar(label: "5h", percent: account.fiveHourRemainingPercent, tint: .green)
                    MiniUsageBar(label: "周", percent: account.weeklyRemainingPercent, tint: .blue)
                }
            }

            Spacer(minLength: 8)

            Button(account.active ? "已选" : "切换") {
                onSwitch()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(account.active || isBusy)
        }
        .padding(9)
        .background(account.active ? Color.green.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.52), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(account.active ? Color.green.opacity(0.3) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct MiniUsageBar: View {
    let label: String
    let percent: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)

                    Capsule()
                        .fill(percent == nil ? Color.secondary.opacity(0.35) : tint.opacity(0.86))
                        .frame(width: proxy.size.width * CGFloat(min(max(percent ?? 0, 0), 100)) / 100)
                }
            }
            .frame(width: 52, height: 5)

            Text(percent.map { "\($0)%" } ?? "--")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

private struct AccountToolsCard: View {
    @ObservedObject var model: AppModel
    @State private var isExpanded = false

    var body: some View {
        SectionCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    ActionRowButton(title: "账号登录", icon: "person.badge.plus") {
                        model.startLogin(deviceAuth: false)
                    }
                    .disabled(model.isBusy)

                    ActionRowButton(title: "设备码登录", icon: "number.square") {
                        model.startLogin(deviceAuth: true)
                    }
                    .disabled(model.isBusy)

                    ActionRowButton(title: "导入 auth.json 或文件夹", icon: "tray.and.arrow.down") {
                        model.startImport(source: .standard)
                    }
                    .disabled(model.isBusy)

                    ActionRowButton(title: "导入 CPA 文件或目录", icon: "folder.badge.plus") {
                        model.startImport(source: .cpa)
                    }
                    .disabled(model.isBusy)

                    ActionRowButton(title: "扫描默认 CPA 目录", icon: "folder") {
                        model.startImport(source: .cpaDefault)
                    }
                    .disabled(model.isBusy)
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("添加账号")
                            .font(.headline)

                        Text("首次登录仍走官方 Codex CLI，已有快照可直接导入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct FixedFooterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(model.apiStatusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text(model.cliClient.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button {
                    model.openWebControl()
                } label: {
                    Label("打开网页", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    model.quit()
                } label: {
                    Label("退出", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct SectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}

private struct ActionTile: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct ActionRowButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct InfoPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.64), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CapsuleTag: View {
    let text: String
    let style: TagStyle

    enum TagStyle {
        case neutral
        case success
        case warm
        case danger

        var color: Color {
            switch self {
            case .neutral:
                return .secondary
            case .success:
                return .green
            case .warm:
                return .brown
            case .danger:
                return .red
            }
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(style.color)
            .background(style.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum RenewalTone {
    case neutral
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral:
            return .secondary
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }

    var icon: String {
        switch self {
        case .neutral:
            return "calendar"
        case .warning:
            return "calendar.badge.exclamationmark"
        case .danger:
            return "exclamationmark.triangle"
        }
    }

    var summaryColor: Color {
        switch self {
        case .neutral:
            return .primary
        case .warning, .danger:
            return color
        }
    }
}

private extension Account {
    var displayTitle: String {
        let trimmedName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAlias.isEmpty {
            return trimmedAlias
        }
        return label
    }

    var planLabel: String {
        plan?.isEmpty == false ? plan! : "未知套餐"
    }

    var fiveHourRemainingPercent: Int? {
        guard usage?.status == "ok" else { return nil }
        return usage?.fiveHour?.remainingPercent
    }

    var weeklyRemainingPercent: Int? {
        guard usage?.status == "ok" else { return nil }
        return usage?.weekly?.remainingPercent
    }

    var lastUsageText: String {
        guard let lastUsageAt else { return "未同步" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(lastUsageAt)))
    }

    var renewalTone: RenewalTone {
        if renewal.nextRenewalAt == nil {
            return .neutral
        }
        if renewalSummary.contains("已过期") {
            return .danger
        }
        if renewalSummary.contains("还有") {
            return .warning
        }
        return .neutral
    }
}
