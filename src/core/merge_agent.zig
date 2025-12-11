//! Merge agent for resolving conflicts in parallel worker execution.
//!
//! When workers' changes conflict during squash, this agent attempts
//! automated resolution using an LLM before escalating to humans.

const std = @import("std");
const process = @import("../util/process.zig");
const jj = @import("../vcs/jj.zig");
const prompts = @import("prompts.zig");

/// Result of a merge attempt
pub const MergeResult = struct {
    success: bool,
    resolved_files: []const []const u8,
    unresolved_files: []const []const u8,
    error_message: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MergeResult) void {
        for (self.resolved_files) |f| self.allocator.free(f);
        if (self.resolved_files.len > 0) self.allocator.free(self.resolved_files);

        for (self.unresolved_files) |f| self.allocator.free(f);
        if (self.unresolved_files.len > 0) self.allocator.free(self.unresolved_files);

        if (self.error_message) |msg| self.allocator.free(msg);
    }
};

/// Conflict information for a single file
pub const ConflictInfo = struct {
    file_path: []const u8,
    conflict_content: []const u8,
    base_content: ?[]const u8,
    left_content: ?[]const u8,
    right_content: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConflictInfo) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.conflict_content);
        if (self.base_content) |c| self.allocator.free(c);
        if (self.left_content) |c| self.allocator.free(c);
        if (self.right_content) |c| self.allocator.free(c);
    }
};

/// Merge agent configuration
pub const MergeAgentConfig = struct {
    /// Agent to use for merge resolution (default: codex, which is better for focused code tasks)
    agent: []const u8 = "codex",
    build_cmd: ?[]const u8 = null,
    test_cmd: ?[]const u8 = null,
    timeout_seconds: u32 = 300,
    dry_run: bool = false,
};

/// Merge agent prompt template
const MERGE_PROMPT =
    \\MERGE CONFLICT RESOLUTION
    \\
    \\You are resolving a merge conflict that occurred when combining changes from parallel workers.
    \\
    \\CONFLICT CONTEXT:
    \\- Worker was implementing: {s}
    \\- Conflict occurred in: {s}
    \\
    \\CONFLICTING FILE CONTENT:
    \\```
    \\{s}
    \\```
    \\
    \\YOUR TASK:
    \\1. Analyze the conflict markers (<<<<<<< ======= >>>>>>>)
    \\2. Understand what each side was trying to accomplish
    \\3. Produce a merged version that preserves BOTH intentions
    \\4. If intentions are incompatible, prefer the workspace changes (newer work)
    \\
    \\CONSTRAINTS:
    \\- Output ONLY the resolved file content, no explanations
    \\- Preserve all functionality from both sides where possible
    \\- Ensure the result compiles/is syntactically valid
    \\- Do NOT include conflict markers in output
    \\
    \\OUTPUT FORMAT:
    \\Respond with the complete resolved file content wrapped in:
    \\```resolved
    \\<your resolved content here>
    \\```
    \\
;

/// Get list of files with conflicts
pub fn getConflictedFiles(allocator: std.mem.Allocator) ![]const []const u8 {
    // jj status shows conflicts with "C" marker or in conflict list
    var result = try process.shell(allocator, "jj status 2>/dev/null");
    defer result.deinit();

    if (!result.success()) {
        return &[_][]const u8{};
    }

    var files = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Look for conflict markers - jj shows "C path/to/file" for conflicts
        if (trimmed.len > 2 and trimmed[0] == 'C' and trimmed[1] == ' ') {
            const file_path = std.mem.trim(u8, trimmed[2..], " \t");
            if (file_path.len > 0) {
                try files.append(allocator, try allocator.dupe(u8, file_path));
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Get conflict content for a specific file
pub fn getConflictContent(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const cmd = try std.fmt.allocPrint(allocator, "cat \"{s}\" 2>/dev/null", .{file_path});
    defer allocator.free(cmd);

    var result = try process.shell(allocator, cmd);
    defer result.deinit();

    if (!result.success()) {
        return allocator.dupe(u8, "");
    }

    return allocator.dupe(u8, result.stdout);
}

/// Attempt to resolve conflicts using merge agent
pub fn resolveConflicts(
    allocator: std.mem.Allocator,
    config: MergeAgentConfig,
    issue_context: []const u8,
) !MergeResult {
    var resolved = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (resolved.items) |f| allocator.free(f);
        resolved.deinit(allocator);
    }

    var unresolved = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (unresolved.items) |f| allocator.free(f);
        unresolved.deinit(allocator);
    }

    // Get conflicted files
    const conflicted_files = try getConflictedFiles(allocator);
    defer {
        for (conflicted_files) |f| allocator.free(f);
        if (conflicted_files.len > 0) allocator.free(conflicted_files);
    }

    if (conflicted_files.len == 0) {
        // No conflicts detected - might be a different kind of failure
        return MergeResult{
            .success = true,
            .resolved_files = &[_][]const u8{},
            .unresolved_files = &[_][]const u8{},
            .error_message = null,
            .allocator = allocator,
        };
    }

    logInfo("Found {d} conflicted file(s), attempting resolution...", .{conflicted_files.len});

    // Resolve each file
    for (conflicted_files) |file_path| {
        const file_resolved = try resolveFileConflict(
            allocator,
            config,
            file_path,
            issue_context,
        );

        if (file_resolved) {
            try resolved.append(allocator, try allocator.dupe(u8, file_path));
            logSuccess("Resolved: {s}", .{file_path});
        } else {
            try unresolved.append(allocator, try allocator.dupe(u8, file_path));
            logWarn("Could not resolve: {s}", .{file_path});
        }
    }

    const all_resolved = unresolved.items.len == 0;

    // If all resolved, verify with build/test
    if (all_resolved and !config.dry_run) {
        if (config.build_cmd) |build_cmd| {
            logInfo("Running build verification...", .{});
            var build_result = try process.shell(allocator, build_cmd);
            defer build_result.deinit();

            if (!build_result.success()) {
                logWarn("Build failed after merge resolution", .{});
                return MergeResult{
                    .success = false,
                    .resolved_files = try resolved.toOwnedSlice(allocator),
                    .unresolved_files = try unresolved.toOwnedSlice(allocator),
                    .error_message = try allocator.dupe(u8, "Build verification failed"),
                    .allocator = allocator,
                };
            }
        }

        if (config.test_cmd) |test_cmd| {
            logInfo("Running test verification...", .{});
            var test_result = try process.shell(allocator, test_cmd);
            defer test_result.deinit();

            if (!test_result.success()) {
                logWarn("Tests failed after merge resolution", .{});
                return MergeResult{
                    .success = false,
                    .resolved_files = try resolved.toOwnedSlice(allocator),
                    .unresolved_files = try unresolved.toOwnedSlice(allocator),
                    .error_message = try allocator.dupe(u8, "Test verification failed"),
                    .allocator = allocator,
                };
            }
        }
    }

    return MergeResult{
        .success = all_resolved,
        .resolved_files = try resolved.toOwnedSlice(allocator),
        .unresolved_files = try unresolved.toOwnedSlice(allocator),
        .error_message = null,
        .allocator = allocator,
    };
}

/// Resolve a single file's conflicts
fn resolveFileConflict(
    allocator: std.mem.Allocator,
    config: MergeAgentConfig,
    file_path: []const u8,
    issue_context: []const u8,
) !bool {
    // Get current conflict content
    const conflict_content = try getConflictContent(allocator, file_path);
    defer allocator.free(conflict_content);

    if (conflict_content.len == 0) {
        return false;
    }

    // Check if file actually has conflict markers
    if (std.mem.indexOf(u8, conflict_content, "<<<<<<<") == null) {
        // No conflict markers - might already be resolved or different issue
        return true;
    }

    if (config.dry_run) {
        logInfo("[DRY RUN] Would invoke merge agent for {s}", .{file_path});
        return true;
    }

    // Build the merge prompt
    const prompt = try std.fmt.allocPrint(
        allocator,
        MERGE_PROMPT,
        .{ issue_context, file_path, conflict_content },
    );
    defer allocator.free(prompt);

    // Write prompt to temp file
    const prompt_file = "/tmp/noface-merge-prompt.txt";
    {
        const file = try std.fs.cwd().createFile(prompt_file, .{});
        defer file.close();
        try file.writeAll(prompt);
    }
    defer std.fs.cwd().deleteFile(prompt_file) catch {};

    // Invoke merge agent
    const agent_cmd = try std.fmt.allocPrint(
        allocator,
        "{s} -p --dangerously-skip-permissions < {s}",
        .{ config.agent, prompt_file },
    );
    defer allocator.free(agent_cmd);

    // TODO: Add timeout support for merge agent invocation
    var agent_result = try process.shell(allocator, agent_cmd);
    defer agent_result.deinit();

    if (!agent_result.success()) {
        logWarn("Merge agent failed for {s}", .{file_path});
        return false;
    }

    // Extract resolved content from response
    const resolved_content = extractResolvedContent(agent_result.stdout) orelse {
        logWarn("Could not extract resolved content from agent response for {s}", .{file_path});
        return false;
    };

    // Verify no conflict markers remain
    if (std.mem.indexOf(u8, resolved_content, "<<<<<<<") != null or
        std.mem.indexOf(u8, resolved_content, "=======") != null or
        std.mem.indexOf(u8, resolved_content, ">>>>>>>") != null)
    {
        logWarn("Resolved content still contains conflict markers for {s}", .{file_path});
        return false;
    }

    // Write resolved content
    {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(resolved_content);
    }

    return true;
}

/// Extract resolved content from agent response
fn extractResolvedContent(response: []const u8) ?[]const u8 {
    // Look for ```resolved ... ``` block
    const start_marker = "```resolved";
    const end_marker = "```";

    if (std.mem.indexOf(u8, response, start_marker)) |start_idx| {
        const content_start = start_idx + start_marker.len;
        // Skip to next line
        var actual_start = content_start;
        while (actual_start < response.len and response[actual_start] != '\n') {
            actual_start += 1;
        }
        if (actual_start < response.len) {
            actual_start += 1; // Skip the newline
        }

        // Find closing marker
        if (std.mem.indexOfPos(u8, response, actual_start, end_marker)) |end_idx| {
            return std.mem.trim(u8, response[actual_start..end_idx], "\r\n");
        }
    }

    // Fallback: look for any code block
    const code_start = "```";
    if (std.mem.indexOf(u8, response, code_start)) |start_idx| {
        var content_start = start_idx + code_start.len;
        // Skip language identifier line
        while (content_start < response.len and response[content_start] != '\n') {
            content_start += 1;
        }
        if (content_start < response.len) {
            content_start += 1;
        }

        if (std.mem.indexOfPos(u8, response, content_start, code_start)) |end_idx| {
            return std.mem.trim(u8, response[content_start..end_idx], "\r\n");
        }
    }

    return null;
}

// Logging helpers
const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const red = "\x1b[0;31m";
};

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[MERGE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.green ++ "[MERGE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[MERGE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.red ++ "[MERGE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

// Tests
test "extractResolvedContent with resolved block" {
    const response =
        \\Here's the resolved content:
        \\```resolved
        \\line 1
        \\line 2
        \\```
        \\Done!
    ;
    const content = extractResolvedContent(response);
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("line 1\nline 2", content.?);
}

test "extractResolvedContent with generic code block" {
    const response =
        \\```zig
        \\const x = 1;
        \\```
    ;
    const content = extractResolvedContent(response);
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("const x = 1;", content.?);
}

test "extractResolvedContent with no code block" {
    const response = "No code block here";
    const content = extractResolvedContent(response);
    try std.testing.expect(content == null);
}
