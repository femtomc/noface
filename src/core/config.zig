//! Configuration for the noface agent loop.
//!
//! Supports loading from TOML files or using defaults.

const std = @import("std");
const monowiki = @import("../integrations/monowiki.zig");
const issue_sync = @import("../integrations/issue_sync.zig");
const process = @import("../util/process.zig");

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
    compact, // Concise status updates (like workers)
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

    /// Sync issues to GitHub (legacy, use sync_provider instead)
    sync_to_github: bool = true,

    /// Issue sync provider configuration
    sync_provider: issue_sync.ProviderConfig = .{},

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
    num_workers: u32 = 5,

    /// Output format
    output_format: OutputFormat = .compact,

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

    /// TOML parsing error with file/line context
    pub const TomlError = error{
        UnterminatedString,
        InvalidEscapeSequence,
        InvalidSectionHeader,
        MissingEquals,
        InvalidValue,
        UnexpectedCharacter,
        OutOfMemory,
    };

    /// TOML value types we support
    const TomlValue = union(enum) {
        string: []const u8,
        boolean: bool,
        integer: i64,
    };

    /// Parse a TOML quoted string, handling escape sequences
    /// Returns the unquoted, unescaped content and whether memory was allocated
    fn parseQuotedString(allocator: std.mem.Allocator, input: []const u8) TomlError!struct { value: []const u8, owned: bool } {
        if (input.len < 2 or input[0] != '"') {
            return .{ .value = input, .owned = false };
        }

        // Find the closing quote, handling escapes
        var end_idx: usize = 1;
        var has_escapes = false;
        while (end_idx < input.len) {
            if (input[end_idx] == '\\' and end_idx + 1 < input.len) {
                has_escapes = true;
                end_idx += 2; // skip escape sequence
            } else if (input[end_idx] == '"') {
                break;
            } else {
                end_idx += 1;
            }
        }

        if (end_idx >= input.len or input[end_idx] != '"') {
            return TomlError.UnterminatedString;
        }

        const content = input[1..end_idx];

        if (!has_escapes) {
            return .{ .value = content, .owned = false };
        }

        // Process escape sequences
        var result = allocator.alloc(u8, content.len) catch return TomlError.OutOfMemory;
        var write_idx: usize = 0;
        var read_idx: usize = 0;

        while (read_idx < content.len) {
            if (content[read_idx] == '\\' and read_idx + 1 < content.len) {
                const escaped = content[read_idx + 1];
                const replacement: u8 = switch (escaped) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    else => {
                        allocator.free(result);
                        return TomlError.InvalidEscapeSequence;
                    },
                };
                result[write_idx] = replacement;
                write_idx += 1;
                read_idx += 2;
            } else {
                result[write_idx] = content[read_idx];
                write_idx += 1;
                read_idx += 1;
            }
        }

        return .{ .value = allocator.realloc(result, write_idx) catch result[0..write_idx], .owned = true };
    }

    /// Parse a TOML value (string, boolean, or integer)
    fn parseTomlValue(allocator: std.mem.Allocator, raw_value: []const u8) TomlError!struct { value: TomlValue, owned: bool } {
        const trimmed = std.mem.trim(u8, raw_value, " \t");
        if (trimmed.len == 0) {
            return TomlError.InvalidValue;
        }

        // Quoted string
        if (trimmed[0] == '"') {
            const parsed = try parseQuotedString(allocator, trimmed);
            return .{ .value = .{ .string = parsed.value }, .owned = parsed.owned };
        }

        // Boolean
        if (std.mem.eql(u8, trimmed, "true")) {
            return .{ .value = .{ .boolean = true }, .owned = false };
        }
        if (std.mem.eql(u8, trimmed, "false")) {
            return .{ .value = .{ .boolean = false }, .owned = false };
        }

        // Integer
        if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
            return .{ .value = .{ .integer = int_val }, .owned = false };
        } else |_| {}

        // Unquoted string (bare key style - for backwards compat, treat as string)
        // But first strip any inline comment
        var value_end = trimmed.len;
        for (trimmed, 0..) |c, i| {
            if (c == '#') {
                value_end = i;
                break;
            }
        }
        const final_value = std.mem.trimRight(u8, trimmed[0..value_end], " \t");
        if (final_value.len == 0) {
            return TomlError.InvalidValue;
        }
        return .{ .value = .{ .string = final_value }, .owned = false };
    }

    /// Strip inline comment from a line, respecting quoted strings
    fn stripInlineComment(line: []const u8) []const u8 {
        var in_string = false;
        var i: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
                in_string = !in_string;
            } else if (c == '#' and !in_string) {
                return std.mem.trimRight(u8, line[0..i], " \t");
            }
            i += 1;
        }
        return line;
    }

    /// Find the equals sign in a key=value line, respecting quoted keys (rare but valid TOML)
    fn findEqualsSign(line: []const u8) ?usize {
        var in_string = false;
        for (line, 0..) |c, i| {
            if (c == '"') {
                in_string = !in_string;
            } else if (c == '=' and !in_string) {
                return i;
            }
        }
        return null;
    }

    /// Parse TOML content into Config with proper validation
    fn parseToml(allocator: std.mem.Allocator, content: []const u8) !Config {
        var config = Config.default();
        errdefer config.deinit(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_section: ?[]const u8 = null;
        var line_num: u32 = 0;

        while (lines.next()) |raw_line| {
            line_num += 1;
            const line = std.mem.trim(u8, raw_line, " \t\r");

            // Skip empty lines and full-line comments
            if (line.len == 0 or line[0] == '#') continue;

            // Section header
            if (line[0] == '[') {
                if (line[line.len - 1] != ']') {
                    std.debug.print("Error: .noface.toml:{d}: malformed section header (missing closing ']')\n", .{line_num});
                    return TomlError.InvalidSectionHeader;
                }
                current_section = line[1 .. line.len - 1];
                continue;
            }

            // Key = value
            const eq_idx = findEqualsSign(line) orelse {
                std.debug.print("Error: .noface.toml:{d}: expected '=' in key-value pair\n", .{line_num});
                return TomlError.MissingEquals;
            };

            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const raw_value = stripInlineComment(std.mem.trim(u8, line[eq_idx + 1 ..], " \t"));

            // Parse the value with proper TOML semantics
            const parsed = parseTomlValue(allocator, raw_value) catch |err| {
                const err_msg = switch (err) {
                    TomlError.UnterminatedString => "unterminated string (missing closing quote)",
                    TomlError.InvalidEscapeSequence => "invalid escape sequence in string",
                    TomlError.InvalidValue => "invalid or empty value",
                    else => "parsing error",
                };
                std.debug.print("Error: .noface.toml:{d}: {s}\n", .{ line_num, err_msg });
                return err;
            };
            defer if (parsed.owned) {
                switch (parsed.value) {
                    .string => |s| allocator.free(s),
                    else => {},
                }
            };

            // Extract string value for fields that expect strings
            const string_value: ?[]const u8 = switch (parsed.value) {
                .string => |s| s,
                .boolean => |b| if (b) "true" else "false",
                .integer => null,
            };

            // Extract bool value
            const bool_value: ?bool = switch (parsed.value) {
                .boolean => |b| b,
                .string => |s| if (std.mem.eql(u8, s, "true")) true else if (std.mem.eql(u8, s, "false")) false else null,
                .integer => null,
            };

            // Extract integer value
            const int_value: ?i64 = switch (parsed.value) {
                .integer => |i| i,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                .boolean => null,
            };

            // Apply based on section
            if (current_section == null or std.mem.eql(u8, current_section.?, "project")) {
                if (std.mem.eql(u8, key, "name")) {
                    if (string_value) |sv| try setOwnedString(allocator, &config.project_name, &config.project_name_owned, sv);
                } else if (std.mem.eql(u8, key, "build")) {
                    if (string_value) |sv| try setOwnedString(allocator, &config.build_command, &config.build_command_owned, sv);
                } else if (std.mem.eql(u8, key, "test")) {
                    if (string_value) |sv| try setOwnedString(allocator, &config.test_command, &config.test_command_owned, sv);
                }
            } else if (std.mem.eql(u8, current_section.?, "agents")) {
                if (std.mem.eql(u8, key, "implementer")) {
                    if (string_value) |sv| try setOwnedString(allocator, &config.impl_agent, &config.impl_agent_owned, sv);
                } else if (std.mem.eql(u8, key, "reviewer")) {
                    if (string_value) |sv| try setOwnedString(allocator, &config.review_agent, &config.review_agent_owned, sv);
                } else if (std.mem.eql(u8, key, "timeout_seconds")) {
                    if (int_value) |iv| {
                        if (iv <= 0) {
                            std.debug.print("Warning: .noface.toml:{d}: timeout_seconds must be positive, using default\n", .{line_num});
                        } else if (iv > std.math.maxInt(u32)) {
                            std.debug.print("Warning: .noface.toml:{d}: timeout_seconds too large, using default\n", .{line_num});
                        } else {
                            config.agent_timeout_seconds = @intCast(iv);
                        }
                    } else {
                        std.debug.print("Warning: .noface.toml:{d}: timeout_seconds must be an integer\n", .{line_num});
                    }
                } else if (std.mem.eql(u8, key, "num_workers")) {
                    if (int_value) |iv| {
                        if (iv < 1 or iv > 8) {
                            std.debug.print("Warning: .noface.toml:{d}: num_workers must be 1-8, using default\n", .{line_num});
                        } else {
                            config.num_workers = @intCast(iv);
                        }
                    } else {
                        std.debug.print("Warning: .noface.toml:{d}: num_workers must be an integer\n", .{line_num});
                    }
                } else if (std.mem.eql(u8, key, "verbose")) {
                    if (bool_value) |bv| {
                        config.verbose = bv;
                    } else {
                        std.debug.print("Warning: .noface.toml:{d}: verbose must be true or false\n", .{line_num});
                    }
                }
            } else if (std.mem.eql(u8, current_section.?, "passes")) {
                // scrum_enabled/scrum_interval are the design doc names; planner_* are aliases
                if (std.mem.eql(u8, key, "scrum_enabled") or std.mem.eql(u8, key, "planner_enabled")) {
                    if (bool_value) |bv| {
                        config.enable_planner = bv;
                    } else {
                        std.debug.print("Warning: .noface.toml:{d}: {s} must be true or false\n", .{ line_num, key });
                    }
                } else if (std.mem.eql(u8, key, "scrum_interval") or std.mem.eql(u8, key, "planner_interval")) {
                    if (int_value) |iv| {
                        if (iv > 0 and iv <= std.math.maxInt(u32)) {
                            config.planner_interval = @intCast(iv);
                        }
                    }
                } else if (std.mem.eql(u8, key, "scrum_mode") or std.mem.eql(u8, key, "planner_mode")) {
                    if (string_value) |sv| {
                        if (std.mem.eql(u8, sv, "event_driven")) {
                            config.planner_mode = .event_driven;
                        } else {
                            config.planner_mode = .interval;
                        }
                    }
                } else if (std.mem.eql(u8, key, "quality_enabled")) {
                    if (bool_value) |bv| {
                        config.enable_quality = bv;
                    } else {
                        std.debug.print("Warning: .noface.toml:{d}: quality_enabled must be true or false\n", .{line_num});
                    }
                } else if (std.mem.eql(u8, key, "quality_interval")) {
                    if (int_value) |iv| {
                        if (iv > 0 and iv <= std.math.maxInt(u32)) {
                            config.quality_interval = @intCast(iv);
                        }
                    }
                }
            } else if (std.mem.eql(u8, current_section.?, "tracker")) {
                if (std.mem.eql(u8, key, "type")) {
                    if (string_value) |sv| {
                        if (std.mem.eql(u8, sv, "github")) {
                            config.issue_tracker = .github;
                        } else {
                            config.issue_tracker = .beads;
                        }
                    }
                } else if (std.mem.eql(u8, key, "sync_to_github")) {
                    if (bool_value) |bv| {
                        config.sync_to_github = bv;
                    }
                }
            } else if (std.mem.eql(u8, current_section.?, "sync")) {
                // Issue sync provider configuration
                if (std.mem.eql(u8, key, "provider")) {
                    if (string_value) |sv| {
                        config.sync_provider.provider_type = issue_sync.ProviderType.fromString(sv);
                    }
                } else if (std.mem.eql(u8, key, "api_url")) {
                    if (string_value) |sv| {
                        config.sync_provider.api_url = try allocator.dupe(u8, sv);
                    }
                } else if (std.mem.eql(u8, key, "repo")) {
                    if (string_value) |sv| {
                        config.sync_provider.repo = try allocator.dupe(u8, sv);
                    }
                } else if (std.mem.eql(u8, key, "token")) {
                    if (string_value) |sv| {
                        config.sync_provider.token = try allocator.dupe(u8, sv);
                    }
                }
            } else if (std.mem.eql(u8, current_section.?, "monowiki")) {
                // Initialize monowiki config if not yet done
                if (config.monowiki_config == null) {
                    config.monowiki_config = .{ .vault = "" };
                }
                if (std.mem.eql(u8, key, "vault")) {
                    if (string_value) |sv| {
                        config.monowiki_config.?.vault = try allocator.dupe(u8, sv);
                        // Also set legacy field for backwards compatibility
                        config.monowiki_vault = config.monowiki_config.?.vault;
                    }
                } else if (std.mem.eql(u8, key, "proactive_search")) {
                    if (bool_value) |bv| config.monowiki_config.?.proactive_search = bv;
                } else if (std.mem.eql(u8, key, "resolve_wikilinks")) {
                    if (bool_value) |bv| config.monowiki_config.?.resolve_wikilinks = bv;
                } else if (std.mem.eql(u8, key, "expand_neighbors")) {
                    if (bool_value) |bv| config.monowiki_config.?.expand_neighbors = bv;
                } else if (std.mem.eql(u8, key, "neighbor_depth")) {
                    if (int_value) |iv| {
                        if (iv >= 0 and iv <= 255) {
                            config.monowiki_config.?.neighbor_depth = @intCast(iv);
                        }
                    }
                } else if (std.mem.eql(u8, key, "api_docs_slug")) {
                    if (string_value) |sv| {
                        config.monowiki_config.?.api_docs_slug = try allocator.dupe(u8, sv);
                    }
                } else if (std.mem.eql(u8, key, "sync_api_docs")) {
                    if (bool_value) |bv| config.monowiki_config.?.sync_api_docs = bv;
                } else if (std.mem.eql(u8, key, "max_context_docs")) {
                    if (int_value) |iv| {
                        if (iv >= 0 and iv <= 255) {
                            config.monowiki_config.?.max_context_docs = @intCast(iv);
                        }
                    }
                } else if (std.mem.eql(u8, key, "max_file_size_kb")) {
                    if (int_value) |iv| {
                        if (iv > 0 and iv <= std.math.maxInt(u32)) {
                            config.monowiki_config.?.exclusions.max_file_size_kb = @intCast(iv);
                        } else {
                            std.debug.print("Warning: .noface.toml:{d}: max_file_size_kb must be positive\n", .{line_num});
                        }
                    } else {
                        std.debug.print("Warning: .noface.toml:{d}: max_file_size_kb must be an integer\n", .{line_num});
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
        // Free sync provider config strings
        if (self.sync_provider.api_url) |url| {
            allocator.free(url);
        }
        if (self.sync_provider.repo) |repo| {
            allocator.free(repo);
        }
        if (self.sync_provider.token) |token| {
            allocator.free(token);
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
    // 10 is too high, should keep default 5
    try std.testing.expectEqual(@as(u32, 5), config.num_workers);
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

test "parse monowiki max_file_size_kb config" {
    const toml =
        \\[monowiki]
        \\vault = "./docs"
        \\max_file_size_kb = 200
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(config.monowiki_config != null);
    const mwc = config.monowiki_config.?;
    try std.testing.expectEqual(@as(u32, 200), mwc.exclusions.max_file_size_kb);
}

test "default max_file_size_kb is 100" {
    // ExclusionConfig struct defaults are used when not customized
    const default_exclusions = monowiki.ExclusionConfig{};
    try std.testing.expectEqual(@as(u32, 100), default_exclusions.max_file_size_kb);
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

test "parse inline comments" {
    const toml =
        \\[tracker]
        \\type = "beads"          # or "github"
        \\sync_to_github = true   # enable sync
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqual(Config.IssueTracker.beads, config.issue_tracker);
    try std.testing.expect(config.sync_to_github);
}

test "parse string with equals sign" {
    const toml =
        \\[project]
        \\build = "make VAR=value build"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqualStrings("make VAR=value build", config.build_command);
}

test "parse escape sequences" {
    const toml =
        \\[project]
        \\name = "Test\tProject\nWith\\Escapes"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqualStrings("Test\tProject\nWith\\Escapes", config.project_name);
}

test "parse escaped quotes in string" {
    const toml =
        \\[project]
        \\name = "Test \"Quoted\" Project"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqualStrings("Test \"Quoted\" Project", config.project_name);
}

test "reject unterminated string" {
    const toml =
        \\[project]
        \\name = "Unterminated
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = Config.parseToml(arena.allocator(), toml);
    try std.testing.expectError(Config.TomlError.UnterminatedString, result);
}

test "reject malformed section header" {
    const toml =
        \\[project
        \\name = "Test"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = Config.parseToml(arena.allocator(), toml);
    try std.testing.expectError(Config.TomlError.InvalidSectionHeader, result);
}

test "reject line without equals" {
    const toml =
        \\[project]
        \\name "Test"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = Config.parseToml(arena.allocator(), toml);
    try std.testing.expectError(Config.TomlError.MissingEquals, result);
}

test "parse hash in quoted string preserved" {
    const toml =
        \\[project]
        \\name = "Test # Not a comment"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expectEqualStrings("Test # Not a comment", config.project_name);
}

test "parse native booleans" {
    const toml =
        \\[passes]
        \\planner_enabled = true
        \\quality_enabled = false
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(config.enable_planner);
    try std.testing.expect(!config.enable_quality);
}

test "parse boolean with inline comment" {
    const toml =
        \\[passes]
        \\planner_enabled = true  # enable the planner
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try Config.parseToml(arena.allocator(), toml);
    try std.testing.expect(config.enable_planner);
}

test "reject invalid escape sequence" {
    const toml =
        \\[project]
        \\name = "Invalid\xEscape"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = Config.parseToml(arena.allocator(), toml);
    try std.testing.expectError(Config.TomlError.InvalidEscapeSequence, result);
}
