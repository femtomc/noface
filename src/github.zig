//! GitHub Issues sync for beads issues.
//!
//! Syncs beads issues to GitHub Issues using the gh CLI.
//! Maintains a mapping file at .beads/github-map.json to track
//! which beads issues have corresponding GitHub issues.

const std = @import("std");
const process = @import("process.zig");

/// Colors for terminal output
const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const red = "\x1b[0;31m";
};

/// Result of a sync operation
pub const SyncResult = struct {
    created: u32 = 0,
    updated: u32 = 0,
    closed: u32 = 0,
    skipped: u32 = 0,
    errors: u32 = 0,
};

/// GitHub sync context
pub const GitHubSync = struct {
    allocator: std.mem.Allocator,
    dry_run: bool,
    repo: ?[]const u8 = null,
    github_map: std.StringHashMap([]const u8),
    valid_labels: ?[]const u8 = null,

    const GITHUB_MAP_PATH = ".beads/github-map.json";

    pub fn init(allocator: std.mem.Allocator, dry_run: bool) GitHubSync {
        return .{
            .allocator = allocator,
            .dry_run = dry_run,
            .github_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *GitHubSync) void {
        if (self.repo) |r| self.allocator.free(r);
        if (self.valid_labels) |l| self.allocator.free(l);

        var it = self.github_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.github_map.deinit();
    }

    /// Check if gh CLI is available and authenticated
    pub fn checkPrerequisites(self: *GitHubSync) !void {
        // Check gh exists
        if (!process.commandExists(self.allocator, "gh")) {
            logError("gh CLI not found. Install from: https://cli.github.com/", .{});
            return error.GhNotFound;
        }

        // Check authentication
        var auth_result = try process.shell(self.allocator, "gh auth status 2>&1");
        defer auth_result.deinit();

        if (!auth_result.success()) {
            logError("Not authenticated with GitHub. Run: gh auth login", .{});
            return error.GhNotAuthenticated;
        }

        // Get repo info
        var repo_result = try process.shell(self.allocator, "gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null");
        defer repo_result.deinit();

        if (!repo_result.success() or repo_result.stdout.len == 0) {
            logError("Not in a GitHub repository or can't determine repo", .{});
            return error.NotGitHubRepo;
        }

        // Store repo name (trim newline)
        const trimmed = std.mem.trim(u8, repo_result.stdout, " \t\n\r");
        self.repo = try self.allocator.dupe(u8, trimmed);

        logInfo("Repository: {s}", .{self.repo.?});
    }

    /// Load github-map.json mapping file
    pub fn loadMapping(self: *GitHubSync) !void {
        const file = std.fs.cwd().openFile(GITHUB_MAP_PATH, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No mapping file yet, that's fine
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        // Parse JSON manually (simple key-value object)
        // Format: {"beads-id": "gh-number", ...}
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
    pub fn saveMapping(self: *GitHubSync) !void {
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
    pub fn fetchValidLabels(self: *GitHubSync) !void {
        var result = try process.shell(self.allocator, "gh label list --json name -q '.[].name' --limit 1000 2>/dev/null");
        defer result.deinit();

        if (result.success()) {
            self.valid_labels = try self.allocator.dupe(u8, result.stdout);
        }
    }

    /// Check if a label exists in GitHub
    fn hasLabel(self: *GitHubSync, label: []const u8) bool {
        if (self.valid_labels) |labels| {
            var lines = std.mem.splitScalar(u8, labels, '\n');
            while (lines.next()) |line| {
                if (std.mem.eql(u8, line, label)) return true;
            }
        }
        return false;
    }

    /// Run the full sync operation
    pub fn sync(self: *GitHubSync) !SyncResult {
        var result = SyncResult{};

        // Get all beads issues
        var issues_result = try process.shell(self.allocator, "bd list --json 2>/dev/null");
        defer issues_result.deinit();

        if (!issues_result.success()) {
            logError("Failed to get beads issues", .{});
            return error.BeadsListFailed;
        }

        // Parse issues JSON array
        const issues_json = issues_result.stdout;
        var issues = std.ArrayListUnmanaged(BeadsIssue){};
        defer {
            for (issues.items) |*issue| issue.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        try parseIssuesJson(self.allocator, issues_json, &issues);

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
    fn syncIssue(self: *GitHubSync, issue: BeadsIssue, result: *SyncResult) !void {
        const gh_number = self.github_map.get(issue.id);

        if (gh_number == null) {
            // No GitHub issue exists yet
            if (std.mem.eql(u8, issue.status, "closed")) {
                logSkip("{s}: Already closed, not creating GitHub issue", .{issue.id});
                result.skipped += 1;
                return;
            }

            // Create new GitHub issue
            try self.createGitHubIssue(issue, result);
        } else {
            // GitHub issue exists, sync status
            try self.syncExistingIssue(issue, gh_number.?, result);
        }
    }

    /// Create a new GitHub issue
    fn createGitHubIssue(self: *GitHubSync, issue: BeadsIssue, result: *SyncResult) !void {
        logInfo("Creating GitHub issue for {s}: {s}", .{ issue.id, issue.title });

        if (self.dry_run) {
            logSkip("[DRY RUN] Would create: {s}", .{issue.title});
            result.skipped += 1;
            return;
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

        // Build title with beads ID prefix
        var title = std.ArrayListUnmanaged(u8){};
        defer title.deinit(self.allocator);
        try title.writer(self.allocator).print("[{s}] {s}", .{ issue.id, issue.title });

        // Create the issue
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "gh issue create --title \"{s}\" --label \"{s}\" --body \"$(cat <<'BEADS_EOF'\n{s}\nBEADS_EOF\n)\"",
            .{ title.items, labels.items, body.items },
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
            } else {
                logError("Failed to extract issue number from: {s}", .{create_result.stdout});
                result.errors += 1;
            }
        } else {
            logError("Failed to create issue: {s}", .{create_result.stderr});
            result.errors += 1;
        }
    }

    /// Sync an existing GitHub issue
    fn syncExistingIssue(self: *GitHubSync, issue: BeadsIssue, gh_number: []const u8, result: *SyncResult) !void {
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
            // Issue is open, could update body here if needed
            // For now, skip updates to reduce API calls
            logSkip("{s}: GitHub #{s} exists, skipping update", .{ issue.id, gh_number });
            result.skipped += 1;
        }
    }
};

/// Minimal beads issue structure
const BeadsIssue = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    priority: u8,
    issue_type: []const u8,

    fn deinit(self: *BeadsIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.status);
        allocator.free(self.issue_type);
    }
};

/// Extract issue number from GitHub URL
fn extractIssueNumber(url: []const u8) ?[]const u8 {
    // Look for /issues/NNN pattern
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

/// Parse beads issues JSON array
fn parseIssuesJson(allocator: std.mem.Allocator, json: []const u8, out: *std.ArrayListUnmanaged(BeadsIssue)) !void {
    // Simple JSON parser for the issues array format
    // Format: [{"id": "...", "title": "...", ...}, ...]

    var i: usize = 0;

    // Skip to opening bracket
    while (i < json.len and json[i] != '[') : (i += 1) {}
    i += 1;

    while (i < json.len) {
        // Skip whitespace and commas
        while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t' or json[i] == ',')) : (i += 1) {}

        if (i >= json.len or json[i] == ']') break;

        if (json[i] == '{') {
            const issue = try parseIssueObject(allocator, json, &i);
            try out.append(allocator, issue);
        } else {
            i += 1;
        }
    }
}

/// Parse a single issue object from JSON
fn parseIssueObject(allocator: std.mem.Allocator, json: []const u8, idx: *usize) !BeadsIssue {
    var issue = BeadsIssue{
        .id = "",
        .title = "",
        .description = "",
        .status = "open",
        .priority = 2,
        .issue_type = "task",
    };

    var i = idx.*;

    // Skip opening brace
    while (i < json.len and json[i] != '{') : (i += 1) {}
    i += 1;

    while (i < json.len and json[i] != '}') {
        // Skip whitespace and commas
        while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t' or json[i] == ',')) : (i += 1) {}

        if (i >= json.len or json[i] == '}') break;

        // Parse key
        if (json[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;
        const key_start = i;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        const key = json[key_start..i];
        i += 1;

        // Skip colon and whitespace
        while (i < json.len and (json[i] == ':' or json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

        // Parse value
        if (i >= json.len) break;

        if (json[i] == '"') {
            // String value
            i += 1;
            const val_start = i;
            while (i < json.len and json[i] != '"') {
                if (json[i] == '\\' and i + 1 < json.len) {
                    i += 2; // Skip escaped char
                } else {
                    i += 1;
                }
            }
            const val = json[val_start..i];
            i += 1;

            // Unescape and store
            const unescaped = try unescapeJson(allocator, val);

            if (std.mem.eql(u8, key, "id")) {
                issue.id = unescaped;
            } else if (std.mem.eql(u8, key, "title")) {
                issue.title = unescaped;
            } else if (std.mem.eql(u8, key, "description")) {
                issue.description = unescaped;
            } else if (std.mem.eql(u8, key, "status")) {
                issue.status = unescaped;
            } else if (std.mem.eql(u8, key, "issue_type")) {
                issue.issue_type = unescaped;
            } else {
                allocator.free(unescaped);
            }
        } else if (json[i] >= '0' and json[i] <= '9') {
            // Number value
            const val_start = i;
            while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
            const val = json[val_start..i];

            if (std.mem.eql(u8, key, "priority")) {
                issue.priority = std.fmt.parseInt(u8, val, 10) catch 2;
            }
        } else if (json[i] == 'n' or json[i] == 't' or json[i] == 'f' or json[i] == '[' or json[i] == '{') {
            // Skip null, bool, array, or nested object
            i = skipJsonValue(json, i);
        }
    }

    // Skip closing brace
    if (i < json.len and json[i] == '}') i += 1;

    idx.* = i;

    // Ensure required fields have defaults
    if (issue.id.len == 0) {
        issue.id = try allocator.dupe(u8, "unknown");
    }
    if (issue.title.len == 0) {
        issue.title = try allocator.dupe(u8, "Untitled");
    }
    if (issue.description.len == 0) {
        issue.description = try allocator.dupe(u8, "");
    }
    if (issue.status.len == 0) {
        issue.status = try allocator.dupe(u8, "open");
    }
    if (issue.issue_type.len == 0) {
        issue.issue_type = try allocator.dupe(u8, "task");
    }

    return issue;
}

/// Skip a JSON value (for values we don't care about)
fn skipJsonValue(json: []const u8, start: usize) usize {
    var i = start;
    if (i >= json.len) return i;

    switch (json[i]) {
        'n' => { // null
            i += 4;
        },
        't' => { // true
            i += 4;
        },
        'f' => { // false
            i += 5;
        },
        '"' => { // string
            i += 1;
            while (i < json.len and json[i] != '"') {
                if (json[i] == '\\' and i + 1 < json.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            i += 1;
        },
        '[' => { // array
            var depth: u32 = 1;
            i += 1;
            while (i < json.len and depth > 0) {
                if (json[i] == '[') depth += 1;
                if (json[i] == ']') depth -= 1;
                if (json[i] == '"') {
                    i += 1;
                    while (i < json.len and json[i] != '"') {
                        if (json[i] == '\\' and i + 1 < json.len) {
                            i += 2;
                        } else {
                            i += 1;
                        }
                    }
                }
                i += 1;
            }
        },
        '{' => { // object
            var depth: u32 = 1;
            i += 1;
            while (i < json.len and depth > 0) {
                if (json[i] == '{') depth += 1;
                if (json[i] == '}') depth -= 1;
                if (json[i] == '"') {
                    i += 1;
                    while (i < json.len and json[i] != '"') {
                        if (json[i] == '\\' and i + 1 < json.len) {
                            i += 2;
                        } else {
                            i += 1;
                        }
                    }
                }
                i += 1;
            }
        },
        else => {
            // Number or unknown
            while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ']') : (i += 1) {}
        },
    }
    return i;
}

/// Unescape JSON string
fn unescapeJson(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                '/' => try result.append(allocator, '/'),
                else => {
                    try result.append(allocator, s[i]);
                    try result.append(allocator, s[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, s[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// Logging helpers
fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[INFO]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.green ++ "[SYNC]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logSkip(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[SKIP]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.red ++ "[ERROR]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

/// Run GitHub sync (entry point for loop.zig)
pub fn syncToGitHub(allocator: std.mem.Allocator, dry_run: bool) !SyncResult {
    var gh = GitHubSync.init(allocator, dry_run);
    defer gh.deinit();

    // Check prerequisites
    gh.checkPrerequisites() catch |err| {
        switch (err) {
            error.GhNotFound, error.GhNotAuthenticated, error.NotGitHubRepo => {
                // These are expected failures, return empty result
                return SyncResult{ .errors = 1 };
            },
            else => return err,
        }
    };

    // Load existing mapping
    try gh.loadMapping();

    // Fetch valid labels
    try gh.fetchValidLabels();

    // Run sync
    return gh.sync();
}

test "extract issue number" {
    try std.testing.expectEqualStrings("123", extractIssueNumber("https://github.com/owner/repo/issues/123").?);
    try std.testing.expectEqualStrings("1", extractIssueNumber("https://github.com/foo/bar/issues/1\n").?);
    try std.testing.expect(extractIssueNumber("not a url") == null);
}

test "unescape json" {
    const result = try unescapeJson(std.testing.allocator, "hello\\nworld\\t!");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld\t!", result);
}
