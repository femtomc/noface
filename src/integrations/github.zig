//! GitHub Issues sync provider.
//!
//! Syncs beads issues to GitHub Issues using the gh CLI.
//! Maintains a mapping file at .beads/github-map.json to track
//! which beads issues have corresponding GitHub issues.

const std = @import("std");
const process = @import("../util/process.zig");
const issue_sync = @import("issue_sync.zig");

const SyncResult = issue_sync.SyncResult;
const BeadsIssue = issue_sync.BeadsIssue;
const IssueProvider = issue_sync.IssueProvider;
const logInfo = issue_sync.logInfo;
const logSuccess = issue_sync.logSuccess;
const logSkip = issue_sync.logSkip;
const logError = issue_sync.logError;

/// GitHub sync provider
pub const GitHubProvider = struct {
    allocator: std.mem.Allocator,
    dry_run: bool,
    repo: ?[]const u8 = null,
    github_map: std.StringHashMap([]const u8),
    valid_labels: ?[]const u8 = null,

    const GITHUB_MAP_PATH = ".beads/github-map.json";

    pub fn init(allocator: std.mem.Allocator, dry_run: bool) GitHubProvider {
        return .{
            .allocator = allocator,
            .dry_run = dry_run,
            .github_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *GitHubProvider) void {
        if (self.repo) |r| self.allocator.free(r);
        if (self.valid_labels) |l| self.allocator.free(l);

        var it = self.github_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.github_map.deinit();
    }

    /// Create provider implementing IssueProvider interface
    pub fn create(allocator: std.mem.Allocator, dry_run: bool) IssueProvider {
        const self = allocator.create(GitHubProvider) catch unreachable;
        self.* = GitHubProvider.init(allocator, dry_run);
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = IssueProvider.VTable{
        .checkPrerequisites = checkPrerequisitesVtable,
        .loadMapping = loadMappingVtable,
        .saveMapping = saveMappingVtable,
        .sync = syncVtable,
        .deinit = deinitVtable,
        .getProviderName = getProviderName,
    };

    fn checkPrerequisitesVtable(ptr: *anyopaque) anyerror!void {
        const self: *GitHubProvider = @ptrCast(@alignCast(ptr));
        return self.checkPrerequisites();
    }

    fn loadMappingVtable(ptr: *anyopaque) anyerror!void {
        const self: *GitHubProvider = @ptrCast(@alignCast(ptr));
        return self.loadMapping();
    }

    fn saveMappingVtable(ptr: *anyopaque) anyerror!void {
        const self: *GitHubProvider = @ptrCast(@alignCast(ptr));
        return self.saveMapping();
    }

    fn syncVtable(ptr: *anyopaque) anyerror!SyncResult {
        const self: *GitHubProvider = @ptrCast(@alignCast(ptr));
        return self.sync();
    }

    fn deinitVtable(ptr: *anyopaque) void {
        const self: *GitHubProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.allocator.destroy(self);
    }

    fn getProviderName() []const u8 {
        return "GitHub";
    }

    /// Check if gh CLI is available and authenticated
    pub fn checkPrerequisites(self: *GitHubProvider) !void {
        // Check gh exists
        if (!process.commandExists(self.allocator, "gh")) {
            logError("gh CLI not found. Install from: https://cli.github.com/", .{});
            return error.ProviderNotAvailable;
        }

        // Check authentication
        var auth_result = try process.shell(self.allocator, "gh auth status 2>&1");
        defer auth_result.deinit();

        if (!auth_result.success()) {
            logError("Not authenticated with GitHub. Run: gh auth login", .{});
            return error.NotAuthenticated;
        }

        // Get repo info
        var repo_result = try process.shell(self.allocator, "gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null");
        defer repo_result.deinit();

        if (!repo_result.success() or repo_result.stdout.len == 0) {
            logError("Not in a GitHub repository or can't determine repo", .{});
            return error.NotInRepository;
        }

        // Store repo name (trim newline)
        const trimmed = std.mem.trim(u8, repo_result.stdout, " \t\n\r");
        self.repo = try self.allocator.dupe(u8, trimmed);

        logInfo("Repository: {s}", .{self.repo.?});
    }

    /// Load github-map.json mapping file
    pub fn loadMapping(self: *GitHubProvider) !void {
        const file = std.fs.cwd().openFile(GITHUB_MAP_PATH, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        // Parse JSON manually (simple key-value object)
        var i: usize = 0;

        // Skip opening brace
        while (i < content.len and content[i] != '{') : (i += 1) {}
        i += 1;

        while (i < content.len) {
            // Skip whitespace
            while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '\r' or content[i] == '\t' or content[i] == ',')) : (i += 1) {}

            if (i >= content.len or content[i] == '}') break;

            // Parse key (beads ID)
            if (content[i] != '"') break;
            i += 1;
            const key_start = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const key = content[key_start..i];
            i += 1;

            // Skip colon
            while (i < content.len and content[i] != ':') : (i += 1) {}
            i += 1;

            // Skip whitespace
            while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '\r' or content[i] == '\t')) : (i += 1) {}

            // Parse value (GitHub issue number as string)
            if (content[i] != '"') break;
            i += 1;
            const val_start = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const val = content[val_start..i];
            i += 1;

            // Store in map
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            const owned_val = try self.allocator.dupe(u8, val);
            try self.github_map.put(owned_key, owned_val);
        }

        logInfo("Loaded {d} existing mappings", .{self.github_map.count()});
    }

    /// Save github-map.json mapping file
    pub fn saveMapping(self: *GitHubProvider) !void {
        if (self.dry_run) return;

        // Ensure .beads directory exists
        std.fs.cwd().makeDir(".beads") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Build JSON content in memory
        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "{\n");

        var first = true;
        var it = self.github_map.iterator();
        while (it.next()) |entry| {
            if (!first) try content.appendSlice(self.allocator, ",\n");
            first = false;
            const line = try std.fmt.allocPrint(self.allocator, "  \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(line);
            try content.appendSlice(self.allocator, line);
        }

        try content.appendSlice(self.allocator, "\n}\n");

        // Write to file
        const file = try std.fs.cwd().createFile(GITHUB_MAP_PATH, .{});
        defer file.close();
        try file.writeAll(content.items);
    }

    /// Fetch valid GitHub labels for the repo
    fn fetchValidLabels(self: *GitHubProvider) !void {
        var result = try process.shell(self.allocator, "gh label list --json name -q '.[].name' --limit 1000 2>/dev/null");
        defer result.deinit();

        if (result.success()) {
            self.valid_labels = try self.allocator.dupe(u8, result.stdout);
        }
    }

    /// Check if a label exists in GitHub
    fn hasLabel(self: *GitHubProvider, label: []const u8) bool {
        if (self.valid_labels) |labels| {
            var lines = std.mem.splitScalar(u8, labels, '\n');
            while (lines.next()) |line| {
                if (std.mem.eql(u8, line, label)) return true;
            }
        }
        return false;
    }

    /// Run the full sync operation
    pub fn sync(self: *GitHubProvider) !SyncResult {
        var result = SyncResult{};

        // Fetch valid labels
        try self.fetchValidLabels();

        // Get all beads issues
        var issues = issue_sync.getBeadsIssues(self.allocator) catch |err| {
            if (err == error.BeadsListFailed) {
                return SyncResult{ .errors = 1 };
            }
            return err;
        };
        defer {
            for (issues.items) |*issue| issue.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        logInfo("Found {d} beads issues", .{issues.items.len});

        // Process each issue
        for (issues.items) |issue| {
            self.syncIssue(issue, &result) catch |err| {
                logError("Failed to sync {s}: {}", .{ issue.id, err });
                result.errors += 1;
            };
        }

        // Save updated mapping
        try self.saveMapping();

        return result;
    }

    /// Sync a single issue
    fn syncIssue(self: *GitHubProvider, issue: BeadsIssue, result: *SyncResult) !void {
        const gh_number = self.github_map.get(issue.id);

        if (gh_number == null) {
            // No GitHub issue exists yet - create it
            const created_num = try self.createGitHubIssue(issue, result);

            // If issue is closed in beads and we successfully created it, close it on GitHub too
            if (created_num) |num| {
                if (std.mem.eql(u8, issue.status, "closed")) {
                    try self.closeGitHubIssue(num, result);
                }
            }
        } else {
            // GitHub issue exists, sync status
            try self.syncExistingIssue(issue, gh_number.?, result);
        }
    }

    /// Create a new GitHub issue
    fn createGitHubIssue(self: *GitHubProvider, issue: BeadsIssue, result: *SyncResult) !?[]const u8 {
        logInfo("Creating GitHub issue for {s}: {s}", .{ issue.id, issue.title });

        if (self.dry_run) {
            logSkip("[DRY RUN] Would create: {s}", .{issue.title});
            if (std.mem.eql(u8, issue.status, "closed")) {
                logSkip("[DRY RUN] Would then close (already closed in beads)", .{});
            }
            result.skipped += 1;
            return null;
        }

        // Build labels
        var labels = std.ArrayListUnmanaged(u8){};
        defer labels.deinit(self.allocator);
        try labels.appendSlice(self.allocator, "beads");

        if (std.mem.eql(u8, issue.issue_type, "bug") and self.hasLabel("bug")) {
            try labels.appendSlice(self.allocator, ",bug");
        }
        if (issue.priority <= 1 and self.hasLabel("priority:high")) {
            try labels.appendSlice(self.allocator, ",priority:high");
        }

        // Build body with metadata
        var body = std.ArrayListUnmanaged(u8){};
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, issue.description);
        try body.appendSlice(self.allocator, "\n\n---\n");
        try body.writer(self.allocator).print("**Beads ID:** `{s}`\n", .{issue.id});
        try body.writer(self.allocator).print("**Priority:** P{d}\n", .{issue.priority});
        try body.writer(self.allocator).print("**Type:** {s}\n", .{issue.issue_type});

        // Build title with beads ID prefix, escaping double quotes for shell
        var title = std.ArrayListUnmanaged(u8){};
        defer title.deinit(self.allocator);
        try title.writer(self.allocator).print("[{s}] ", .{issue.id});
        // Escape double quotes in title
        for (issue.title) |c| {
            if (c == '"') {
                try title.appendSlice(self.allocator, "\\\"");
            } else {
                try title.append(self.allocator, c);
            }
        }

        // Write body to temp file to avoid shell escaping issues
        const body_file_path = "/tmp/noface-gh-body.md";
        {
            const file = std.fs.cwd().createFile(body_file_path, .{}) catch |err| {
                logError("Failed to create temp file: {}", .{err});
                result.errors += 1;
                return null;
            };
            defer file.close();
            file.writeAll(body.items) catch |err| {
                logError("Failed to write temp file: {}", .{err});
                result.errors += 1;
                return null;
            };
        }
        defer std.fs.cwd().deleteFile(body_file_path) catch {};

        // Create the issue using --body-file to avoid shell escaping
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "gh issue create --title \"{s}\" --label \"{s}\" --body-file {s}",
            .{ title.items, labels.items, body_file_path },
        );
        defer self.allocator.free(cmd);

        var create_result = try process.shell(self.allocator, cmd);
        defer create_result.deinit();

        if (create_result.success()) {
            // Extract issue number from URL (format: https://github.com/owner/repo/issues/123)
            const gh_num = extractIssueNumber(create_result.stdout);
            if (gh_num) |num| {
                // Store mapping
                const owned_id = try self.allocator.dupe(u8, issue.id);
                errdefer self.allocator.free(owned_id);
                const owned_num = try self.allocator.dupe(u8, num);
                try self.github_map.put(owned_id, owned_num);

                logSuccess("{s} -> GitHub #{s}", .{ issue.id, num });
                result.created += 1;
                return owned_num;
            } else {
                logError("Failed to extract issue number from: {s}", .{create_result.stdout});
                result.errors += 1;
                return null;
            }
        } else {
            logError("Failed to create issue: {s}", .{create_result.stderr});
            result.errors += 1;
            return null;
        }
    }

    /// Close a GitHub issue
    fn closeGitHubIssue(self: *GitHubProvider, gh_number: []const u8, result: *SyncResult) !void {
        logInfo("Closing newly created GitHub #{s} (beads issue was already closed)", .{gh_number});

        if (self.dry_run) {
            logSkip("[DRY RUN] Would close #{s}", .{gh_number});
            return;
        }

        const close_cmd = try std.fmt.allocPrint(
            self.allocator,
            "gh issue close {s} --comment \"Created and closed via beads sync (historical closed issue)\"",
            .{gh_number},
        );
        defer self.allocator.free(close_cmd);

        var close_result = try process.shell(self.allocator, close_cmd);
        defer close_result.deinit();

        if (close_result.success()) {
            logSuccess("Closed GitHub #{s}", .{gh_number});
            result.closed += 1;
        } else {
            logError("Failed to close #{s}: {s}", .{ gh_number, close_result.stderr });
            result.errors += 1;
        }
    }

    /// Sync an existing GitHub issue
    fn syncExistingIssue(self: *GitHubProvider, issue: BeadsIssue, gh_number: []const u8, result: *SyncResult) !void {
        if (std.mem.eql(u8, issue.status, "closed")) {
            // Check if GitHub issue needs closing
            const cmd = try std.fmt.allocPrint(
                self.allocator,
                "gh issue view {s} --json state -q '.state' 2>/dev/null",
                .{gh_number},
            );
            defer self.allocator.free(cmd);

            var state_result = try process.shell(self.allocator, cmd);
            defer state_result.deinit();

            const state = std.mem.trim(u8, state_result.stdout, " \t\n\r");

            if (std.mem.eql(u8, state, "OPEN")) {
                logInfo("Closing GitHub #{s} (beads {s} is closed)", .{ gh_number, issue.id });

                if (self.dry_run) {
                    logSkip("[DRY RUN] Would close #{s}", .{gh_number});
                    result.skipped += 1;
                    return;
                }

                const close_cmd = try std.fmt.allocPrint(
                    self.allocator,
                    "gh issue close {s} --comment \"Closed via beads sync (issue {s} completed)\"",
                    .{ gh_number, issue.id },
                );
                defer self.allocator.free(close_cmd);

                var close_result = try process.shell(self.allocator, close_cmd);
                defer close_result.deinit();

                if (close_result.success()) {
                    logSuccess("Closed GitHub #{s}", .{gh_number});
                    result.closed += 1;
                } else {
                    logError("Failed to close #{s}: {s}", .{ gh_number, close_result.stderr });
                    result.errors += 1;
                }
            } else {
                logSkip("{s}: GitHub #{s} already closed", .{ issue.id, gh_number });
                result.skipped += 1;
            }
        } else {
            logSkip("{s}: GitHub #{s} exists, skipping update", .{ issue.id, gh_number });
            result.skipped += 1;
        }
    }
};

/// Extract issue number from GitHub URL
fn extractIssueNumber(url: []const u8) ?[]const u8 {
    const marker = "/issues/";
    if (std.mem.indexOf(u8, url, marker)) |idx| {
        const start = idx + marker.len;
        var end = start;
        while (end < url.len and url[end] >= '0' and url[end] <= '9') : (end += 1) {}
        if (end > start) {
            return url[start..end];
        }
    }
    return null;
}

// Legacy API for backwards compatibility
pub const GitHubSync = GitHubProvider;

/// Run GitHub sync (legacy entry point for loop.zig)
pub fn syncToGitHub(allocator: std.mem.Allocator, dry_run: bool) !SyncResult {
    var gh = GitHubProvider.init(allocator, dry_run);
    defer gh.deinit();

    // Check prerequisites
    gh.checkPrerequisites() catch |err| {
        switch (err) {
            error.ProviderNotAvailable, error.NotAuthenticated, error.NotInRepository => {
                return SyncResult{ .errors = 1 };
            },
            else => return err,
        }
    };

    // Load existing mapping
    try gh.loadMapping();

    // Run sync
    return gh.sync();
}

test "extract issue number" {
    try std.testing.expectEqualStrings("123", extractIssueNumber("https://github.com/owner/repo/issues/123").?);
    try std.testing.expectEqualStrings("1", extractIssueNumber("https://github.com/foo/bar/issues/1\n").?);
    try std.testing.expect(extractIssueNumber("not a url") == null);
}
