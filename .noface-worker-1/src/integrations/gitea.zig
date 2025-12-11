//! Gitea Issues sync provider.
//!
//! Syncs beads issues to Gitea Issues using the Gitea REST API.
//! Maintains a mapping file at .beads/gitea-map.json to track
//! which beads issues have corresponding Gitea issues.

const std = @import("std");
const process = @import("../util/process.zig");
const issue_sync = @import("issue_sync.zig");

const SyncResult = issue_sync.SyncResult;
const BeadsIssue = issue_sync.BeadsIssue;
const IssueProvider = issue_sync.IssueProvider;
const ProviderConfig = issue_sync.ProviderConfig;
const logInfo = issue_sync.logInfo;
const logSuccess = issue_sync.logSuccess;
const logSkip = issue_sync.logSkip;
const logError = issue_sync.logError;

/// Gitea sync provider
pub const GiteaProvider = struct {
    allocator: std.mem.Allocator,
    dry_run: bool,
    api_url: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    gitea_map: std.StringHashMap([]const u8),

    const GITEA_MAP_PATH = ".beads/gitea-map.json";

    pub fn init(allocator: std.mem.Allocator, config: ProviderConfig, dry_run: bool) !GiteaProvider {
        // Determine API URL from config or detect from git remote
        const api_url = if (config.api_url) |url|
            try allocator.dupe(u8, url)
        else
            try detectApiUrlFromRemote(allocator);

        // Determine repo from config or detect from git remote
        const repo = if (config.repo) |r|
            try allocator.dupe(u8, r)
        else
            try detectRepoFromRemote(allocator);

        // Get token from config or environment
        const token = if (config.token) |t|
            try allocator.dupe(u8, t)
        else
            getTokenFromEnv(allocator);

        return .{
            .allocator = allocator,
            .dry_run = dry_run,
            .api_url = api_url,
            .repo = repo,
            .token = token,
            .gitea_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *GiteaProvider) void {
        self.allocator.free(self.api_url);
        self.allocator.free(self.repo);
        if (self.token) |t| self.allocator.free(t);

        var it = self.gitea_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.gitea_map.deinit();
    }

    /// Create provider implementing IssueProvider interface
    pub fn create(allocator: std.mem.Allocator, config: ProviderConfig, dry_run: bool) IssueProvider {
        const self = allocator.create(GiteaProvider) catch unreachable;
        self.* = GiteaProvider.init(allocator, config, dry_run) catch {
            // Return a placeholder that will fail on checkPrerequisites
            self.* = .{
                .allocator = allocator,
                .dry_run = dry_run,
                .api_url = "",
                .repo = "",
                .token = null,
                .gitea_map = std.StringHashMap([]const u8).init(allocator),
            };
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        };
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
        const self: *GiteaProvider = @ptrCast(@alignCast(ptr));
        return self.checkPrerequisites();
    }

    fn loadMappingVtable(ptr: *anyopaque) anyerror!void {
        const self: *GiteaProvider = @ptrCast(@alignCast(ptr));
        return self.loadMapping();
    }

    fn saveMappingVtable(ptr: *anyopaque) anyerror!void {
        const self: *GiteaProvider = @ptrCast(@alignCast(ptr));
        return self.saveMapping();
    }

    fn syncVtable(ptr: *anyopaque) anyerror!SyncResult {
        const self: *GiteaProvider = @ptrCast(@alignCast(ptr));
        return self.sync();
    }

    fn deinitVtable(ptr: *anyopaque) void {
        const self: *GiteaProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.allocator.destroy(self);
    }

    fn getProviderName() []const u8 {
        return "Gitea";
    }

    /// Check if we have valid Gitea configuration
    pub fn checkPrerequisites(self: *GiteaProvider) !void {
        // Check curl exists
        if (!process.commandExists(self.allocator, "curl")) {
            logError("curl not found. Install curl to use Gitea sync.", .{});
            return error.ProviderNotAvailable;
        }

        // Check we have required config
        if (self.api_url.len == 0) {
            logError("Gitea API URL not configured. Set GITEA_URL or configure in .noface.toml", .{});
            return error.NotInRepository;
        }

        if (self.repo.len == 0) {
            logError("Gitea repository not configured. Set in .noface.toml or ensure git remote is set", .{});
            return error.NotInRepository;
        }

        // Warn if no token (read-only operations only)
        if (self.token == null) {
            logInfo("No Gitea token found. Set GITEA_TOKEN for write access.", .{});
            logInfo("Will operate in read-only mode (no issue creation/updates)", .{});
        }

        // Test API access
        const test_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v1/repos/{s}",
            .{ self.api_url, self.repo },
        );
        defer self.allocator.free(test_url);

        var auth_header: []const u8 = "";
        if (self.token) |t| {
            auth_header = try std.fmt.allocPrint(self.allocator, "-H \"Authorization: token {s}\"", .{t});
        }
        defer if (self.token != null) self.allocator.free(auth_header);

        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "curl -s -o /dev/null -w '%{{http_code}}' {s} \"{s}\"",
            .{ auth_header, test_url },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        const status = std.mem.trim(u8, result.stdout, " \t\n\r'");
        if (!std.mem.eql(u8, status, "200")) {
            logError("Cannot access Gitea repository: HTTP {s}", .{status});
            logError("URL: {s}", .{test_url});
            return error.NotInRepository;
        }

        logInfo("Gitea: {s}/{s}", .{ self.api_url, self.repo });
    }

    /// Load gitea-map.json mapping file
    pub fn loadMapping(self: *GiteaProvider) !void {
        const file = std.fs.cwd().openFile(GITEA_MAP_PATH, .{}) catch |err| {
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

            // Parse value (Gitea issue number as string)
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
            try self.gitea_map.put(owned_key, owned_val);
        }

        logInfo("Loaded {d} existing mappings", .{self.gitea_map.count()});
    }

    /// Save gitea-map.json mapping file
    pub fn saveMapping(self: *GiteaProvider) !void {
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
        var it = self.gitea_map.iterator();
        while (it.next()) |entry| {
            if (!first) try content.appendSlice(self.allocator, ",\n");
            first = false;
            const line = try std.fmt.allocPrint(self.allocator, "  \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(line);
            try content.appendSlice(self.allocator, line);
        }

        try content.appendSlice(self.allocator, "\n}\n");

        // Write to file
        const file = try std.fs.cwd().createFile(GITEA_MAP_PATH, .{});
        defer file.close();
        try file.writeAll(content.items);
    }

    /// Run the full sync operation
    pub fn sync(self: *GiteaProvider) !SyncResult {
        var result = SyncResult{};

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
    fn syncIssue(self: *GiteaProvider, issue: BeadsIssue, result: *SyncResult) !void {
        const gitea_number = self.gitea_map.get(issue.id);

        if (gitea_number == null) {
            // No Gitea issue exists yet - create it
            const created_num = try self.createGiteaIssue(issue, result);

            // If issue is closed in beads and we successfully created it, close it on Gitea too
            if (created_num) |num| {
                if (std.mem.eql(u8, issue.status, "closed")) {
                    try self.closeGiteaIssue(num, result);
                }
            }
        } else {
            // Gitea issue exists, sync status
            try self.syncExistingIssue(issue, gitea_number.?, result);
        }
    }

    /// Create a new Gitea issue
    fn createGiteaIssue(self: *GiteaProvider, issue: BeadsIssue, result: *SyncResult) !?[]const u8 {
        logInfo("Creating Gitea issue for {s}: {s}", .{ issue.id, issue.title });

        if (self.token == null) {
            logSkip("No token - cannot create issue", .{});
            result.skipped += 1;
            return null;
        }

        if (self.dry_run) {
            logSkip("[DRY RUN] Would create: {s}", .{issue.title});
            if (std.mem.eql(u8, issue.status, "closed")) {
                logSkip("[DRY RUN] Would then close (already closed in beads)", .{});
            }
            result.skipped += 1;
            return null;
        }

        // Build title with beads ID prefix
        var title = std.ArrayListUnmanaged(u8){};
        defer title.deinit(self.allocator);
        try title.writer(self.allocator).print("[{s}] {s}", .{ issue.id, issue.title });

        // Build body with metadata
        var body = std.ArrayListUnmanaged(u8){};
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, issue.description);
        try body.appendSlice(self.allocator, "\n\n---\n");
        try body.writer(self.allocator).print("**Beads ID:** `{s}`\n", .{issue.id});
        try body.writer(self.allocator).print("**Priority:** P{d}\n", .{issue.priority});
        try body.writer(self.allocator).print("**Type:** {s}\n", .{issue.issue_type});

        // Build JSON payload - write to temp file to handle escaping
        const json_file_path = "/tmp/noface-gitea-issue.json";
        {
            const file = std.fs.cwd().createFile(json_file_path, .{}) catch |err| {
                logError("Failed to create temp file: {}", .{err});
                result.errors += 1;
                return null;
            };
            defer file.close();

            // Escape JSON strings
            var escaped_title = std.ArrayListUnmanaged(u8){};
            defer escaped_title.deinit(self.allocator);
            for (title.items) |c| {
                switch (c) {
                    '"' => try escaped_title.appendSlice(self.allocator, "\\\""),
                    '\\' => try escaped_title.appendSlice(self.allocator, "\\\\"),
                    '\n' => try escaped_title.appendSlice(self.allocator, "\\n"),
                    '\r' => try escaped_title.appendSlice(self.allocator, "\\r"),
                    '\t' => try escaped_title.appendSlice(self.allocator, "\\t"),
                    else => try escaped_title.append(self.allocator, c),
                }
            }

            var escaped_body = std.ArrayListUnmanaged(u8){};
            defer escaped_body.deinit(self.allocator);
            for (body.items) |c| {
                switch (c) {
                    '"' => try escaped_body.appendSlice(self.allocator, "\\\""),
                    '\\' => try escaped_body.appendSlice(self.allocator, "\\\\"),
                    '\n' => try escaped_body.appendSlice(self.allocator, "\\n"),
                    '\r' => try escaped_body.appendSlice(self.allocator, "\\r"),
                    '\t' => try escaped_body.appendSlice(self.allocator, "\\t"),
                    else => try escaped_body.append(self.allocator, c),
                }
            }

            const json = try std.fmt.allocPrint(
                self.allocator,
                "{{\"title\":\"{s}\",\"body\":\"{s}\",\"labels\":[\"beads\"]}}",
                .{ escaped_title.items, escaped_body.items },
            );
            defer self.allocator.free(json);

            file.writeAll(json) catch |err| {
                logError("Failed to write temp file: {}", .{err});
                result.errors += 1;
                return null;
            };
        }
        defer std.fs.cwd().deleteFile(json_file_path) catch {};

        // Create issue via API
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v1/repos/{s}/issues",
            .{ self.api_url, self.repo },
        );
        defer self.allocator.free(url);

        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "curl -s -X POST -H \"Authorization: token {s}\" -H \"Content-Type: application/json\" -d @{s} \"{s}\"",
            .{ self.token.?, json_file_path, url },
        );
        defer self.allocator.free(cmd);

        var create_result = try process.shell(self.allocator, cmd);
        defer create_result.deinit();

        // Parse response to get issue number
        const issue_num = extractGiteaIssueNumber(create_result.stdout);
        if (issue_num) |num| {
            // Store mapping
            const owned_id = try self.allocator.dupe(u8, issue.id);
            errdefer self.allocator.free(owned_id);
            const owned_num = try self.allocator.dupe(u8, num);
            try self.gitea_map.put(owned_id, owned_num);

            logSuccess("{s} -> Gitea #{s}", .{ issue.id, num });
            result.created += 1;
            return owned_num;
        } else {
            logError("Failed to extract issue number from response: {s}", .{create_result.stdout});
            result.errors += 1;
            return null;
        }
    }

    /// Close a Gitea issue
    fn closeGiteaIssue(self: *GiteaProvider, gitea_number: []const u8, result: *SyncResult) !void {
        logInfo("Closing Gitea #{s}", .{gitea_number});

        if (self.token == null) {
            logSkip("No token - cannot close issue", .{});
            return;
        }

        if (self.dry_run) {
            logSkip("[DRY RUN] Would close #{s}", .{gitea_number});
            return;
        }

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v1/repos/{s}/issues/{s}",
            .{ self.api_url, self.repo, gitea_number },
        );
        defer self.allocator.free(url);

        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "curl -s -X PATCH -H \"Authorization: token {s}\" -H \"Content-Type: application/json\" -d '{{\"state\":\"closed\"}}' \"{s}\"",
            .{ self.token.?, url },
        );
        defer self.allocator.free(cmd);

        var close_result = try process.shell(self.allocator, cmd);
        defer close_result.deinit();

        // Check if response contains "closed"
        if (std.mem.indexOf(u8, close_result.stdout, "\"state\":\"closed\"") != null) {
            logSuccess("Closed Gitea #{s}", .{gitea_number});
            result.closed += 1;
        } else {
            logError("Failed to close #{s}: {s}", .{ gitea_number, close_result.stdout });
            result.errors += 1;
        }
    }

    /// Sync an existing Gitea issue
    fn syncExistingIssue(self: *GiteaProvider, issue: BeadsIssue, gitea_number: []const u8, result: *SyncResult) !void {
        if (std.mem.eql(u8, issue.status, "closed")) {
            // Check if Gitea issue needs closing
            const url = try std.fmt.allocPrint(
                self.allocator,
                "{s}/api/v1/repos/{s}/issues/{s}",
                .{ self.api_url, self.repo, gitea_number },
            );
            defer self.allocator.free(url);

            var auth_header: []const u8 = "";
            if (self.token) |t| {
                auth_header = try std.fmt.allocPrint(self.allocator, "-H \"Authorization: token {s}\"", .{t});
            }
            defer if (self.token != null) self.allocator.free(auth_header);

            const cmd = try std.fmt.allocPrint(
                self.allocator,
                "curl -s {s} \"{s}\"",
                .{ auth_header, url },
            );
            defer self.allocator.free(cmd);

            var state_result = try process.shell(self.allocator, cmd);
            defer state_result.deinit();

            // Check if issue is open
            if (std.mem.indexOf(u8, state_result.stdout, "\"state\":\"open\"") != null) {
                logInfo("Closing Gitea #{s} (beads {s} is closed)", .{ gitea_number, issue.id });

                if (self.dry_run) {
                    logSkip("[DRY RUN] Would close #{s}", .{gitea_number});
                    result.skipped += 1;
                    return;
                }

                try self.closeGiteaIssue(gitea_number, result);
            } else {
                logSkip("{s}: Gitea #{s} already closed", .{ issue.id, gitea_number });
                result.skipped += 1;
            }
        } else {
            logSkip("{s}: Gitea #{s} exists, skipping update", .{ issue.id, gitea_number });
            result.skipped += 1;
        }
    }
};

/// Detect API URL from git remote
fn detectApiUrlFromRemote(allocator: std.mem.Allocator) ![]const u8 {
    // First check environment variable
    const env_url = std.process.getEnvVarOwned(allocator, "GITEA_URL") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            // Try to detect from git remote
            var result = try process.shell(allocator, "git remote get-url origin 2>/dev/null");
            defer result.deinit();

            if (result.success()) {
                const url = std.mem.trim(u8, result.stdout, " \t\n\r");
                // Parse URL to get base (e.g., https://jgok76.gitea.cloud/femtomc/noface -> https://jgok76.gitea.cloud)
                if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
                    // Find the third slash (after protocol)
                    var slash_count: u32 = 0;
                    var end_idx: usize = 0;
                    for (url, 0..) |c, i| {
                        if (c == '/') {
                            slash_count += 1;
                            if (slash_count == 3) {
                                end_idx = i;
                                break;
                            }
                        }
                    }
                    if (end_idx > 0) {
                        return try allocator.dupe(u8, url[0..end_idx]);
                    }
                }
            }
            return allocator.dupe(u8, "");
        }
        return err;
    };
    return env_url;
}

/// Detect repository from git remote
fn detectRepoFromRemote(allocator: std.mem.Allocator) ![]const u8 {
    var result = try process.shell(allocator, "git remote get-url origin 2>/dev/null");
    defer result.deinit();

    if (result.success()) {
        const url = std.mem.trim(u8, result.stdout, " \t\n\r");
        // Parse URL to get owner/repo
        // Handle: https://host/owner/repo(.git)?
        if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
            var slash_count: u32 = 0;
            var start_idx: usize = 0;
            for (url, 0..) |c, i| {
                if (c == '/') {
                    slash_count += 1;
                    if (slash_count == 3) {
                        start_idx = i + 1;
                        break;
                    }
                }
            }
            if (start_idx > 0 and start_idx < url.len) {
                var repo_part = url[start_idx..];
                // Strip .git suffix if present
                if (std.mem.endsWith(u8, repo_part, ".git")) {
                    repo_part = repo_part[0 .. repo_part.len - 4];
                }
                return try allocator.dupe(u8, repo_part);
            }
        }
    }
    return allocator.dupe(u8, "");
}

/// Get token from environment variable
fn getTokenFromEnv(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "GITEA_TOKEN") catch null;
}

/// Extract issue number from Gitea API response
fn extractGiteaIssueNumber(response: []const u8) ?[]const u8 {
    // Look for "number":123 pattern
    const marker = "\"number\":";
    if (std.mem.indexOf(u8, response, marker)) |idx| {
        const start = idx + marker.len;
        var end = start;
        while (end < response.len and response[end] >= '0' and response[end] <= '9') : (end += 1) {}
        if (end > start) {
            return response[start..end];
        }
    }
    return null;
}

test "extract gitea issue number" {
    const response =
        \\{"id":1,"url":"...","number":42,"title":"Test"}
    ;
    try std.testing.expectEqualStrings("42", extractGiteaIssueNumber(response).?);
    try std.testing.expect(extractGiteaIssueNumber("{}") == null);
}
