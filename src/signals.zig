//! Signal handling for graceful shutdown.
//!
//! Handles SIGINT (Ctrl+C) and SIGTERM for clean termination.

const std = @import("std");

/// Global interrupt flag (use atomic operations)
var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Current issue being worked on (for cleanup messages)
var current_issue: ?[]const u8 = null;

/// Colors for terminal output
const Color = struct {
    const reset = "\x1b[0m";
    const yellow = "\x1b[1;33m";
};

/// Check if we've been interrupted
pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Set the current issue (for cleanup messages)
pub fn setCurrentIssue(issue: ?[]const u8) void {
    current_issue = issue;
}

/// Signal handler function
fn handleSignal(sig: i32) callconv(.c) void {
    _ = sig;
    interrupted.store(true, .release);

    // Print cleanup message to stderr (signal-safe via write syscall)
    const msg1 = "\n" ++ Color.yellow ++ "[INTERRUPTED]" ++ Color.reset ++ " Caught signal, cleaning up...\n";
    _ = std.posix.write(std.posix.STDERR_FILENO, msg1) catch {};

    if (current_issue) |issue| {
        const msg2 = Color.yellow ++ "[INTERRUPTED]" ++ Color.reset ++ " Issue ";
        _ = std.posix.write(std.posix.STDERR_FILENO, msg2) catch {};
        _ = std.posix.write(std.posix.STDERR_FILENO, issue) catch {};
        const msg3 = " was NOT completed\n";
        _ = std.posix.write(std.posix.STDERR_FILENO, msg3) catch {};

        const msg4 = Color.yellow ++ "[INTERRUPTED]" ++ Color.reset ++ " Issue status left as-is (check with: bd show ";
        _ = std.posix.write(std.posix.STDERR_FILENO, msg4) catch {};
        _ = std.posix.write(std.posix.STDERR_FILENO, issue) catch {};
        const msg5 = ")\n";
        _ = std.posix.write(std.posix.STDERR_FILENO, msg5) catch {};
    }
}

/// Install signal handlers for SIGINT and SIGTERM
pub fn install() void {
    const sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = @as(std.posix.sigset_t, 0),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigint_action, null);
}

/// Reset signal handlers to default
pub fn reset() void {
    const default_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = @as(std.posix.sigset_t, 0),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &default_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &default_action, null);
}

test "signal module compiles" {
    // Just verify the module compiles
    try std.testing.expect(!isInterrupted());
}
