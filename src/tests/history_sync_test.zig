const std = @import("std");
const history_sync = @import("../history_sync.zig");

fn sqlite3Available(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sqlite3", "--version" },
        .max_output_bytes = 4096,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn runSqlite(allocator: std.mem.Allocator, db_path: []const u8, sql: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sqlite3", "-batch", "-noheader", db_path, sql },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
        },
        else => {},
    }
    allocator.free(result.stdout);
    return error.CommandFailed;
}

test "history sync normalizes threads to the active provider without mirroring" {
    const gpa = std.testing.allocator;
    if (!sqlite3Available(gpa)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("codex-home/accounts");
    try tmp.dir.makePath("codex-home/sessions/2026/04/18");
    const codex_home = try tmp.dir.realpathAlloc(gpa, "codex-home");
    defer gpa.free(codex_home);

    const db_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "state_5.sqlite" });
    defer gpa.free(db_path);

    const rollout_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2026", "04", "18", "CUSTOM-THREAD.jsonl" });
    defer gpa.free(rollout_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = rollout_path,
        .data = "{\"event\":\"session_meta\",\"payload\":{\"id\":\"CUSTOM-THREAD\",\"model_provider\":\"custom\",\"title\":\"Shared thread\"}}\n" ++
            "{\"event\":\"user\",\"payload\":{\"text\":\"hello\"}}\n",
    });
    const registry_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "accounts", "registry.json" });
    defer gpa.free(registry_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = registry_path,
        .data = "{\"active_auth_mode\":\"chatgpt\"}\n",
    });

    const create_sql = try std.fmt.allocPrint(
        gpa,
        \\CREATE TABLE threads (
        \\  id TEXT PRIMARY KEY,
        \\  rollout_path TEXT NOT NULL,
        \\  created_at INTEGER,
        \\  updated_at INTEGER,
        \\  source TEXT,
        \\  model_provider TEXT,
        \\  cwd TEXT,
        \\  title TEXT,
        \\  sandbox_policy TEXT,
        \\  approval_mode TEXT,
        \\  tokens_used INTEGER,
        \\  has_user_event INTEGER,
        \\  archived INTEGER,
        \\  archived_at INTEGER,
        \\  git_sha TEXT,
        \\  git_branch TEXT,
        \\  git_origin_url TEXT,
        \\  cli_version TEXT,
        \\  first_user_message TEXT,
        \\  agent_nickname TEXT,
        \\  agent_role TEXT,
        \\  memory_mode TEXT,
        \\  model TEXT,
        \\  reasoning_effort TEXT,
        \\  agent_path TEXT,
        \\  created_at_ms INTEGER,
        \\  updated_at_ms INTEGER
        \\);
        \\
        \\INSERT INTO threads (
        \\  id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
        \\  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
        \\  git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
        \\  agent_role, memory_mode, model, reasoning_effort, agent_path, created_at_ms, updated_at_ms
        \\) VALUES (
        \\  'CUSTOM-THREAD', '{s}', 1710000000, 1710000000, 'cli', 'custom', '/tmp/demo',
        \\  'Shared thread', 'workspace-write', 'never', 0, 1, 0, NULL, NULL, NULL, NULL,
        \\  '0.0.0', 'hello', NULL, NULL, NULL, 'gpt-5', 'medium', NULL, 1710000000123, 1710000000456
        \\);
    ,
        .{rollout_path},
    );
    defer gpa.free(create_sql);
    const setup_out = try runSqlite(gpa, db_path, create_sql);
    defer gpa.free(setup_out);

    const first_summary = try history_sync.ensureDualProviderHistory(gpa, codex_home);
    try std.testing.expectEqual(@as(usize, 1), first_summary.provider_updated_threads);
    try std.testing.expectEqual(@as(usize, 1), first_summary.indexed_threads);

    const second_summary = try history_sync.ensureDualProviderHistory(gpa, codex_home);
    try std.testing.expectEqual(@as(usize, 0), second_summary.provider_updated_threads);
    try std.testing.expectEqual(@as(usize, 0), second_summary.indexed_threads);

    const providers_out = try runSqlite(
        gpa,
        db_path,
        "SELECT model_provider || '|' || COUNT(*) FROM threads GROUP BY model_provider ORDER BY model_provider;",
    );
    defer gpa.free(providers_out);
    try std.testing.expectEqualStrings("openai|1\n", providers_out);

    const openai_rollout_out = try runSqlite(
        gpa,
        db_path,
        "SELECT rollout_path FROM threads WHERE model_provider = 'openai' LIMIT 1;",
    );
    defer gpa.free(openai_rollout_out);
    const openai_rollout_path = std.mem.trim(u8, openai_rollout_out, " \n\r\t");
    try std.fs.cwd().access(openai_rollout_path, .{});

    const mirrored_first_line = try std.fs.cwd().readFileAlloc(gpa, openai_rollout_path, 1024 * 1024);
    defer gpa.free(mirrored_first_line);
    const first_line_end = std.mem.indexOfScalar(u8, mirrored_first_line, '\n') orelse mirrored_first_line.len;
    try std.testing.expect(std.mem.indexOf(u8, mirrored_first_line[0..first_line_end], "\"model_provider\":\"openai\"") != null);

    const index_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "session_index.jsonl" });
    defer gpa.free(index_path);
    const index_data = try std.fs.cwd().readFileAlloc(gpa, index_path, 1024 * 1024);
    defer gpa.free(index_data);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, index_data, "\"id\""));
}

test "history sync keeps provider normalization idempotent after timestamps change" {
    const gpa = std.testing.allocator;
    if (!sqlite3Available(gpa)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("codex-home/accounts");
    try tmp.dir.makePath("codex-home/sessions/2026/04/18");
    const codex_home = try tmp.dir.realpathAlloc(gpa, "codex-home");
    defer gpa.free(codex_home);

    const db_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "state_5.sqlite" });
    defer gpa.free(db_path);

    const rollout_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2026", "04", "18", "CUSTOM-THREAD.jsonl" });
    defer gpa.free(rollout_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = rollout_path,
        .data = "{\"event\":\"session_meta\",\"payload\":{\"id\":\"CUSTOM-THREAD\",\"model_provider\":\"custom\",\"title\":\"Shared thread\"}}\n" ++
            "{\"event\":\"user\",\"payload\":{\"text\":\"hello\"}}\n",
    });
    const registry_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "accounts", "registry.json" });
    defer gpa.free(registry_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = registry_path,
        .data = "{\"active_auth_mode\":\"chatgpt\"}\n",
    });

    const create_sql = try std.fmt.allocPrint(
        gpa,
        \\CREATE TABLE threads (
        \\  id TEXT PRIMARY KEY,
        \\  rollout_path TEXT NOT NULL,
        \\  created_at INTEGER,
        \\  updated_at INTEGER,
        \\  source TEXT,
        \\  model_provider TEXT,
        \\  cwd TEXT,
        \\  title TEXT,
        \\  sandbox_policy TEXT,
        \\  approval_mode TEXT,
        \\  tokens_used INTEGER,
        \\  has_user_event INTEGER,
        \\  archived INTEGER,
        \\  archived_at INTEGER,
        \\  git_sha TEXT,
        \\  git_branch TEXT,
        \\  git_origin_url TEXT,
        \\  cli_version TEXT,
        \\  first_user_message TEXT,
        \\  agent_nickname TEXT,
        \\  agent_role TEXT,
        \\  memory_mode TEXT,
        \\  model TEXT,
        \\  reasoning_effort TEXT,
        \\  agent_path TEXT,
        \\  created_at_ms INTEGER,
        \\  updated_at_ms INTEGER
        \\);
        \\
        \\INSERT INTO threads (
        \\  id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
        \\  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
        \\  git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
        \\  agent_role, memory_mode, model, reasoning_effort, agent_path, created_at_ms, updated_at_ms
        \\) VALUES (
        \\  'CUSTOM-THREAD', '{s}', 1710000000, 1710000000, 'cli', 'custom', '/tmp/demo',
        \\  'Shared thread', 'workspace-write', 'never', 0, 1, 0, NULL, NULL, NULL, NULL,
        \\  '0.0.0', 'hello', NULL, NULL, NULL, 'gpt-5', 'medium', NULL, 1710000000123, 1710000000456
        \\);
    ,
        .{rollout_path},
    );
    defer gpa.free(create_sql);
    const setup_out = try runSqlite(gpa, db_path, create_sql);
    defer gpa.free(setup_out);

    _ = try history_sync.ensureDualProviderHistory(gpa, codex_home);

    const update_out = try runSqlite(
        gpa,
        db_path,
        "UPDATE threads SET updated_at_ms = 1710000000999 WHERE id = 'CUSTOM-THREAD';",
    );
    defer gpa.free(update_out);

    const second_summary = try history_sync.ensureDualProviderHistory(gpa, codex_home);
    try std.testing.expectEqual(@as(usize, 0), second_summary.provider_updated_threads);
    try std.testing.expectEqual(@as(usize, 0), second_summary.indexed_threads);

    const providers_out = try runSqlite(
        gpa,
        db_path,
        "SELECT model_provider || '|' || COUNT(*) FROM threads GROUP BY model_provider ORDER BY model_provider;",
    );
    defer gpa.free(providers_out);
    try std.testing.expectEqualStrings("openai|1\n", providers_out);
}

test "history sync backfills missing session index entries without provider context" {
    const gpa = std.testing.allocator;
    if (!sqlite3Available(gpa)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("codex-home/sessions/2026/04/18");
    const codex_home = try tmp.dir.realpathAlloc(gpa, "codex-home");
    defer gpa.free(codex_home);

    const db_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "state_5.sqlite" });
    defer gpa.free(db_path);

    const custom_rollout = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2026", "04", "18", "CUSTOM-THREAD.jsonl" });
    defer gpa.free(custom_rollout);
    const openai_rollout = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2026", "04", "18", "OPENAI-THREAD.jsonl" });
    defer gpa.free(openai_rollout);

    try std.fs.cwd().writeFile(.{
        .sub_path = custom_rollout,
        .data = "{\"event\":\"session_meta\",\"payload\":{\"id\":\"CUSTOM-THREAD\",\"model_provider\":\"custom\",\"title\":\"Shared thread\"}}\n" ++
            "{\"event\":\"user\",\"payload\":{\"text\":\"hello\"}}\n",
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = openai_rollout,
        .data = "{\"event\":\"session_meta\",\"payload\":{\"id\":\"OPENAI-THREAD\",\"model_provider\":\"openai\",\"title\":\"Shared thread\"}}\n" ++
            "{\"event\":\"user\",\"payload\":{\"text\":\"hello\"}}\n",
    });

    const create_sql = try std.fmt.allocPrint(
        gpa,
        \\CREATE TABLE threads (
        \\  id TEXT PRIMARY KEY,
        \\  rollout_path TEXT NOT NULL,
        \\  created_at INTEGER,
        \\  updated_at INTEGER,
        \\  source TEXT,
        \\  model_provider TEXT,
        \\  cwd TEXT,
        \\  title TEXT,
        \\  sandbox_policy TEXT,
        \\  approval_mode TEXT,
        \\  tokens_used INTEGER,
        \\  has_user_event INTEGER,
        \\  archived INTEGER,
        \\  archived_at INTEGER,
        \\  git_sha TEXT,
        \\  git_branch TEXT,
        \\  git_origin_url TEXT,
        \\  cli_version TEXT,
        \\  first_user_message TEXT,
        \\  agent_nickname TEXT,
        \\  agent_role TEXT,
        \\  memory_mode TEXT,
        \\  model TEXT,
        \\  reasoning_effort TEXT,
        \\  agent_path TEXT,
        \\  created_at_ms INTEGER,
        \\  updated_at_ms INTEGER
        \\);
        \\
        \\INSERT INTO threads (
        \\  id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
        \\  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
        \\  git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
        \\  agent_role, memory_mode, model, reasoning_effort, agent_path, created_at_ms, updated_at_ms
        \\) VALUES (
        \\  'CUSTOM-THREAD', '{s}', 1710000000, 1710000000, 'cli', 'custom', '/tmp/demo',
        \\  'Shared thread', 'workspace-write', 'never', 0, 1, 0, NULL, NULL, NULL, NULL,
        \\  '0.0.0', 'hello', NULL, NULL, NULL, 'gpt-5', 'medium', NULL, 1710000000123, 1710000000456
        \\), (
        \\  'OPENAI-THREAD', '{s}', 1710000000, 1710000000, 'cli', 'openai', '/tmp/demo',
        \\  'Shared thread', 'workspace-write', 'never', 0, 1, 0, NULL, NULL, NULL, NULL,
        \\  '0.0.0', 'hello', NULL, NULL, NULL, 'gpt-5', 'medium', NULL, 1710000000123, 1710000000456
        \\);
    ,
        .{ custom_rollout, openai_rollout },
    );
    defer gpa.free(create_sql);
    const setup_out = try runSqlite(gpa, db_path, create_sql);
    defer gpa.free(setup_out);

    const index_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "session_index.jsonl" });
    defer gpa.free(index_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = index_path,
        .data = "{\"id\":\"OPENAI-THREAD\",\"title\":\"Shared thread\",\"updated_at_ms\":1710000000456}\n",
    });

    const summary = try history_sync.ensureDualProviderHistory(gpa, codex_home);
    try std.testing.expectEqual(@as(usize, 0), summary.provider_updated_threads);
    try std.testing.expectEqual(@as(usize, 1), summary.indexed_threads);

    const index_data = try std.fs.cwd().readFileAlloc(gpa, index_path, 1024 * 1024);
    defer gpa.free(index_data);
    try std.testing.expect(std.mem.indexOf(u8, index_data, "\"CUSTOM-THREAD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_data, "\"OPENAI-THREAD\"") != null);
}
