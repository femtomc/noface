//! Process execution utilities for running external commands.

const std = @import("std");

/// Result of running a command
pub const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn success(self: CommandResult) bool {
        return self.exit_code == 0;
    }
};

/// Run a command and capture output
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read all output BEFORE waiting (pipes close after wait)
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);

    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout_file.read(&buf) catch break;
            if (n == 0) break;
            try stdout_list.appendSlice(allocator, buf[0..n]);
        }
    }

    if (child.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr_file.read(&buf) catch break;
            if (n == 0) break;
            try stderr_list.appendSlice(allocator, buf[0..n]);
        }
    }

    // Now wait for process to exit
    const result = try child.wait();

    return .{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
        .exit_code = switch (result) {
            .Exited => |code| code,
            else => 1,
        },
        .allocator = allocator,
    };
}

/// Run a shell command (via /bin/sh -c)
pub fn shell(allocator: std.mem.Allocator, command: []const u8) !CommandResult {
    return run(allocator, &.{ "/bin/sh", "-c", command });
}

/// Spawn a process with streaming output (for agent execution)
pub const StreamingProcess = struct {
    child: std.process.Child,
    read_buf: [4096]u8 = undefined,

    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8) !StreamingProcess {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        return .{
            .child = child,
        };
    }

    /// Read a line from stdout (blocking)
    pub fn readLine(self: *StreamingProcess, buf: []u8) !?[]const u8 {
        if (self.child.stdout) |stdout_file| {
            var i: usize = 0;
            while (i < buf.len) {
                var read_buf: [1]u8 = undefined;
                const n = stdout_file.read(&read_buf) catch |err| {
                    if (i == 0) return null;
                    return err;
                };
                if (n == 0) {
                    if (i == 0) return null;
                    return buf[0..i];
                }
                const byte = read_buf[0];
                if (byte == '\n') {
                    return buf[0..i];
                }
                buf[i] = byte;
                i += 1;
            }
            return buf[0..i];
        }
        return null;
    }

    /// Wait for process to complete
    pub fn wait(self: *StreamingProcess) !u8 {
        const result = try self.child.wait();
        return switch (result) {
            .Exited => |code| code,
            else => 1,
        };
    }

    pub fn kill(self: *StreamingProcess) void {
        _ = self.child.kill() catch {};
    }
};

/// Check if a command exists in PATH
pub fn commandExists(allocator: std.mem.Allocator, command: []const u8) bool {
    var result = run(allocator, &.{ "which", command }) catch return false;
    defer result.deinit();
    return result.success();
}

test "shell command" {
    var result = try shell(std.testing.allocator, "echo hello");
    defer result.deinit();

    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expect(result.success());
}

test "command exists" {
    try std.testing.expect(commandExists(std.testing.allocator, "ls"));
    try std.testing.expect(!commandExists(std.testing.allocator, "nonexistent_command_xyz"));
}
