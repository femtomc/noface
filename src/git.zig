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

    // === Worktree Operations ===

    /// Create a new worktree for a worker
    /// Returns the absolute path to the created worktree
    /// The worktree is created in detached HEAD state from the current HEAD
    pub fn createWorktree(self: *GitRepo, worker_id: u32) ![]const u8 {
        const worktree_path = try std.fmt.allocPrint(self.allocator, ".noface-worker-{d}", .{worker_id});
        errdefer self.allocator.free(worktree_path);

        // Create worktree in detached HEAD state (no branch)
        // Using --detach avoids branch name conflicts between workers
        const cmd = try std.fmt.allocPrint(self.allocator, "git worktree add \"{s}\" --detach 2>&1", .{worktree_path});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success()) {
            // Check if worktree already exists (from crash recovery)
            if (std.mem.indexOf(u8, result.stderr, "already exists") != null or
                std.mem.indexOf(u8, result.stdout, "already exists") != null)
            {
                // Worktree exists, try to reuse it by resetting to HEAD
                const reset_cmd = try std.fmt.allocPrint(self.allocator, "git -C \"{s}\" reset --hard HEAD 2>&1", .{worktree_path});
                defer self.allocator.free(reset_cmd);
                var reset_result = try process.shell(self.allocator, reset_cmd);
                defer reset_result.deinit();
                // Return path even if reset fails - we'll try to use it
                return worktree_path;
            }
            self.allocator.free(worktree_path);
            return error.WorktreeCreationFailed;
        }

        return worktree_path;
    }

    /// Remove a worktree
    pub fn removeWorktree(self: *GitRepo, worktree_path: []const u8) !void {
        // First, try to remove cleanly
        const cmd = try std.fmt.allocPrint(self.allocator, "git worktree remove \"{s}\" --force 2>&1", .{worktree_path});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        // If that fails, try manual cleanup
        if (!result.success()) {
            // Remove directory manually
            const rm_cmd = try std.fmt.allocPrint(self.allocator, "rm -rf \"{s}\" 2>&1", .{worktree_path});
            defer self.allocator.free(rm_cmd);
            var rm_result = try process.shell(self.allocator, rm_cmd);
            defer rm_result.deinit();

            // Prune worktree references
            var prune_result = try process.shell(self.allocator, "git worktree prune 2>&1");
            defer prune_result.deinit();
        }
    }

    /// List all worktrees (for cleanup/recovery)
    /// Returns list of worktree paths (excluding main worktree)
    pub fn listWorktrees(self: *GitRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "git worktree list --porcelain");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        var paths = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        // Parse porcelain output: "worktree <path>" lines
        var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        var is_first = true;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "worktree ")) {
                const path = line["worktree ".len..];
                // Skip the main worktree (first one listed)
                if (is_first) {
                    is_first = false;
                    continue;
                }
                try paths.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        }

        return paths.toOwnedSlice(self.allocator);
    }

    /// Clean up orphaned noface worktrees (from crashes)
    /// Removes any worktrees matching .noface-worker-* pattern
    pub fn cleanupOrphanedWorktrees(self: *GitRepo) !u32 {
        const worktrees = try self.listWorktrees();
        defer {
            for (worktrees) |w| self.allocator.free(w);
            if (worktrees.len > 0) self.allocator.free(worktrees);
        }

        var cleaned: u32 = 0;
        for (worktrees) |worktree| {
            // Check if this is a noface worker worktree
            if (std.mem.indexOf(u8, worktree, ".noface-worker-") != null) {
                self.removeWorktree(worktree) catch {};
                cleaned += 1;
            }
        }

        return cleaned;
    }

    /// Get changes in a worktree relative to main
    /// Returns list of modified files
    pub fn getWorktreeChanges(self: *GitRepo, worktree_path: []const u8) ![]const []const u8 {
        // Get diff between worktree HEAD and main HEAD
        const cmd = try std.fmt.allocPrint(self.allocator, "git -C \"{s}\" diff --name-only HEAD", .{worktree_path});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseFileList(self.allocator, result.stdout);
    }

    /// Stage all changes in a worktree
    pub fn stageAllInWorktree(self: *GitRepo, worktree_path: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "git -C \"{s}\" add -A", .{worktree_path});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();
    }

    /// Commit changes in a worktree
    pub fn commitInWorktree(self: *GitRepo, worktree_path: []const u8, message: []const u8) !bool {
        // Stage all changes first
        try self.stageAllInWorktree(worktree_path);

        const cmd = try std.fmt.allocPrint(self.allocator, "git -C \"{s}\" commit -m \"{s}\" 2>&1", .{ worktree_path, message });
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        // Check if there was nothing to commit
        if (std.mem.indexOf(u8, result.stdout, "nothing to commit") != null) {
            return false;
        }

        return result.success();
    }

    /// Cherry-pick commits from worktree into main working directory
    /// Returns true if successful, false if there were conflicts
    pub fn cherryPickFromWorktree(self: *GitRepo, worktree_path: []const u8) !bool {
        // Get the HEAD commit of the worktree
        const head_cmd = try std.fmt.allocPrint(self.allocator, "git -C \"{s}\" rev-parse HEAD", .{worktree_path});
        defer self.allocator.free(head_cmd);

        var head_result = try process.shell(self.allocator, head_cmd);
        defer head_result.deinit();

        if (!head_result.success()) {
            return error.WorktreeHeadNotFound;
        }

        const commit_sha = std.mem.trim(u8, head_result.stdout, " \t\r\n");
        if (commit_sha.len == 0) {
            return error.WorktreeHeadNotFound;
        }

        // Cherry-pick the commit into main worktree
        const pick_cmd = try std.fmt.allocPrint(self.allocator, "git cherry-pick {s} --no-commit 2>&1", .{commit_sha});
        defer self.allocator.free(pick_cmd);

        var pick_result = try process.shell(self.allocator, pick_cmd);
        defer pick_result.deinit();

        // Check for conflicts
        if (std.mem.indexOf(u8, pick_result.stdout, "CONFLICT") != null or
            std.mem.indexOf(u8, pick_result.stderr, "CONFLICT") != null)
        {
            // Abort the cherry-pick
            var abort_result = try process.shell(self.allocator, "git cherry-pick --abort 2>&1");
            defer abort_result.deinit();
            return false;
        }

        return pick_result.success();
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
