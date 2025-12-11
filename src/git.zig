//! Git repository operations.
//!
//! Provides a clean interface for git operations used by the orchestrator.

const std = @import("std");
const process = @import("process.zig");

/// Result of getting all changed files
pub const ChangedFiles = struct {
    modified: []const []const u8,
    staged: []const []const u8,
    untracked: []const []const u8,
    allocator: std.mem.Allocator,

    /// Get all changed files combined (caller must NOT free the result)
    pub fn all(self: *const ChangedFiles, allocator: std.mem.Allocator) ![]const []const u8 {
        var result = std.ArrayListUnmanaged([]const u8){};
        errdefer result.deinit(allocator);

        // Add modified files
        for (self.modified) |f| {
            try result.append(allocator, f);
        }

        // Add staged files (avoiding duplicates)
        for (self.staged) |f| {
            var found = false;
            for (result.items) |existing| {
                if (std.mem.eql(u8, existing, f)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.append(allocator, f);
            }
        }

        // Add untracked files (avoiding duplicates)
        for (self.untracked) |f| {
            var found = false;
            for (result.items) |existing| {
                if (std.mem.eql(u8, existing, f)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.append(allocator, f);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ChangedFiles) void {
        for (self.modified) |f| self.allocator.free(f);
        if (self.modified.len > 0) self.allocator.free(self.modified);

        for (self.staged) |f| self.allocator.free(f);
        if (self.staged.len > 0) self.allocator.free(self.staged);

        for (self.untracked) |f| self.allocator.free(f);
        if (self.untracked.len > 0) self.allocator.free(self.untracked);
    }
};

/// Git repository operations interface
pub const GitRepo = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitRepo {
        return .{ .allocator = allocator };
    }

    /// Get list of modified files (unstaged changes compared to HEAD)
    pub fn getModifiedFiles(self: *GitRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "git diff --name-only HEAD");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseFileList(self.allocator, result.stdout);
    }

    /// Get list of staged files (changes in the index)
    pub fn getStagedFiles(self: *GitRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "git diff --name-only --cached");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseFileList(self.allocator, result.stdout);
    }

    /// Get list of untracked files
    pub fn getUntrackedFiles(self: *GitRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "git ls-files --others --exclude-standard");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseFileList(self.allocator, result.stdout);
    }

    /// Get all changed files (modified + staged + untracked)
    pub fn getAllChangedFiles(self: *GitRepo) !ChangedFiles {
        return .{
            .modified = try self.getModifiedFiles(),
            .staged = try self.getStagedFiles(),
            .untracked = try self.getUntrackedFiles(),
            .allocator = self.allocator,
        };
    }

    /// Unstage a file (git reset HEAD -- file)
    pub fn unstageFile(self: *GitRepo, file: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "git reset HEAD -- \"{s}\"", .{file});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();
        // Ignore result - file might not be staged
    }

    /// Checkout a file to HEAD state (discard changes for tracked files)
    pub fn checkoutHead(self: *GitRepo, file: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "git checkout HEAD -- \"{s}\" 2>/dev/null || true", .{file});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();
        // Ignore result - file might be untracked
    }

    /// Remove an untracked file (git clean -f -- file)
    pub fn cleanFile(self: *GitRepo, file: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "git clean -f -- \"{s}\" 2>/dev/null || true", .{file});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();
        // Ignore result - file might be tracked
    }

    /// Rollback a file to HEAD state (unstage, checkout, and clean)
    pub fn rollbackFile(self: *GitRepo, file: []const u8) !void {
        try self.unstageFile(file);
        try self.checkoutHead(file);
        try self.cleanFile(file);
    }

    /// Check if working directory is clean
    pub fn isClean(self: *GitRepo) !bool {
        var result = try process.shell(self.allocator, "git status --porcelain");
        defer result.deinit();

        if (!result.success()) {
            // Not a git repo or other error - treat as clean
            return true;
        }

        // If output is empty, working directory is clean
        return std.mem.trim(u8, result.stdout, " \t\r\n").len == 0;
    }

    /// Free a file list returned by getModifiedFiles, getStagedFiles, or getUntrackedFiles
    pub fn freeFileList(self: *GitRepo, files: []const []const u8) void {
        for (files) |f| self.allocator.free(f);
        if (files.len > 0) self.allocator.free(files);
    }
};

/// Parse newline-separated file list from git output
fn parseFileList(allocator: std.mem.Allocator, output: []const u8) ![]const []const u8 {
    var files = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try files.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    return files.toOwnedSlice(allocator);
}

test "parseFileList parses empty output" {
    const allocator = std.testing.allocator;
    const files = try parseFileList(allocator, "");
    defer {
        for (files) |f| allocator.free(f);
        if (files.len > 0) allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "parseFileList parses single file" {
    const allocator = std.testing.allocator;
    const files = try parseFileList(allocator, "src/main.zig\n");
    defer {
        for (files) |f| allocator.free(f);
        if (files.len > 0) allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0]);
}

test "parseFileList parses multiple files" {
    const allocator = std.testing.allocator;
    const files = try parseFileList(allocator, "src/main.zig\nsrc/loop.zig\nsrc/git.zig\n");
    defer {
        for (files) |f| allocator.free(f);
        if (files.len > 0) allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0]);
    try std.testing.expectEqualStrings("src/loop.zig", files[1]);
    try std.testing.expectEqualStrings("src/git.zig", files[2]);
}

test "parseFileList handles whitespace" {
    const allocator = std.testing.allocator;
    const files = try parseFileList(allocator, "  src/main.zig  \n\n  src/loop.zig\t\n");
    defer {
        for (files) |f| allocator.free(f);
        if (files.len > 0) allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0]);
    try std.testing.expectEqualStrings("src/loop.zig", files[1]);
}

test "ChangedFiles.all combines without duplicates" {
    const allocator = std.testing.allocator;

    // Create test data
    var modified = std.ArrayListUnmanaged([]const u8){};
    try modified.append(allocator, try allocator.dupe(u8, "file1.zig"));
    try modified.append(allocator, try allocator.dupe(u8, "file2.zig"));

    var staged = std.ArrayListUnmanaged([]const u8){};
    try staged.append(allocator, try allocator.dupe(u8, "file2.zig")); // duplicate
    try staged.append(allocator, try allocator.dupe(u8, "file3.zig"));

    var untracked = std.ArrayListUnmanaged([]const u8){};
    try untracked.append(allocator, try allocator.dupe(u8, "file3.zig")); // duplicate
    try untracked.append(allocator, try allocator.dupe(u8, "file4.zig"));

    var changed = ChangedFiles{
        .modified = try modified.toOwnedSlice(allocator),
        .staged = try staged.toOwnedSlice(allocator),
        .untracked = try untracked.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer changed.deinit();

    const all_files = try changed.all(allocator);
    defer {
        // Only free the slice itself, not the contents (they're borrowed)
        allocator.free(all_files);
    }

    try std.testing.expectEqual(@as(usize, 4), all_files.len);
}
