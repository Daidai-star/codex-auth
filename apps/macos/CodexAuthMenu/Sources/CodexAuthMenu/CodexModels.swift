import Foundation

enum UsageRefreshScope: Sendable {
    case none
    case activeOnly
    case allAccounts

    var cliFlag: String? {
        switch self {
        case .none:
            return nil
        case .activeOnly:
            return "--refresh-active-usage"
        case .allAccounts:
            return "--refresh-usage"
        }
    }
}

struct CodexState: Codable, Sendable {
    var schemaVersion: Int
    var codexHome: String
    var activeAccountKey: String?
    var activeAPIProfileKey: String?
    var activeAuthMode: String?
    var api: ApiConfig
    var accounts: [Account]
    var apiProfiles: [APIProfile]
    var refresh: RefreshSummary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case codexHome = "codex_home"
        case activeAccountKey = "active_account_key"
        case activeAPIProfileKey = "active_api_profile_key"
        case activeAuthMode = "active_auth_mode"
        case api
        case accounts
        case apiProfiles = "api_profiles"
        case refresh
    }

    var activeAccount: Account? {
        accounts.first { $0.active }
    }

    var activeAPIProfile: APIProfile? {
        apiProfiles.first { $0.active }
    }

    var isAPIKeyMode: Bool {
        activeAuthMode == "apikey"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        codexHome = try container.decode(String.self, forKey: .codexHome)
        activeAccountKey = try container.decodeIfPresent(String.self, forKey: .activeAccountKey)
        activeAPIProfileKey = try container.decodeIfPresent(String.self, forKey: .activeAPIProfileKey)
        activeAuthMode = try container.decodeIfPresent(String.self, forKey: .activeAuthMode)
        api = try container.decode(ApiConfig.self, forKey: .api)
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        apiProfiles = try container.decodeIfPresent([APIProfile].self, forKey: .apiProfiles) ?? []
        refresh = try container.decode(RefreshSummary.self, forKey: .refresh)
    }
}

struct ApiConfig: Codable, Sendable {
    var usage: Bool
    var account: Bool
    var renewal: Bool
}

struct RefreshSummary: Codable, Sendable {
    var usageRequested: Bool
    var attempted: Int
    var updated: Int
    var failed: Int
    var unchanged: Int
    var localOnlyMode: Bool

    enum CodingKeys: String, CodingKey {
        case usageRequested = "usage_requested"
        case attempted
        case updated
        case failed
        case unchanged
        case localOnlyMode = "local_only_mode"
    }
}

struct Account: Codable, Identifiable, Sendable {
    var accountKey: String
    var label: String
    var email: String
    var alias: String
    var accountName: String?
    var plan: String?
    var authMode: String?
    var active: Bool
    var lastUsedAt: Int64?
    var lastUsageAt: Int64?
    var usage: UsageSnapshot?
    var renewal: RenewalSnapshot

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case label
        case email
        case alias
        case accountName = "account_name"
        case plan
        case authMode = "auth_mode"
        case active
        case lastUsedAt = "last_used_at"
        case lastUsageAt = "last_usage_at"
        case usage
        case renewal
    }

    var id: String { accountKey }

    var subtitle: String {
        let planText = plan ?? "未知"
        if alias.isEmpty {
            return "\(email) - \(planText)"
        }
        return "\(email) - \(alias) - \(planText)"
    }

    var usageLine: String {
        guard let usage else { return "本地额度待同步" }
        if usage.status != "ok" {
            return "额度刷新状态：\(Account.usageStatusPresentation(for: usage.status).summary)"
        }
        let fiveHour = usage.fiveHour?.remainingPercent.map { "\($0)% 5小时" } ?? "-- 5小时"
        let weekly = usage.weekly?.remainingPercent.map { "\($0)% 每周" } ?? "-- 每周"
        return "\(fiveHour), \(weekly)"
    }

    var menuUsageSummary: String {
        guard let usage else { return "5 小时未同步 · 每周未同步" }
        if usage.status != "ok" {
            let presentation = Account.usageStatusPresentation(for: usage.status)
            return "5 小时 \(presentation.shortLabel) · 每周 \(presentation.shortLabel)"
        }
        let fiveHour = usage.fiveHour?.remainingPercent.map { "\($0)%" } ?? "--"
        let weekly = usage.weekly?.remainingPercent.map { "\($0)%" } ?? "--"
        return "5 小时 \(fiveHour) · 每周 \(weekly)"
    }

    var menuUsageDetail: String {
        if let usage, usage.status != "ok" {
            let presentation = Account.usageStatusPresentation(for: usage.status)
            if let lastUsageAt {
                return "\(presentation.detail) · 上次同步 \(Account.shortDateTime(lastUsageAt))"
            }
            return presentation.detail
        }
        if let lastUsageAt {
            return "同步于 \(Account.shortDateTime(lastUsageAt))"
        }
        return "还没有同步记录"
    }

    var renewalSummary: String {
        guard let date = renewal.nextRenewalAt else {
            return "下次续费：未设置"
        }
        if let days = Account.daysUntil(date) {
            if days < 0 {
                return "下次续费：\(date) · 已过期 \(abs(days)) 天"
            }
            if days <= 7 {
                return "下次续费：\(date) · 还有 \(days) 天"
            }
        }
        return "下次续费：\(date)"
    }

    var renewalDetail: String {
        if let updatedAt = renewal.updatedAt {
            return "手动记录 · 更新于 \(Account.shortDateTime(updatedAt))"
        }
        return "手动记录一个日期后，我们会帮你提醒。"
    }

    var usageFailureSummary: String? {
        guard let usage, usage.status != "ok" else { return nil }
        return Account.usageStatusPresentation(for: usage.status).summary
    }

    static func shortDateTime(_ timestamp: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static func daysUntil(_ dateString: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let target = formatter.date(from: dateString) else { return nil }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let targetDay = calendar.startOfDay(for: target)
        return calendar.dateComponents([.day], from: startOfToday, to: targetDay).day
    }

    private static func usageStatusPresentation(for status: String) -> (
        shortLabel: String,
        summary: String,
        detail: String
    ) {
        switch status {
        case "NodeJsRequired":
            return (
                shortLabel: "需要 Node",
                summary: "需要本机 Node.js 18+",
                detail: "额度刷新依赖本机 Node.js 18+。菜单栏 App 重新打开后会自动重试。"
            )
        case "MissingAuth":
            return (
                shortLabel: "不支持",
                summary: "当前登录态不支持额度接口",
                detail: "这个账号当前没有可用的 ChatGPT 额度接口凭证。"
            )
        case "TimedOut":
            return (
                shortLabel: "超时",
                summary: "额度接口请求超时",
                detail: "这次刷新超时了，稍后重试通常就够了。"
            )
        default:
            if let code = Int(status) {
                return (
                    shortLabel: "\(code)",
                    summary: "额度接口返回 \(code)",
                    detail: "接口返回了 \(code) 状态，暂时没拿到新的额度结果。"
                )
            }
            return (
                shortLabel: "失败",
                summary: "额度刷新失败",
                detail: "接口返回了 \(status)，这次没有拿到新的额度结果。"
            )
        }
    }
}

struct APIProfile: Codable, Identifiable, Sendable {
    var profileKey: String
    var label: String
    var modelProvider: String?
    var providerName: String?
    var model: String?
    var baseURL: String?
    var wireAPI: String?
    var active: Bool
    var createdAt: Int64
    var lastUsedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key"
        case label
        case modelProvider = "model_provider"
        case providerName = "provider_name"
        case model
        case baseURL = "base_url"
        case wireAPI = "wire_api"
        case active
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    var id: String { profileKey }

    var isImportedFromCCSwitch: Bool {
        profileKey.hasPrefix("ccswitch-")
    }

    var sourceLabel: String {
        isImportedFromCCSwitch ? "cc switch" : "本地保存"
    }

    var subtitle: String {
        let parts = [providerName, modelProvider, model, baseURL]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? "已保存的 API 配置档案" : parts.joined(separator: " · ")
    }

    var usageLine: String {
        if let lastUsedAt {
            return "上次切换：\(Account.shortDateTime(lastUsedAt))"
        }
        return "还没有切换记录"
    }
}

struct UsageSnapshot: Codable, Sendable {
    var status: String
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var credits: CreditsSnapshot?

    enum CodingKeys: String, CodingKey {
        case status
        case fiveHour = "five_hour"
        case weekly
        case credits
    }
}

struct UsageWindow: Codable, Sendable {
    var usedPercent: Double
    var remainingPercent: Int?
    var windowMinutes: Int64?
    var resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

struct CreditsSnapshot: Codable, Sendable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

struct RenewalSnapshot: Codable, Sendable {
    var nextRenewalAt: String?
    var source: String?
    var updatedAt: Int64?
    var status: String

    enum CodingKeys: String, CodingKey {
        case nextRenewalAt = "next_renewal_at"
        case source
        case updatedAt = "updated_at"
        case status
    }
}
