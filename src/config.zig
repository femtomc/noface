//! Configuration for the noface agent loop.
//!
//! Supports loading from TOML files or using defaults.

const std = @import("std");
const monowiki = @import("monowiki.zig");

/// Output format for agent sessions
pub const OutputFormat = enum {
    text, // Human-readable text with markdown rendering
    stream_json, // Raw JSON streaming for programmatic use
    raw, // Plain text without markdown rendering
};

/// Agent loop configuration
pub const Config = struct {
    /// Project name (used in prompts)
    project_name: []const u8 = "Project",
    project_name_owned: bool = false,

    /// Build command to verify project compiles
    build_command: []const u8 = "make build",
    build_command_owned: bool = false,

    /// Test command to verify tests pass
    test_command: []const u8 = "make test",
    test_command_owned: bool = false,

    /// Maximum iterations (0 = unlimited)
    max_iterations: u32 = 0,

    /// Specific issue to work on (null = pick from ready queue)
    specific_issue: ?[]const u8 = null,

    /// Dry run mode - don't execute, just show what would happen
    dry_run: bool = false,

    /// Enable planner passes (strategic planning from design docs)
    enable_planner: bool = true,

    /// Planner pass interval (every N iterations)
    planner_interval: u32 = 5,

    /// Enable code quality review passes
    enable_quality: bool = true,

    /// Quality review interval (every N iterations)
    quality_interval: u32 = 10,

    /// Issue tracker type
    issue_tracker: IssueTracker = .beads,

    /// Sync issues to GitHub
    sync_to_github: bool = true,

    /// Implementation agent command
    impl_agent: []const u8 = "claude",
    impl_agent_owned: bool = false,

    /// Review agent command
    review_agent: []const u8 = "codex",
    review_agent_owned: bool = false,

    /// Custom implementation prompt template (null = use default)
    impl_prompt_template: ?[]const u8 = null,

    /// Custom planner prompt template (null = use default)
    planner_prompt_template: ?[]const u8 = null,

    /// Custom quality prompt template (null = use default)
    quality_prompt_template: ?[]const u8 = null,

    /// Output format
    output_format: OutputFormat = .text,

    /// Directory to store JSON session logs
    log_dir: []const u8 = "/tmp",

    /// Path to progress markdown file (null = don't update)
    progress_file: ?[]const u8 = null,

    /// Monowiki vault path for design documents (null = disabled)
    /// Deprecated: Use monowiki_config instead
    monowiki_vault: ?[]const u8 = null,

    /// Full monowiki configuration
    monowiki_config: ?monowiki.MonowikiConfig = null,

    pub const IssueTracker = enum {
        beads,
        github,
    };

    /// Returns default configuration
    pub fn default() Config {
        return .{};
    }

    /// Load configuration from a TOML file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Error: Could not open config file '{s}': {}\n", .{ path, err });
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            std.debug.print("Error: Could not read config file: {}\n", .{err});
            return err;
        };
        defer allocator.free(content);

        return parseToml(allocator, content);
    }

    /// Try to load .noface.toml from current directory, return default if not found
    pub fn loadOrDefault(allocator: std.mem.Allocator) Config {
        return loadFromFile(allocator, ".noface.toml") catch Config.default();
    }

    /// Parse TOML content into Config
    fn parseToml(allocator: std.mem.Allocator, content: []const u8) !Config {
        var config = Config.default();
        errdefer config.deinit(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_section: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Section header
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                current_section = trimmed[1 .. trimmed.len - 1];
                continue;
            }

            // Key = value
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

                // Strip quotes from string values
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }

                // Apply based on section
                if (current_section == null or std.mem.eql(u8, current_section.?, "project")) {
                    if (std.mem.eql(u8, key, "name")) {
                        try setOwnedString(allocator, &config.project_name, &config.project_name_owned, value);
                    } else if (std.mem.eql(u8, key, "build")) {
                        try setOwnedString(allocator, &config.build_command, &config.build_command_owned, value);
                    } else if (std.mem.eql(u8, key, "test")) {
                        try setOwnedString(allocator, &config.test_command, &config.test_command_owned, value);
                    }
                } else if (std.mem.eql(u8, current_section.?, "agents")) {
                    if (std.mem.eql(u8, key, "implementer")) {
                        try setOwnedString(allocator, &config.impl_agent, &config.impl_agent_owned, value);
                    } else if (std.mem.eql(u8, key, "reviewer")) {
                        try setOwnedString(allocator, &config.review_agent, &config.review_agent_owned, value);
                    }
                } else if (std.mem.eql(u8, current_section.?, "passes")) {
                    if (std.mem.eql(u8, key, "planner_enabled")) {
                        config.enable_planner = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "planner_interval")) {
                        config.planner_interval = std.fmt.parseInt(u32, value, 10) catch 5;
                    } else if (std.mem.eql(u8, key, "quality_enabled")) {
                        config.enable_quality = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "quality_interval")) {
                        config.quality_interval = std.fmt.parseInt(u32, value, 10) catch 10;
                    }
                } else if (std.mem.eql(u8, current_section.?, "tracker")) {
                    if (std.mem.eql(u8, key, "type")) {
                        if (std.mem.eql(u8, value, "github")) {
                            config.issue_tracker = .github;
                        } else {
                            config.issue_tracker = .beads;
                        }
                    } else if (std.mem.eql(u8, key, "sync_to_github")) {
                        config.sync_to_github = std.mem.eql(u8, value, "true");
                    }
                } else if (std.mem.eql(u8, current_section.?, "monowiki")) {
                    // Initialize monowiki config if not yet done
                    if (config.monowiki_config == null) {
                        config.monowiki_config = .{ .vault = "" };
                    }
                    if (std.mem.eql(u8, key, "vault")) {
                        config.monowiki_config.?.vault = try allocator.dupe(u8, value);
                        // Also set legacy field for backwards compatibility
                        config.monowiki_vault = config.monowiki_config.?.vault;
                    } else if (std.mem.eql(u8, key, "proactive_search")) {
                        config.monowiki_config.?.proactive_search = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "resolve_wikilinks")) {
                        config.monowiki_config.?.resolve_wikilinks = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "expand_neighbors")) {
                        config.monowiki_config.?.expand_neighbors = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "neighbor_depth")) {
                        config.monowiki_config.?.neighbor_depth = std.fmt.parseInt(u8, value, 10) catch 1;
                    } else if (std.mem.eql(u8, key, "api_docs_slug")) {
                        config.monowiki_config.?.api_docs_slug = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "sync_api_docs")) {
                        config.monowiki_config.?.sync_api_docs = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "max_context_docs")) {
                        config.monowiki_config.?.max_context_docs = std.fmt.parseInt(u8, value, 10) catch 5;
                    }
                }
            }
        }

        return config;
    }

    /// Free any owned fields allocated during parsing
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.project_name_owned) {
            allocator.free(self.project_name);
            self.project_name_owned = false;
        }
        if (self.build_command_owned) {
            allocator.free(self.build_command);
            self.build_command_owned = false;
        }
        if (self.test_command_owned) {
            allocator.free(self.test_command);
            self.test_command_owned = false;
        }
        if (self.impl_agent_owned) {
            allocator.free(self.impl_agent);
            self.impl_agent_owned = false;
        }
        if (self.review_agent_owned) {
            allocator.free(self.review_agent);
            self.review_agent_owned = false;
        }
        // Free monowiki config strings
        if (self.monowiki_config) |*mwc| {
            if (mwc.vault.len > 0) {
                allocator.free(mwc.vault);
            }
            if (mwc.api_docs_slug) |slug| {
                allocator.free(slug);
            }
        }
    }
};

/// Replace a string field, freeing previous owned value if needed
fn setOwnedString(
    allocator: std.mem.Allocator,
    field: *[]const u8,
    owned_flag: *bool,
    value: []const u8,
) !void {
    if (owned_flag.*) {
        allocator.free(field.*);
    }
    field.* = try allocator.dupe(u8, value);
    owned_flag.* = true;
}

test "default config" {
    const config = Config.default();
    try std.testing.expectEqual(@as(u32, 5), config.planner_interval);
    try std.testing.expectEqual(@as(u32, 10), config.quality_interval);
    try std.testing.expect(config.enable_planner);
}

test "parse toml" {
    const toml =
        \\[project]
        \\name = "TestProject"
        \\build = "zig build"
        \\test = "zig build test"
        \\
        \\[passes]
        \\planner_interval = 3
        \\quality_enabled = false
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqualStrings("TestProject", config.project_name);
    try std.testing.expectEqualStrings("zig build", config.build_command);
    try std.testing.expectEqual(@as(u32, 3), config.planner_interval);
    try std.testing.expect(!config.enable_quality);
}

test "parse monowiki config" {
    const toml =
        \\[project]
        \\name = "TestProject"
        \\
        \\[monowiki]
        \\vault = "./docs"
        \\proactive_search = true
        \\resolve_wikilinks = true
        \\expand_neighbors = false
        \\api_docs_slug = "api-reference"
        \\sync_api_docs = true
        \\max_context_docs = 3
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(config.monowiki_config != null);
    const mwc = config.monowiki_config.?;
    try std.testing.expectEqualStrings("./docs", mwc.vault);
    try std.testing.expect(mwc.proactive_search);
    try std.testing.expect(mwc.resolve_wikilinks);
    try std.testing.expect(!mwc.expand_neighbors);
    try std.testing.expectEqualStrings("api-reference", mwc.api_docs_slug.?);
    try std.testing.expect(mwc.sync_api_docs);
    try std.testing.expectEqual(@as(u8, 3), mwc.max_context_docs);
}
