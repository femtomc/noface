//! Configuration for the noface agent loop.
//!
//! Supports loading from TOML files or using defaults.

const std = @import("std");
const monowiki = @import("monowiki.zig");
const process = @import("process.zig");

/// Validation warning for config issues
pub const ValidationWarning = struct {
    line: u32,
    message: []const u8,
    suggestion: ?[]const u8 = null,
    is_critical: bool = false,
};

/// Result of config validation
pub const ValidationResult = struct {
    warnings: std.ArrayListUnmanaged(ValidationWarning),
    allocator: std.mem.Allocator,
    has_critical: bool = false,

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .warnings = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        for (self.warnings.items) |w| {
            self.allocator.free(w.message);
            if (w.suggestion) |s| {
                self.allocator.free(s);
            }
        }
        self.warnings.deinit(self.allocator);
    }

    pub fn addWarning(self: *ValidationResult, line: u32, message: []const u8, suggestion: ?[]const u8) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(msg_copy);
        const sug_copy = if (suggestion) |s| try self.allocator.dupe(u8, s) else null;
        try self.warnings.append(self.allocator, .{
            .line = line,
            .message = msg_copy,
            .suggestion = sug_copy,
        });
    }

    pub fn addCritical(self: *ValidationResult, line: u32, message: []const u8, suggestion: ?[]const u8) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(msg_copy);
        const sug_copy = if (suggestion) |s| try self.allocator.dupe(u8, s) else null;
        try self.warnings.append(self.allocator, .{
            .line = line,
            .message = msg_copy,
            .suggestion = sug_copy,
            .is_critical = true,
        });
        self.has_critical = true;
    }

    /// Print all warnings to stderr
    pub fn printWarnings(self: *const ValidationResult, path: []const u8) void {
        if (self.warnings.items.len == 0) return;

        std.debug.print("\n\x1b[1;33mConfig validation warnings:\x1b[0m\n", .{});
        for (self.warnings.items) |w| {
            const severity = if (w.is_critical) "\x1b[1;31mERROR\x1b[0m" else "\x1b[1;33mWARN\x1b[0m";
            std.debug.print("  {s}: {s}:{d}: {s}\n", .{ severity, path, w.line, w.message });
            if (w.suggestion) |s| {
                std.debug.print("         \x1b[36msuggestion:\x1b[0m {s}\n", .{s});
            }
        }
        std.debug.print("\n", .{});
    }
};

/// Output format for agent sessions
pub const OutputFormat = enum {
    text, // Human-readable text with markdown rendering
    stream_json, // Raw JSON streaming for programmatic use
    raw, // Plain text without markdown rendering
};

/// Planner invocation mode
pub const PlannerMode = enum {
    interval, // Run planner every N iterations (default, backwards compatible)
    event_driven, // Run planner only when needed: no ready issues, batch completed
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

    /// Planner pass interval (every N iterations, only used in interval mode)
    planner_interval: u32 = 5,

    /// Planner invocation mode (interval or event_driven)
    planner_mode: PlannerMode = .interval,

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

    /// Agent timeout in seconds (0 = no timeout)
    /// If an agent produces no output for this duration, it is killed
    agent_timeout_seconds: u32 = 900,  // 15 minutes - complex issues need time

    /// Number of parallel workers for batch execution (1-8)
    num_workers: u32 = 3,

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

    /// User directions for the planner (e.g., "prioritize issue X", "focus on Y")
    planner_directions: ?[]const u8 = null,

    /// Verbose mode - show detailed logging (commands, timings, prompts, API responses)
    verbose: bool = false,

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
                    } else if (std.mem.eql(u8, key, "timeout_seconds")) {
                        const timeout = std.fmt.parseInt(u32, value, 10) catch {
                            std.debug.print("Warning: invalid timeout_seconds value '{s}', using default 300\n", .{value});
                            continue;
                        };
                        if (timeout == 0) {
                            std.debug.print("Warning: timeout_seconds cannot be 0, using default 300\n", .{});
                            continue;
                        }
                        config.agent_timeout_seconds = timeout;
                    } else if (std.mem.eql(u8, key, "num_workers")) {
                        const num = std.fmt.parseInt(u32, value, 10) catch {
                            std.debug.print("Warning: invalid num_workers value '{s}', using default 3\n", .{value});
                            continue;
                        };
                        if (num == 0 or num > 8) {
                            std.debug.print("Warning: num_workers must be 1-8, using default 3\n", .{});
                            continue;
                        }
                        config.num_workers = num;
                    } else if (std.mem.eql(u8, key, "verbose")) {
                        config.verbose = std.mem.eql(u8, value, "true");
                    }
                } else if (std.mem.eql(u8, current_section.?, "passes")) {
                    // scrum_enabled/scrum_interval are the design doc names; planner_* are aliases
                    if (std.mem.eql(u8, key, "scrum_enabled") or std.mem.eql(u8, key, "planner_enabled")) {
                        config.enable_planner = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "scrum_interval") or std.mem.eql(u8, key, "planner_interval")) {
                        config.planner_interval = std.fmt.parseInt(u32, value, 10) catch 5;
                    } else if (std.mem.eql(u8, key, "scrum_mode") or std.mem.eql(u8, key, "planner_mode")) {
                        if (std.mem.eql(u8, value, "event_driven")) {
                            config.planner_mode = .event_driven;
                        } else {
                            config.planner_mode = .interval;
                        }
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
    try std.testing.expectEqual(@as(u32, 900), config.agent_timeout_seconds);
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

test "parse agents timeout config" {
    const toml =
        \\[project]
        \\name = "TestProject"
        \\
        \\[agents]
        \\implementer = "claude"
        \\reviewer = "codex"
        \\timeout_seconds = 600
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqual(@as(u32, 600), config.agent_timeout_seconds);
}

test "parse agents timeout zero rejected" {
    const toml =
        \\[agents]
        \\timeout_seconds = 0
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    // Zero is rejected, should keep default
    try std.testing.expectEqual(@as(u32, 900), config.agent_timeout_seconds);
}

test "parse agents num_workers config" {
    const toml =
        \\[agents]
        \\num_workers = 5
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqual(@as(u32, 5), config.num_workers);
}

test "parse agents num_workers invalid rejected" {
    const toml =
        \\[agents]
        \\num_workers = 10
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    // 10 is too high, should keep default 3
    try std.testing.expectEqual(@as(u32, 3), config.num_workers);
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

test "parse verbose config" {
    const toml =
        \\[agents]
        \\verbose = true
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(config.verbose);
}

test "default verbose is false" {
    const config = Config.default();
    try std.testing.expect(!config.verbose);
}

test "parse scrum config keys" {
    const toml =
        \\[passes]
        \\scrum_enabled = false
        \\scrum_interval = 7
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(!config.enable_planner);
    try std.testing.expectEqual(@as(u32, 7), config.planner_interval);
}

test "parse planner config keys as aliases" {
    const toml =
        \\[passes]
        \\planner_enabled = false
        \\planner_interval = 8
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(!config.enable_planner);
    try std.testing.expectEqual(@as(u32, 8), config.planner_interval);
}

test "parse planner mode event_driven" {
    const toml =
        \\[passes]
        \\planner_mode = "event_driven"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqual(PlannerMode.event_driven, config.planner_mode);
}

test "parse planner mode interval (explicit)" {
    const toml =
        \\[passes]
        \\planner_mode = "interval"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqual(PlannerMode.interval, config.planner_mode);
}

test "default planner mode is interval" {
    const config = Config.default();
    try std.testing.expectEqual(PlannerMode.interval, config.planner_mode);
}

test "parse scrum_mode as alias for planner_mode" {
    const toml =
        \\[passes]
        \\scrum_mode = "event_driven"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqual(PlannerMode.event_driven, config.planner_mode);
}
