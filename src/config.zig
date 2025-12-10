//! Configuration for the noface agent loop.
//!
//! Supports loading from TOML files or using defaults.

const std = @import("std");

/// Agent loop configuration
pub const Config = struct {
    /// Project name (used in prompts)
    project_name: []const u8 = "Project",

    /// Build command to verify project compiles
    build_command: []const u8 = "make build",

    /// Test command to verify tests pass
    test_command: []const u8 = "make test",

    /// Maximum iterations (0 = unlimited)
    max_iterations: u32 = 0,

    /// Specific issue to work on (null = pick from ready queue)
    specific_issue: ?[]const u8 = null,

    /// Dry run mode - don't execute, just show what would happen
    dry_run: bool = false,

    /// Enable scrum/grooming passes
    enable_scrum: bool = true,

    /// Scrum pass interval (every N iterations)
    scrum_interval: u32 = 5,

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

    /// Review agent command
    review_agent: []const u8 = "codex",

    /// Custom implementation prompt template (null = use default)
    impl_prompt_template: ?[]const u8 = null,

    /// Custom scrum prompt template (null = use default)
    scrum_prompt_template: ?[]const u8 = null,

    /// Custom quality prompt template (null = use default)
    quality_prompt_template: ?[]const u8 = null,

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
                        config.project_name = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "build")) {
                        config.build_command = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "test")) {
                        config.test_command = try allocator.dupe(u8, value);
                    }
                } else if (std.mem.eql(u8, current_section.?, "agents")) {
                    if (std.mem.eql(u8, key, "implementer")) {
                        config.impl_agent = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "reviewer")) {
                        config.review_agent = try allocator.dupe(u8, value);
                    }
                } else if (std.mem.eql(u8, current_section.?, "passes")) {
                    if (std.mem.eql(u8, key, "scrum_enabled")) {
                        config.enable_scrum = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "scrum_interval")) {
                        config.scrum_interval = std.fmt.parseInt(u32, value, 10) catch 5;
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
                }
            }
        }

        return config;
    }
};

test "default config" {
    const config = Config.default();
    try std.testing.expectEqual(@as(u32, 5), config.scrum_interval);
    try std.testing.expectEqual(@as(u32, 10), config.quality_interval);
    try std.testing.expect(config.enable_scrum);
}

test "parse toml" {
    const toml =
        \\[project]
        \\name = "TestProject"
        \\build = "zig build"
        \\test = "zig build test"
        \\
        \\[passes]
        \\scrum_interval = 3
        \\quality_enabled = false
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqualStrings("TestProject", config.project_name);
    try std.testing.expectEqualStrings("zig build", config.build_command);
    try std.testing.expectEqual(@as(u32, 3), config.scrum_interval);
    try std.testing.expect(!config.enable_quality);
}
