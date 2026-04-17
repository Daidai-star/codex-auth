import Foundation

enum UsageRefreshScope: Sendable {
    case none
    case activeOnly

    var cliFlag: String? {
        switch self {
        case .none:
            return nil
        case .activeOnly:
            return "--refresh-active-usage"
        }
    }
}

struct CodexState: Codable, Sendable {
    var schemaVersion: Int
    var codexHome: String
    var activeAccountKey: String?
    var api: ApiConfig
    var accounts: [Account]
    var refresh: RefreshSummary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case codexHome = "codex_home"
        case activeAccountKey = "active_account_key"
        case api
        case accounts
        case refresh
    }

    var activeAccount: Account? {
        accounts.first { $0.active }
    }
}

struct ApiConfig: Codable, Sendable {
    var usage: Bool
    var account: Bool
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
            return "本地额度状态：\(usage.status)"
        }
        let fiveHour = usage.fiveHour?.remainingPercent.map { "\($0)% 5小时" } ?? "-- 5小时"
        let weekly = usage.weekly?.remainingPercent.map { "\($0)% 每周" } ?? "-- 每周"
        return "\(fiveHour), \(weekly)"
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
