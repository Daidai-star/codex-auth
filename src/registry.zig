const std = @import("std");
const builtin = @import("builtin");
const account_api = @import("account_api.zig");
const history_sync = @import("history_sync.zig");
const io_util = @import("io_util.zig");
const c_time = @cImport({
    @cInclude("time.h");
});

pub const PlanType = enum { free, plus, prolite, pro, team, business, enterprise, edu, unknown };
pub const AuthMode = enum { chatgpt, apikey };
pub const RenewalSource = enum { manual, auto };
pub const RenewalStatus = enum { ok, missing, unsupported, fetch_failed };
pub const current_schema_version: u32 = 5;
pub const min_supported_schema_version: u32 = 2;
pub const default_auto_switch_threshold_5h_percent: u8 = 10;
pub const default_auto_switch_threshold_weekly_percent: u8 = 5;
pub const account_name_refresh_lock_file_name = "account-name-refresh.lock";

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

pub const RateLimitWindow = struct {
    used_percent: f64,
    window_minutes: ?i64,
    resets_at: ?i64,
};

pub const CreditsSnapshot = struct {
    has_credits: bool,
    unlimited: bool,
    balance: ?[]u8,
};

pub const RateLimitSnapshot = struct {
    primary: ?RateLimitWindow,
    secondary: ?RateLimitWindow,
    credits: ?CreditsSnapshot,
    plan_type: ?PlanType,
};

pub const RolloutSignature = struct {
    path: []u8,
    event_timestamp_ms: i64,
};

pub const AutoSwitchConfig = struct {
    enabled: bool = false,
    threshold_5h_percent: u8 = default_auto_switch_threshold_5h_percent,
    threshold_weekly_percent: u8 = default_auto_switch_threshold_weekly_percent,
};

pub const ApiConfig = struct {
    usage: bool = false,
    account: bool = false,
    renewal: bool = false,
};

const ApiConfigParseResult = struct {
    has_object: bool = false,
    has_usage: bool = false,
    has_account: bool = false,
    has_renewal: bool = false,
};

pub const RenewalInfo = struct {
    next_renewal_at: ?[]u8 = null,
    source: ?RenewalSource = null,
    updated_at: ?i64 = null,
    status: RenewalStatus = .missing,
};

pub const ApiProfileRecord = struct {
    profile_key: []u8,
    label: []u8,
    model_provider: ?[]u8 = null,
    provider_name: ?[]u8 = null,
    model: ?[]u8 = null,
    base_url: ?[]u8 = null,
    wire_api: ?[]u8 = null,
    created_at: i64,
    last_used_at: ?i64 = null,
};

pub const CcSwitchImportSelector = union(enum) {
    current,
    all,
    provider_id: []const u8,
};

pub const CcSwitchImportSummary = struct {
    imported: usize = 0,
    updated: usize = 0,
    skipped: usize = 0,
};

pub const AccountRecord = struct {
    account_key: []u8,
    chatgpt_account_id: []u8,
    chatgpt_user_id: []u8,
    email: []u8,
    alias: []u8,
    account_name: ?[]u8,
    plan: ?PlanType,
    auth_mode: ?AuthMode,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?RateLimitSnapshot,
    last_usage_at: ?i64,
    last_local_rollout: ?RolloutSignature,
    renewal: RenewalInfo = .{},
};

pub fn resolvePlan(rec: *const AccountRecord) ?PlanType {
    if (rec.plan) |p| return p;
    if (rec.last_usage) |u| return u.plan_type;
    return null;
}

pub fn planLabel(plan: PlanType) []const u8 {
    return switch (plan) {
        .free => "Free",
        .plus => "Plus",
        .prolite => "Pro Lite",
        .pro => "Pro",
        .team => "Team",
        .business => "Business",
        .enterprise => "Enterprise",
        .edu => "Edu",
        .unknown => "Unknown",
    };
}

pub const Registry = struct {
    schema_version: u32,
    active_account_key: ?[]u8,
    active_api_profile_key: ?[]u8 = null,
    active_auth_mode: ?AuthMode = null,
    active_account_activated_at_ms: ?i64,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    accounts: std.ArrayList(AccountRecord),
    api_profiles: std.ArrayList(ApiProfileRecord) = std.ArrayList(ApiProfileRecord).empty,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.accounts.items) |*rec| {
            freeAccountRecord(allocator, rec);
        }
        if (self.active_account_key) |k| allocator.free(k);
        if (self.active_api_profile_key) |k| allocator.free(k);
        self.accounts.deinit(allocator);
        for (self.api_profiles.items) |*profile| {
            freeApiProfileRecord(allocator, profile);
        }
        self.api_profiles.deinit(allocator);
    }
};

pub fn defaultAutoSwitchConfig() AutoSwitchConfig {
    return .{};
}

pub fn defaultApiConfig() ApiConfig {
    return .{};
}

fn freeAccountRecord(allocator: std.mem.Allocator, rec: *const AccountRecord) void {
    allocator.free(rec.account_key);
    allocator.free(rec.chatgpt_account_id);
    allocator.free(rec.chatgpt_user_id);
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.account_name) |account_name| allocator.free(account_name);
    if (rec.last_local_rollout) |*sig| freeRolloutSignature(allocator, sig);
    if (rec.last_usage) |*u| {
        freeRateLimitSnapshot(allocator, u);
    }
    freeRenewalInfo(allocator, &rec.renewal);
}

fn freeApiProfileRecord(allocator: std.mem.Allocator, rec: *const ApiProfileRecord) void {
    allocator.free(rec.profile_key);
    allocator.free(rec.label);
    if (rec.model_provider) |value| allocator.free(value);
    if (rec.provider_name) |value| allocator.free(value);
    if (rec.model) |value| allocator.free(value);
    if (rec.base_url) |value| allocator.free(value);
    if (rec.wire_api) |value| allocator.free(value);
}

pub fn freeRateLimitSnapshot(allocator: std.mem.Allocator, snapshot: *const RateLimitSnapshot) void {
    if (snapshot.credits) |*c| {
        if (c.balance) |b| allocator.free(b);
    }
}

pub fn freeRolloutSignature(allocator: std.mem.Allocator, signature: *const RolloutSignature) void {
    allocator.free(signature.path);
}

pub fn rolloutSignaturesEqual(a: ?RolloutSignature, b: ?RolloutSignature) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.event_timestamp_ms == b.?.event_timestamp_ms and std.mem.eql(u8, a.?.path, b.?.path);
}

pub fn cloneRolloutSignature(allocator: std.mem.Allocator, signature: RolloutSignature) !RolloutSignature {
    return .{
        .path = try allocator.dupe(u8, signature.path),
        .event_timestamp_ms = signature.event_timestamp_ms,
    };
}

pub fn cloneRateLimitSnapshot(allocator: std.mem.Allocator, snapshot: RateLimitSnapshot) !RateLimitSnapshot {
    var cloned_credits: ?CreditsSnapshot = null;
    if (snapshot.credits) |credits| {
        var cloned_balance: ?[]u8 = null;
        if (credits.balance) |balance| {
            cloned_balance = try allocator.dupe(u8, balance);
        }
        cloned_credits = .{
            .has_credits = credits.has_credits,
            .unlimited = credits.unlimited,
            .balance = cloned_balance,
        };
    }
    errdefer if (cloned_credits) |credits| {
        if (credits.balance) |balance| allocator.free(balance);
    };

    return .{
        .primary = snapshot.primary,
        .secondary = snapshot.secondary,
        .credits = cloned_credits,
        .plan_type = snapshot.plan_type,
    };
}

fn setRolloutSignature(
    allocator: std.mem.Allocator,
    target: *?RolloutSignature,
    path: []const u8,
    event_timestamp_ms: i64,
) !void {
    if (target.*) |*sig| {
        if (sig.event_timestamp_ms == event_timestamp_ms and std.mem.eql(u8, sig.path, path)) {
            return;
        }
    }
    const new_path = try allocator.dupe(u8, path);
    errdefer allocator.free(new_path);
    if (target.*) |*sig| {
        allocator.free(sig.path);
    }
    target.* = .{
        .path = new_path,
        .event_timestamp_ms = event_timestamp_ms,
    };
}

pub fn setAccountLastLocalRollout(
    allocator: std.mem.Allocator,
    rec: *AccountRecord,
    path: []const u8,
    event_timestamp_ms: i64,
) !void {
    try setRolloutSignature(allocator, &rec.last_local_rollout, path, event_timestamp_ms);
}

pub fn rateLimitSnapshotsEqual(a: ?RateLimitSnapshot, b: ?RateLimitSnapshot) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return rateLimitSnapshotEqual(a.?, b.?);
}

pub fn rateLimitSnapshotEqual(a: RateLimitSnapshot, b: RateLimitSnapshot) bool {
    return rateLimitWindowEqual(a.primary, b.primary) and
        rateLimitWindowEqual(a.secondary, b.secondary) and
        creditsEqual(a.credits, b.credits) and
        a.plan_type == b.plan_type;
}

fn rateLimitWindowEqual(a: ?RateLimitWindow, b: ?RateLimitWindow) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.used_percent == b.?.used_percent and
        a.?.window_minutes == b.?.window_minutes and
        a.?.resets_at == b.?.resets_at;
}

fn creditsEqual(a: ?CreditsSnapshot, b: ?CreditsSnapshot) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.has_credits == b.?.has_credits and
        a.?.unlimited == b.?.unlimited and
        optionalStringEqual(a.?.balance, b.?.balance);
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn cloneOptionalStringAlloc(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn freeRenewalInfo(allocator: std.mem.Allocator, renewal: *const RenewalInfo) void {
    if (renewal.next_renewal_at) |date| allocator.free(date);
}

fn cloneRenewalInfo(allocator: std.mem.Allocator, renewal: RenewalInfo) !RenewalInfo {
    return .{
        .next_renewal_at = if (renewal.next_renewal_at) |date| try allocator.dupe(u8, date) else null,
        .source = renewal.source,
        .updated_at = renewal.updated_at,
        .status = renewal.status,
    };
}

fn renewalInfoIsEmpty(renewal: RenewalInfo) bool {
    return renewal.next_renewal_at == null and
        renewal.source == null and
        renewal.updated_at == null and
        renewal.status == .missing;
}

fn replaceOptionalStringAlloc(
    allocator: std.mem.Allocator,
    target: *?[]u8,
    value: ?[]const u8,
) !bool {
    if (optionalStringEqual(target.*, value)) return false;
    const replacement = try cloneOptionalStringAlloc(allocator, value);
    if (target.*) |existing| allocator.free(existing);
    target.* = replacement;
    return true;
}

fn replaceRequiredStringAlloc(
    allocator: std.mem.Allocator,
    target: *[]u8,
    value: []const u8,
) !bool {
    if (std.mem.eql(u8, target.*, value)) return false;
    const replacement = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = replacement;
    return true;
}

fn cloneApiProfileRecord(allocator: std.mem.Allocator, profile: ApiProfileRecord) !ApiProfileRecord {
    return .{
        .profile_key = try allocator.dupe(u8, profile.profile_key),
        .label = try allocator.dupe(u8, profile.label),
        .model_provider = try cloneOptionalStringAlloc(allocator, profile.model_provider),
        .provider_name = try cloneOptionalStringAlloc(allocator, profile.provider_name),
        .model = try cloneOptionalStringAlloc(allocator, profile.model),
        .base_url = try cloneOptionalStringAlloc(allocator, profile.base_url),
        .wire_api = try cloneOptionalStringAlloc(allocator, profile.wire_api),
        .created_at = profile.created_at,
        .last_used_at = profile.last_used_at,
    };
}

fn getNonEmptyEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const val = io_util.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (val.len == 0) {
        allocator.free(val);
        return null;
    }
    return val;
}

fn resolveExistingCodexHomeOverride(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => {
            return std.fs.realpathAlloc(allocator, path) catch |realpath_err| {
                logCodexHomeResolutionError("failed to canonicalize CODEX_HOME `{s}`: {s}", .{ path, @errorName(realpath_err) });
                return realpath_err;
            };
        },
        error.FileNotFound => {
            logCodexHomeResolutionError("CODEX_HOME points to `{s}`, but that path does not exist", .{path});
            return err;
        },
        else => {
            logCodexHomeResolutionError("failed to read CODEX_HOME `{s}`: {s}", .{ path, @errorName(err) });
            return err;
        },
    };
    if (stat.kind != .directory) {
        logCodexHomeResolutionError("CODEX_HOME points to `{s}`, but that path is not a directory", .{path});
        return error.NotDir;
    }
    return std.fs.realpathAlloc(allocator, path) catch |err| {
        logCodexHomeResolutionError("failed to canonicalize CODEX_HOME `{s}`: {s}", .{ path, @errorName(err) });
        return err;
    };
}

fn logCodexHomeResolutionError(
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (builtin.is_test) return;
    std.log.err(fmt, args);
}

pub fn resolveCodexHomeFromEnv(
    allocator: std.mem.Allocator,
    codex_home_override: ?[]const u8,
    home: ?[]const u8,
    user_profile: ?[]const u8,
) ![]u8 {
    if (codex_home_override) |path| {
        if (path.len != 0) return try resolveExistingCodexHomeOverride(allocator, path);
    }
    if (home) |path| {
        if (path.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ path, ".codex" });
    }
    if (user_profile) |path| {
        if (path.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ path, ".codex" });
    }
    return error.EnvironmentVariableNotFound;
}

pub fn resolveCodexHome(allocator: std.mem.Allocator) ![]u8 {
    const codex_home_override = try getNonEmptyEnvVarOwned(allocator, "CODEX_HOME");
    defer if (codex_home_override) |path| allocator.free(path);

    const home = try getNonEmptyEnvVarOwned(allocator, "HOME");
    defer if (home) |path| allocator.free(path);

    const user_profile = try getNonEmptyEnvVarOwned(allocator, "USERPROFILE");
    defer if (user_profile) |path| allocator.free(path);

    return try resolveCodexHomeFromEnv(allocator, codex_home_override, home, user_profile);
}

pub fn resolveUserHome(allocator: std.mem.Allocator) ![]u8 {
    if (try getNonEmptyEnvVarOwned(allocator, "HOME")) |home| return home;

    if (try getNonEmptyEnvVarOwned(allocator, "USERPROFILE")) |user_profile| return user_profile;

    return error.EnvironmentVariableNotFound;
}

pub fn ensureAccountsDir(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const accounts_dir = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    try std.fs.cwd().makePath(accounts_dir);
}

pub fn registryPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "registry.json" });
}

fn encodedFileKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(key.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, key);
    return buf;
}

fn keyNeedsFilenameEncoding(key: []const u8) bool {
    if (key.len == 0) return true;
    if (std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return true;
    for (key) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return true,
        }
    }
    return false;
}

fn accountFileKey(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    if (keyNeedsFilenameEncoding(account_key)) {
        return encodedFileKey(allocator, account_key);
    }
    return allocator.dupe(u8, account_key);
}

fn accountSnapshotFileName(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    const key = try accountFileKey(allocator, account_key);
    defer allocator.free(key);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
}

fn accountConfigSnapshotFileName(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    const key = try accountFileKey(allocator, account_key);
    defer allocator.free(key);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".config.toml" });
}

fn apiProfileAuthSnapshotFileName(allocator: std.mem.Allocator, profile_key: []const u8) ![]u8 {
    const key = try accountFileKey(allocator, profile_key);
    defer allocator.free(key);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ "api-profile.", key, ".api-auth.json" });
}

fn apiProfileConfigSnapshotFileName(allocator: std.mem.Allocator, profile_key: []const u8) ![]u8 {
    const key = try accountFileKey(allocator, profile_key);
    defer allocator.free(key);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ "api-profile.", key, ".config.toml" });
}

pub fn accountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) ![]u8 {
    const filename = try accountSnapshotFileName(allocator, account_key);
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn accountConfigPath(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) ![]u8 {
    const filename = try accountConfigSnapshotFileName(allocator, account_key);
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn apiProfileAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, profile_key: []const u8) ![]u8 {
    const filename = try apiProfileAuthSnapshotFileName(allocator, profile_key);
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn apiProfileConfigPath(allocator: std.mem.Allocator, codex_home: []const u8, profile_key: []const u8) ![]u8 {
    const filename = try apiProfileConfigSnapshotFileName(allocator, profile_key);
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

fn legacyAccountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8) ![]u8 {
    const key = try encodedFileKey(allocator, email);
    defer allocator.free(key);
    const filename = try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn activeAuthPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "auth.json" });
}

pub fn activeConfigPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "config.toml" });
}

pub fn copyFile(src: []const u8, dest: []const u8) !void {
    try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

const max_backups: usize = 5;

pub const CleanSummary = struct {
    auth_backups_removed: usize = 0,
    registry_backups_removed: usize = 0,
    stale_snapshot_files_removed: usize = 0,
};

fn fileExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const cwd = std.fs.cwd();
    var file = cwd.openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn filesEqual(allocator: std.mem.Allocator, a_path: []const u8, b_path: []const u8) !bool {
    const a = try readFileIfExists(allocator, a_path);
    defer if (a) |buf| allocator.free(buf);
    const b = try readFileIfExists(allocator, b_path);
    defer if (b) |buf| allocator.free(buf);
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

fn deleteFileIfExists(path: []const u8) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn syncSnapshotFileFromCurrent(
    allocator: std.mem.Allocator,
    current_path: []const u8,
    snapshot_path: []const u8,
) !bool {
    const current_bytes = try readFileIfExists(allocator, current_path);
    defer if (current_bytes) |bytes| allocator.free(bytes);

    if (current_bytes) |bytes| {
        if (try fileEqualsBytes(allocator, snapshot_path, bytes)) return false;
        try writeFile(snapshot_path, bytes);
        return true;
    }

    if (!(try fileExists(snapshot_path))) return false;
    try deleteFileIfExists(snapshot_path);
    return true;
}

fn restoreActiveFileFromSnapshot(
    allocator: std.mem.Allocator,
    snapshot_path: []const u8,
    active_path: []const u8,
) !bool {
    if (try fileExists(snapshot_path)) {
        if (try filesEqual(allocator, snapshot_path, active_path)) return false;
        try copyFile(snapshot_path, active_path);
        return true;
    }

    if (!(try fileExists(active_path))) return false;
    try deleteFileIfExists(active_path);
    return true;
}

const ActiveApiConfigSummary = struct {
    model_provider: ?[]u8 = null,
    provider_name: ?[]u8 = null,
    model: ?[]u8 = null,
    base_url: ?[]u8 = null,
    wire_api: ?[]u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.model_provider) |value| allocator.free(value);
        if (self.provider_name) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
        if (self.wire_api) |value| allocator.free(value);
    }
};

fn parseTomlQuotedStringValue(line: []const u8, key: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, key)) return null;
    var rest = trimmed[key.len..];
    rest = std.mem.trimLeft(u8, rest, " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    rest = std.mem.trimLeft(u8, rest[1..], " \t");
    if (rest.len < 2 or rest[0] != '"') return null;

    var idx: usize = 1;
    while (idx < rest.len) : (idx += 1) {
        if (rest[idx] == '"' and rest[idx - 1] != '\\') {
            return rest[1..idx];
        }
    }

    return null;
}

fn parseTomlSectionName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 3) return null;
    if (trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return null;
    return trimmed[1 .. trimmed.len - 1];
}

fn parseActiveApiConfigSummary(allocator: std.mem.Allocator, data: []const u8) !ActiveApiConfigSummary {
    var summary = ActiveApiConfigSummary{};
    errdefer summary.deinit(allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (summary.model_provider == null) {
            if (parseTomlQuotedStringValue(line, "model_provider")) |value| {
                summary.model_provider = try allocator.dupe(u8, value);
            }
        }
        if (summary.model == null) {
            if (parseTomlQuotedStringValue(line, "model")) |value| {
                summary.model = try allocator.dupe(u8, value);
            }
        }
    }

    const model_provider = summary.model_provider orelse return summary;
    const target_section = try std.fmt.allocPrint(allocator, "model_providers.{s}", .{model_provider});
    defer allocator.free(target_section);

    var in_target_section = false;
    lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parseTomlSectionName(line)) |section_name| {
            in_target_section = std.mem.eql(u8, section_name, target_section);
            continue;
        }
        if (!in_target_section) continue;

        if (summary.provider_name == null) {
            if (parseTomlQuotedStringValue(line, "name")) |value| {
                summary.provider_name = try allocator.dupe(u8, value);
                continue;
            }
        }
        if (summary.base_url == null) {
            if (parseTomlQuotedStringValue(line, "base_url")) |value| {
                summary.base_url = try allocator.dupe(u8, value);
                continue;
            }
        }
        if (summary.wire_api == null) {
            if (parseTomlQuotedStringValue(line, "wire_api")) |value| {
                summary.wire_api = try allocator.dupe(u8, value);
                continue;
            }
        }
    }

    return summary;
}

const cc_switch_sqlite_max_output_bytes = 16 * 1024 * 1024;

const CcSwitchProviderRecord = struct {
    id: []u8,
    name: []u8,
    is_current: bool,
    settings_config: []u8,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.settings_config);
    }
};

fn appendSqlStringLiteral(sql: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try sql.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') try sql.append(allocator, '\'');
        try sql.append(allocator, ch);
    }
    try sql.append(allocator, '\'');
}

fn runSqliteCapture(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    sql: []const u8,
) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sqlite3", "-batch", "-noheader", db_path, sql },
        .max_output_bytes = cc_switch_sqlite_max_output_bytes,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.Sqlite3NotFound,
        else => return err,
    };
}

fn expectSqliteSuccess(result: std.process.Child.RunResult) !void {
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    return error.SqliteQueryFailed;
}

fn decodeHexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHexString,
    };
}

fn decodeHexAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidHexString;
    const out = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < text.len) : (i += 2) {
        const hi = try decodeHexNibble(text[i]);
        const lo = try decodeHexNibble(text[i + 1]);
        out[i / 2] = (hi << 4) | lo;
    }
    return out;
}

fn ccSwitchProfileKeyAlloc(allocator: std.mem.Allocator, provider_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "ccswitch-{s}", .{provider_id});
}

pub fn defaultCcSwitchDbPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".cc-switch", "cc-switch.db" });
}

fn loadCcSwitchProviders(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    selector: CcSwitchImportSelector,
) !std.ArrayList(CcSwitchProviderRecord) {
    std.fs.cwd().access(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.CcSwitchDbNotFound,
        else => return err,
    };

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT hex(id), hex(name), coalesce(is_current, 0), hex(settings_config) FROM providers WHERE app_type = 'codex'");
    switch (selector) {
        .current => try sql.appendSlice(allocator, " AND is_current = 1"),
        .all => {},
        .provider_id => |provider_id| {
            try sql.appendSlice(allocator, " AND id = ");
            try appendSqlStringLiteral(&sql, allocator, provider_id);
        },
    }
    try sql.appendSlice(allocator, " ORDER BY sort_index, created_at, id;");

    const result = try runSqliteCapture(allocator, db_path, sql.items);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectSqliteSuccess(result);

    var providers = std.ArrayList(CcSwitchProviderRecord).empty;
    errdefer {
        for (providers.items) |*provider| provider.deinit(allocator);
        providers.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        var cols = std.mem.splitScalar(u8, line, '|');
        const id_hex = cols.next() orelse return error.InvalidCcSwitchProviderRow;
        const name_hex = cols.next() orelse return error.InvalidCcSwitchProviderRow;
        const current_text = cols.next() orelse return error.InvalidCcSwitchProviderRow;
        const settings_hex = cols.next() orelse return error.InvalidCcSwitchProviderRow;
        if (cols.next() != null) return error.InvalidCcSwitchProviderRow;

        try providers.append(allocator, .{
            .id = try decodeHexAlloc(allocator, id_hex),
            .name = try decodeHexAlloc(allocator, name_hex),
            .is_current = std.mem.eql(u8, current_text, "1"),
            .settings_config = try decodeHexAlloc(allocator, settings_hex),
        });
    }

    if (selector == .provider_id and providers.items.len == 0) return error.CcSwitchProviderNotFound;
    return providers;
}

fn serializeJsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn writeOptionalSnapshotData(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: ?[]const u8,
) !bool {
    if (data) |bytes| {
        if (try fileEqualsBytes(allocator, path, bytes)) return false;
        try writeFile(path, bytes);
        return true;
    }

    if (!(try fileExists(path))) return false;
    try deleteFileIfExists(path);
    return true;
}

fn importCcSwitchProviderRecord(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    provider: *const CcSwitchProviderRecord,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, provider.settings_config, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCcSwitchSettingsConfig,
    };
    const auth_value = root_obj.get("auth") orelse return false;

    const auth_bytes = try serializeJsonValueAlloc(allocator, auth_value);
    defer allocator.free(auth_bytes);

    const auth_info = try @import("auth.zig").parseAuthInfoData(allocator, auth_bytes);
    defer auth_info.deinit(allocator);
    if (auth_info.auth_mode != .apikey) return false;

    const config_bytes = if (root_obj.get("config")) |config_value| switch (config_value) {
        .string => |text| if (text.len == 0) null else try allocator.dupe(u8, text),
        .null => null,
        else => return error.InvalidCcSwitchSettingsConfig,
    } else null;
    defer if (config_bytes) |bytes| allocator.free(bytes);

    var summary = if (config_bytes) |bytes|
        try parseActiveApiConfigSummary(allocator, bytes)
    else
        ActiveApiConfigSummary{};
    defer summary.deinit(allocator);

    const profile_key = try ccSwitchProfileKeyAlloc(allocator, provider.id);
    defer allocator.free(profile_key);

    const auth_path = try apiProfileAuthPath(allocator, codex_home, profile_key);
    defer allocator.free(auth_path);
    const config_path = try apiProfileConfigPath(allocator, codex_home, profile_key);
    defer allocator.free(config_path);

    var changed = false;
    changed = (try writeOptionalSnapshotData(allocator, auth_path, auth_bytes)) or changed;
    changed = (try writeOptionalSnapshotData(allocator, config_path, config_bytes)) or changed;

    if (findApiProfileIndexByKey(reg, profile_key)) |idx| {
        var rec = &reg.api_profiles.items[idx];
        changed = (try replaceRequiredStringAlloc(allocator, &rec.label, provider.name)) or changed;
        changed = (try updateApiProfileMetadata(allocator, rec, null, &summary)) or changed;
        return changed;
    }

    try reg.api_profiles.append(allocator, .{
        .profile_key = try allocator.dupe(u8, profile_key),
        .label = try allocator.dupe(u8, provider.name),
        .model_provider = try cloneOptionalStringAlloc(allocator, summary.model_provider),
        .provider_name = try cloneOptionalStringAlloc(allocator, summary.provider_name),
        .model = try cloneOptionalStringAlloc(allocator, summary.model),
        .base_url = try cloneOptionalStringAlloc(allocator, summary.base_url),
        .wire_api = try cloneOptionalStringAlloc(allocator, summary.wire_api),
        .created_at = std.time.timestamp(),
        .last_used_at = null,
    });
    return true;
}

pub fn importCcSwitchApiProfiles(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    db_path: []const u8,
    selector: CcSwitchImportSelector,
) !CcSwitchImportSummary {
    try ensureAccountsDir(allocator, codex_home);

    var providers = try loadCcSwitchProviders(allocator, db_path, selector);
    defer {
        for (providers.items) |*provider| provider.deinit(allocator);
        providers.deinit(allocator);
    }

    var summary: CcSwitchImportSummary = .{};
    for (providers.items) |*provider| {
        const profile_key = try ccSwitchProfileKeyAlloc(allocator, provider.id);
        const existed = findApiProfileIndexByKey(reg, profile_key) != null;
        allocator.free(profile_key);

        const changed = try importCcSwitchProviderRecord(allocator, codex_home, reg, provider);
        if (!changed) {
            summary.skipped += 1;
            continue;
        }
        if (existed) {
            summary.updated += 1;
        } else {
            summary.imported += 1;
        }
    }

    return summary;
}

fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn backupDir(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
}

fn localtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_localtime64_s") and @hasDecl(c_time, "__time64_t")) {
            var t64 = std.math.cast(c_time.__time64_t, ts) orelse return false;
            return c_time._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c_time.time_t, ts) orelse return false;
    if (comptime @hasDecl(c_time, "localtime_r")) {
        return c_time.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c_time, "localtime")) {
        const tm_ptr = c_time.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn formatBackupTimestamp(allocator: std.mem.Allocator, ts: i64) ![]u8 {
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) {
        return std.fmt.allocPrint(allocator, "{d}", .{ts});
    }

    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    });
}

fn makeBackupPath(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    const timestamp = try formatBackupTimestamp(allocator, std.time.timestamp());
    defer allocator.free(timestamp);
    const base = try std.fmt.allocPrint(allocator, "{s}.bak.{s}", .{ base_name, timestamp });
    defer allocator.free(base);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const name = if (attempt == 0)
            try allocator.dupe(u8, base)
        else
            try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base, attempt });

        const path = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
        allocator.free(name);

        var file = std.fs.cwd().openFile(path, .{}) catch return path;
        file.close();
        allocator.free(path);
        continue;
    }
}

const BackupEntry = struct {
    name: []u8,
    mtime: i128,
};

fn backupEntryLessThan(_: void, a: BackupEntry, b: BackupEntry) bool {
    return a.mtime > b.mtime;
}

fn pruneBackups(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8, max: usize) !void {
    var list = std.ArrayList(BackupEntry).empty;
    defer {
        for (list.items) |item| allocator.free(item.name);
        list.deinit(allocator);
    }

    var dir_handle = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer dir_handle.close();

    var it = dir_handle.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, base_name)) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) continue;

        const stat = try dir_handle.statFile(entry.name);
        const name = try allocator.dupe(u8, entry.name);
        try list.append(allocator, .{ .name = name, .mtime = stat.mtime });
    }

    std.sort.insertion(BackupEntry, list.items, {}, backupEntryLessThan);
    if (list.items.len <= max) return;

    var i: usize = max;
    while (i < list.items.len) : (i += 1) {
        const old = list.items[i].name;
        dir_handle.deleteFile(old) catch {};
    }
}

fn countBackupsByBaseName(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) !usize {
    var count: usize = 0;
    var dir_handle = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer dir_handle.close();

    var it = dir_handle.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, base_name)) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) continue;
        _ = allocator;
        count += 1;
    }
    return count;
}

fn resolveStrictAccountAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
) ![]u8 {
    const path = try accountAuthPath(allocator, codex_home, account_key);
    if (std.fs.cwd().openFile(path, .{})) |file| {
        file.close();
        return path;
    } else |err| {
        allocator.free(path);
        return err;
    }
}

fn isAllowedCurrentSnapshot(reg: *const Registry, entry_name: []const u8) bool {
    for (reg.accounts.items) |rec| {
        const auth_name = accountSnapshotFileName(std.heap.page_allocator, rec.account_key) catch continue;
        defer std.heap.page_allocator.free(auth_name);
        if (std.mem.eql(u8, entry_name, auth_name)) {
            return true;
        }

        const config_name = accountConfigSnapshotFileName(std.heap.page_allocator, rec.account_key) catch continue;
        defer std.heap.page_allocator.free(config_name);
        if (std.mem.eql(u8, entry_name, config_name)) {
            return true;
        }
    }

    for (reg.api_profiles.items) |profile| {
        const auth_name = apiProfileAuthSnapshotFileName(std.heap.page_allocator, profile.profile_key) catch continue;
        defer std.heap.page_allocator.free(auth_name);
        if (std.mem.eql(u8, entry_name, auth_name)) {
            return true;
        }

        const config_name = apiProfileConfigSnapshotFileName(std.heap.page_allocator, profile.profile_key) catch continue;
        defer std.heap.page_allocator.free(config_name);
        if (std.mem.eql(u8, entry_name, config_name)) {
            return true;
        }
    }
    return false;
}

fn isAllowedAccountsEntry(reg: *const Registry, entry_name: []const u8) bool {
    if (std.mem.eql(u8, entry_name, "registry.json")) return true;
    if (std.mem.eql(u8, entry_name, "auto-switch.lock")) return true;
    if (std.mem.eql(u8, entry_name, account_name_refresh_lock_file_name)) return true;
    if (std.mem.eql(u8, entry_name, "backups")) return true;
    return isAllowedCurrentSnapshot(reg, entry_name);
}

pub fn cleanAccountsBackups(allocator: std.mem.Allocator, codex_home: []const u8) !CleanSummary {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    const reg_path = try registryPath(allocator, codex_home);
    defer allocator.free(reg_path);

    var cwd = std.fs.cwd();
    var dir_handle = cwd.openDir(dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    dir_handle.close();

    const auth_before = try countBackupsByBaseName(allocator, dir, "auth.json");
    const registry_before = try countBackupsByBaseName(allocator, dir, "registry.json");

    try pruneBackups(allocator, dir, "auth.json", 0);
    try pruneBackups(allocator, dir, "registry.json", 0);

    const auth_after = try countBackupsByBaseName(allocator, dir, "auth.json");
    const registry_after = try countBackupsByBaseName(allocator, dir, "registry.json");

    if (!(try fileExists(reg_path))) {
        return .{
            .auth_backups_removed = if (auth_before >= auth_after) auth_before - auth_after else 0,
            .registry_backups_removed = if (registry_before >= registry_after) registry_before - registry_after else 0,
            .stale_snapshot_files_removed = 0,
        };
    }

    var reg = try loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var stale_snapshot_files_removed: usize = 0;
    var accounts_dir = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer accounts_dir.close();
    var it = accounts_dir.iterate();
    while (try it.next()) |entry| {
        if (isAllowedAccountsEntry(&reg, entry.name)) {
            continue;
        }

        switch (entry.kind) {
            .file, .sym_link => try accounts_dir.deleteFile(entry.name),
            .directory => try accounts_dir.deleteTree(entry.name),
            else => continue,
        }
        stale_snapshot_files_removed += 1;
    }

    return .{
        .auth_backups_removed = if (auth_before >= auth_after) auth_before - auth_after else 0,
        .registry_backups_removed = if (registry_before >= registry_after) registry_before - registry_after else 0,
        .stale_snapshot_files_removed = stale_snapshot_files_removed,
    };
}

pub fn backupAuthIfChanged(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    current_auth_path: []const u8,
    new_auth_path: []const u8,
) !void {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    try ensureDir(dir);

    if (!(try filesEqual(allocator, current_auth_path, new_auth_path))) {
        var file = std.fs.cwd().openFile(current_auth_path, .{}) catch return;
        file.close();
        const backup = try makeBackupPath(allocator, dir, "auth.json");
        defer allocator.free(backup);
        try std.fs.cwd().copyFile(current_auth_path, std.fs.cwd(), backup, .{});
        try pruneBackups(allocator, dir, "auth.json", max_backups);
    }
}

fn backupRegistryIfChanged(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    current_registry_path: []const u8,
    new_registry_bytes: []const u8,
) !void {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    try ensureDir(dir);

    if (try fileEqualsBytes(allocator, current_registry_path, new_registry_bytes)) {
        return;
    }

    var file = std.fs.cwd().openFile(current_registry_path, .{}) catch return;
    file.close();

    const backup = try makeBackupPath(allocator, dir, "registry.json");
    defer allocator.free(backup);
    try std.fs.cwd().copyFile(current_registry_path, std.fs.cwd(), backup, .{});
    try pruneBackups(allocator, dir, "registry.json", max_backups);
}

pub const ImportRenderKind = enum {
    single_file,
    scanned,
};

pub const ImportOutcome = enum {
    imported,
    updated,
    skipped,
};

pub const ImportEvent = struct {
    label: []u8,
    outcome: ImportOutcome,
    reason: ?[]u8 = null,

    pub fn deinit(self: *ImportEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.reason) |reason| allocator.free(reason);
    }
};

pub const ImportReport = struct {
    render_kind: ImportRenderKind,
    source_label: ?[]u8 = null,
    failure: ?anyerror = null,
    imported: usize = 0,
    updated: usize = 0,
    skipped: usize = 0,
    total_files: usize = 0,
    events: std.ArrayList(ImportEvent),

    pub fn init(render_kind: ImportRenderKind) ImportReport {
        return .{
            .render_kind = render_kind,
            .events = std.ArrayList(ImportEvent).empty,
        };
    }

    pub fn deinit(self: *ImportReport, allocator: std.mem.Allocator) void {
        if (self.source_label) |source_label| allocator.free(source_label);
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
    }

    pub fn addEvent(
        self: *ImportReport,
        allocator: std.mem.Allocator,
        label: []const u8,
        outcome: ImportOutcome,
        reason: ?[]const u8,
    ) !void {
        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        const owned_reason = if (reason) |reason_text| try allocator.dupe(u8, reason_text) else null;
        errdefer if (owned_reason) |owned| allocator.free(owned);

        try self.events.append(allocator, .{
            .label = owned_label,
            .outcome = outcome,
            .reason = owned_reason,
        });
        self.total_files += 1;
        switch (outcome) {
            .imported => self.imported += 1,
            .updated => self.updated += 1,
            .skipped => self.skipped += 1,
        }
    }

    pub fn appliedCount(self: *const ImportReport) usize {
        return self.imported + self.updated;
    }
};

const PurgeCarryForwardConfig = struct {
    auto_switch: AutoSwitchConfig = defaultAutoSwitchConfig(),
    api: ApiConfig = defaultApiConfig(),
};

pub fn purgeRegistryFromImportSource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    auth_path: ?[]const u8,
    explicit_alias: ?[]const u8,
) !ImportReport {
    if (auth_path == null and explicit_alias != null) {
        std.log.warn("--alias is ignored when purging from {s}", .{"~/.codex/accounts"});
    }

    const carry_forward = try loadPurgeCarryForwardConfig(allocator, codex_home);

    var reg = defaultRegistry();
    reg.auto_switch = carry_forward.auto_switch;
    reg.api = carry_forward.api;
    defer reg.deinit(allocator);

    var report = if (auth_path) |path|
        try importAuthPath(allocator, codex_home, &reg, path, explicit_alias)
    else
        try importAccountsSnapshotDirectory(allocator, codex_home, &reg);
    errdefer report.deinit(allocator);
    report.render_kind = .scanned;
    if (report.source_label == null) {
        report.source_label = try allocator.dupe(u8, auth_path orelse "~/.codex/accounts");
    }
    if (report.failure != null) {
        return report;
    }

    if (try syncCurrentAuthBestEffort(allocator, codex_home, &reg)) |outcome| {
        try report.addEvent(allocator, "auth.json (active)", outcome, null);
    }

    sortAccountsByEmail(&reg);
    if (reg.active_account_key == null and reg.accounts.items.len > 0) {
        try activateAccountByKey(allocator, codex_home, &reg, reg.accounts.items[0].account_key);
    }
    try saveRegistry(allocator, codex_home, &reg);
    return report;
}

fn loadPurgeCarryForwardConfig(allocator: std.mem.Allocator, codex_home: []const u8) !PurgeCarryForwardConfig {
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const cwd = std.fs.cwd();
    var file = cwd.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    return parsePurgeCarryForwardConfig(allocator, data);
}

fn parsePurgeCarryForwardConfig(allocator: std.mem.Allocator, data: []const u8) PurgeCarryForwardConfig {
    var cfg = PurgeCarryForwardConfig{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        applyCarryForwardObjectSlice(allocator, data, "auto_switch", &cfg.auto_switch, parseCarryForwardAutoSwitch);
        applyCarryForwardObjectSlice(allocator, data, "api", &cfg.api, parseCarryForwardApiConfig);
        return cfg;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            if (obj.get("auto_switch")) |v| parseAutoSwitch(allocator, &cfg.auto_switch, v);
            if (obj.get("api")) |v| parseApiConfig(&cfg.api, v);
        },
        else => {},
    }
    return cfg;
}

fn parseCarryForwardAutoSwitch(allocator: std.mem.Allocator, value: std.json.Value, target: *AutoSwitchConfig) void {
    parseAutoSwitch(allocator, target, value);
}

fn parseCarryForwardApiConfig(_: std.mem.Allocator, value: std.json.Value, target: *ApiConfig) void {
    parseApiConfig(target, value);
}

fn applyCarryForwardObjectSlice(
    allocator: std.mem.Allocator,
    data: []const u8,
    field_name: []const u8,
    target: anytype,
    comptime parser: fn (std.mem.Allocator, std.json.Value, @TypeOf(target)) void,
) void {
    const slice = findJsonObjectFieldSlice(data, field_name) orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch return;
    defer parsed.deinit();
    parser(allocator, parsed.value, target);
}

fn findJsonObjectFieldSlice(data: []const u8, field_name: []const u8) ?[]const u8 {
    var pattern_buffer: [64]u8 = undefined;
    if (field_name.len + 2 > pattern_buffer.len) return null;
    pattern_buffer[0] = '"';
    @memcpy(pattern_buffer[1 .. 1 + field_name.len], field_name);
    pattern_buffer[1 + field_name.len] = '"';
    const pattern = pattern_buffer[0 .. field_name.len + 2];

    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, data, search_start, pattern)) |name_idx| {
        search_start = name_idx + pattern.len;
        var idx = skipJsonWhitespace(data, search_start);
        if (idx >= data.len or data[idx] != ':') continue;
        idx = skipJsonWhitespace(data, idx + 1);
        if (idx >= data.len or data[idx] != '{') continue;
        const end_idx = findBalancedObjectEnd(data, idx) orelse continue;
        return data[idx .. end_idx + 1];
    }
    return null;
}

fn skipJsonWhitespace(data: []const u8, start: usize) usize {
    var idx = start;
    while (idx < data.len and std.ascii.isWhitespace(data[idx])) : (idx += 1) {}
    return idx;
}

fn findBalancedObjectEnd(data: []const u8, start: usize) ?usize {
    var idx = start;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    while (idx < data.len) : (idx += 1) {
        const ch = data[idx];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            switch (ch) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }

    return null;
}

fn importDisplayLabelFromName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, name, ".auth.json")) {
        return allocator.dupe(u8, name[0 .. name.len - ".auth.json".len]);
    }
    if (std.mem.endsWith(u8, name, ".json")) {
        return allocator.dupe(u8, name[0 .. name.len - ".json".len]);
    }
    return allocator.dupe(u8, name);
}

fn importDisplayLabel(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return importDisplayLabelFromName(allocator, std.fs.path.basename(path));
}

fn importReasonLabel(err: anyerror) []const u8 {
    switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        => return "MalformedJson",
        else => {},
    }
    return @errorName(err);
}

fn isImportValidationError(err: anyerror) bool {
    return switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.InvalidCpaFormat,
        error.MissingEmail,
        error.MissingChatgptUserId,
        error.MissingAccountId,
        error.MissingRefreshToken,
        error.AccountIdMismatch,
        error.InvalidJwt,
        error.InvalidBase64,
        => true,
        else => false,
    };
}

fn isImportSourceFileError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.IsDir,
        error.NotDir,
        error.StreamTooLong,
        error.SymLinkLoop,
        => true,
        else => false,
    };
}

fn isImportSkippableBatchEntryError(err: anyerror) bool {
    return isImportValidationError(err) or isImportSourceFileError(err);
}

pub fn importCpaPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: ?[]const u8,
    explicit_alias: ?[]const u8,
) !ImportReport {
    if (auth_path == null) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{"~/.cli-proxy-api"});
        }
        const default_path = try defaultCpaImportPath(allocator);
        defer allocator.free(default_path);
        return try importCpaDirectory(allocator, codex_home, reg, default_path, "~/.cli-proxy-api", false);
    }

    const path = auth_path.?;
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => {
            if (explicit_alias != null) {
                std.log.warn("--alias is ignored when importing a directory: {s}", .{path});
            }
            return try importCpaDirectory(allocator, codex_home, reg, path, path, false);
        },
        else => return err,
    };
    if (stat.kind == .directory) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{path});
        }
        return try importCpaDirectory(allocator, codex_home, reg, path, path, false);
    }

    var report = ImportReport.init(.single_file);
    errdefer report.deinit(allocator);

    const outcome = importCpaFile(allocator, codex_home, reg, path, explicit_alias) catch |err| {
        if (!isImportValidationError(err) and !isImportSourceFileError(err)) return err;
        const label = try importDisplayLabel(allocator, path);
        defer allocator.free(label);
        try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
        report.failure = err;
        return report;
    };

    const label = try importDisplayLabel(allocator, path);
    defer allocator.free(label);
    try report.addEvent(allocator, label, outcome, null);
    return report;
}

pub fn importAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: []const u8,
    explicit_alias: ?[]const u8,
) !ImportReport {
    const stat = std.fs.cwd().statFile(auth_path) catch |err| switch (err) {
        error.IsDir => {
            if (explicit_alias != null) {
                std.log.warn("--alias is ignored when importing a directory: {s}", .{auth_path});
            }
            return try importAuthDirectory(allocator, codex_home, reg, auth_path);
        },
        else => return err,
    };
    if (stat.kind == .directory) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{auth_path});
        }
        return try importAuthDirectory(allocator, codex_home, reg, auth_path);
    }

    var report = ImportReport.init(.single_file);
    errdefer report.deinit(allocator);

    const outcome = importAuthFile(allocator, codex_home, reg, auth_path, explicit_alias) catch |err| {
        if (!isImportValidationError(err)) return err;
        const label = try importDisplayLabel(allocator, auth_path);
        defer allocator.free(label);
        try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
        report.failure = err;
        return report;
    };

    const label = try importDisplayLabel(allocator, auth_path);
    defer allocator.free(label);
    try report.addEvent(allocator, label, outcome, null);
    return report;
}

fn defaultCpaImportPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".cli-proxy-api" });
}

fn importCpaFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
) !ImportOutcome {
    var file = try std.fs.cwd().openFile(auth_file, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    const converted = try @import("auth.zig").convertCpaAuthJson(allocator, data);
    defer allocator.free(converted);

    const info = try @import("auth.zig").parseAuthInfoData(allocator, converted);
    defer info.deinit(allocator);

    return try importConvertedAuthInfo(allocator, codex_home, reg, explicit_alias, &info, converted);
}

fn importConvertedAuthInfo(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    explicit_alias: ?[]const u8,
    info: *const @import("auth.zig").AuthInfo,
    auth_data: []const u8,
) !ImportOutcome {
    _ = info.email orelse return error.MissingEmail;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const alias = explicit_alias orelse "";
    const existed = findAccountIndexByAccountKey(reg, record_key) != null;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try writeFile(dest, auth_data);

    const record = try accountFromAuth(allocator, alias, info);
    try upsertAccount(allocator, reg, record);
    return if (existed) .updated else .imported;
}

fn importAuthFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
) !ImportOutcome {
    const info = try @import("auth.zig").parseAuthInfo(allocator, auth_file);
    defer info.deinit(allocator);
    return try importAuthInfo(allocator, codex_home, reg, auth_file, explicit_alias, &info);
}

fn importAuthInfo(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
    info: *const @import("auth.zig").AuthInfo,
) !ImportOutcome {
    _ = info.email orelse return error.MissingEmail;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const alias = explicit_alias orelse "";
    const existed = findAccountIndexByAccountKey(reg, record_key) != null;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_file, dest);

    const record = try accountFromAuth(allocator, alias, info);
    try upsertAccount(allocator, reg, record);
    return if (existed) .updated else .imported;
}

fn importCpaDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    dir_path: []const u8,
    source_label: []const u8,
    missing_ok: bool,
) !ImportReport {
    var report = ImportReport.init(.scanned);
    errdefer report.deinit(allocator);
    report.source_label = try allocator.dupe(u8, source_label);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => if (missing_ok) return report else return err,
        else => return err,
    };
    defer dir.close();

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isImportConfigFile(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.insertion([]u8, names.items, {}, importFileNameLessThan);

    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
        defer allocator.free(file_path);
        const label = try importDisplayLabelFromName(allocator, name);
        defer allocator.free(label);
        const outcome = importCpaFile(allocator, codex_home, reg, file_path, null) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        try report.addEvent(allocator, label, outcome, null);
    }

    return report;
}

fn importAuthDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    dir_path: []const u8,
) !ImportReport {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isImportConfigFile(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.insertion([]u8, names.items, {}, importFileNameLessThan);

    var report = ImportReport.init(.scanned);
    errdefer report.deinit(allocator);
    report.source_label = try allocator.dupe(u8, dir_path);
    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
        defer allocator.free(file_path);
        const label = try importDisplayLabelFromName(allocator, name);
        defer allocator.free(label);
        const info = @import("auth.zig").parseAuthInfo(allocator, file_path) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        defer info.deinit(allocator);
        const outcome = importAuthInfo(allocator, codex_home, reg, file_path, null, &info) catch |err| {
            if (!isImportValidationError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        try report.addEvent(allocator, label, outcome, null);
    }
    return report;
}

fn importAccountsSnapshotDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
) !ImportReport {
    var report = ImportReport.init(.scanned);
    errdefer report.deinit(allocator);
    report.source_label = try allocator.dupe(u8, "~/.codex/accounts");

    const dir_path = try backupDir(allocator, codex_home);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return report,
        else => return err,
    };
    defer dir.close();

    var candidates = std.ArrayList(PurgeImportCandidate).empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isPurgeImportAuthFile(entry.name)) continue;

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        var file_path_owned = true;
        errdefer if (file_path_owned) allocator.free(file_path);

        const label = try importDisplayLabelFromName(allocator, entry.name);
        defer allocator.free(label);

        const stat = dir.statFile(entry.name) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        var info = @import("auth.zig").parseAuthInfo(allocator, file_path) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        defer info.deinit(allocator);

        const email = info.email orelse {
            try report.addEvent(allocator, label, .skipped, importReasonLabel(error.MissingEmail));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        const record_key = info.record_key orelse {
            try report.addEvent(allocator, label, .skipped, importReasonLabel(error.MissingChatgptUserId));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };

        const canonical_name = try accountSnapshotFileName(allocator, record_key);
        defer allocator.free(canonical_name);

        const candidate_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(candidate_name);
        const candidate_record_key = try allocator.dupe(u8, record_key);
        errdefer allocator.free(candidate_record_key);
        const candidate_email = try allocator.dupe(u8, email);
        errdefer allocator.free(candidate_email);

        var candidate = PurgeImportCandidate{
            .name = candidate_name,
            .path = file_path,
            .record_key = candidate_record_key,
            .email = candidate_email,
            .mtime = stat.mtime,
            .kind = if (std.mem.eql(u8, entry.name, canonical_name))
                .current_snapshot
            else if (std.mem.startsWith(u8, entry.name, "auth.json.bak."))
                .backup
            else
                .legacy_snapshot,
        };
        errdefer candidate.deinit(allocator);
        file_path_owned = false;

        if (findPurgeImportCandidateIndexByRecordKey(candidates.items, candidate.record_key)) |idx| {
            if (purgeImportCandidateIsNewer(&candidates.items[idx], &candidate)) {
                try report.addEvent(allocator, candidates.items[idx].name, .skipped, "SupersededByNewerSnapshot");
                candidates.items[idx].deinit(allocator);
                candidates.items[idx] = candidate;
            } else {
                try report.addEvent(allocator, candidate.name, .skipped, "SupersededByNewerSnapshot");
                candidate.deinit(allocator);
            }
            continue;
        }

        try candidates.append(allocator, candidate);
    }

    std.sort.insertion(PurgeImportCandidate, candidates.items, {}, purgeImportCandidateLessThan);

    for (candidates.items) |candidate| {
        const label = try importDisplayLabelFromName(allocator, candidate.name);
        defer allocator.free(label);
        const outcome = importAuthFile(allocator, codex_home, reg, candidate.path, null) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        try report.addEvent(allocator, label, outcome, null);
    }
    return report;
}

const PurgeImportCandidateKind = enum(u8) {
    legacy_snapshot,
    backup,
    current_snapshot,
};

const PurgeImportCandidate = struct {
    name: []u8,
    path: []u8,
    record_key: []u8,
    email: []u8,
    mtime: i128,
    kind: PurgeImportCandidateKind,

    fn deinit(self: *PurgeImportCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.record_key);
        allocator.free(self.email);
    }
};

fn purgeImportCandidateRank(kind: PurgeImportCandidateKind) u8 {
    return switch (kind) {
        .legacy_snapshot => 0,
        .backup => 1,
        .current_snapshot => 2,
    };
}

fn purgeImportCandidateIsNewer(current: *const PurgeImportCandidate, incoming: *const PurgeImportCandidate) bool {
    if (incoming.mtime != current.mtime) return incoming.mtime > current.mtime;

    const incoming_rank = purgeImportCandidateRank(incoming.kind);
    const current_rank = purgeImportCandidateRank(current.kind);
    if (incoming_rank != current_rank) return incoming_rank > current_rank;

    return std.mem.order(u8, incoming.name, current.name) == .gt;
}

fn findPurgeImportCandidateIndexByRecordKey(candidates: []const PurgeImportCandidate, record_key: []const u8) ?usize {
    for (candidates, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate.record_key, record_key)) return idx;
    }
    return null;
}

fn purgeImportCandidateLessThan(_: void, a: PurgeImportCandidate, b: PurgeImportCandidate) bool {
    return accountRecordOrderLessThan(a.email, a.record_key, b.email, b.record_key);
}

fn isImportConfigFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".json");
}

fn isPurgeImportAuthFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".auth.json") or
        std.mem.startsWith(u8, name, "auth.json.bak.");
}

fn importFileNameLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn accountRecordOrderLessThan(a_email: []const u8, a_account_key: []const u8, b_email: []const u8, b_account_key: []const u8) bool {
    return switch (std.mem.order(u8, a_email, b_email)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a_account_key, b_account_key),
    };
}

fn accountRecordLessThan(_: void, a: AccountRecord, b: AccountRecord) bool {
    return accountRecordOrderLessThan(a.email, a.account_key, b.email, b.account_key);
}

fn sortAccountsByEmail(reg: *Registry) void {
    std.sort.insertion(AccountRecord, reg.accounts.items, {}, accountRecordLessThan);
}

fn syncCurrentAuthBestEffort(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
) !?ImportOutcome {
    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    var file = std.fs.cwd().openFile(auth_path, .{}) catch return null;
    file.close();

    const info = @import("auth.zig").parseAuthInfo(allocator, auth_path) catch return null;
    defer info.deinit(allocator);
    if (info.auth_mode == .apikey) return null;
    _ = info.email orelse return null;
    const record_key = info.record_key orelse return null;

    const existing_idx = findAccountIndexByAccountKey(reg, record_key);
    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);
    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_path, dest);

    if (existing_idx) |idx| {
        const email = info.email.?;
        if (!std.mem.eql(u8, reg.accounts.items[idx].email, email)) {
            const new_email = try allocator.dupe(u8, email);
            allocator.free(reg.accounts.items[idx].email);
            reg.accounts.items[idx].email = new_email;
        }
        if (info.chatgpt_account_id) |chatgpt_account_id| {
            if (!std.mem.eql(u8, reg.accounts.items[idx].chatgpt_account_id, chatgpt_account_id)) {
                const new_chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id);
                allocator.free(reg.accounts.items[idx].chatgpt_account_id);
                reg.accounts.items[idx].chatgpt_account_id = new_chatgpt_account_id;
            }
        }
        if (info.chatgpt_user_id) |chatgpt_user_id| {
            if (!std.mem.eql(u8, reg.accounts.items[idx].chatgpt_user_id, chatgpt_user_id)) {
                const new_chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id);
                allocator.free(reg.accounts.items[idx].chatgpt_user_id);
                reg.accounts.items[idx].chatgpt_user_id = new_chatgpt_user_id;
            }
        }
        reg.accounts.items[idx].plan = info.plan;
        reg.accounts.items[idx].auth_mode = info.auth_mode;
    } else {
        var record = try accountFromAuth(allocator, "", &info);
        errdefer freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
    }

    _ = try syncActiveConfigSnapshotForAccount(allocator, codex_home, record_key);
    try setActiveAccountKey(allocator, reg, record_key);
    return if (existing_idx != null) .updated else .imported;
}

pub fn findAccountIndexByAccountKey(reg: *Registry, account_key: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.account_key, account_key)) return i;
    }
    return null;
}

pub fn findApiProfileIndexByKey(reg: *Registry, profile_key: []const u8) ?usize {
    for (reg.api_profiles.items, 0..) |profile, i| {
        if (std.mem.eql(u8, profile.profile_key, profile_key)) return i;
    }
    return null;
}

fn apiProfileByKey(reg: *Registry, profile_key: []const u8) !*ApiProfileRecord {
    const idx = findApiProfileIndexByKey(reg, profile_key) orelse return error.ApiProfileNotFound;
    return &reg.api_profiles.items[idx];
}

fn clearActiveAccountKey(allocator: std.mem.Allocator, reg: *Registry) void {
    if (reg.active_account_key) |key| allocator.free(key);
    reg.active_account_key = null;
}

fn clearActiveApiProfileKey(allocator: std.mem.Allocator, reg: *Registry) void {
    if (reg.active_api_profile_key) |key| allocator.free(key);
    reg.active_api_profile_key = null;
}

pub fn setActiveAccountKey(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8) !void {
    if (reg.active_account_key) |k| {
        if (std.mem.eql(u8, k, account_key) and reg.active_auth_mode == .chatgpt and reg.active_api_profile_key == null) {
            return;
        }
    }
    const new_active_account_key = try allocator.dupe(u8, account_key);
    clearActiveAccountKey(allocator, reg);
    clearActiveApiProfileKey(allocator, reg);
    reg.active_account_key = new_active_account_key;
    reg.active_auth_mode = .chatgpt;
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
    const now = std.time.timestamp();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            rec.last_used_at = now;
            break;
        }
    }
}

pub fn setActiveApiProfileKey(allocator: std.mem.Allocator, reg: *Registry, profile_key: []const u8) !void {
    const idx = findApiProfileIndexByKey(reg, profile_key) orelse return error.ApiProfileNotFound;
    const new_active_profile_key = try allocator.dupe(u8, profile_key);
    clearActiveAccountKey(allocator, reg);
    clearActiveApiProfileKey(allocator, reg);
    reg.active_api_profile_key = new_active_profile_key;
    reg.active_auth_mode = .apikey;
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
    reg.api_profiles.items[idx].last_used_at = std.time.timestamp();
}

fn setUntrackedApiMode(allocator: std.mem.Allocator, reg: *Registry) void {
    clearActiveAccountKey(allocator, reg);
    clearActiveApiProfileKey(allocator, reg);
    reg.active_auth_mode = .apikey;
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
}

fn updateApiProfileMetadata(
    allocator: std.mem.Allocator,
    profile: *ApiProfileRecord,
    label: ?[]const u8,
    summary: *const ActiveApiConfigSummary,
) !bool {
    var changed = false;
    if (label) |value| {
        changed = (try replaceRequiredStringAlloc(allocator, &profile.label, value)) or changed;
    }
    changed = (try replaceOptionalStringAlloc(allocator, &profile.model_provider, summary.model_provider)) or changed;
    changed = (try replaceOptionalStringAlloc(allocator, &profile.provider_name, summary.provider_name)) or changed;
    changed = (try replaceOptionalStringAlloc(allocator, &profile.model, summary.model)) or changed;
    changed = (try replaceOptionalStringAlloc(allocator, &profile.base_url, summary.base_url)) or changed;
    changed = (try replaceOptionalStringAlloc(allocator, &profile.wire_api, summary.wire_api)) or changed;
    return changed;
}

fn generateApiProfileKey(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "api-{d}-{x}",
        .{ std.time.milliTimestamp(), std.hash.Wyhash.hash(0, label) },
    );
}

pub fn updateUsage(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8, snapshot: RateLimitSnapshot) void {
    const now = std.time.timestamp();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            if (rec.last_usage) |*u| {
                if (u.credits) |*c| {
                    if (c.balance) |b| allocator.free(b);
                }
            }
            rec.last_usage = snapshot;
            rec.last_usage_at = now;
            break;
        }
    }
}

fn setRenewalDateAlloc(
    allocator: std.mem.Allocator,
    renewal: *RenewalInfo,
    next_renewal_at: ?[]const u8,
) !void {
    const replacement = if (next_renewal_at) |value| try allocator.dupe(u8, value) else null;
    errdefer if (replacement) |value| allocator.free(value);
    if (renewal.next_renewal_at) |existing| allocator.free(existing);
    renewal.next_renewal_at = replacement;
}

fn accountByKey(reg: *Registry, account_key: []const u8) !*AccountRecord {
    const idx = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    return &reg.accounts.items[idx];
}

pub fn setAccountRenewal(
    allocator: std.mem.Allocator,
    reg: *Registry,
    account_key: []const u8,
    next_renewal_at: []const u8,
    source: RenewalSource,
    status: RenewalStatus,
) !void {
    var rec = try accountByKey(reg, account_key);
    try setRenewalDateAlloc(allocator, &rec.renewal, next_renewal_at);
    rec.renewal.source = source;
    rec.renewal.status = status;
    rec.renewal.updated_at = std.time.timestamp();
}

pub fn clearAccountRenewal(
    allocator: std.mem.Allocator,
    reg: *Registry,
    account_key: []const u8,
) !void {
    var rec = try accountByKey(reg, account_key);
    try setRenewalDateAlloc(allocator, &rec.renewal, null);
    rec.renewal.source = null;
    rec.renewal.status = .missing;
    rec.renewal.updated_at = std.time.timestamp();
}

pub fn markAccountRenewalStatus(
    reg: *Registry,
    account_key: []const u8,
    status: RenewalStatus,
) !void {
    var rec = try accountByKey(reg, account_key);
    rec.renewal.status = status;
    rec.renewal.updated_at = std.time.timestamp();
    if (status == .missing and rec.renewal.next_renewal_at == null) {
        rec.renewal.source = null;
    }
}

pub fn syncActiveAccountFromAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !bool {
    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const auth_bytes_opt = try readFileIfExists(allocator, auth_path);
    if (auth_bytes_opt == null) {
        tryEnsureDualProviderHistory(allocator, codex_home);
        return false;
    }
    const auth_bytes = auth_bytes_opt.?;
    defer allocator.free(auth_bytes);

    const info = @import("auth.zig").parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("auth.json sync skipped: {s}", .{@errorName(err)});
            tryEnsureDualProviderHistory(allocator, codex_home);
            return false;
        },
    };
    defer info.deinit(allocator);

    if (info.auth_mode == .apikey) {
        const config_path = try activeConfigPath(allocator, codex_home);
        defer allocator.free(config_path);
        const config_bytes = try readFileIfExists(allocator, config_path);
        defer if (config_bytes) |bytes| allocator.free(bytes);

        if (try findMatchingApiProfileIndexForCurrentFiles(
            allocator,
            codex_home,
            reg,
            auth_bytes,
            config_bytes,
        )) |idx| {
            const profile_key = reg.api_profiles.items[idx].profile_key;
            const changed = reg.active_auth_mode != .apikey or
                reg.active_account_key != null or
                reg.active_api_profile_key == null or
                !std.mem.eql(u8, reg.active_api_profile_key.?, profile_key);
            try setActiveApiProfileKey(allocator, reg, profile_key);
            tryEnsureDualProviderHistory(allocator, codex_home);
            return changed;
        }

        const changed = reg.active_auth_mode != .apikey or
            reg.active_account_key != null or
            reg.active_api_profile_key != null;
        setUntrackedApiMode(allocator, reg);
        tryEnsureDualProviderHistory(allocator, codex_home);
        return changed;
    }

    const email = info.email orelse {
        std.log.warn("auth.json missing email; skipping sync", .{});
        tryEnsureDualProviderHistory(allocator, codex_home);
        return false;
    };
    const record_key = info.record_key orelse {
        std.log.warn("auth.json missing record_key; skipping sync", .{});
        tryEnsureDualProviderHistory(allocator, codex_home);
        return false;
    };

    const matched_index = findAccountIndexByAccountKey(reg, record_key);
    if (matched_index == null) {
        const dest = try accountAuthPath(allocator, codex_home, record_key);
        defer allocator.free(dest);

        try ensureAccountsDir(allocator, codex_home);
        try copyFile(auth_path, dest);

        var record = try accountFromAuth(allocator, "", &info);
        var record_owned = true;
        errdefer if (record_owned) freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
        record_owned = false;
        if (try syncActiveConfigSnapshotForAccount(allocator, codex_home, record_key)) {
            // Config snapshot changed with the new record.
        }
        try setActiveAccountKey(allocator, reg, record_key);
        tryEnsureDualProviderHistory(allocator, codex_home);
        return true;
    }

    const idx = matched_index.?;
    const rec_account_key = reg.accounts.items[idx].account_key;
    var changed = false;
    if (reg.active_account_key) |k| {
        if (!std.mem.eql(u8, k, rec_account_key)) changed = true;
    } else {
        changed = true;
    }

    if (!std.mem.eql(u8, reg.accounts.items[idx].email, email)) {
        const new_email = try allocator.dupe(u8, email);
        allocator.free(reg.accounts.items[idx].email);
        reg.accounts.items[idx].email = new_email;
        changed = true;
    }
    if (reg.accounts.items[idx].plan != info.plan) {
        changed = true;
    }
    reg.accounts.items[idx].plan = info.plan;
    if (reg.accounts.items[idx].auth_mode != info.auth_mode) {
        changed = true;
    }
    reg.accounts.items[idx].auth_mode = info.auth_mode;

    const dest = try accountAuthPath(allocator, codex_home, rec_account_key);
    defer allocator.free(dest);
    if (!(try fileEqualsBytes(allocator, dest, auth_bytes))) {
        try copyFile(auth_path, dest);
        changed = true;
    }
    if (try syncActiveConfigSnapshotForAccount(allocator, codex_home, rec_account_key)) {
        changed = true;
    }

    try setActiveAccountKey(allocator, reg, rec_account_key);
    tryEnsureDualProviderHistory(allocator, codex_home);
    return changed;
}

pub fn removeAccounts(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry, indices: []const usize) !void {
    if (indices.len == 0 or reg.accounts.items.len == 0) return;

    var removed = try allocator.alloc(bool, reg.accounts.items.len);
    defer allocator.free(removed);
    @memset(removed, false);
    for (indices) |idx| {
        if (idx < removed.len) removed[idx] = true;
    }

    try deleteRemovedAccountBackups(allocator, codex_home, reg, removed);

    if (reg.active_account_key) |key| {
        var active_removed = false;
        for (reg.accounts.items, 0..) |rec, i| {
            if (removed[i] and std.mem.eql(u8, rec.account_key, key)) {
                active_removed = true;
                break;
            }
        }
        if (active_removed) {
            allocator.free(key);
            reg.active_account_key = null;
            reg.active_account_activated_at_ms = null;
        }
    }

    var write_idx: usize = 0;
    for (reg.accounts.items, 0..) |*rec, i| {
        if (removed[i]) {
            const preferred_path = try accountAuthPath(allocator, codex_home, rec.account_key);
            defer allocator.free(preferred_path);
            std.fs.cwd().deleteFile(preferred_path) catch {};
            const config_path = try accountConfigPath(allocator, codex_home, rec.account_key);
            defer allocator.free(config_path);
            std.fs.cwd().deleteFile(config_path) catch {};
            freeAccountRecord(allocator, rec);
            continue;
        }
        if (write_idx != i) {
            reg.accounts.items[write_idx] = rec.*;
        }
        write_idx += 1;
    }
    reg.accounts.items.len = write_idx;
}

fn deleteRemovedAccountBackups(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    removed: []const bool,
) !void {
    const dir_path = try backupDir(allocator, codex_home);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;

        const path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(path);

        var info = @import("auth.zig").parseAuthInfo(allocator, path) catch continue;
        defer info.deinit(allocator);

        const record_key = info.record_key orelse continue;
        if (!isRemovedAccountKey(reg, removed, record_key)) continue;

        dir.deleteFile(entry.name) catch {};
    }
}

fn isRemovedAccountKey(reg: *const Registry, removed: []const bool, record_key: []const u8) bool {
    for (reg.accounts.items, 0..) |rec, i| {
        if (!removed[i]) continue;
        if (std.mem.eql(u8, rec.account_key, record_key)) return true;
    }
    return false;
}

pub fn selectBestAccountIndexByUsage(reg: *Registry) ?usize {
    if (reg.accounts.items.len == 0) return null;
    const now = std.time.timestamp();
    var best_idx: ?usize = null;
    var best_score: i64 = -2;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |rec, i| {
        const score = usageScoreAt(rec.last_usage, now) orelse -1;
        const seen = rec.last_usage_at orelse -1;
        if (score > best_score) {
            best_score = score;
            best_seen = seen;
            best_idx = i;
        } else if (score == best_score and seen > best_seen) {
            best_seen = seen;
            best_idx = i;
        }
    }
    return best_idx;
}

pub fn usageScoreAt(usage: ?RateLimitSnapshot, now: i64) ?i64 {
    const rate_5h = resolveRateWindow(usage, 300, true);
    const rate_week = resolveRateWindow(usage, 10080, false);
    const rem_5h = remainingPercentAt(rate_5h, now);
    const rem_week = remainingPercentAt(rate_week, now);
    if (rem_5h != null and rem_week != null) return @min(rem_5h.?, rem_week.?);
    if (rem_5h != null) return rem_5h.?;
    if (rem_week != null) return rem_week.?;
    return null;
}

pub fn remainingPercentAt(window: ?RateLimitWindow, now: i64) ?i64 {
    if (window == null) return null;
    if (window.?.resets_at) |resets_at| {
        if (resets_at <= now) return 100;
    }
    const remaining = 100.0 - window.?.used_percent;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

pub fn resolveRateWindow(usage: ?RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

fn hasStoredAccountName(rec: *const AccountRecord) bool {
    const account_name = rec.account_name orelse return false;
    return account_name.len != 0;
}

fn isTeamAccount(rec: *const AccountRecord) bool {
    const plan = resolvePlan(rec) orelse return false;
    return plan == .team;
}

fn inAccountNameRefreshScope(reg: *const Registry, chatgpt_user_id: []const u8, rec: *const AccountRecord) bool {
    _ = reg;
    return std.mem.eql(u8, rec.chatgpt_user_id, chatgpt_user_id);
}

pub fn hasMissingAccountNameForUser(reg: *const Registry, chatgpt_user_id: []const u8) bool {
    for (reg.accounts.items) |rec| {
        if (!inAccountNameRefreshScope(reg, chatgpt_user_id, &rec)) continue;
        if (isTeamAccount(&rec) and !hasStoredAccountName(&rec)) return true;
    }
    return false;
}

pub fn shouldFetchTeamAccountNamesForUser(reg: *const Registry, chatgpt_user_id: []const u8) bool {
    var account_count: usize = 0;
    var has_team_account = false;
    var has_missing_team_account_name = false;

    for (reg.accounts.items) |rec| {
        if (!inAccountNameRefreshScope(reg, chatgpt_user_id, &rec)) continue;

        account_count += 1;
        if (!isTeamAccount(&rec)) continue;

        has_team_account = true;
        if (!hasStoredAccountName(&rec)) {
            has_missing_team_account_name = true;
        }
    }

    if (!has_team_account or !has_missing_team_account_name) return false;
    return account_count > 1;
}

pub fn activeChatgptUserId(reg: *Registry) ?[]const u8 {
    const active_account_key = reg.active_account_key orelse return null;
    const idx = findAccountIndexByAccountKey(reg, active_account_key) orelse return null;
    return reg.accounts.items[idx].chatgpt_user_id;
}

pub fn applyAccountNamesForUser(
    allocator: std.mem.Allocator,
    reg: *Registry,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var changed = false;
    for (reg.accounts.items) |*rec| {
        if (!inAccountNameRefreshScope(reg, chatgpt_user_id, rec)) continue;

        var account_name: ?[]const u8 = null;
        var matched = false;
        for (entries) |entry| {
            if (!std.mem.eql(u8, rec.chatgpt_account_id, entry.account_id)) continue;
            account_name = entry.account_name;
            matched = true;
            break;
        }

        if (!matched and !isTeamAccount(rec) and !hasStoredAccountName(rec)) continue;
        if (try replaceOptionalStringAlloc(allocator, &rec.account_name, account_name)) {
            changed = true;
        }
    }
    return changed;
}

fn syncActiveConfigSnapshotForAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
) !bool {
    try ensureAccountsDir(allocator, codex_home);
    const current_config_path = try activeConfigPath(allocator, codex_home);
    defer allocator.free(current_config_path);
    const snapshot_path = try accountConfigPath(allocator, codex_home, account_key);
    defer allocator.free(snapshot_path);
    return syncSnapshotFileFromCurrent(allocator, current_config_path, snapshot_path);
}

fn restoreAccountConfigSnapshotToActive(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
    delete_when_missing: bool,
) !bool {
    const snapshot_path = try accountConfigPath(allocator, codex_home, account_key);
    defer allocator.free(snapshot_path);
    if (!delete_when_missing and !(try fileExists(snapshot_path))) return false;
    const current_config_path = try activeConfigPath(allocator, codex_home);
    defer allocator.free(current_config_path);
    return restoreActiveFileFromSnapshot(allocator, snapshot_path, current_config_path);
}

fn findMatchingApiProfileIndexForCurrentFiles(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_bytes: []const u8,
    config_bytes: ?[]const u8,
) !?usize {
    for (reg.api_profiles.items, 0..) |profile, idx| {
        const auth_path = try apiProfileAuthPath(allocator, codex_home, profile.profile_key);
        defer allocator.free(auth_path);
        if (!(try fileEqualsBytes(allocator, auth_path, auth_bytes))) continue;

        const config_path = try apiProfileConfigPath(allocator, codex_home, profile.profile_key);
        defer allocator.free(config_path);
        if (config_bytes) |bytes| {
            if (!(try fileEqualsBytes(allocator, config_path, bytes))) continue;
        } else if (try fileExists(config_path)) {
            continue;
        }

        return idx;
    }
    return null;
}

pub fn captureCurrentApiProfile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    label: []const u8,
) ![]u8 {
    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    const config_path = try activeConfigPath(allocator, codex_home);
    defer allocator.free(config_path);

    const auth_bytes = try readFileIfExists(allocator, auth_path) orelse return error.AuthFileNotFound;
    defer allocator.free(auth_bytes);
    const config_bytes = try readFileIfExists(allocator, config_path) orelse return error.ConfigFileNotFound;
    defer allocator.free(config_bytes);

    const info = try @import("auth.zig").parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    if (info.auth_mode != .apikey) return error.ApiKeyModeRequired;

    var summary = try parseActiveApiConfigSummary(allocator, config_bytes);
    defer summary.deinit(allocator);

    try ensureAccountsDir(allocator, codex_home);

    if (try findMatchingApiProfileIndexForCurrentFiles(allocator, codex_home, reg, auth_bytes, config_bytes)) |idx| {
        const profile = &reg.api_profiles.items[idx];
        _ = try updateApiProfileMetadata(allocator, profile, label, &summary);
        try setActiveApiProfileKey(allocator, reg, profile.profile_key);
        return try allocator.dupe(u8, profile.profile_key);
    }

    const profile_key = try generateApiProfileKey(allocator, label);
    errdefer allocator.free(profile_key);
    const auth_dest = try apiProfileAuthPath(allocator, codex_home, profile_key);
    defer allocator.free(auth_dest);
    const config_dest = try apiProfileConfigPath(allocator, codex_home, profile_key);
    defer allocator.free(config_dest);

    try writeFile(auth_dest, auth_bytes);
    try writeFile(config_dest, config_bytes);

    const profile = ApiProfileRecord{
        .profile_key = try allocator.dupe(u8, profile_key),
        .label = try allocator.dupe(u8, label),
        .model_provider = try cloneOptionalStringAlloc(allocator, summary.model_provider),
        .provider_name = try cloneOptionalStringAlloc(allocator, summary.provider_name),
        .model = try cloneOptionalStringAlloc(allocator, summary.model),
        .base_url = try cloneOptionalStringAlloc(allocator, summary.base_url),
        .wire_api = try cloneOptionalStringAlloc(allocator, summary.wire_api),
        .created_at = std.time.timestamp(),
        .last_used_at = std.time.timestamp(),
    };
    try reg.api_profiles.append(allocator, profile);
    try setActiveApiProfileKey(allocator, reg, profile_key);
    return profile_key;
}

pub fn activateAccountByKey(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    account_key: []const u8,
) !void {
    _ = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const previous_mode = reg.active_auth_mode;
    if (previous_mode == .chatgpt) {
        if (reg.active_account_key) |current_key| {
            if (!std.mem.eql(u8, current_key, account_key)) {
                _ = try syncActiveConfigSnapshotForAccount(allocator, codex_home, current_key);
            }
        }
    }
    const src = try resolveStrictAccountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);

    const dest = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try backupAuthIfChanged(allocator, codex_home, dest, src);
    try copyFile(src, dest);
    _ = try restoreAccountConfigSnapshotToActive(allocator, codex_home, account_key, previous_mode == .apikey);
    try setActiveAccountKey(allocator, reg, account_key);
    tryEnsureDualProviderHistory(allocator, codex_home);
}

pub fn activateApiProfileByKey(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    profile_key: []const u8,
) !void {
    _ = findApiProfileIndexByKey(reg, profile_key) orelse return error.ApiProfileNotFound;
    if (reg.active_auth_mode == .chatgpt) {
        if (reg.active_account_key) |current_key| {
            _ = try syncActiveConfigSnapshotForAccount(allocator, codex_home, current_key);
        }
    }

    const src_auth = try apiProfileAuthPath(allocator, codex_home, profile_key);
    defer allocator.free(src_auth);
    const src_config = try apiProfileConfigPath(allocator, codex_home, profile_key);
    defer allocator.free(src_config);
    const dest_auth = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest_auth);
    const dest_config = try activeConfigPath(allocator, codex_home);
    defer allocator.free(dest_config);

    try backupAuthIfChanged(allocator, codex_home, dest_auth, src_auth);
    try copyFile(src_auth, dest_auth);
    _ = try restoreActiveFileFromSnapshot(allocator, src_config, dest_config);
    try setActiveApiProfileKey(allocator, reg, profile_key);
    tryEnsureDualProviderHistory(allocator, codex_home);
}

pub fn replaceActiveAuthWithAccountByKey(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    account_key: []const u8,
) !void {
    _ = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const src = try resolveStrictAccountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);

    const dest = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try copyFile(src, dest);
    _ = try restoreAccountConfigSnapshotToActive(allocator, codex_home, account_key, true);
    try setActiveAccountKey(allocator, reg, account_key);
    tryEnsureDualProviderHistory(allocator, codex_home);
}

fn tryEnsureDualProviderHistory(allocator: std.mem.Allocator, codex_home: []const u8) void {
    if (shouldSkipHistorySync(allocator)) return;

    _ = history_sync.ensureDualProviderHistory(allocator, codex_home) catch |err| {
        std.log.warn("history sync skipped: {s}", .{@errorName(err)});
    };
}

fn shouldSkipHistorySync(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "CODEX_AUTH_SKIP_HISTORY_SYNC") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => {
            std.log.warn("history sync skip flag ignored: {s}", .{@errorName(err)});
            return false;
        },
    };
    defer allocator.free(value);

    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

pub fn accountFromAuth(
    allocator: std.mem.Allocator,
    alias: []const u8,
    info: *const @import("auth.zig").AuthInfo,
) !AccountRecord {
    const email = info.email orelse return error.MissingEmail;
    const chatgpt_account_id = info.chatgpt_account_id orelse return error.MissingAccountId;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const chatgpt_user_id = info.chatgpt_user_id orelse return error.MissingChatgptUserId;
    const owned_record_key = try allocator.dupe(u8, record_key);
    errdefer allocator.free(owned_record_key);
    const owned_chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id);
    errdefer allocator.free(owned_chatgpt_account_id);
    const owned_chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id);
    errdefer allocator.free(owned_chatgpt_user_id);
    const owned_email = try allocator.dupe(u8, email);
    errdefer allocator.free(owned_email);
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    return AccountRecord{
        .account_key = owned_record_key,
        .chatgpt_account_id = owned_chatgpt_account_id,
        .chatgpt_user_id = owned_chatgpt_user_id,
        .email = owned_email,
        .alias = owned_alias,
        .account_name = null,
        .plan = info.plan,
        .auth_mode = info.auth_mode,
        .created_at = std.time.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    };
}

fn recordFreshness(rec: *const AccountRecord) i64 {
    var best = rec.created_at;
    if (rec.last_used_at) |t| {
        if (t > best) best = t;
    }
    if (rec.last_usage_at) |t| {
        if (t > best) best = t;
    }
    return best;
}

fn mergeAccountRecord(allocator: std.mem.Allocator, dest: *AccountRecord, incoming: AccountRecord) void {
    var merged_incoming = incoming;
    if (recordFreshness(&merged_incoming) > recordFreshness(dest)) {
        if (merged_incoming.account_name == null and dest.account_name != null) {
            merged_incoming.account_name = cloneOptionalStringAlloc(allocator, dest.account_name) catch unreachable;
        }
        if (renewalInfoIsEmpty(merged_incoming.renewal) and !renewalInfoIsEmpty(dest.renewal)) {
            merged_incoming.renewal = cloneRenewalInfo(allocator, dest.renewal) catch unreachable;
        }
        freeAccountRecord(allocator, dest);
        dest.* = merged_incoming;
        return;
    }
    if (merged_incoming.alias.len != 0 and dest.alias.len == 0) {
        const replacement = allocator.dupe(u8, merged_incoming.alias) catch allocator.dupe(u8, "") catch unreachable;
        allocator.free(dest.alias);
        dest.alias = replacement;
    }
    if (dest.account_name == null and merged_incoming.account_name != null) {
        dest.account_name = cloneOptionalStringAlloc(allocator, merged_incoming.account_name) catch unreachable;
    }
    if (renewalInfoIsEmpty(dest.renewal) and !renewalInfoIsEmpty(merged_incoming.renewal)) {
        dest.renewal = cloneRenewalInfo(allocator, merged_incoming.renewal) catch unreachable;
    }
    if (dest.plan == null) dest.plan = merged_incoming.plan;
    if (dest.auth_mode == null) dest.auth_mode = merged_incoming.auth_mode;
    freeAccountRecord(allocator, &merged_incoming);
}

pub fn upsertAccount(allocator: std.mem.Allocator, reg: *Registry, record: AccountRecord) !void {
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, record.account_key)) {
            mergeAccountRecord(allocator, rec, record);
            return;
        }
    }
    try reg.accounts.append(allocator, record);
}

const LegacyAccountRecord = struct {
    email: []u8,
    alias: []u8,
    plan: ?PlanType,
    auth_mode: ?AuthMode,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?RateLimitSnapshot,
    last_usage_at: ?i64,
};

fn freeLegacyAccountRecord(allocator: std.mem.Allocator, rec: *LegacyAccountRecord) void {
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.last_usage) |*u| freeRateLimitSnapshot(allocator, u);
}

fn defaultRegistry() Registry {
    return Registry{
        .schema_version = current_schema_version,
        .active_account_key = null,
        .active_api_profile_key = null,
        .active_auth_mode = null,
        .active_account_activated_at_ms = null,
        .auto_switch = defaultAutoSwitchConfig(),
        .api = defaultApiConfig(),
        .accounts = std.ArrayList(AccountRecord).empty,
        .api_profiles = std.ArrayList(ApiProfileRecord).empty,
    };
}

fn parseLegacyAccountRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !LegacyAccountRecord {
    const email_val = obj.get("email") orelse return error.MissingEmail;
    const alias_val = obj.get("alias") orelse return error.MissingAlias;
    const email = switch (email_val) {
        .string => |s| s,
        else => return error.MissingEmail,
    };
    const alias = switch (alias_val) {
        .string => |s| s,
        else => return error.MissingAlias,
    };
    var rec = LegacyAccountRecord{
        .email = try normalizeEmailAlloc(allocator, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = null,
        .auth_mode = null,
        .created_at = readInt(obj.get("created_at")) orelse std.time.timestamp(),
        .last_used_at = readInt(obj.get("last_used_at")),
        .last_usage = null,
        .last_usage_at = readInt(obj.get("last_usage_at")),
    };
    errdefer freeLegacyAccountRecord(allocator, &rec);

    if (obj.get("plan")) |p| {
        switch (p) {
            .string => |s| rec.plan = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("auth_mode")) |m| {
        switch (m) {
            .string => |s| rec.auth_mode = parseAuthMode(s),
            else => {},
        }
    }
    if (obj.get("last_usage")) |u| {
        rec.last_usage = parseUsage(allocator, u);
    }
    return rec;
}

fn parseAccountRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !AccountRecord {
    const account_key_val = obj.get("account_key") orelse return error.MissingAccountKey;
    const email_val = obj.get("email") orelse return error.MissingEmail;
    const alias_val = obj.get("alias") orelse return error.MissingAlias;
    const account_key = switch (account_key_val) {
        .string => |s| s,
        else => return error.MissingAccountKey,
    };
    const email = switch (email_val) {
        .string => |s| s,
        else => return error.MissingEmail,
    };
    const alias = switch (alias_val) {
        .string => |s| s,
        else => return error.MissingAlias,
    };
    var rec = AccountRecord{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = switch (obj.get("chatgpt_account_id") orelse return error.MissingChatgptAccountId) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.MissingChatgptAccountId,
        },
        .chatgpt_user_id = switch (obj.get("chatgpt_user_id") orelse return error.MissingChatgptUserId) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.MissingChatgptUserId,
        },
        .email = try normalizeEmailAlloc(allocator, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = try parseOptionalStoredStringAlloc(allocator, obj.get("account_name")),
        .plan = null,
        .auth_mode = null,
        .created_at = readInt(obj.get("created_at")) orelse std.time.timestamp(),
        .last_used_at = readInt(obj.get("last_used_at")),
        .last_usage = null,
        .last_usage_at = readInt(obj.get("last_usage_at")),
        .last_local_rollout = null,
        .renewal = .{},
    };
    errdefer freeAccountRecord(allocator, &rec);

    if (obj.get("plan")) |p| {
        switch (p) {
            .string => |s| rec.plan = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("auth_mode")) |m| {
        switch (m) {
            .string => |s| rec.auth_mode = parseAuthMode(s),
            else => {},
        }
    }
    if (obj.get("last_usage")) |u| {
        rec.last_usage = parseUsage(allocator, u);
    }
    if (obj.get("last_local_rollout")) |v| {
        rec.last_local_rollout = parseRolloutSignature(allocator, v);
    }
    if (obj.get("renewal")) |v| {
        rec.renewal = parseRenewalInfo(allocator, v);
    }
    return rec;
}

fn parseApiProfileRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ApiProfileRecord {
    const profile_key_val = obj.get("profile_key") orelse return error.MissingApiProfileKey;
    const label_val = obj.get("label") orelse return error.MissingApiProfileLabel;
    const profile_key = switch (profile_key_val) {
        .string => |s| s,
        else => return error.MissingApiProfileKey,
    };
    const label = switch (label_val) {
        .string => |s| s,
        else => return error.MissingApiProfileLabel,
    };

    return .{
        .profile_key = try allocator.dupe(u8, profile_key),
        .label = try allocator.dupe(u8, label),
        .model_provider = try parseOptionalStoredStringAlloc(allocator, obj.get("model_provider")),
        .provider_name = try parseOptionalStoredStringAlloc(allocator, obj.get("provider_name")),
        .model = try parseOptionalStoredStringAlloc(allocator, obj.get("model")),
        .base_url = try parseOptionalStoredStringAlloc(allocator, obj.get("base_url")),
        .wire_api = try parseOptionalStoredStringAlloc(allocator, obj.get("wire_api")),
        .created_at = readInt(obj.get("created_at")) orelse std.time.timestamp(),
        .last_used_at = readInt(obj.get("last_used_at")),
    };
}

fn parseOptionalStoredStringAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const text = switch (value orelse return null) {
        .string => |s| s,
        .null => return null,
        else => return null,
    };
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
}

fn maybeCopyFile(src: []const u8, dest: []const u8) !void {
    if (std.mem.eql(u8, src, dest)) return;
    try copyFile(src, dest);
}

fn resolveLegacySnapshotPathForEmail(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
) ![]u8 {
    const legacy_path = try legacyAccountAuthPath(allocator, codex_home, email);
    legacy_check: {
        var file = std.fs.cwd().openFile(legacy_path, .{}) catch {
            allocator.free(legacy_path);
            break :legacy_check;
        };
        file.close();
        return legacy_path;
    }

    const accounts_dir = try backupDir(allocator, codex_home);
    defer allocator.free(accounts_dir);
    var dir = std.fs.cwd().openDir(accounts_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".auth.json")) continue;
        if (std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;

        const path = try std.fs.path.join(allocator, &[_][]const u8{ accounts_dir, entry.name });
        errdefer allocator.free(path);
        const info = @import("auth.zig").parseAuthInfo(allocator, path) catch {
            allocator.free(path);
            continue;
        };
        defer info.deinit(allocator);
        if (info.email != null and std.mem.eql(u8, info.email.?, email)) {
            return path;
        }
        allocator.free(path);
    }

    const active_path = try activeAuthPath(allocator, codex_home);
    errdefer allocator.free(active_path);
    const active_info = @import("auth.zig").parseAuthInfo(allocator, active_path) catch {
        allocator.free(active_path);
        return error.FileNotFound;
    };
    defer active_info.deinit(allocator);
    if (active_info.email != null and std.mem.eql(u8, active_info.email.?, email)) {
        return active_path;
    }

    allocator.free(active_path);
    return error.FileNotFound;
}

fn migrateLegacyRecord(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    legacy_active_email: ?[]const u8,
    legacy: *LegacyAccountRecord,
) !void {
    const legacy_path = try resolveLegacySnapshotPathForEmail(allocator, codex_home, legacy.email);
    defer allocator.free(legacy_path);

    const info = try @import("auth.zig").parseAuthInfo(allocator, legacy_path);
    defer info.deinit(allocator);
    const email = info.email orelse return error.MissingEmail;
    const chatgpt_account_id = info.chatgpt_account_id orelse return error.MissingAccountId;
    if (!std.mem.eql(u8, email, legacy.email)) return error.EmailMismatch;

    var rec = AccountRecord{
        .account_key = try allocator.dupe(u8, info.record_key orelse return error.MissingChatgptUserId),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, info.chatgpt_user_id orelse return error.MissingChatgptUserId),
        .email = try allocator.dupe(u8, legacy.email),
        .alias = try allocator.dupe(u8, legacy.alias),
        .account_name = null,
        .plan = info.plan orelse legacy.plan,
        .auth_mode = info.auth_mode,
        .created_at = legacy.created_at,
        .last_used_at = legacy.last_used_at,
        .last_usage = legacy.last_usage,
        .last_usage_at = legacy.last_usage_at,
        .last_local_rollout = null,
    };
    legacy.last_usage = null;
    var rec_owned = true;
    errdefer if (rec_owned) freeAccountRecord(allocator, &rec);

    const new_path = try accountAuthPath(allocator, codex_home, rec.account_key);
    defer allocator.free(new_path);
    try ensureAccountsDir(allocator, codex_home);
    if (!(try filesEqual(allocator, legacy_path, new_path))) {
        try maybeCopyFile(legacy_path, new_path);
    }

    const old_legacy_path = try legacyAccountAuthPath(allocator, codex_home, legacy.email);
    defer allocator.free(old_legacy_path);
    if (std.mem.eql(u8, legacy_path, old_legacy_path)) {
        std.fs.cwd().deleteFile(old_legacy_path) catch {};
    }

    const should_activate = if (legacy_active_email) |active_email|
        reg.active_account_key == null and std.mem.eql(u8, active_email, legacy.email)
    else
        false;
    const active_account_key = if (should_activate) try allocator.dupe(u8, rec.account_key) else null;
    errdefer if (active_account_key) |value| allocator.free(value);

    try upsertAccount(allocator, reg, rec);
    rec_owned = false;
    if (active_account_key) |value| {
        reg.active_account_key = value;
        reg.active_account_activated_at_ms = 0;
    }
}

fn loadLegacyRegistryV2(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    root_obj: std.json.ObjectMap,
) !Registry {
    var reg = defaultRegistry();
    errdefer reg.deinit(allocator);
    var legacy_active_email: ?[]u8 = null;
    var legacy_accounts = std.ArrayList(LegacyAccountRecord).empty;
    defer {
        for (legacy_accounts.items) |*rec| freeLegacyAccountRecord(allocator, rec);
        legacy_accounts.deinit(allocator);
        if (legacy_active_email) |value| allocator.free(value);
    }

    if (root_obj.get("active_account_key")) |v| {
        switch (v) {
            .string => |s| reg.active_account_key = try allocator.dupe(u8, s),
            else => {},
        }
    }
    if (reg.active_account_key != null) {
        reg.active_account_activated_at_ms = 0;
    }
    if (root_obj.get("active_email")) |v| {
        switch (v) {
            .string => |s| legacy_active_email = try normalizeEmailAlloc(allocator, s),
            else => {},
        }
    }
    if (root_obj.get("accounts")) |v| {
        switch (v) {
            .array => |arr| {
                for (arr.items) |item| {
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (obj.get("account_key") != null) {
                        const rec = try parseAccountRecord(allocator, obj);
                        try upsertAccount(allocator, &reg, rec);
                    } else {
                        try legacy_accounts.append(allocator, try parseLegacyAccountRecord(allocator, obj));
                    }
                }
            },
            else => {},
        }
    }

    if (root_obj.get("auto_switch")) |v| {
        parseAutoSwitch(allocator, &reg.auto_switch, v);
    }
    if (root_obj.get("api")) |v| {
        parseApiConfig(&reg.api, v);
    }

    for (legacy_accounts.items) |*legacy| {
        try migrateLegacyRecord(allocator, codex_home, &reg, legacy_active_email, legacy);
    }

    if (reg.active_account_key != null) {
        reg.active_auth_mode = .chatgpt;
    }

    return reg;
}

fn loadCurrentRegistry(allocator: std.mem.Allocator, root_obj: std.json.ObjectMap) !Registry {
    if (root_obj.get("active_email") != null) return error.UnsupportedRegistryLayout;

    var reg = defaultRegistry();
    errdefer reg.deinit(allocator);

    if (root_obj.get("active_account_key")) |v| {
        switch (v) {
            .string => |s| reg.active_account_key = try allocator.dupe(u8, s),
            else => {},
        }
    }
    if (root_obj.get("active_api_profile_key")) |v| {
        switch (v) {
            .string => |s| reg.active_api_profile_key = try allocator.dupe(u8, s),
            else => {},
        }
    }
    if (root_obj.get("active_auth_mode")) |v| {
        switch (v) {
            .string => |s| reg.active_auth_mode = parseAuthMode(s),
            else => {},
        }
    }
    if (root_obj.get("active_account_activated_at_ms")) |v| {
        reg.active_account_activated_at_ms = readInt(v);
    } else if (reg.active_account_key != null or reg.active_api_profile_key != null) {
        reg.active_account_activated_at_ms = 0;
    }
    if (root_obj.get("accounts")) |v| {
        switch (v) {
            .array => |arr| {
                for (arr.items) |item| {
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const rec = try parseAccountRecord(allocator, obj);
                    try upsertAccount(allocator, &reg, rec);
                }
            },
            else => {},
        }
    }
    if (root_obj.get("api_profiles")) |v| {
        switch (v) {
            .array => |arr| {
                for (arr.items) |item| {
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    try reg.api_profiles.append(allocator, try parseApiProfileRecord(allocator, obj));
                }
            },
            else => {},
        }
    }

    if (root_obj.get("auto_switch")) |v| {
        parseAutoSwitch(allocator, &reg.auto_switch, v);
    }
    if (root_obj.get("api")) |v| {
        parseApiConfig(&reg.api, v);
    }

    if (reg.active_auth_mode == null) {
        if (reg.active_api_profile_key != null) {
            reg.active_auth_mode = .apikey;
        } else if (reg.active_account_key != null) {
            reg.active_auth_mode = .chatgpt;
        }
    }

    return reg;
}

fn schemaVersionFieldValue(root_obj: std.json.ObjectMap) ?u32 {
    if (root_obj.get("schema_version") != null) {
        if (std.math.cast(u32, readInt(root_obj.get("schema_version")) orelse return null)) |value| return value;
        return null;
    }
    if (root_obj.get("version") != null) {
        if (std.math.cast(u32, readInt(root_obj.get("version")) orelse return null)) |value| return value;
        return null;
    }
    return null;
}

fn usesLegacyVersionField(root_obj: std.json.ObjectMap) bool {
    return root_obj.get("schema_version") == null and root_obj.get("version") != null;
}

fn currentLayoutNeedsRewrite(root_obj: std.json.ObjectMap) bool {
    if (root_obj.get("last_attributed_rollout") != null) return true;
    if (root_obj.get("api")) |v| {
        if (apiConfigNeedsRewrite(v)) return true;
    } else {
        return true;
    }
    if (root_obj.get("accounts")) |value| {
        switch (value) {
            .array => |accounts| {
                for (accounts.items) |item| {
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (obj.get("renewal") == null) return true;
                }
            },
            else => {},
        }
    }
    if (root_obj.get("api_profiles") == null) return true;
    if (root_obj.get("active_auth_mode") == null and
        (root_obj.get("active_account_key") != null or root_obj.get("active_api_profile_key") != null))
    {
        return true;
    }
    return (root_obj.get("active_account_key") != null or root_obj.get("active_api_profile_key") != null) and
        root_obj.get("active_account_activated_at_ms") == null;
}

fn detectSchemaVersion(root_obj: std.json.ObjectMap) u32 {
    return schemaVersionFieldValue(root_obj) orelse if (root_obj.get("active_email") != null) 2 else current_schema_version;
}

fn logUnsupportedRegistryVersion(version_value: u32) void {
    if (builtin.is_test) return;
    std.log.err(
        "registry schema_version {d} is newer than this codex-auth binary supports (max {d}); upgrade codex-auth",
        .{ version_value, current_schema_version },
    );
}

pub fn loadRegistry(allocator: std.mem.Allocator, codex_home: []const u8) !Registry {
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const cwd = std.fs.cwd();
    const data = blk: {
        var file = cwd.openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return defaultRegistry();
            }
            return err;
        };
        defer file.close();

        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = switch (root) {
        .object => |o| o,
        else => return defaultRegistry(),
    };

    const schema_version = detectSchemaVersion(root_obj);
    if (schema_version > current_schema_version) {
        logUnsupportedRegistryVersion(schema_version);
        return error.UnsupportedRegistryVersion;
    }

    const needs_rewrite = schema_version < current_schema_version or
        usesLegacyVersionField(root_obj) or
        (schema_version == current_schema_version and currentLayoutNeedsRewrite(root_obj));
    var reg = switch (schema_version) {
        2 => try loadLegacyRegistryV2(allocator, codex_home, root_obj),
        3 => try loadCurrentRegistry(allocator, root_obj),
        4 => try loadCurrentRegistry(allocator, root_obj),
        5 => try loadCurrentRegistry(allocator, root_obj),
        else => {
            std.log.err(
                "registry schema_version {d} is older than the minimum supported {d}; use an intermediate codex-auth release or import --purge",
                .{ schema_version, min_supported_schema_version },
            );
            return error.UnsupportedRegistryVersion;
        },
    };
    errdefer reg.deinit(allocator);

    if (schema_version < current_schema_version) {
        reg.api = defaultApiConfig();
        for (reg.accounts.items) |*rec| {
            normalizeRenewalInfo(&rec.renewal);
        }
        if (reg.active_api_profile_key) |key| allocator.free(key);
        reg.active_api_profile_key = null;
        reg.active_auth_mode = if (reg.active_account_key != null) .chatgpt else null;
        for (reg.api_profiles.items) |*profile| {
            freeApiProfileRecord(allocator, profile);
        }
        reg.api_profiles.deinit(allocator);
        reg.api_profiles = std.ArrayList(ApiProfileRecord).empty;
    }

    if (needs_rewrite) {
        try saveRegistry(allocator, codex_home, &reg);
    }

    return reg;
}

fn writeRegistryFileReplace(path: []const u8, data: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.time.nanoTimestamp() });
    defer allocator.free(temp_path);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ path, std.time.nanoTimestamp() });
    defer allocator.free(backup_path);

    {
        var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        try file.sync();
    }

    const had_original = blk: {
        std.fs.cwd().rename(path, backup_path) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    errdefer {
        std.fs.cwd().deleteFile(temp_path) catch {};
        if (had_original) {
            std.fs.cwd().rename(backup_path, path) catch {};
        }
    }
    try std.fs.cwd().rename(temp_path, path);
    if (had_original) {
        std.fs.cwd().deleteFile(backup_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn writeRegistryFileAtomic(path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return writeRegistryFileReplace(path, data);
    }
    var buf: [4096]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer atomic_file.deinit();
    try atomic_file.file_writer.interface.writeAll(data);
    try atomic_file.finish();
}

pub fn saveRegistry(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    reg.schema_version = current_schema_version;
    try ensureAccountsDir(allocator, codex_home);
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const out = RegistryOut{
        .schema_version = current_schema_version,
        .active_account_key = reg.active_account_key,
        .active_api_profile_key = reg.active_api_profile_key,
        .active_auth_mode = reg.active_auth_mode,
        .active_account_activated_at_ms = reg.active_account_activated_at_ms,
        .auto_switch = reg.auto_switch,
        .api = reg.api,
        .accounts = reg.accounts.items,
        .api_profiles = reg.api_profiles.items,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, writer);
    const data = aw.written();

    if (try fileEqualsBytes(allocator, path, data)) {
        return;
    }

    try backupRegistryIfChanged(allocator, codex_home, path, data);
    try writeRegistryFileAtomic(path, data);
}

const RegistryOut = struct {
    schema_version: u32,
    active_account_key: ?[]const u8,
    active_api_profile_key: ?[]const u8,
    active_auth_mode: ?AuthMode,
    active_account_activated_at_ms: ?i64,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    accounts: []const AccountRecord,
    api_profiles: []const ApiProfileRecord,
};

const RenewalDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn parsePlanType(s: []const u8) ?PlanType {
    if (std.mem.eql(u8, s, "free")) return .free;
    if (std.mem.eql(u8, s, "plus")) return .plus;
    if (std.mem.eql(u8, s, "prolite")) return .prolite;
    if (std.mem.eql(u8, s, "pro")) return .pro;
    if (std.mem.eql(u8, s, "team")) return .team;
    if (std.mem.eql(u8, s, "business")) return .business;
    if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
    if (std.mem.eql(u8, s, "edu")) return .edu;
    return .unknown;
}

fn parseAuthMode(s: []const u8) ?AuthMode {
    if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, s, "apikey")) return .apikey;
    return null;
}

fn parseRenewalSource(s: []const u8) ?RenewalSource {
    if (std.mem.eql(u8, s, "manual")) return .manual;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    return null;
}

fn parseRenewalStatus(s: []const u8) ?RenewalStatus {
    if (std.mem.eql(u8, s, "ok")) return .ok;
    if (std.mem.eql(u8, s, "missing")) return .missing;
    if (std.mem.eql(u8, s, "unsupported")) return .unsupported;
    if (std.mem.eql(u8, s, "fetch_failed")) return .fetch_failed;
    return null;
}

fn parseUsage(allocator: std.mem.Allocator, v: std.json.Value) ?RateLimitSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var snap = RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };

    if (obj.get("plan_type")) |p| {
        switch (p) {
            .string => |s| snap.plan_type = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |c| snap.credits = parseCredits(allocator, c);
    return snap;
}

fn parseRenewalInfo(allocator: std.mem.Allocator, v: std.json.Value) RenewalInfo {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{},
    };

    var renewal: RenewalInfo = .{};
    if (obj.get("next_renewal_at")) |value| {
        renewal.next_renewal_at = parseOptionalStoredStringAlloc(allocator, value) catch null;
        if (renewal.next_renewal_at) |date| {
            if (parseRenewalDate(date) == null) {
                allocator.free(date);
                renewal.next_renewal_at = null;
            }
        }
    }
    if (obj.get("source")) |value| {
        switch (value) {
            .string => |text| renewal.source = parseRenewalSource(text),
            else => {},
        }
    }
    if (obj.get("updated_at")) |value| {
        renewal.updated_at = readInt(value);
    }
    if (obj.get("status")) |value| {
        switch (value) {
            .string => |text| {
                if (parseRenewalStatus(text)) |status| {
                    renewal.status = status;
                }
            },
            else => {},
        }
    }
    normalizeRenewalInfo(&renewal);
    return renewal;
}

fn parseAutoSwitch(allocator: std.mem.Allocator, cfg: *AutoSwitchConfig, v: std.json.Value) void {
    _ = allocator;
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("enabled")) |enabled| {
        switch (enabled) {
            .bool => |flag| cfg.enabled = flag,
            else => {},
        }
    }
    if (obj.get("threshold_5h_percent")) |threshold| {
        if (parseThresholdPercent(threshold)) |value| {
            cfg.threshold_5h_percent = value;
        }
    }
    if (obj.get("threshold_weekly_percent")) |threshold| {
        if (parseThresholdPercent(threshold)) |value| {
            cfg.threshold_weekly_percent = value;
        }
    }
}

fn parseApiConfig(cfg: *ApiConfig, v: std.json.Value) void {
    _ = parseApiConfigDetailed(cfg, v);
}

fn apiConfigNeedsRewrite(v: std.json.Value) bool {
    var cfg = defaultApiConfig();
    const result = parseApiConfigDetailed(&cfg, v);
    return !result.has_object or !result.has_usage or !result.has_account or !result.has_renewal;
}

fn parseApiConfigDetailed(cfg: *ApiConfig, v: std.json.Value) ApiConfigParseResult {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{},
    };
    var result = ApiConfigParseResult{ .has_object = true };
    if (obj.get("usage")) |usage| {
        switch (usage) {
            .bool => |flag| {
                cfg.usage = flag;
                result.has_usage = true;
            },
            else => {},
        }
    }
    if (obj.get("account")) |account| {
        switch (account) {
            .bool => |flag| {
                cfg.account = flag;
                result.has_account = true;
            },
            else => {},
        }
    }
    if (obj.get("renewal")) |renewal| {
        switch (renewal) {
            .bool => |flag| {
                cfg.renewal = flag;
                result.has_renewal = true;
            },
            else => {},
        }
    }
    if (result.has_usage and !result.has_account) {
        cfg.account = cfg.usage;
    } else if (result.has_account and !result.has_usage) {
        cfg.usage = cfg.account;
    }
    return result;
}

fn normalizeRenewalInfo(renewal: *RenewalInfo) void {
    if (renewal.next_renewal_at == null) {
        if (renewal.status == .ok) renewal.status = .missing;
        if (renewal.status == .missing) {
            renewal.source = null;
        }
    } else if (renewal.source == null and renewal.status == .ok) {
        renewal.source = .manual;
    }
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    return @mod(year, 4) == 0;
}

fn daysInMonth(year: i32, month: u8) ?u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => null,
    };
}

fn parseRenewalDate(text: []const u8) ?RenewalDate {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const max_day = daysInMonth(year, month) orelse return null;
    if (day < 1 or day > max_day) return null;
    return .{ .year = year, .month = month, .day = day };
}

pub fn renewalDateStringIsValid(text: []const u8) bool {
    return parseRenewalDate(text) != null;
}

fn renewalDateLessThan(lhs: RenewalDate, rhs: RenewalDate) bool {
    if (lhs.year != rhs.year) return lhs.year < rhs.year;
    if (lhs.month != rhs.month) return lhs.month < rhs.month;
    return lhs.day < rhs.day;
}

fn formatRenewalDateAlloc(allocator: std.mem.Allocator, date: RenewalDate) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date.year,
        date.month,
        date.day,
    });
}

fn todayLocalRenewalDate() ?RenewalDate {
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(std.time.timestamp(), &tm)) return null;
    return .{
        .year = @intCast(tm.tm_year + 1900),
        .month = @intCast(tm.tm_mon + 1),
        .day = @intCast(tm.tm_mday),
    };
}

fn advanceRenewalDateByMonth(date: RenewalDate) RenewalDate {
    var year = date.year;
    var month = date.month + 1;
    if (month > 12) {
        month = 1;
        year += 1;
    }
    const max_day = daysInMonth(year, month) orelse date.day;
    return .{
        .year = year,
        .month = month,
        .day = @min(date.day, max_day),
    };
}

pub fn nextMonthlyRenewalDateAlloc(
    allocator: std.mem.Allocator,
    current_date_text: []const u8,
) !?[]u8 {
    var date = parseRenewalDate(current_date_text) orelse return null;
    const today = todayLocalRenewalDate() orelse return null;
    while (renewalDateLessThan(date, today)) {
        date = advanceRenewalDateByMonth(date);
    }
    return try formatRenewalDateAlloc(allocator, date);
}

pub fn renewalPlanSupportsAutomaticRefresh(plan: ?PlanType) bool {
    return switch (plan orelse return false) {
        .plus, .prolite, .pro => true,
        else => false,
    };
}

pub fn renewalPlanIsUnsupported(plan: ?PlanType) bool {
    return switch (plan orelse return false) {
        .free, .team, .business, .enterprise, .edu => true,
        else => false,
    };
}

fn parseRolloutSignature(allocator: std.mem.Allocator, v: std.json.Value) ?RolloutSignature {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const path = switch (obj.get("path") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const event_timestamp_ms = readInt(obj.get("event_timestamp_ms")) orelse return null;
    return .{
        .path = allocator.dupe(u8, path) catch return null,
        .event_timestamp_ms = event_timestamp_ms,
    };
}

fn parseWindow(v: std.json.Value) ?RateLimitWindow {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const used = obj.get("used_percent") orelse return null;
    const used_percent = switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => 0.0,
    };
    const window_minutes = if (obj.get("window_minutes")) |wm| switch (wm) {
        .integer => |i| i,
        else => null,
    } else null;
    const resets_at = if (obj.get("resets_at")) |ra| switch (ra) {
        .integer => |i| i,
        else => null,
    } else null;
    return RateLimitWindow{ .used_percent = used_percent, .window_minutes = window_minutes, .resets_at = resets_at };
}

fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) ?CreditsSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const has_credits = if (obj.get("has_credits")) |hc| switch (hc) {
        .bool => |b| b,
        else => false,
    } else false;
    const unlimited = if (obj.get("unlimited")) |u| switch (u) {
        .bool => |b| b,
        else => false,
    } else false;
    var balance: ?[]u8 = null;
    if (obj.get("balance")) |b| {
        switch (b) {
            .string => |s| balance = allocator.dupe(u8, s) catch null,
            else => {},
        }
    }
    return CreditsSnapshot{ .has_credits = has_credits, .unlimited = unlimited, .balance = balance };
}

fn readInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    switch (v.?) {
        .integer => |i| return i,
        else => return null,
    }
}

fn parseThresholdPercent(v: std.json.Value) ?u8 {
    const raw = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (raw < 1 or raw > 100) return null;
    return @as(u8, @intCast(raw));
}

pub fn autoImportActiveAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !bool {
    if (reg.accounts.items.len != 0) return false;

    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    var file = std.fs.cwd().openFile(auth_path, .{}) catch return false;
    file.close();

    const info = try @import("auth.zig").parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    if (info.auth_mode == .apikey) {
        return false;
    }
    _ = info.email orelse {
        std.log.warn("auth.json missing email; cannot import", .{});
        return false;
    };
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_path, dest);

    const record = try accountFromAuth(allocator, "", &info);
    try upsertAccount(allocator, reg, record);
    _ = try syncActiveConfigSnapshotForAccount(allocator, codex_home, record_key);
    try setActiveAccountKey(allocator, reg, record_key);
    return true;
}
