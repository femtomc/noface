//! Issue sync provider abstraction.
//!
//! Supports syncing beads issues to multiple providers (GitHub, Gitea, etc.)
//! through a unified interface.

const std = @import("std");
const process = @import("../util/process.zig");

/// Colors for terminal output
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const green = "\x1b[0;32m";
    pub const yellow = "\x1b[1;33m";
    pub const blue = "\x1b[0;34m";
    pub const red = "\x1b[0;31m";
};

/// Result of a sync operation
pub const SyncResult = struct {
    created: u32 = 0,
    updated: u32 = 0,
    closed: u32 = 0,
    skipped: u32 = 0,
    errors: u32 = 0,
};

/// Beads issue structure for sync
pub const BeadsIssue = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    priority: u8,
    issue_type: []const u8,

    pub fn deinit(self: *BeadsIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.status);
        allocator.free(self.issue_type);
    }
};

/// Issue sync provider type
pub const ProviderType = enum {
    github,
    gitea,
    none,

    pub fn fromString(s: []const u8) ProviderType {
        if (std.mem.eql(u8, s, "github")) return .github;
        if (std.mem.eql(u8, s, "gitea")) return .gitea;
        return .none;
    }

    pub fn toString(self: ProviderType) []const u8 {
        return switch (self) {
            .github => "GitHub",
            .gitea => "Gitea",
            .none => "None",
        };
    }
};

/// Provider configuration
pub const ProviderConfig = struct {
    /// Provider type
    provider_type: ProviderType = .github,

    /// Base URL for API (used by Gitea, ignored by GitHub which uses gh CLI)
    api_url: ?[]const u8 = null,

    /// Repository in "owner/repo" format
    repo: ?[]const u8 = null,

    /// API token (for Gitea direct API access)
    token: ?[]const u8 = null,
};

/// Issue provider interface (vtable pattern)
pub const IssueProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        checkPrerequisites: *const fn (*anyopaque) anyerror!void,
        loadMapping: *const fn (*anyopaque) anyerror!void,
        saveMapping: *const fn (*anyopaque) anyerror!void,
        sync: *const fn (*anyopaque) anyerror!SyncResult,
        deinit: *const fn (*anyopaque) void,
        getProviderName: *const fn () []const u8,
    };

    pub fn checkPrerequisites(self: IssueProvider) !void {
        return self.vtable.checkPrerequisites(self.ptr);
    }

    pub fn loadMapping(self: IssueProvider) !void {
        return self.vtable.loadMapping(self.ptr);
    }

    pub fn saveMapping(self: IssueProvider) !void {
        return self.vtable.saveMapping(self.ptr);
    }

    pub fn sync(self: IssueProvider) !SyncResult {
        return self.vtable.sync(self.ptr);
    }

    pub fn deinit(self: IssueProvider) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getProviderName(self: IssueProvider) []const u8 {
        return self.vtable.getProviderName();
    }
};

/// Create a provider based on configuration
pub fn createProvider(allocator: std.mem.Allocator, config: ProviderConfig, dry_run: bool) !?IssueProvider {
    const github = @import("github.zig");
    const gitea = @import("gitea.zig");

    return switch (config.provider_type) {
        .github => github.GitHubProvider.create(allocator, dry_run),
        .gitea => gitea.GiteaProvider.create(allocator, config, dry_run),
        .none => null,
    };
}

/// Sync issues to the configured provider
pub fn syncToProvider(allocator: std.mem.Allocator, config: ProviderConfig, dry_run: bool) !SyncResult {
    const provider = try createProvider(allocator, config, dry_run) orelse {
        return SyncResult{ .errors = 0 }; // No provider configured
    };
    defer provider.deinit();

    provider.checkPrerequisites() catch |err| {
        switch (err) {
            error.ProviderNotAvailable,
            error.NotAuthenticated,
            error.NotInRepository,
            => return SyncResult{ .errors = 1 },
            else => return err,
        }
    };

    try provider.loadMapping();
    return provider.sync();
}

// Logging helpers (shared by providers)
pub fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[INFO]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

pub fn logSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.green ++ "[SYNC]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

pub fn logSkip(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[SKIP]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

pub fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.red ++ "[ERROR]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

/// Parse beads issues JSON array
pub fn parseIssuesJson(allocator: std.mem.Allocator, json: []const u8, out: *std.ArrayListUnmanaged(BeadsIssue)) !void {
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
        'n' => i += 4, // null
        't' => i += 4, // true
        'f' => i += 5, // false
        '"' => {
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
        '[' => {
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
        '{' => {
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
pub fn unescapeJson(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
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

/// Get beads issues via bd CLI
pub fn getBeadsIssues(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(BeadsIssue) {
    var issues_result = try process.shell(allocator, "bd list --json 2>/dev/null");
    defer issues_result.deinit();

    if (!issues_result.success()) {
        logError("Failed to get beads issues", .{});
        return error.BeadsListFailed;
    }

    var issues = std.ArrayListUnmanaged(BeadsIssue){};
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    try parseIssuesJson(allocator, issues_result.stdout, &issues);
    return issues;
}

test "unescape json" {
    const result = try unescapeJson(std.testing.allocator, "hello\\nworld\\t!");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld\t!", result);
}

test "provider type from string" {
    try std.testing.expectEqual(ProviderType.github, ProviderType.fromString("github"));
    try std.testing.expectEqual(ProviderType.gitea, ProviderType.fromString("gitea"));
    try std.testing.expectEqual(ProviderType.none, ProviderType.fromString("unknown"));
}
