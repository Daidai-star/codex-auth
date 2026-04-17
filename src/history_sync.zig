const std = @import("std");

const sqlite3_max_output_bytes = 32 * 1024 * 1024;
const rollout_read_limit_bytes = 128 * 1024 * 1024;
const openai_provider = "openai";
const custom_provider = "custom";

pub const SyncSummary = struct {
    mirrored_threads: usize = 0,
};

const SyncThread = struct {
    id: []u8,
    rollout_path: []u8,
    source: []u8,
    model_provider: []u8,
    cwd: []u8,
    title: []u8,
    first_user_message: []u8,
    archived: bool,
    created_at_ms: i64,
    updated_at_ms: i64,

    fn deinit(self: *SyncThread, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.rollout_path);
        allocator.free(self.source);
        allocator.free(self.model_provider);
        allocator.free(self.cwd);
        allocator.free(self.title);
        allocator.free(self.first_user_message);
    }
};

const SqliteQueryError = error{CommandFailed};

pub fn ensureDualProviderHistory(allocator: std.mem.Allocator, codex_home: []const u8) !SyncSummary {
    var summary: SyncSummary = .{};
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "state_5.sqlite" });
    defer allocator.free(db_path);

    std.fs.cwd().access(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return summary,
        else => return err,
    };

    var thread_columns = loadThreadColumns(allocator, db_path) catch |err| switch (err) {
        error.FileNotFound, error.CommandFailed => return summary,
        else => {
            std.log.warn("history sync skipped while loading columns: {s}", .{@errorName(err)});
            return summary;
        },
    };
    defer thread_columns.deinit(allocator);
    defer freeOwnedStrings(allocator, thread_columns.items);

    if (thread_columns.items.len == 0) return summary;

    var threads = loadThreads(allocator, db_path) catch |err| switch (err) {
        error.FileNotFound, error.CommandFailed => return summary,
        else => {
            std.log.warn("history sync skipped while loading threads: {s}", .{@errorName(err)});
            return summary;
        },
    };
    defer {
        for (threads.items) |*thread| thread.deinit(allocator);
        threads.deinit(allocator);
    }

    var known_threads = std.StringHashMap(void).init(allocator);
    defer {
        var it = known_threads.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        known_threads.deinit();
    }

    var known_thread_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = known_thread_ids.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        known_thread_ids.deinit();
    }

    for (threads.items) |thread| {
        const key = try buildMatchKey(allocator, thread.model_provider, thread);
        const entry = try known_threads.getOrPut(key);
        if (entry.found_existing) {
            allocator.free(key);
        }

        const thread_id = try allocator.dupe(u8, thread.id);
        const id_entry = try known_thread_ids.getOrPut(thread_id);
        if (id_entry.found_existing) {
            allocator.free(thread_id);
        }
    }

    const session_index_path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "session_index.jsonl" });
    defer allocator.free(session_index_path);

    for (threads.items) |*thread| {
        const target_provider = mirrorProvider(thread.model_provider) orelse continue;
        const mirrored_id = try deterministicMirrorThreadId(allocator, thread.id, target_provider);
        defer allocator.free(mirrored_id);
        if (known_thread_ids.contains(mirrored_id)) continue;

        const target_key = try buildMatchKey(allocator, target_provider, thread.*);
        defer allocator.free(target_key);
        if (known_threads.contains(target_key)) continue;

        syncSingleThread(
            allocator,
            db_path,
            session_index_path,
            thread_columns.items,
            thread,
            target_provider,
        ) catch |err| {
            std.log.warn("history sync skipped thread {s}: {s}", .{ thread.id, @errorName(err) });
            continue;
        };

        const owned_key = try allocator.dupe(u8, target_key);
        const entry = try known_threads.getOrPut(owned_key);
        if (entry.found_existing) allocator.free(owned_key);

        const owned_id = try allocator.dupe(u8, mirrored_id);
        const id_entry = try known_thread_ids.getOrPut(owned_id);
        if (id_entry.found_existing) allocator.free(owned_id);
        summary.mirrored_threads += 1;
    }
    return summary;
}

fn syncSingleThread(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    session_index_path: []const u8,
    thread_columns: []const []const u8,
    source_thread: *const SyncThread,
    target_provider: []const u8,
) !void {
    const new_id = try deterministicMirrorThreadId(allocator, source_thread.id, target_provider);
    defer allocator.free(new_id);

    const new_rollout_path = try buildMirroredRolloutPath(allocator, source_thread.rollout_path, new_id);
    defer allocator.free(new_rollout_path);

    try cloneRolloutWithMirroredMeta(
        allocator,
        source_thread.rollout_path,
        new_rollout_path,
        new_id,
        target_provider,
    );
    try insertMirroredThread(
        allocator,
        db_path,
        thread_columns,
        source_thread.id,
        new_id,
        new_rollout_path,
        target_provider,
    );
    try appendSessionIndexEntry(
        allocator,
        session_index_path,
        new_id,
        source_thread.title,
        source_thread.updated_at_ms,
    );
}

fn mirrorProvider(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, openai_provider)) return custom_provider;
    if (std.mem.eql(u8, provider, custom_provider)) return openai_provider;
    return null;
}

fn loadThreadColumns(allocator: std.mem.Allocator, db_path: []const u8) !std.ArrayList([]u8) {
    const sql =
        \\SELECT json_object('name', name)
        \\FROM pragma_table_info('threads')
        \\ORDER BY cid;
    ;
    const result = try runSqliteCapture(allocator, db_path, sql);
    defer freeRunResult(allocator, result);
    try expectSqliteSuccess(result);

    var columns = std.ArrayList([]u8).empty;
    errdefer {
        freeOwnedStrings(allocator, columns.items);
        columns.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const name_value = obj.get("name") orelse continue;
        switch (name_value) {
            .string => |text| try columns.append(allocator, try allocator.dupe(u8, text)),
            else => continue,
        }
    }

    return columns;
}

fn loadThreads(allocator: std.mem.Allocator, db_path: []const u8) !std.ArrayList(SyncThread) {
    const sql =
        \\SELECT json_object(
        \\  'id', id,
        \\  'rollout_path', rollout_path,
        \\  'source', source,
        \\  'model_provider', model_provider,
        \\  'cwd', cwd,
        \\  'title', title,
        \\  'first_user_message', first_user_message,
        \\  'archived', archived,
        \\  'created_at_ms', created_at_ms,
        \\  'updated_at_ms', updated_at_ms
        \\)
        \\FROM threads;
    ;
    const result = try runSqliteCapture(allocator, db_path, sql);
    defer freeRunResult(allocator, result);
    try expectSqliteSuccess(result);

    var threads = std.ArrayList(SyncThread).empty;
    errdefer {
        for (threads.items) |*thread| thread.deinit(allocator);
        threads.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        try threads.append(allocator, try parseThreadJson(allocator, trimmed));
    }

    return threads;
}

fn parseThreadJson(allocator: std.mem.Allocator, line: []const u8) !SyncThread {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJson,
    };

    return .{
        .id = try dupJsonString(allocator, obj.get("id")),
        .rollout_path = try dupJsonString(allocator, obj.get("rollout_path")),
        .source = try dupOptionalJsonString(allocator, obj.get("source")),
        .model_provider = try dupJsonString(allocator, obj.get("model_provider")),
        .cwd = try dupOptionalJsonString(allocator, obj.get("cwd")),
        .title = try dupOptionalJsonString(allocator, obj.get("title")),
        .first_user_message = try dupOptionalJsonString(allocator, obj.get("first_user_message")),
        .archived = jsonBoolish(obj.get("archived")),
        .created_at_ms = jsonIntegerOrZero(obj.get("created_at_ms")),
        .updated_at_ms = jsonIntegerOrZero(obj.get("updated_at_ms")),
    };
}

fn dupJsonString(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const json_value = value orelse return error.MissingField;
    return switch (json_value) {
        .string => |text| allocator.dupe(u8, text),
        else => error.InvalidField,
    };
}

fn dupOptionalJsonString(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const json_value = value orelse return allocator.dupe(u8, "");
    return switch (json_value) {
        .string => |text| allocator.dupe(u8, text),
        .null => allocator.dupe(u8, ""),
        else => allocator.dupe(u8, ""),
    };
}

fn jsonBoolish(value: ?std.json.Value) bool {
    const json_value = value orelse return false;
    return switch (json_value) {
        .bool => |v| v,
        .integer => |v| v != 0,
        else => false,
    };
}

fn jsonIntegerOrZero(value: ?std.json.Value) i64 {
    const json_value = value orelse return 0;
    return switch (json_value) {
        .integer => |v| @intCast(v),
        else => 0,
    };
}

fn buildMatchKey(allocator: std.mem.Allocator, provider: []const u8, thread: SyncThread) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{d}\x1f{d}\x1f{d}",
        .{
            provider,
            thread.cwd,
            thread.title,
            thread.source,
            thread.first_user_message,
            if (thread.archived) @as(u8, 1) else @as(u8, 0),
            thread.created_at_ms,
            thread.updated_at_ms,
        },
    );
}

fn deterministicMirrorThreadId(allocator: std.mem.Allocator, source_id: []const u8, target_provider: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source_id);
    hasher.update("|");
    hasher.update(target_provider);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    digest[6] = (digest[6] & 0x0f) | 0x40;
    digest[8] = (digest[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}",
        .{
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9],
            digest[10], digest[11],
            digest[12], digest[13],
            digest[14], digest[15], digest[16], digest[17], digest[18], digest[19],
        },
    );
}

fn buildMirroredRolloutPath(allocator: std.mem.Allocator, rollout_path: []const u8, new_id: []const u8) ![]u8 {
    const dir_name = std.fs.path.dirname(rollout_path) orelse return error.InvalidRolloutPath;
    const base_name = std.fs.path.basename(rollout_path);
    const extension = std.fs.path.extension(base_name);
    const new_file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ new_id, extension });
    defer allocator.free(new_file_name);
    return try std.fs.path.join(allocator, &[_][]const u8{ dir_name, new_file_name });
}

fn cloneRolloutWithMirroredMeta(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    new_id: []const u8,
    target_provider: []const u8,
) !void {
    const data = try std.fs.cwd().readFileAlloc(allocator, source_path, rollout_read_limit_bytes);
    defer allocator.free(data);

    const first_line_end = std.mem.indexOfScalar(u8, data, '\n');
    const first_line = if (first_line_end) |idx| data[0..idx] else data;
    const rest = if (first_line_end) |idx| data[idx + 1 ..] else "";

    const new_first_line = try rewriteRolloutSessionMetaLine(allocator, first_line, new_id, target_provider);
    defer allocator.free(new_first_line);

    const parent = std.fs.path.dirname(dest_path) orelse return error.InvalidRolloutPath;
    try std.fs.cwd().makePath(parent);

    var out = try std.fs.cwd().createFile(dest_path, .{});
    defer out.close();

    try out.writeAll(new_first_line);
    if (first_line_end != null) {
        try out.writeAll("\n");
        try out.writeAll(rest);
    }
}

fn rewriteRolloutSessionMetaLine(
    allocator: std.mem.Allocator,
    first_line: []const u8,
    new_id: []const u8,
    target_provider: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, first_line, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |*root| {
            const payload_value = root.getPtr("payload") orelse return error.MissingPayload;
            switch (payload_value.*) {
                .object => |*payload| {
                    try payload.put("id", .{ .string = new_id });
                    try payload.put("model_provider", .{ .string = target_provider });
                },
                else => return error.InvalidPayload,
            }
        },
        else => return error.InvalidJson,
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &aw.writer);
    return try allocator.dupe(u8, aw.written());
}

fn insertMirroredThread(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    columns: []const []const u8,
    source_id: []const u8,
    new_id: []const u8,
    new_rollout_path: []const u8,
    target_provider: []const u8,
) !void {
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);

    try sql.appendSlice(allocator, "INSERT INTO threads (");
    for (columns, 0..) |column, idx| {
        if (idx != 0) try sql.appendSlice(allocator, ", ");
        try appendSqlIdentifier(&sql, allocator, column);
    }
    try sql.appendSlice(allocator, ") SELECT ");
    for (columns, 0..) |column, idx| {
        if (idx != 0) try sql.appendSlice(allocator, ", ");
        if (std.mem.eql(u8, column, "id")) {
            try appendSqlStringLiteral(&sql, allocator, new_id);
        } else if (std.mem.eql(u8, column, "rollout_path")) {
            try appendSqlStringLiteral(&sql, allocator, new_rollout_path);
        } else if (std.mem.eql(u8, column, "model_provider")) {
            try appendSqlStringLiteral(&sql, allocator, target_provider);
        } else {
            try appendSqlIdentifier(&sql, allocator, column);
        }
    }
    try sql.appendSlice(allocator, " FROM threads WHERE id = ");
    try appendSqlStringLiteral(&sql, allocator, source_id);
    try sql.appendSlice(allocator, ";");

    const result = try runSqliteCapture(allocator, db_path, sql.items);
    defer freeRunResult(allocator, result);
    try expectSqliteSuccess(result);
}

fn appendSessionIndexEntry(
    allocator: std.mem.Allocator,
    session_index_path: []const u8,
    thread_id: []const u8,
    title: []const u8,
    updated_at_ms: i64,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(.{
        .id = thread_id,
        .title = title,
        .updated_at_ms = updated_at_ms,
    }, .{}, &aw.writer);

    var file = std.fs.cwd().openFile(session_index_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(session_index_path, .{}),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(aw.written());
    try file.writeAll("\n");
}

fn appendSqlIdentifier(sql: *std.ArrayList(u8), allocator: std.mem.Allocator, ident: []const u8) !void {
    try sql.append(allocator, '"');
    for (ident) |ch| {
        if (ch == '"') try sql.append(allocator, '"');
        try sql.append(allocator, ch);
    }
    try sql.append(allocator, '"');
}

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
        .max_output_bytes = sqlite3_max_output_bytes,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
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
    return SqliteQueryError.CommandFailed;
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.Child.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []u8) void {
    for (items) |item| allocator.free(item);
}
