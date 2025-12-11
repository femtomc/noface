//! Jujutsu (jj) repository operations.
//!
//! Provides a clean interface for jj operations used by the orchestrator.
//! jj is a Git-compatible VCS with better support for parallel workspaces.

const std = @import("std");
const process = @import("process.zig");

/// Result of getting all changed files
/// Note: jj doesn't distinguish between staged/unstaged - all changes are tracked
pub const ChangedFiles = struct {
    modified: []const []const u8,
    added: []const []const u8,
    deleted: []const []const u8,
    allocator: std.mem.Allocator,

    /// Get all changed files combined (caller must NOT free the result)
    pub fn all(self: *const ChangedFiles, allocator: std.mem.Allocator) ![]const []const u8 {
        var result = std.ArrayListUnmanaged([]const u8){};
        errdefer result.deinit(allocator);

        // Add modified files
        for (self.modified) |f| {
            try result.append(allocator, f);
        }

        // Add added files (avoiding duplicates)
        for (self.added) |f| {
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

        // Add deleted files (avoiding duplicates)
        for (self.deleted) |f| {
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

        for (self.added) |f| self.allocator.free(f);
        if (self.added.len > 0) self.allocator.free(self.added);

        for (self.deleted) |f| self.allocator.free(f);
        if (self.deleted.len > 0) self.allocator.free(self.deleted);
    }
};

/// Jujutsu repository operations interface
pub const JjRepo = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JjRepo {
        return .{ .allocator = allocator };
    }

    /// Get list of modified files in the current working copy
    pub fn getModifiedFiles(self: *JjRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "jj diff --summary 2>/dev/null");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseDiffSummary(self.allocator, result.stdout, 'M');
    }

    /// Get list of added files in the current working copy
    pub fn getAddedFiles(self: *JjRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "jj diff --summary 2>/dev/null");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseDiffSummary(self.allocator, result.stdout, 'A');
    }

    /// Get list of deleted files in the current working copy
    pub fn getDeletedFiles(self: *JjRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "jj diff --summary 2>/dev/null");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        return try parseDiffSummary(self.allocator, result.stdout, 'D');
    }

    /// Get all changed files (modified + added + deleted)
    pub fn getAllChangedFiles(self: *JjRepo) !ChangedFiles {
        return .{
            .modified = try self.getModifiedFiles(),
            .added = try self.getAddedFiles(),
            .deleted = try self.getDeletedFiles(),
            .allocator = self.allocator,
        };
    }

    /// Restore a file to its state in the parent revision
    pub fn restoreFile(self: *JjRepo, file: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "jj restore \"{s}\" 2>/dev/null || true", .{file});
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();
    }

    /// Rollback a file to parent state
    pub fn rollbackFile(self: *JjRepo, file: []const u8) !void {
        try self.restoreFile(file);
    }

    /// Check if working directory is clean (no uncommitted changes)
    pub fn isClean(self: *JjRepo) !bool {
        var result = try process.shell(self.allocator, "jj diff --summary 2>/dev/null");
        defer result.deinit();

        if (!result.success()) {
            // Not a jj repo or other error - treat as clean
            return true;
        }

        // If output is empty, working directory is clean
        return std.mem.trim(u8, result.stdout, " \t\r\n").len == 0;
    }

    /// Free a file list returned by getModifiedFiles, etc.
    pub fn freeFileList(self: *JjRepo, files: []const []const u8) void {
        for (files) |f| self.allocator.free(f);
        if (files.len > 0) self.allocator.free(files);
    }

    // === Workspace Operations ===

    /// Create a new workspace for a worker
    /// Returns the path to the created workspace
    /// The workspace is created with a new working-copy commit based on current @
    pub fn createWorkspace(self: *JjRepo, worker_id: u32) ![]const u8 {
        const workspace_path = try std.fmt.allocPrint(self.allocator, ".noface-worker-{d}", .{worker_id});
        errdefer self.allocator.free(workspace_path);

        const workspace_name = try std.fmt.allocPrint(self.allocator, "worker-{d}", .{worker_id});
        defer self.allocator.free(workspace_name);

        // Create workspace with a new working-copy commit on top of current @-
        // Using --revision @- puts it on the same parent as current working copy
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "jj workspace add \"{s}\" --name \"{s}\" --revision @- 2>&1",
            .{ workspace_path, workspace_name },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success()) {
            // Check if workspace already exists (from crash recovery)
            if (std.mem.indexOf(u8, result.stderr, "already exists") != null or
                std.mem.indexOf(u8, result.stdout, "already exists") != null)
            {
                // Workspace exists, try to update it
                const update_cmd = try std.fmt.allocPrint(
                    self.allocator,
                    "jj --repository \"{s}\" workspace update-stale 2>&1",
                    .{workspace_path},
                );
                defer self.allocator.free(update_cmd);
                var update_result = try process.shell(self.allocator, update_cmd);
                defer update_result.deinit();
                return workspace_path;
            }
            self.allocator.free(workspace_path);
            return error.WorkspaceCreationFailed;
        }

        return workspace_path;
    }

    /// Remove a workspace
    pub fn removeWorkspace(self: *JjRepo, workspace_path: []const u8) !void {
        // Extract workspace name from path
        const basename = std.fs.path.basename(workspace_path);
        var workspace_name: []const u8 = undefined;

        // Convert .noface-worker-N to worker-N
        if (std.mem.startsWith(u8, basename, ".noface-worker-")) {
            workspace_name = try std.fmt.allocPrint(self.allocator, "worker-{s}", .{basename[".noface-worker-".len..]});
        } else {
            workspace_name = try self.allocator.dupe(u8, basename);
        }
        defer self.allocator.free(workspace_name);

        // Forget the workspace from jj's tracking
        const forget_cmd = try std.fmt.allocPrint(self.allocator, "jj workspace forget \"{s}\" 2>&1", .{workspace_name});
        defer self.allocator.free(forget_cmd);

        var forget_result = try process.shell(self.allocator, forget_cmd);
        defer forget_result.deinit();

        // Remove the directory
        const rm_cmd = try std.fmt.allocPrint(self.allocator, "rm -rf \"{s}\" 2>&1", .{workspace_path});
        defer self.allocator.free(rm_cmd);

        var rm_result = try process.shell(self.allocator, rm_cmd);
        defer rm_result.deinit();
    }

    /// List all workspaces (for cleanup/recovery)
    /// Returns list of workspace paths (excluding default workspace)
    pub fn listWorkspaces(self: *JjRepo) ![]const []const u8 {
        var result = try process.shell(self.allocator, "jj workspace list 2>/dev/null");
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        var paths = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        // Parse output: "name: commit_id" lines
        // We need to convert workspace names back to paths
        var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            // Skip the default workspace
            if (std.mem.startsWith(u8, line, "default:")) continue;

            // Extract workspace name (before the colon)
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const name = std.mem.trim(u8, line[0..colon_pos], " \t");
                // Convert worker-N to .noface-worker-N
                if (std.mem.startsWith(u8, name, "worker-")) {
                    const path = try std.fmt.allocPrint(self.allocator, ".noface-worker-{s}", .{name["worker-".len..]});
                    try paths.append(self.allocator, path);
                }
            }
        }

        return paths.toOwnedSlice(self.allocator);
    }

    /// Clean up orphaned noface workspaces (from crashes)
    /// Removes any workspaces matching worker-* pattern
    pub fn cleanupOrphanedWorkspaces(self: *JjRepo) !u32 {
        const workspaces = try self.listWorkspaces();
        defer {
            for (workspaces) |w| self.allocator.free(w);
            if (workspaces.len > 0) self.allocator.free(workspaces);
        }

        var cleaned: u32 = 0;
        for (workspaces) |workspace| {
            // All workspaces from listWorkspaces are noface worker workspaces
            self.removeWorkspace(workspace) catch {};
            cleaned += 1;
        }

        return cleaned;
    }

    /// Get changes in a workspace relative to its parent
    /// Returns list of modified files
    pub fn getWorkspaceChanges(self: *JjRepo, workspace_path: []const u8) ![]const []const u8 {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "jj --repository \"{s}\" diff --summary 2>/dev/null",
            .{workspace_path},
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success()) {
            return &[_][]const u8{};
        }

        // Parse all change types (M, A, D)
        return try parseAllChanges(self.allocator, result.stdout);
    }

    /// Commit changes in a workspace (creates a new revision with description)
    /// jj auto-snapshots, so this just describes the current working copy and creates a new one
    pub fn commitInWorkspace(self: *JjRepo, workspace_path: []const u8, message: []const u8) !bool {
        // Check if there are any changes first
        const changes = try self.getWorkspaceChanges(workspace_path);
        defer self.freeFileList(changes);

        if (changes.len == 0) {
            return false; // Nothing to commit
        }

        // Use jj commit to describe current change and create new working copy
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "jj --repository \"{s}\" commit -m \"{s}\" 2>&1",
            .{ workspace_path, message },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        return result.success();
    }

    /// Squash workspace changes into the main working copy
    /// This is the jj equivalent of cherry-pick
    /// Returns true if successful, false if there were conflicts
    pub fn squashFromWorkspace(self: *JjRepo, workspace_path: []const u8) !bool {
        // Extract workspace name
        const basename = std.fs.path.basename(workspace_path);
        var workspace_name: []const u8 = undefined;

        if (std.mem.startsWith(u8, basename, ".noface-worker-")) {
            workspace_name = try std.fmt.allocPrint(self.allocator, "worker-{s}", .{basename[".noface-worker-".len..]});
        } else {
            workspace_name = try self.allocator.dupe(u8, basename);
        }
        defer self.allocator.free(workspace_name);

        // Get the working copy commit of the workspace
        const log_cmd = try std.fmt.allocPrint(
            self.allocator,
            "jj --repository \"{s}\" log -r @ --no-graph -T 'change_id' 2>/dev/null",
            .{workspace_path},
        );
        defer self.allocator.free(log_cmd);

        var log_result = try process.shell(self.allocator, log_cmd);
        defer log_result.deinit();

        if (!log_result.success()) {
            return error.WorkspaceCommitNotFound;
        }

        const change_id = std.mem.trim(u8, log_result.stdout, " \t\r\n");
        if (change_id.len == 0) {
            return error.WorkspaceCommitNotFound;
        }

        // Squash the workspace's working copy into our working copy
        // This brings all changes from the workspace into main
        const squash_cmd = try std.fmt.allocPrint(
            self.allocator,
            "jj squash --from {s} --into @ 2>&1",
            .{change_id},
        );
        defer self.allocator.free(squash_cmd);

        var squash_result = try process.shell(self.allocator, squash_cmd);
        defer squash_result.deinit();

        // Check for conflicts
        if (std.mem.indexOf(u8, squash_result.stdout, "conflict") != null or
            std.mem.indexOf(u8, squash_result.stderr, "conflict") != null)
        {
            return false;
        }

        return squash_result.success();
    }
};

/// Parse jj diff --summary output for a specific change type
/// Format: "M path/to/file" or "A path/to/file" or "D path/to/file"
fn parseDiffSummary(allocator: std.mem.Allocator, output: []const u8, change_type: u8) ![]const []const u8 {
    var files = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 2) continue;

        // Check if line starts with the requested change type
        if (trimmed[0] == change_type and trimmed[1] == ' ') {
            const file_path = std.mem.trim(u8, trimmed[2..], " \t");
            if (file_path.len > 0) {
                try files.append(allocator, try allocator.dupe(u8, file_path));
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Parse jj diff --summary output for all change types
fn parseAllChanges(allocator: std.mem.Allocator, output: []const u8) ![]const []const u8 {
    var files = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 2) continue;

        // Check if line starts with a change type (M, A, D)
        if ((trimmed[0] == 'M' or trimmed[0] == 'A' or trimmed[0] == 'D') and trimmed[1] == ' ') {
            const file_path = std.mem.trim(u8, trimmed[2..], " \t");
            if (file_path.len > 0) {
                try files.append(allocator, try allocator.dupe(u8, file_path));
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

// === Tests ===

test "parseDiffSummary parses modified files" {
    const allocator = std.testing.allocator;
    const output = "M src/main.zig\nA src/new.zig\nD src/old.zig\n";

    const modified = try parseDiffSummary(allocator, output, 'M');
    defer {
        for (modified) |f| allocator.free(f);
        if (modified.len > 0) allocator.free(modified);
    }

    try std.testing.expectEqual(@as(usize, 1), modified.len);
    try std.testing.expectEqualStrings("src/main.zig", modified[0]);
}

test "parseDiffSummary parses added files" {
    const allocator = std.testing.allocator;
    const output = "M src/main.zig\nA src/new.zig\nD src/old.zig\n";

    const added = try parseDiffSummary(allocator, output, 'A');
    defer {
        for (added) |f| allocator.free(f);
        if (added.len > 0) allocator.free(added);
    }

    try std.testing.expectEqual(@as(usize, 1), added.len);
    try std.testing.expectEqualStrings("src/new.zig", added[0]);
}

test "parseAllChanges parses all change types" {
    const allocator = std.testing.allocator;
    const output = "M src/main.zig\nA src/new.zig\nD src/old.zig\n";

    const all = try parseAllChanges(allocator, output);
    defer {
        for (all) |f| allocator.free(f);
        if (all.len > 0) allocator.free(all);
    }

    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "parseDiffSummary handles empty output" {
    const allocator = std.testing.allocator;
    const files = try parseDiffSummary(allocator, "", 'M');
    defer {
        for (files) |f| allocator.free(f);
        if (files.len > 0) allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "ChangedFiles.all combines without duplicates" {
    const allocator = std.testing.allocator;

    // Create test data
    var modified = std.ArrayListUnmanaged([]const u8){};
    try modified.append(allocator, try allocator.dupe(u8, "file1.zig"));
    try modified.append(allocator, try allocator.dupe(u8, "file2.zig"));

    var added = std.ArrayListUnmanaged([]const u8){};
    try added.append(allocator, try allocator.dupe(u8, "file2.zig")); // duplicate
    try added.append(allocator, try allocator.dupe(u8, "file3.zig"));

    var deleted = std.ArrayListUnmanaged([]const u8){};
    try deleted.append(allocator, try allocator.dupe(u8, "file3.zig")); // duplicate
    try deleted.append(allocator, try allocator.dupe(u8, "file4.zig"));

    var changed = ChangedFiles{
        .modified = try modified.toOwnedSlice(allocator),
        .added = try added.toOwnedSlice(allocator),
        .deleted = try deleted.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer changed.deinit();

    const all_files = try changed.all(allocator);
    defer {
        allocator.free(all_files);
    }

    try std.testing.expectEqual(@as(usize, 4), all_files.len);
}
