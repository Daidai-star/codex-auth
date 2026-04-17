const std = @import("std");
const builtin = @import("builtin");

const use_new_io = builtin.zig_version.major > 0 or
    (builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16);
pub const File = if (use_new_io) std.Io.File else std.fs.File;
pub const FileWriter = if (use_new_io) std.Io.File.Writer else std.fs.File.Writer;

var runtime_io: ?std.Io = null;
var runtime_environ_map: if (use_new_io) ?*std.process.Environ.Map else void = if (use_new_io) null else {};

pub fn setRuntimeIo(io: anytype) void {
    if (use_new_io) runtime_io = io;
}

pub fn setRuntimeEnvironMap(environ_map: anytype) void {
    if (use_new_io) runtime_environ_map = environ_map;
}

fn currentIo() std.Io {
    return runtime_io orelse std.Io.failing;
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (use_new_io) {
        const environ_map = runtime_environ_map orelse return error.EnvironmentVariableNotFound;
        const value = environ_map.get(name) orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, value);
    }
    return std.process.getEnvVarOwned(allocator, name);
}

pub fn hasNonEmptyEnvVarConstant(comptime name: []const u8) bool {
    if (use_new_io) {
        const environ_map = runtime_environ_map orelse return false;
        const value = environ_map.get(name) orelse return false;
        return value.len > 0;
    }
    return std.process.hasNonEmptyEnvVarConstant(name);
}

pub fn stdoutFile() File {
    return if (use_new_io) std.Io.File.stdout() else std.fs.File.stdout();
}

pub fn stderrFile() File {
    return if (use_new_io) std.Io.File.stderr() else std.fs.File.stderr();
}

pub fn stdinFile() File {
    return if (use_new_io) std.Io.File.stdin() else std.fs.File.stdin();
}

pub fn stdoutWriter(buffer: []u8) FileWriter {
    return if (use_new_io)
        stdoutFile().writer(currentIo(), buffer)
    else
        stdoutFile().writer(buffer);
}

pub fn stderrWriter(buffer: []u8) FileWriter {
    return if (use_new_io)
        stderrFile().writer(currentIo(), buffer)
    else
        stderrFile().writer(buffer);
}

pub fn stdoutIsTty() bool {
    return if (use_new_io)
        stdoutFile().isTty(currentIo()) catch false
    else
        stdoutFile().isTty();
}

pub fn stderrIsTty() bool {
    return if (use_new_io)
        stderrFile().isTty(currentIo()) catch false
    else
        stderrFile().isTty();
}

pub fn stdinIsTty() bool {
    return if (use_new_io)
        stdinFile().isTty(currentIo()) catch false
    else
        stdinFile().isTty();
}

pub fn stdinRead(buffer: []u8) !usize {
    return if (use_new_io)
        stdinFile().readStreaming(currentIo(), &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        }
    else
        stdinFile().read(buffer);
}

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: FileWriter,

    pub fn init(self: *Stdout) void {
        self.writer = stdoutWriter(&self.buffer);
    }

    pub fn out(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};
