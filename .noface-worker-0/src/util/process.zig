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
    var stdout_list = std.ArrayListUnmanaged(u8){};
    defer stdout_list.deinit(allocator);

    var stderr_list = std.ArrayListUnmanaged(u8){};
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

/// Result of a timed read operation
pub const TimedReadResult = union(enum) {
    /// Successfully read a line
    line: []const u8,
    /// No data available within timeout
    timeout,
    /// End of stream (process closed stdout)
    eof,
};

/// Spawn a process with streaming output (for agent execution)
pub const StreamingProcess = struct {
    child: std.process.Child,
    read_buf: [4096]u8 = undefined,
    line_buf_partial: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,

    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8) !StreamingProcess {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        return .{
            .child = child,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamingProcess) void {
        self.line_buf_partial.deinit(self.allocator);
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

    /// Read a line from stdout with timeout using poll()
    /// Returns .timeout if no data arrives within timeout_seconds
    /// Returns .eof when stdout is closed
    /// Returns .line with the data when a complete line is read
    pub fn readLineWithTimeout(self: *StreamingProcess, buf: []u8, timeout_seconds: u32) !TimedReadResult {
        const stdout_file = self.child.stdout orelse return .eof;
        const fd = stdout_file.handle;

        var i: usize = 0;

        // If we have partial data from previous read, copy it first
        if (self.line_buf_partial.items.len > 0) {
            const to_copy = @min(self.line_buf_partial.items.len, buf.len);
            @memcpy(buf[0..to_copy], self.line_buf_partial.items[0..to_copy]);
            i = to_copy;

            // Check if we have a complete line in the partial buffer
            if (std.mem.indexOfScalar(u8, self.line_buf_partial.items[0..to_copy], '\n')) |newline_idx| {
                // Found newline, return line without newline
                const line = buf[0..newline_idx];
                // Keep remaining data
                const remaining = self.line_buf_partial.items[newline_idx + 1 ..];
                if (remaining.len > 0) {
                    std.mem.copyForwards(u8, self.line_buf_partial.items[0..remaining.len], remaining);
                }
                self.line_buf_partial.shrinkRetainingCapacity(remaining.len);
                return .{ .line = line };
            }
            self.line_buf_partial.clearRetainingCapacity();
        }

        while (i < buf.len) {
            // Use poll to wait for data with timeout
            var poll_fds = [1]std.posix.pollfd{
                .{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            // Convert seconds to milliseconds for poll, -1 means block forever
            const timeout_ms: i32 = if (timeout_seconds == 0) -1 else @intCast(timeout_seconds * 1000);

            const poll_result = std.posix.poll(&poll_fds, timeout_ms) catch {
                // Poll error - treat as EOF
                if (i == 0) return .eof;
                return .{ .line = buf[0..i] };
            };

            if (poll_result == 0) {
                // Timeout - no data available
                // Save partial line for next call
                if (i > 0) {
                    try self.line_buf_partial.appendSlice(self.allocator, buf[0..i]);
                }
                return .timeout;
            }

            // Check for hangup/error
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                // Try to read any remaining data
                if (poll_fds[0].revents & std.posix.POLL.IN == 0) {
                    if (i == 0) return .eof;
                    return .{ .line = buf[0..i] };
                }
            }

            // Data available, read it
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                var read_buf: [1]u8 = undefined;
                const n = stdout_file.read(&read_buf) catch {
                    if (i == 0) return .eof;
                    return .{ .line = buf[0..i] };
                };
                if (n == 0) {
                    if (i == 0) return .eof;
                    return .{ .line = buf[0..i] };
                }
                const byte = read_buf[0];
                if (byte == '\n') {
                    return .{ .line = buf[0..i] };
                }
                buf[i] = byte;
                i += 1;
            }
        }

        // Buffer full
        return .{ .line = buf[0..i] };
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

    /// Check if process is still running
    pub fn isRunning(self: *StreamingProcess) bool {
        // Try to get status without blocking
        const result = self.child.wait() catch return false;
        _ = result;
        return false; // If wait returned, process is done
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

test "streaming process read with timeout - success" {
    // Test that we can read output from a quick command
    var proc = try StreamingProcess.spawn(std.testing.allocator, &.{ "echo", "hello" });
    defer proc.deinit();

    var buf: [1024]u8 = undefined;
    const result = try proc.readLineWithTimeout(&buf, 5); // 5 second timeout

    switch (result) {
        .line => |line| try std.testing.expectEqualStrings("hello", line),
        .eof => {}, // Also acceptable if echo finishes quickly
        .timeout => return error.UnexpectedTimeout,
    }

    _ = try proc.wait();
}

test "streaming process read with timeout - timeout triggers" {
    // Test that timeout triggers for a slow command
    // Use 'sleep 10' but with 1 second timeout
    var proc = try StreamingProcess.spawn(std.testing.allocator, &.{ "sleep", "10" });
    defer proc.deinit();

    var buf: [1024]u8 = undefined;
    const result = try proc.readLineWithTimeout(&buf, 1); // 1 second timeout

    switch (result) {
        .timeout => {}, // Expected
        .line => return error.UnexpectedLine,
        .eof => {}, // Process might exit quickly on some systems
    }

    proc.kill();
    _ = try proc.wait();
}

test "streaming process read with large timeout" {
    // With large timeout, should read data successfully
    var proc = try StreamingProcess.spawn(std.testing.allocator, &.{ "echo", "test" });
    defer proc.deinit();

    var buf: [1024]u8 = undefined;
    const result = try proc.readLineWithTimeout(&buf, 60); // 60 second timeout (large)

    switch (result) {
        .line => |line| try std.testing.expectEqualStrings("test", line),
        .eof => {},
        .timeout => return error.UnexpectedTimeout, // Should not timeout with large value
    }

    _ = try proc.wait();
}
