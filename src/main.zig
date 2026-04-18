const std = @import("std");
const builtin = @import("builtin");
const account_api = @import("account_api.zig");
const account_name_refresh = @import("account_name_refresh.zig");
const cli = @import("cli.zig");
const display_rows = @import("display_rows.zig");
const history_sync = @import("history_sync.zig");
const registry = @import("registry.zig");
const auth = @import("auth.zig");
const auto = @import("auto.zig");
const format = @import("format.zig");
const io_util = @import("io_util.zig");
const usage_api = @import("usage_api.zig");

const skip_service_reconcile_env = "CODEX_AUTH_SKIP_SERVICE_RECONCILE";
const account_name_refresh_only_env = "CODEX_AUTH_REFRESH_ACCOUNT_NAMES_ONLY";
const disable_background_account_name_refresh_env = "CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH";
const foreground_usage_refresh_concurrency: usize = 3;
const use_process_init_main = builtin.zig_version.major > 0 or
    (builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16);

const AccountFetchFn = *const fn (
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) anyerror!account_api.FetchResult;
const UsageFetchDetailedFn = *const fn (
    allocator: std.mem.Allocator,
    auth_path: []const u8,
) anyerror!usage_api.UsageFetchResult;
const ForegroundUsagePoolInitFn = *const fn (
    pool: *std.Thread.Pool,
    allocator: std.mem.Allocator,
    n_jobs: usize,
) anyerror!void;
const BackgroundRefreshLockAcquirer = *const fn (
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) anyerror!?account_name_refresh.BackgroundRefreshLock;

const ForegroundUsageWorkerResult = struct {
    status_code: ?u16 = null,
    missing_auth: bool = false,
    error_name: ?[]const u8 = null,
    snapshot: ?registry.RateLimitSnapshot = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| {
            registry.freeRateLimitSnapshot(allocator, snapshot);
            self.snapshot = null;
        }
    }
};

pub const ForegroundUsageOutcome = struct {
    attempted: bool = false,
    status_code: ?u16 = null,
    missing_auth: bool = false,
    error_name: ?[]const u8 = null,
    has_usage_windows: bool = false,
    updated: bool = false,
    unchanged: bool = false,
};

pub const ForegroundUsageRefreshState = struct {
    usage_overrides: []?[]const u8,
    outcomes: []ForegroundUsageOutcome,
    attempted: usize = 0,
    updated: usize = 0,
    failed: usize = 0,
    unchanged: usize = 0,
    local_only_mode: bool = false,

    pub fn deinit(self: *ForegroundUsageRefreshState, allocator: std.mem.Allocator) void {
        for (self.usage_overrides) |override| {
            if (override) |value| allocator.free(value);
        }
        allocator.free(self.usage_overrides);
        allocator.free(self.outcomes);
        self.* = undefined;
    }
};

pub const JsonRefreshSummary = struct {
    usage_requested: bool = false,
    attempted: usize = 0,
    updated: usize = 0,
    failed: usize = 0,
    unchanged: usize = 0,
    local_only_mode: bool = false,
};

fn jsonString(out: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, out);
}

fn writeOptionalJsonString(out: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try jsonString(out, text);
    } else {
        try out.writeAll("null");
    }
}

fn writeOptionalI64(out: *std.Io.Writer, value: ?i64) !void {
    if (value) |number| {
        try out.print("{d}", .{number});
    } else {
        try out.writeAll("null");
    }
}

fn writeOptionalBool(out: *std.Io.Writer, value: bool) !void {
    try out.writeAll(if (value) "true" else "false");
}

fn planJsonLabel(plan: ?registry.PlanType) ?[]const u8 {
    return if (plan) |value| registry.planLabel(value) else null;
}

fn authModeJsonLabel(mode: ?registry.AuthMode) ?[]const u8 {
    return switch (mode orelse return null) {
        .chatgpt => "chatgpt",
        .apikey => "apikey",
    };
}

fn accountLabelForDisplay(
    display: *const display_rows.DisplayRows,
    account_idx: usize,
    fallback: []const u8,
) []const u8 {
    for (display.rows) |row| {
        if (row.account_index) |idx| {
            if (idx == account_idx) return row.account_cell;
        }
    }
    return fallback;
}

fn writeWindowJson(out: *std.Io.Writer, window: ?registry.RateLimitWindow, now: i64) !void {
    if (window == null) {
        try out.writeAll("null");
        return;
    }
    const value = window.?;
    try out.writeAll("{");
    try out.writeAll("\"used_percent\":");
    try out.print("{d}", .{value.used_percent});
    try out.writeAll(",\"remaining_percent\":");
    if (registry.remainingPercentAt(value, now)) |remaining| {
        try out.print("{d}", .{remaining});
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"window_minutes\":");
    try writeOptionalI64(out, value.window_minutes);
    try out.writeAll(",\"resets_at\":");
    try writeOptionalI64(out, value.resets_at);
    try out.writeAll("}");
}

fn writeCreditsJson(out: *std.Io.Writer, credits: ?registry.CreditsSnapshot) !void {
    if (credits == null) {
        try out.writeAll("null");
        return;
    }
    const value = credits.?;
    try out.writeAll("{\"has_credits\":");
    try writeOptionalBool(out, value.has_credits);
    try out.writeAll(",\"unlimited\":");
    try writeOptionalBool(out, value.unlimited);
    try out.writeAll(",\"balance\":");
    try writeOptionalJsonString(out, value.balance);
    try out.writeAll("}");
}

fn writeUsageJson(
    out: *std.Io.Writer,
    snapshot: ?registry.RateLimitSnapshot,
    usage_override: ?[]const u8,
    now: i64,
) !void {
    if (snapshot == null and usage_override == null) {
        try out.writeAll("null");
        return;
    }

    try out.writeAll("{\"status\":");
    try jsonString(out, usage_override orelse "ok");
    const rate_5h = registry.resolveRateWindow(snapshot, 300, true);
    const rate_week = registry.resolveRateWindow(snapshot, 10080, false);
    try out.writeAll(",\"five_hour\":");
    try writeWindowJson(out, rate_5h, now);
    try out.writeAll(",\"weekly\":");
    try writeWindowJson(out, rate_week, now);
    try out.writeAll(",\"credits\":");
    try writeCreditsJson(out, if (snapshot) |value| value.credits else null);
    try out.writeAll("}");
}

fn renewalSourceJsonLabel(source: ?registry.RenewalSource) ?[]const u8 {
    return switch (source orelse return null) {
        .manual => "manual",
        .auto => "auto",
    };
}

fn renewalStatusJsonLabel(status: registry.RenewalStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .missing => "missing",
        .unsupported => "unsupported",
        .fetch_failed => "fetch_failed",
    };
}

fn writeRenewalJson(out: *std.Io.Writer, renewal: registry.RenewalInfo) !void {
    try out.writeAll("{\"next_renewal_at\":");
    try writeOptionalJsonString(out, renewal.next_renewal_at);
    try out.writeAll(",\"source\":");
    try writeOptionalJsonString(out, renewalSourceJsonLabel(renewal.source));
    try out.writeAll(",\"updated_at\":");
    try writeOptionalI64(out, renewal.updated_at);
    try out.writeAll(",\"status\":");
    try jsonString(out, renewalStatusJsonLabel(renewal.status));
    try out.writeAll("}");
}

fn writeApiProfileJson(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    profile: registry.ApiProfileRecord,
) !void {
    const active = if (reg.active_api_profile_key) |key|
        std.mem.eql(u8, key, profile.profile_key)
    else
        false;
    try out.writeAll("{\"profile_key\":");
    try jsonString(out, profile.profile_key);
    try out.writeAll(",\"label\":");
    try jsonString(out, profile.label);
    try out.writeAll(",\"model_provider\":");
    try writeOptionalJsonString(out, profile.model_provider);
    try out.writeAll(",\"provider_name\":");
    try writeOptionalJsonString(out, profile.provider_name);
    try out.writeAll(",\"model\":");
    try writeOptionalJsonString(out, profile.model);
    try out.writeAll(",\"base_url\":");
    try writeOptionalJsonString(out, profile.base_url);
    try out.writeAll(",\"wire_api\":");
    try writeOptionalJsonString(out, profile.wire_api);
    try out.writeAll(",\"active\":");
    try writeOptionalBool(out, active);
    try out.writeAll(",\"created_at\":");
    try out.print("{d}", .{profile.created_at});
    try out.writeAll(",\"last_used_at\":");
    try writeOptionalI64(out, profile.last_used_at);
    try out.writeAll("}");
}

fn usageOverrideForAccount(
    usage_overrides: ?[]const ?[]const u8,
    account_idx: usize,
) ?[]const u8 {
    const overrides = usage_overrides orelse return null;
    if (account_idx >= overrides.len) return null;
    return overrides[account_idx];
}

pub fn writeAccountsJson(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    refresh: JsonRefreshSummary,
) !void {
    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    const now = std.time.timestamp();

    try out.writeAll("{\"schema_version\":");
    try out.print("{d}", .{reg.schema_version});
    try out.writeAll(",\"codex_home\":");
    try jsonString(out, codex_home);
    try out.writeAll(",\"active_account_key\":");
    try writeOptionalJsonString(out, reg.active_account_key);
    try out.writeAll(",\"active_api_profile_key\":");
    try writeOptionalJsonString(out, reg.active_api_profile_key);
    try out.writeAll(",\"active_auth_mode\":");
    try writeOptionalJsonString(out, authModeJsonLabel(reg.active_auth_mode));
    try out.writeAll(",\"api\":{\"usage\":");
    try writeOptionalBool(out, reg.api.usage);
    try out.writeAll(",\"account\":");
    try writeOptionalBool(out, reg.api.account);
    try out.writeAll(",\"renewal\":");
    try writeOptionalBool(out, reg.api.renewal);
    try out.writeAll("},\"accounts\":[");
    for (reg.accounts.items, 0..) |rec, idx| {
        if (idx != 0) try out.writeAll(",");
        const active = if (reg.active_account_key) |key|
            std.mem.eql(u8, key, rec.account_key)
        else
            false;
        const label = accountLabelForDisplay(&display, idx, rec.email);
        try out.writeAll("{\"account_key\":");
        try jsonString(out, rec.account_key);
        try out.writeAll(",\"label\":");
        try jsonString(out, label);
        try out.writeAll(",\"email\":");
        try jsonString(out, rec.email);
        try out.writeAll(",\"alias\":");
        try jsonString(out, rec.alias);
        try out.writeAll(",\"account_name\":");
        try writeOptionalJsonString(out, rec.account_name);
        try out.writeAll(",\"plan\":");
        try writeOptionalJsonString(out, planJsonLabel(registry.resolvePlan(&rec)));
        try out.writeAll(",\"auth_mode\":");
        try writeOptionalJsonString(out, authModeJsonLabel(rec.auth_mode));
        try out.writeAll(",\"active\":");
        try writeOptionalBool(out, active);
        try out.writeAll(",\"last_used_at\":");
        try writeOptionalI64(out, rec.last_used_at);
        try out.writeAll(",\"last_usage_at\":");
        try writeOptionalI64(out, rec.last_usage_at);
        try out.writeAll(",\"usage\":");
        try writeUsageJson(out, rec.last_usage, usageOverrideForAccount(usage_overrides, idx), now);
        try out.writeAll(",\"renewal\":");
        try writeRenewalJson(out, rec.renewal);
        try out.writeAll("}");
    }
    try out.writeAll("],\"api_profiles\":[");
    for (reg.api_profiles.items, 0..) |profile, idx| {
        if (idx != 0) try out.writeAll(",");
        try writeApiProfileJson(out, reg, profile);
    }
    try out.writeAll("],\"refresh\":{\"usage_requested\":");
    try writeOptionalBool(out, refresh.usage_requested);
    try out.writeAll(",\"attempted\":");
    try out.print("{d}", .{refresh.attempted});
    try out.writeAll(",\"updated\":");
    try out.print("{d}", .{refresh.updated});
    try out.writeAll(",\"failed\":");
    try out.print("{d}", .{refresh.failed});
    try out.writeAll(",\"unchanged\":");
    try out.print("{d}", .{refresh.unchanged});
    try out.writeAll(",\"local_only_mode\":");
    try writeOptionalBool(out, refresh.local_only_mode);
    try out.writeAll("}}\n");
}

fn printAccountsJson(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    refresh: JsonRefreshSummary,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeAccountsJson(allocator, out, codex_home, reg, usage_overrides, refresh);
    try out.flush();
}

const DebugUsageLabelState = struct {
    labels: [][]const u8,
    display_order: []usize,

    fn deinit(self: *DebugUsageLabelState, allocator: std.mem.Allocator) void {
        for (self.labels) |label| allocator.free(@constCast(label));
        allocator.free(self.labels);
        allocator.free(self.display_order);
        self.* = undefined;
    }
};

pub const main = if (use_process_init_main) mainWithProcessInit else mainLegacy;

fn mainLegacy() !void {
    var exit_code: u8 = 0;

    {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        exit_code = try cliExitCode(runMainArgs(allocator, args));
    }

    if (exit_code != 0) std.process.exit(exit_code);
}

fn mainWithProcessInit(init: std.process.Init) !void {
    io_util.setRuntimeIo(init.io);
    io_util.setRuntimeEnvironMap(init.environ_map);
    var exit_code: u8 = 0;

    {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const args = try init.minimal.args.toSlice(arena.allocator());

        exit_code = try cliExitCode(runMainArgs(allocator, args));
    }

    if (exit_code != 0) std.process.exit(exit_code);
}

fn cliExitCode(result: anyerror!void) !u8 {
    result catch |err| {
        if (err == error.InvalidCliUsage) return 2;
        if (isHandledCliError(err)) return 1;
        return err;
    };
    return 0;
}

fn runMainArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var parsed = try cli.parseArgs(allocator, args);
    defer cli.freeParseResult(allocator, &parsed);

    const cmd = switch (parsed) {
        .command => |command| command,
        .usage_error => |usage_err| {
            try cli.printUsageError(&usage_err);
            return error.InvalidCliUsage;
        },
    };

    const needs_codex_home = switch (cmd) {
        .version => false,
        .help => |topic| topic == .top_level,
        else => true,
    };
    const codex_home = if (needs_codex_home) try registry.resolveCodexHome(allocator) else null;
    defer if (codex_home) |path| allocator.free(path);

    switch (cmd) {
        .version => try cli.printVersion(),
        .help => |topic| switch (topic) {
            .top_level => try handleTopLevelHelp(allocator, codex_home.?),
            else => try cli.printCommandHelp(topic),
        },
        .status => try auto.printStatus(allocator, codex_home.?),
        .daemon => |opts| switch (opts.mode) {
            .watch => try auto.runDaemon(allocator, codex_home.?),
            .once => try auto.runDaemonOnce(allocator, codex_home.?),
        },
        .sync_history => try handleSyncHistory(allocator, codex_home.?),
        .config => |opts| try handleConfig(allocator, codex_home.?, opts),
        .list => |opts| try handleList(allocator, codex_home.?, opts),
        .login => |opts| try handleLogin(allocator, codex_home.?, opts),
        .import_auth => |opts| try handleImport(allocator, codex_home.?, opts),
        .switch_account => |opts| try handleSwitch(allocator, codex_home.?, opts),
        .api_profile => |opts| try handleApiProfile(allocator, codex_home.?, opts),
        .renewal => |opts| try handleRenewal(allocator, codex_home.?, opts),
        .remove_account => |opts| try handleRemove(allocator, codex_home.?, opts),
        .clean => try handleClean(allocator, codex_home.?),
    }

    if (shouldReconcileManagedService(cmd)) {
        try auto.reconcileManagedService(allocator, codex_home.?);
    }
}

fn isHandledCliError(err: anyerror) bool {
    return err == error.AccountNotFound or
        err == error.ApiProfileNotFound or
        err == error.ApiKeyModeRequired or
        err == error.AuthFileNotFound or
        err == error.ConfigFileNotFound or
        err == error.CcSwitchDbNotFound or
        err == error.CcSwitchProviderNotFound or
        err == error.Sqlite3NotFound or
        err == error.SqliteQueryFailed or
        err == error.CodexLoginFailed or
        err == error.InvalidRenewalDate or
        err == error.RemoveConfirmationUnavailable or
        err == error.RemoveSelectionRequiresTty or
        err == error.InvalidRemoveSelectionInput;
}

pub fn shouldReconcileManagedService(cmd: cli.Command) bool {
    if (io_util.hasNonEmptyEnvVarConstant(skip_service_reconcile_env)) return false;
    return switch (cmd) {
        .help, .version, .status, .daemon, .sync_history => false,
        else => true,
    };
}

pub const ForegroundUsageRefreshTarget = enum {
    list,
    switch_account,
    remove_account,
};

pub fn shouldRefreshForegroundUsage(target: ForegroundUsageRefreshTarget) bool {
    return target == .list or target == .switch_account;
}

fn isAccountNameRefreshOnlyMode() bool {
    return io_util.hasNonEmptyEnvVarConstant(account_name_refresh_only_env);
}

fn isBackgroundAccountNameRefreshDisabled() bool {
    return io_util.hasNonEmptyEnvVarConstant(disable_background_account_name_refresh_env);
}

fn trackedActiveAccountKey(reg: *registry.Registry) ?[]const u8 {
    const account_key = reg.active_account_key orelse return null;
    if (registry.findAccountIndexByAccountKey(reg, account_key) == null) return null;
    return account_key;
}

fn clearStaleActiveAccountKey(allocator: std.mem.Allocator, reg: *registry.Registry) void {
    const account_key = reg.active_account_key orelse return;
    if (registry.findAccountIndexByAccountKey(reg, account_key) != null) return;
    allocator.free(account_key);
    reg.active_account_key = null;
    reg.active_account_activated_at_ms = null;
}

pub fn reconcileActiveAuthAfterRemove(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    allow_auth_file_update: bool,
) !void {
    clearStaleActiveAccountKey(allocator, reg);
    if (reg.active_account_key != null) return;

    if (reg.accounts.items.len > 0) {
        const best_idx = registry.selectBestAccountIndexByUsage(reg) orelse 0;
        const account_key = reg.accounts.items[best_idx].account_key;
        if (allow_auth_file_update) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, reg, account_key);
        } else {
            try registry.setActiveAccountKey(allocator, reg, account_key);
        }
        return;
    }

    if (!allow_auth_file_update) return;

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    std.fs.cwd().deleteFile(auth_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub const HelpConfig = struct {
    auto_switch: registry.AutoSwitchConfig,
    api: registry.ApiConfig,
};

pub fn loadHelpConfig(allocator: std.mem.Allocator, codex_home: []const u8) HelpConfig {
    var reg = registry.loadRegistry(allocator, codex_home) catch {
        return .{
            .auto_switch = registry.defaultAutoSwitchConfig(),
            .api = registry.defaultApiConfig(),
        };
    };
    defer reg.deinit(allocator);
    return .{
        .auto_switch = reg.auto_switch,
        .api = reg.api,
    };
}

fn initForegroundUsageRefreshState(
    allocator: std.mem.Allocator,
    account_count: usize,
) !ForegroundUsageRefreshState {
    const usage_overrides = try allocator.alloc(?[]const u8, account_count);
    errdefer allocator.free(usage_overrides);
    for (usage_overrides) |*slot| slot.* = null;

    const outcomes = try allocator.alloc(ForegroundUsageOutcome, account_count);
    errdefer allocator.free(outcomes);
    for (outcomes) |*outcome| outcome.* = .{};

    return .{
        .usage_overrides = usage_overrides,
        .outcomes = outcomes,
    };
}

fn maybeRefreshForegroundUsage(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
) !void {
    if (!shouldRefreshForegroundUsage(target)) return;
    if (try auto.refreshActiveUsage(allocator, codex_home, reg)) {
        try registry.saveRegistry(allocator, codex_home, reg);
    }
}

fn refreshActiveUsageForJson(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !JsonRefreshSummary {
    return refreshActiveUsageForJsonWithApiFetcher(allocator, codex_home, reg, usage_api.fetchActiveUsage);
}

pub fn refreshActiveUsageForJsonWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !JsonRefreshSummary {
    const attempted: usize = if (trackedActiveAccountKey(reg) != null) 1 else 0;
    if (attempted == 0) {
        return .{
            .usage_requested = true,
            .local_only_mode = !reg.api.usage,
        };
    }

    const updated = try auto.refreshActiveUsageWithApiFetcher(allocator, codex_home, reg, api_fetcher);
    if (updated) {
        try registry.saveRegistry(allocator, codex_home, reg);
    }

    return .{
        .usage_requested = true,
        .attempted = attempted,
        .updated = if (updated) 1 else 0,
        .unchanged = if (updated) 0 else attempted,
        .local_only_mode = !reg.api.usage,
    };
}

pub fn refreshForegroundUsageForDisplayWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        initForegroundUsagePool,
    );
}

pub fn refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
) !ForegroundUsageRefreshState {
    var state = try initForegroundUsageRefreshState(allocator, reg.accounts.items.len);
    errdefer state.deinit(allocator);

    if (!reg.api.usage) {
        state.local_only_mode = true;
        if (try auto.refreshActiveUsage(allocator, codex_home, reg)) {
            try registry.saveRegistry(allocator, codex_home, reg);
        }
        return state;
    }

    if (reg.accounts.items.len == 0) return state;

    const worker_results = try allocator.alloc(ForegroundUsageWorkerResult, reg.accounts.items.len);
    defer {
        for (worker_results) |*worker_result| worker_result.deinit(allocator);
        allocator.free(worker_results);
    }
    for (worker_results) |*worker_result| worker_result.* = .{};

    if (reg.accounts.items.len <= 1) {
        runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, worker_results);
    } else {
        var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
        const thread_allocator = thread_safe_allocator.allocator();
        var pool: std.Thread.Pool = undefined;
        const pool_started = blk: {
            pool_init(
                &pool,
                thread_allocator,
                @min(reg.accounts.items.len, foreground_usage_refresh_concurrency),
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break :blk false,
            };
            break :blk true;
        };

        if (pool_started) {
            defer pool.deinit();

            var wait_group: std.Thread.WaitGroup = .{};
            for (reg.accounts.items, 0..) |_, idx| {
                pool.spawnWg(&wait_group, foregroundUsageRefreshWorker, .{
                    thread_allocator,
                    codex_home,
                    reg,
                    idx,
                    usage_fetcher,
                    worker_results,
                });
            }
            wait_group.wait();
        } else {
            runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, worker_results);
        }
    }

    var registry_changed = false;
    for (worker_results, 0..) |*worker_result, idx| {
        const outcome = &state.outcomes[idx];
        outcome.* = .{
            .attempted = true,
            .status_code = worker_result.status_code,
            .missing_auth = worker_result.missing_auth,
            .error_name = worker_result.error_name,
            .has_usage_windows = worker_result.snapshot != null,
        };
        state.attempted += 1;

        if (worker_result.snapshot) |snapshot| {
            if (registry.rateLimitSnapshotsEqual(reg.accounts.items[idx].last_usage, snapshot)) {
                outcome.unchanged = true;
                state.unchanged += 1;
                worker_result.deinit(allocator);
            } else {
                registry.updateUsage(allocator, reg, reg.accounts.items[idx].account_key, snapshot);
                worker_result.snapshot = null;
                outcome.updated = true;
                state.updated += 1;
                registry_changed = true;
            }
        } else if (try setForegroundUsageOverrideForOutcome(allocator, &state.usage_overrides[idx], outcome.*)) {
            state.failed += 1;
        } else {
            outcome.unchanged = true;
            state.unchanged += 1;
        }
    }

    if (registry_changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
    }

    return state;
}

fn initForegroundUsagePool(
    pool: *std.Thread.Pool,
    allocator: std.mem.Allocator,
    n_jobs: usize,
) !void {
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = n_jobs,
    });
}

fn runForegroundUsageRefreshWorkersSerially(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
) void {
    for (reg.accounts.items, 0..) |_, idx| {
        foregroundUsageRefreshWorker(allocator, codex_home, reg, idx, usage_fetcher, results);
    }
}

fn foregroundUsageRefreshWorker(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_idx: usize,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth_path = registry.accountAuthPath(arena, codex_home, reg.accounts.items[account_idx].account_key) catch |err| {
        results[account_idx] = .{ .error_name = @errorName(err) };
        return;
    };

    const fetch_result = usage_fetcher(arena, auth_path) catch |err| {
        results[account_idx] = .{ .error_name = @errorName(err) };
        return;
    };

    var result: ForegroundUsageWorkerResult = .{
        .status_code = fetch_result.status_code,
        .missing_auth = fetch_result.missing_auth,
    };

    if (fetch_result.snapshot) |snapshot| {
        result.snapshot = registry.cloneRateLimitSnapshot(allocator, snapshot) catch |err| {
            results[account_idx] = .{
                .status_code = fetch_result.status_code,
                .missing_auth = fetch_result.missing_auth,
                .error_name = @errorName(err),
            };
            return;
        };
    }

    results[account_idx] = result;
}

fn setForegroundUsageOverrideForOutcome(
    allocator: std.mem.Allocator,
    slot: *?[]const u8,
    outcome: ForegroundUsageOutcome,
) !bool {
    if (outcome.error_name) |error_name| {
        slot.* = try allocator.dupe(u8, error_name);
        return true;
    }
    if (outcome.missing_auth) {
        slot.* = try allocator.dupe(u8, "MissingAuth");
        return true;
    }
    if (outcome.status_code) |status_code| {
        if (status_code != 200) {
            slot.* = try std.fmt.allocPrint(allocator, "{d}", .{status_code});
            return true;
        }
    }
    return false;
}

fn buildDebugUsageLabelState(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
) !DebugUsageLabelState {
    var labels = try allocator.alloc([]const u8, reg.accounts.items.len);
    errdefer allocator.free(labels);
    for (reg.accounts.items, 0..) |rec, idx| {
        labels[idx] = try allocator.dupe(u8, rec.email);
    }
    errdefer {
        for (labels) |label| allocator.free(@constCast(label));
    }

    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    var display_order = std.ArrayList(usize).empty;
    defer display_order.deinit(allocator);

    for (display.rows) |row| {
        const account_idx = row.account_index orelse continue;
        const next_label = if (row.depth == 0)
            try allocator.dupe(u8, row.account_cell)
        else
            try std.fmt.allocPrint(allocator, "{s} | {s}", .{
                reg.accounts.items[account_idx].email,
                row.account_cell,
            });
        allocator.free(@constCast(labels[account_idx]));
        labels[account_idx] = next_label;
        try display_order.append(allocator, account_idx);
    }

    return .{
        .labels = labels,
        .display_order = try display_order.toOwnedSlice(allocator),
    };
}

fn debugStatusLabel(buf: *[32]u8, outcome: ForegroundUsageOutcome) []const u8 {
    if (outcome.error_name) |error_name| return error_name;
    if (outcome.missing_auth) return "MissingAuth";
    if (outcome.status_code) |status_code| {
        return std.fmt.bufPrint(buf, "{d}", .{status_code}) catch "-";
    }
    return if (outcome.has_usage_windows) "200" else "-";
}

fn outcomeHasNoUsageWindow(outcome: ForegroundUsageOutcome) bool {
    return outcome.error_name == null and
        !outcome.missing_auth and
        !outcome.has_usage_windows and
        outcome.status_code != null and
        outcome.status_code.? == 200;
}

fn formatRemainingPercentAlloc(
    allocator: std.mem.Allocator,
    window: ?registry.RateLimitWindow,
) ![]const u8 {
    const remaining = registry.remainingPercentAt(window, std.time.timestamp()) orelse return allocator.dupe(u8, "-");
    return std.fmt.allocPrint(allocator, "{d}%", .{remaining});
}

fn printForegroundUsageDebug(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    state: *const ForegroundUsageRefreshState,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();

    if (state.local_only_mode) {
        try out.writeAll("[debug] usage refresh skipped: mode=local-only; only the active account can refresh from local rollout data\n");
        try out.flush();
        return;
    }

    var label_state = try buildDebugUsageLabelState(allocator, reg);
    defer label_state.deinit(allocator);

    try out.print(
        "[debug] usage refresh start: accounts={d} concurrency={d}\n",
        .{
            reg.accounts.items.len,
            @min(reg.accounts.items.len, foreground_usage_refresh_concurrency),
        },
    );

    for (label_state.display_order) |account_idx| {
        if (!state.outcomes[account_idx].attempted) continue;
        try out.print("[debug] request usage: {s}\n", .{label_state.labels[account_idx]});
    }

    for (label_state.display_order) |account_idx| {
        const outcome = state.outcomes[account_idx];
        if (!outcome.attempted) continue;

        var status_buf: [32]u8 = undefined;
        try out.print(
            "[debug] response usage: {s} status={s}",
            .{
                label_state.labels[account_idx],
                debugStatusLabel(&status_buf, outcome),
            },
        );
        if (outcomeHasNoUsageWindow(outcome)) {
            try out.writeAll(" result=no-usage-limits-window");
        }
        try out.writeAll("\n");

        if (outcome.updated) {
            const rate_5h = registry.resolveRateWindow(reg.accounts.items[account_idx].last_usage, 300, true);
            const rate_weekly = registry.resolveRateWindow(reg.accounts.items[account_idx].last_usage, 10080, false);
            const rate_5h_text = try formatRemainingPercentAlloc(allocator, rate_5h);
            defer allocator.free(rate_5h_text);
            const rate_weekly_text = try formatRemainingPercentAlloc(allocator, rate_weekly);
            defer allocator.free(rate_weekly_text);
            try out.print(
                "[debug] updated usage: {s} 5h={s} weekly={s}\n",
                .{
                    label_state.labels[account_idx],
                    rate_5h_text,
                    rate_weekly_text,
                },
            );
        }
    }

    try out.print(
        "[debug] usage refresh done: attempted={d} updated={d} failed={d} unchanged={d}\n",
        .{ state.attempted, state.updated, state.failed, state.unchanged },
    );
    try out.flush();
}

pub fn maybeRefreshForegroundAccountNames(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    fetcher: AccountFetchFn,
) !void {
    const changed = switch (target) {
        .list => try refreshAccountNamesForList(allocator, codex_home, reg, fetcher),
        .switch_account => try refreshAccountNamesAfterSwitch(allocator, codex_home, reg, fetcher),
        .remove_account => false,
    };
    if (!changed) return;
    try registry.saveRegistry(allocator, codex_home, reg);
}

fn defaultAccountFetcher(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    return try account_api.fetchAccountsForTokenDetailed(
        allocator,
        account_api.default_account_endpoint,
        access_token,
        account_id,
    );
}

fn maybeRefreshAccountNamesForAuthInfo(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    info: *const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    const chatgpt_user_id = info.chatgpt_user_id orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScope(reg, chatgpt_user_id)) return false;
    const access_token = info.access_token orelse return false;
    const chatgpt_account_id = info.chatgpt_account_id orelse return false;

    const result = fetcher(allocator, access_token, chatgpt_account_id) catch |err| {
        std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
        return false;
    };
    defer result.deinit(allocator);

    const entries = result.entries orelse return false;
    return try registry.applyAccountNamesForUser(allocator, reg, chatgpt_user_id, entries);
}

fn loadActiveAuthInfoForAccountRefresh(allocator: std.mem.Allocator, codex_home: []const u8) !?auth.AuthInfo {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    return auth.parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => null,
        else => {
            std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
            return null;
        },
    };
}

fn refreshAccountNamesForActiveAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    const active_user_id = registry.activeChatgptUserId(reg) orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScope(reg, active_user_id)) return false;

    var info = (try loadActiveAuthInfoForAccountRefresh(allocator, codex_home)) orelse return false;
    defer info.deinit(allocator);
    return try maybeRefreshAccountNamesForAuthInfo(allocator, reg, &info, fetcher);
}

pub fn refreshAccountNamesAfterLogin(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    info: *const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    return try maybeRefreshAccountNamesForAuthInfo(allocator, reg, info, fetcher);
}

pub fn refreshAccountNamesAfterSwitch(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    return try refreshAccountNamesForActiveAuth(allocator, codex_home, reg, fetcher);
}

pub fn refreshAccountNamesForList(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    return try refreshAccountNamesForActiveAuth(allocator, codex_home, reg, fetcher);
}

fn shouldRefreshTeamAccountNamesForUserScope(reg: *registry.Registry, chatgpt_user_id: []const u8) bool {
    if (!reg.api.account) return false;
    return registry.shouldFetchTeamAccountNamesForUser(reg, chatgpt_user_id);
}

pub fn shouldScheduleBackgroundAccountNameRefresh(reg: *registry.Registry) bool {
    if (!reg.api.account) return false;

    for (reg.accounts.items) |rec| {
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        if (registry.shouldFetchTeamAccountNamesForUser(reg, rec.chatgpt_user_id)) return true;
    }

    return false;
}

fn applyAccountNameRefreshEntriesToLatestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);

    if (!shouldRefreshTeamAccountNamesForUserScope(&latest, chatgpt_user_id)) return false;
    if (!try registry.applyAccountNamesForUser(allocator, &latest, chatgpt_user_id, entries)) return false;

    try registry.saveRegistry(allocator, codex_home, &latest);
    return true;
}

pub fn runBackgroundAccountNameRefresh(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    fetcher: AccountFetchFn,
) !void {
    return try runBackgroundAccountNameRefreshWithLockAcquirer(
        allocator,
        codex_home,
        fetcher,
        account_name_refresh.BackgroundRefreshLock.acquire,
    );
}

fn runBackgroundAccountNameRefreshWithLockAcquirer(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    fetcher: AccountFetchFn,
    lock_acquirer: BackgroundRefreshLockAcquirer,
) !void {
    var refresh_lock = (try lock_acquirer(allocator, codex_home)) orelse return;
    defer refresh_lock.release();

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    var candidates = try account_name_refresh.collectCandidates(allocator, &reg);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    for (candidates.items) |candidate| {
        var latest = try registry.loadRegistry(allocator, codex_home);
        defer latest.deinit(allocator);

        if (!shouldRefreshTeamAccountNamesForUserScope(&latest, candidate.chatgpt_user_id)) continue;

        var info = (try account_name_refresh.loadStoredAuthInfoForUser(
            allocator,
            codex_home,
            &latest,
            candidate.chatgpt_user_id,
        )) orelse continue;
        defer info.deinit(allocator);

        const access_token = info.access_token orelse continue;
        const chatgpt_account_id = info.chatgpt_account_id orelse continue;
        const result = fetcher(allocator, access_token, chatgpt_account_id) catch |err| {
            std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
            continue;
        };
        defer result.deinit(allocator);

        const entries = result.entries orelse continue;
        _ = try applyAccountNameRefreshEntriesToLatestRegistry(allocator, codex_home, candidate.chatgpt_user_id, entries);
    }
}

fn spawnBackgroundAccountNameRefresh(allocator: std.mem.Allocator) !void {
    var env_map = std.process.getEnvMap(allocator) catch |err| {
        std.log.warn("background account metadata refresh skipped: {s}", .{@errorName(err)});
        return;
    };
    defer env_map.deinit();

    try env_map.put(account_name_refresh_only_env, "1");
    try env_map.put(disable_background_account_name_refresh_env, "1");
    try env_map.put(skip_service_reconcile_env, "1");

    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    var child = std.process.Child.init(&[_][]const u8{ self_exe, "list" }, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
}

fn maybeSpawnBackgroundAccountNameRefresh(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
) void {
    if (isBackgroundAccountNameRefreshDisabled()) return;
    if (!shouldScheduleBackgroundAccountNameRefresh(reg)) return;

    spawnBackgroundAccountNameRefresh(allocator) catch |err| {
        std.log.warn("background account metadata refresh skipped: {s}", .{@errorName(err)});
    };
}

pub fn refreshAccountNamesAfterImport(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    purge: bool,
    render_kind: registry.ImportRenderKind,
    info: ?*const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    if (purge or render_kind != .single_file or info == null) return false;
    return try maybeRefreshAccountNamesForAuthInfo(allocator, reg, info.?, fetcher);
}

fn loadSingleFileImportAuthInfo(
    allocator: std.mem.Allocator,
    opts: cli.ImportOptions,
) !?auth.AuthInfo {
    if (opts.purge or opts.auth_path == null) return null;

    return switch (opts.source) {
        .standard => auth.parseAuthInfo(allocator, opts.auth_path.?) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                return null;
            },
        },
        .cpa => blk: {
            var file = std.fs.cwd().openFile(opts.auth_path.?, .{}) catch |err| {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                return null;
            };
            defer file.close();

            const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                    return null;
                },
            };
            defer allocator.free(data);

            const converted = auth.convertCpaAuthJson(allocator, data) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                    return null;
                },
            };
            defer allocator.free(converted);

            break :blk auth.parseAuthInfoData(allocator, converted) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                    return null;
                },
            };
        },
    };
}

fn handleList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ListOptions) !void {
    if (isAccountNameRefreshOnlyMode()) return try runBackgroundAccountNameRefresh(allocator, codex_home, defaultAccountFetcher);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (opts.json) {
        if (opts.refresh_usage) {
            var usage_state = try refreshForegroundUsageForDisplayWithApiFetcher(
                allocator,
                codex_home,
                &reg,
                usage_api.fetchUsageForAuthPathDetailed,
            );
            defer usage_state.deinit(allocator);
            try printAccountsJson(allocator, codex_home, &reg, usage_state.usage_overrides, .{
                .usage_requested = true,
                .attempted = usage_state.attempted,
                .updated = usage_state.updated,
                .failed = usage_state.failed,
                .unchanged = usage_state.unchanged,
                .local_only_mode = usage_state.local_only_mode,
            });
        } else if (opts.refresh_active_usage) {
            const refresh = try refreshActiveUsageForJson(allocator, codex_home, &reg);
            try printAccountsJson(allocator, codex_home, &reg, null, refresh);
        } else {
            try printAccountsJson(allocator, codex_home, &reg, null, .{});
        }
        return;
    }
    var usage_state = try refreshForegroundUsageForDisplayWithApiFetcher(
        allocator,
        codex_home,
        &reg,
        usage_api.fetchUsageForAuthPathDetailed,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNames(allocator, codex_home, &reg, .list, defaultAccountFetcher);
    if (opts.debug) {
        try printForegroundUsageDebug(allocator, &reg, &usage_state);
    }
    try format.printAccountsWithUsageOverrides(&reg, usage_state.usage_overrides);
}

fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.LoginOptions) !void {
    try cli.runCodexLogin(opts);
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    const email = info.email orelse return error.MissingEmail;
    _ = email;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const dest = try registry.accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.copyFile(auth_path, dest);

    const record = try registry.accountFromAuth(allocator, "", &info);
    try registry.upsertAccount(allocator, &reg, record);
    try registry.setActiveAccountKey(allocator, &reg, record_key);
    _ = try refreshAccountNamesAfterLogin(allocator, &reg, &info, defaultAccountFetcher);
    try registry.saveRegistry(allocator, codex_home, &reg);
    _ = history_sync.ensureDualProviderHistory(allocator, codex_home) catch |err| {
        std.log.warn("history sync skipped after login: {s}", .{@errorName(err)});
    };
}

fn handleImport(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ImportOptions) !void {
    if (opts.purge) {
        var report = try registry.purgeRegistryFromImportSource(allocator, codex_home, opts.auth_path, opts.alias);
        defer report.deinit(allocator);
        try cli.printImportReport(&report);
        if (report.failure) |err| return err;
        return;
    }

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    var report = switch (opts.source) {
        .standard => try registry.importAuthPath(allocator, codex_home, &reg, opts.auth_path.?, opts.alias),
        .cpa => try registry.importCpaPath(allocator, codex_home, &reg, opts.auth_path, opts.alias),
    };
    defer report.deinit(allocator);
    if (report.appliedCount() > 0) {
        if (report.render_kind == .single_file) {
            var imported_info = try loadSingleFileImportAuthInfo(allocator, opts);
            defer if (imported_info) |*info| info.deinit(allocator);
            _ = try refreshAccountNamesAfterImport(
                allocator,
                &reg,
                opts.purge,
                report.render_kind,
                if (imported_info) |*info| info else null,
                defaultAccountFetcher,
            );
        }
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try cli.printImportReport(&report);
    if (report.failure) |err| return err;
}

fn handleSwitch(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.SwitchOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (opts.account_key) |account_key| {
        if (registry.findAccountIndexByAccountKey(&reg, account_key) == null) {
            try cli.printAccountNotFoundError(account_key);
            return error.AccountNotFound;
        }
        try registry.activateAccountByKey(allocator, codex_home, &reg, account_key);
        try registry.saveRegistry(allocator, codex_home, &reg);
        if (opts.json) {
            try printAccountsJson(allocator, codex_home, &reg, null, .{});
        }
        return;
    }
    var usage_state = try refreshForegroundUsageForDisplayWithApiFetcher(
        allocator,
        codex_home,
        &reg,
        usage_api.fetchUsageForAuthPathDetailed,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNames(allocator, codex_home, &reg, .switch_account, defaultAccountFetcher);

    var selected_account_key: ?[]const u8 = null;
    if (opts.query) |query| {
        var matches = try findMatchingAccounts(allocator, &reg, query);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            try cli.printAccountNotFoundError(query);
            return error.AccountNotFound;
        }

        if (matches.items.len == 1) {
            selected_account_key = reg.accounts.items[matches.items[0]].account_key;
        } else {
            selected_account_key = try cli.selectAccountFromIndicesWithUsageOverrides(
                allocator,
                &reg,
                matches.items,
                usage_state.usage_overrides,
            );
        }
        if (selected_account_key == null) return;
    } else {
        const selected = try cli.selectAccountWithUsageOverrides(allocator, &reg, usage_state.usage_overrides);
        if (selected == null) return;
        selected_account_key = selected.?;
    }
    const account_key = selected_account_key.?;

    try registry.activateAccountByKey(allocator, codex_home, &reg, account_key);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn printApiProfileMessage(action: []const u8, profile_key: []const u8, label: ?[]const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (label) |value| {
        try out.print("{s}: {s} ({s})\n", .{ action, profile_key, value });
    } else {
        try out.print("{s}: {s}\n", .{ action, profile_key });
    }
    try out.flush();
}

fn printApiProfileImportSummary(summary: registry.CcSwitchImportSummary) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print(
        "imported API profiles from cc-switch: imported={d}, updated={d}, skipped={d}\n",
        .{ summary.imported, summary.updated, summary.skipped },
    );
    try out.flush();
}

fn handleApiProfile(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ApiProfileOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    switch (opts) {
        .capture => |capture_opts| {
            const profile_key = registry.captureCurrentApiProfile(allocator, codex_home, &reg, capture_opts.label) catch |err| switch (err) {
                error.ApiKeyModeRequired => {
                    try printHandledError(
                        "current auth is not in API-key mode.",
                        "Switch Codex to an API-key config first, then run `codex-auth api-profile capture --label <label>`.",
                    );
                    return err;
                },
                error.AuthFileNotFound => {
                    try printHandledError("active auth.json was not found.", null);
                    return err;
                },
                error.ConfigFileNotFound => {
                    try printHandledError(
                        "active config.toml was not found.",
                        "Save the provider config first, then capture it again.",
                    );
                    return err;
                },
                else => return err,
            };
            defer allocator.free(profile_key);
            try registry.saveRegistry(allocator, codex_home, &reg);
            if (capture_opts.json) {
                try printAccountsJson(allocator, codex_home, &reg, null, .{});
            } else {
                try printApiProfileMessage("saved API profile", profile_key, capture_opts.label);
            }
        },
        .switch_profile => |switch_opts| {
            if (registry.findApiProfileIndexByKey(&reg, switch_opts.profile_key) == null) {
                try printHandledError(
                    "API profile not found.",
                    "Run `codex-auth list --json` to inspect saved `api_profiles` keys.",
                );
                return error.ApiProfileNotFound;
            }
            try registry.activateApiProfileByKey(allocator, codex_home, &reg, switch_opts.profile_key);
            try registry.saveRegistry(allocator, codex_home, &reg);
            if (switch_opts.json) {
                try printAccountsJson(allocator, codex_home, &reg, null, .{});
            } else {
                try printApiProfileMessage("switched API profile", switch_opts.profile_key, null);
            }
        },
        .import_cc_switch => |import_opts| {
            const db_path = if (import_opts.db_path) |path|
                try allocator.dupe(u8, path)
            else
                try registry.defaultCcSwitchDbPath(allocator);
            defer allocator.free(db_path);

            const selector: registry.CcSwitchImportSelector = if (import_opts.all)
                .all
            else if (import_opts.provider_id) |provider_id|
                .{ .provider_id = provider_id }
            else
                .current;

            const summary = registry.importCcSwitchApiProfiles(allocator, codex_home, &reg, db_path, selector) catch |err| switch (err) {
                error.CcSwitchDbNotFound => {
                    try printHandledError(
                        "cc-switch database was not found.",
                        "Install cc-switch first or pass `--db-path <path>` to import a specific database.",
                    );
                    return err;
                },
                error.CcSwitchProviderNotFound => {
                    try printHandledError(
                        "cc-switch provider was not found.",
                        "Check the provider id in cc-switch and try `codex-auth api-profile import-cc-switch --provider-id <id>` again.",
                    );
                    return err;
                },
                error.Sqlite3NotFound => {
                    try printHandledError(
                        "`sqlite3` was not found.",
                        "Install `sqlite3` or make sure it is available in PATH before importing cc-switch profiles.",
                    );
                    return err;
                },
                error.SqliteQueryFailed => {
                    try printHandledError(
                        "failed to read the cc-switch database.",
                        "Open cc-switch once to confirm the database is readable, then try the import again.",
                    );
                    return err;
                },
                else => return err,
            };

            var needs_save = summary.imported != 0 or summary.updated != 0;
            if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
                needs_save = true;
            }
            if (needs_save) {
                try registry.saveRegistry(allocator, codex_home, &reg);
            }
            if (import_opts.json) {
                try printAccountsJson(allocator, codex_home, &reg, null, .{});
            } else {
                try printApiProfileImportSummary(summary);
            }
        },
    }
}

fn printHandledError(message: []const u8, hint: ?[]const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = io_util.stderrWriter(&buffer);
    const out = &writer.interface;
    const use_color = io_util.stderrIsTty();
    try cli.writeErrorPrefixTo(out, use_color);
    try out.print(" {s}\n", .{message});
    if (hint) |text| {
        try cli.writeHintPrefixTo(out, use_color);
        try out.print(" {s}\n", .{text});
    }
    try out.flush();
}

fn printRenewalMessage(
    action: []const u8,
    account_key: []const u8,
    value: ?[]const u8,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (value) |text| {
        try out.print("{s}: {s} -> {s}\n", .{ action, account_key, text });
    } else {
        try out.print("{s}: {s}\n", .{ action, account_key });
    }
    try out.flush();
}

fn handleRenewal(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.RenewalOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    switch (opts) {
        .set => |set_opts| {
            if (!registry.renewalDateStringIsValid(set_opts.date)) {
                try printHandledError(
                    "invalid renewal date; expected YYYY-MM-DD.",
                    "Run `codex-auth renewal set --account-key <key> --date YYYY-MM-DD`.",
                );
                return error.InvalidRenewalDate;
            }
            _ = registry.findAccountIndexByAccountKey(&reg, set_opts.account_key) orelse {
                try cli.printAccountNotFoundError(set_opts.account_key);
                return error.AccountNotFound;
            };
            try registry.setAccountRenewal(allocator, &reg, set_opts.account_key, set_opts.date, .manual, .ok);
            try registry.saveRegistry(allocator, codex_home, &reg);
            if (set_opts.json) {
                try printAccountsJson(allocator, codex_home, &reg, null, .{});
            } else {
                try printRenewalMessage("saved next renewal date", set_opts.account_key, set_opts.date);
            }
        },
        .clear => |clear_opts| {
            _ = registry.findAccountIndexByAccountKey(&reg, clear_opts.account_key) orelse {
                try cli.printAccountNotFoundError(clear_opts.account_key);
                return error.AccountNotFound;
            };
            try registry.clearAccountRenewal(allocator, &reg, clear_opts.account_key);
            try registry.saveRegistry(allocator, codex_home, &reg);
            if (clear_opts.json) {
                try printAccountsJson(allocator, codex_home, &reg, null, .{});
            } else {
                try printRenewalMessage("cleared next renewal date", clear_opts.account_key, null);
            }
        },
    }
}

fn handleConfig(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ConfigOptions) !void {
    switch (opts) {
        .auto_switch => |auto_opts| try auto.handleAutoCommand(allocator, codex_home, auto_opts),
        .api => |action| try auto.handleApiCommand(allocator, codex_home, action),
    }
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

pub fn findMatchingAccounts(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !std.ArrayList(usize) {
    var matches = std.ArrayList(usize).empty;
    for (reg.accounts.items, 0..) |*rec, idx| {
        const matches_email = std.ascii.indexOfIgnoreCase(rec.email, query) != null;
        const matches_alias = rec.alias.len != 0 and std.ascii.indexOfIgnoreCase(rec.alias, query) != null;
        const matches_name = if (rec.account_name) |name|
            name.len != 0 and std.ascii.indexOfIgnoreCase(name, query) != null
        else
            false;
        if (matches_email or matches_alias or matches_name) {
            try matches.append(allocator, idx);
        }
    }
    return matches;
}

const CurrentAuthState = struct {
    record_key: ?[]u8,
    syncable: bool,
    missing: bool,

    fn deinit(self: *CurrentAuthState, allocator: std.mem.Allocator) void {
        if (self.record_key) |key| allocator.free(key);
    }
};

fn loadCurrentAuthState(allocator: std.mem.Allocator, codex_home: []const u8) !CurrentAuthState {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    std.fs.cwd().access(auth_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .record_key = null,
            .syncable = false,
            .missing = true,
        },
        else => {},
    };

    const info = auth.parseAuthInfo(allocator, auth_path) catch return .{
        .record_key = null,
        .syncable = false,
        .missing = false,
    };
    defer info.deinit(allocator);

    const record_key = if (info.record_key) |key|
        try allocator.dupe(u8, key)
    else
        null;

    return .{
        .record_key = record_key,
        .syncable = info.email != null and info.record_key != null,
        .missing = false,
    };
}

fn selectionContainsAccountKey(reg: *registry.Registry, indices: []const usize, account_key: []const u8) bool {
    for (indices) |idx| {
        if (idx >= reg.accounts.items.len) continue;
        if (std.mem.eql(u8, reg.accounts.items[idx].account_key, account_key)) return true;
    }
    return false;
}

fn selectionContainsIndex(indices: []const usize, target: usize) bool {
    for (indices) |idx| {
        if (idx == target) return true;
    }
    return false;
}

fn selectBestRemainingAccountKeyByUsageAlloc(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    removed_indices: []const usize,
) !?[]u8 {
    if (reg.accounts.items.len == 0) return null;

    const now = std.time.timestamp();
    var best_idx: ?usize = null;
    var best_score: i64 = -2;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |rec, idx| {
        if (selectionContainsIndex(removed_indices, idx)) continue;

        const score = registry.usageScoreAt(rec.last_usage, now) orelse -1;
        const seen = rec.last_usage_at orelse -1;
        if (score > best_score or (score == best_score and seen > best_seen)) {
            best_idx = idx;
            best_score = score;
            best_seen = seen;
        }
    }

    if (best_idx) |idx| {
        return try allocator.dupe(u8, reg.accounts.items[idx].account_key);
    }
    return null;
}

fn handleRemove(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.RemoveOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try maybeRefreshForegroundUsage(allocator, codex_home, &reg, .remove_account);

    var selected: ?[]usize = null;
    if (opts.all) {
        selected = try allocator.alloc(usize, reg.accounts.items.len);
        for (selected.?, 0..) |*slot, idx| slot.* = idx;
    } else if (opts.query) |query| {
        var matches = try findMatchingAccounts(allocator, &reg, query);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            try cli.printAccountNotFoundError(query);
            return error.AccountNotFound;
        }

        if (matches.items.len > 1) {
            var matched_labels = try cli.buildRemoveLabels(allocator, &reg, matches.items);
            defer {
                freeOwnedStrings(allocator, matched_labels.items);
                matched_labels.deinit(allocator);
            }
            if (!io_util.stdinIsTty()) {
                try cli.printRemoveConfirmationUnavailableError(matched_labels.items);
                return error.RemoveConfirmationUnavailable;
            }
            if (!(try cli.confirmRemoveMatches(matched_labels.items))) return;
        }

        selected = try allocator.dupe(usize, matches.items);
    } else {
        selected = cli.selectAccountsToRemove(allocator, &reg) catch |err| switch (err) {
            error.InvalidRemoveSelectionInput => {
                try cli.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            },
            else => return err,
        };
    }
    if (selected == null) return;
    defer allocator.free(selected.?);
    if (selected.?.len == 0) return;

    var removed_labels = try cli.buildRemoveLabels(allocator, &reg, selected.?);
    defer {
        freeOwnedStrings(allocator, removed_labels.items);
        removed_labels.deinit(allocator);
    }

    const current_active_account_key = if (trackedActiveAccountKey(&reg)) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (current_active_account_key) |key| allocator.free(key);

    var current_auth_state = try loadCurrentAuthState(allocator, codex_home);
    defer current_auth_state.deinit(allocator);

    const active_removed = if (current_active_account_key) |key|
        selectionContainsAccountKey(&reg, selected.?, key)
    else
        false;
    const allow_auth_file_update = if (current_active_account_key) |key|
        active_removed and ((current_auth_state.syncable and current_auth_state.record_key != null and
            std.mem.eql(u8, current_auth_state.record_key.?, key)) or current_auth_state.missing)
    else if (current_auth_state.missing)
        true
    else if (opts.all)
        current_auth_state.syncable and current_auth_state.record_key != null and
            selectionContainsAccountKey(&reg, selected.?, current_auth_state.record_key.?)
    else
        false;

    const replacement_account_key = if (active_removed)
        try selectBestRemainingAccountKeyByUsageAlloc(allocator, &reg, selected.?)
    else
        null;
    defer if (replacement_account_key) |key| allocator.free(key);

    if (replacement_account_key) |key| {
        if (allow_auth_file_update) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, &reg, key);
        } else {
            try registry.setActiveAccountKey(allocator, &reg, key);
        }
    }

    try registry.removeAccounts(allocator, codex_home, &reg, selected.?);
    try reconcileActiveAuthAfterRemove(allocator, codex_home, &reg, allow_auth_file_update);
    try registry.saveRegistry(allocator, codex_home, &reg);
    try cli.printRemoveSummary(removed_labels.items);
}

fn handleTopLevelHelp(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const help_cfg = loadHelpConfig(allocator, codex_home);
    try cli.printHelp(&help_cfg.auto_switch, &help_cfg.api);
}

fn handleClean(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const summary = try registry.cleanAccountsBackups(allocator, codex_home);
    var stdout: [256]u8 = undefined;
    var writer = io_util.stdoutWriter(&stdout);
    const out = &writer.interface;
    try out.print(
        "cleaned accounts: auth_backups={d}, registry_backups={d}, stale_entries={d}\n",
        .{
            summary.auth_backups_removed,
            summary.registry_backups_removed,
            summary.stale_snapshot_files_removed,
        },
    );
    try out.flush();
}

fn handleSyncHistory(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const summary = try history_sync.ensureDualProviderHistory(allocator, codex_home);
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print(
        "history sync complete: provider_updated_threads={d} indexed_threads={d}\n",
        .{ summary.provider_updated_threads, summary.indexed_threads },
    );
    try out.flush();
}

test "background account-name refresh returns early when another refresh holds the lock" {
    const TestState = struct {
        var fetch_count: usize = 0;

        fn lockUnavailable(_: std.mem.Allocator, _: []const u8) !?account_name_refresh.BackgroundRefreshLock {
            return null;
        }

        fn unexpectedFetcher(
            allocator: std.mem.Allocator,
            access_token: []const u8,
            account_id: []const u8,
        ) !account_api.FetchResult {
            _ = allocator;
            _ = access_token;
            _ = account_id;
            fetch_count += 1;
            return error.TestUnexpectedFetch;
        }
    };

    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    TestState.fetch_count = 0;
    try runBackgroundAccountNameRefreshWithLockAcquirer(
        gpa,
        codex_home,
        TestState.unexpectedFetcher,
        TestState.lockUnavailable,
    );
    try std.testing.expectEqual(@as(usize, 0), TestState.fetch_count);
}

// Tests live in separate files but are pulled in by main.zig for zig test.
test {
    _ = @import("tests/auth_test.zig");
    _ = @import("tests/sessions_test.zig");
    _ = @import("tests/history_sync_test.zig");
    _ = @import("tests/account_api_test.zig");
    _ = @import("tests/usage_api_test.zig");
    _ = @import("tests/auto_test.zig");
    _ = @import("tests/registry_test.zig");
    _ = @import("tests/registry_bdd_test.zig");
    _ = @import("tests/cli_bdd_test.zig");
    _ = @import("tests/display_rows_test.zig");
    _ = @import("tests/main_test.zig");
    _ = @import("tests/purge_test.zig");
    _ = @import("tests/e2e_cli_test.zig");
}
