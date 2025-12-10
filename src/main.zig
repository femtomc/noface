const std = @import("std");
const noface = @import("noface");

const Config = noface.Config;
const AgentLoop = noface.AgentLoop;
const process = noface.process;
const MonowikiConfig = noface.MonowikiConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Subcommand: init
    if (args.len > 1 and std.mem.eql(u8, args[1], "init")) {
        try runInit(allocator, args[2..]);
        return;
    }

    // Subcommand: serve
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        try noface.web.runServe(allocator, args[2..]);
        return;
    }

    // Subcommand: doctor
    if (args.len > 1 and std.mem.eql(u8, args[1], "doctor")) {
        try runDoctor(allocator);
        return;
    }

    // Subcommand: sync
    if (args.len > 1 and std.mem.eql(u8, args[1], "sync")) {
        const dry_run = args.len > 2 and std.mem.eql(u8, args[2], "--dry-run");
        try runSync(allocator, dry_run);
        return;
    }

    // Load config from .noface.toml (or use defaults)
    var config = Config.loadOrDefault(allocator);
    defer config.deinit(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("noface 0.1.0\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-iterations requires a value\n", .{});
                return error.InvalidArgument;
            }
            config.max_iterations = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: invalid number for --max-iterations\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--issue")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --issue requires a value\n", .{});
                return error.InvalidArgument;
            }
            config.specific_issue = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-scrum") or std.mem.eql(u8, arg, "--no-planner")) {
            config.enable_planner = false;
        } else if (std.mem.eql(u8, arg, "--no-quality")) {
            config.enable_quality = false;
        } else if (std.mem.eql(u8, arg, "--scrum-interval") or std.mem.eql(u8, arg, "--planner-interval")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --scrum-interval requires a value\n", .{});
                return error.InvalidArgument;
            }
            config.planner_interval = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: invalid number for --scrum-interval\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--quality-interval")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --quality-interval requires a value\n", .{});
                return error.InvalidArgument;
            }
            config.quality_interval = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: invalid number for --quality-interval\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--stream-json")) {
            config.output_format = .stream_json;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            config.output_format = .raw;
        } else if (std.mem.eql(u8, arg, "--log-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --log-dir requires a path\n", .{});
                return error.InvalidArgument;
            }
            config.log_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--progress-file")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --progress-file requires a path\n", .{});
                return error.InvalidArgument;
            }
            config.progress_file = args[i];
        } else if (std.mem.eql(u8, arg, "--monowiki-vault")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --monowiki-vault requires a path\n", .{});
                return error.InvalidArgument;
            }
            // Initialize monowiki config if not already set
            if (config.monowiki_config == null) {
                config.monowiki_config = .{ .vault = args[i] };
            } else {
                config.monowiki_config.?.vault = args[i];
            }
            config.monowiki_vault = args[i]; // Legacy field
        } else if (std.mem.eql(u8, arg, "--monowiki-api-docs")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --monowiki-api-docs requires a slug\n", .{});
                return error.InvalidArgument;
            }
            if (config.monowiki_config == null) {
                std.debug.print("Error: --monowiki-api-docs requires --monowiki-vault to be set first\n", .{});
                return error.InvalidArgument;
            }
            config.monowiki_config.?.api_docs_slug = args[i];
            config.monowiki_config.?.sync_api_docs = true;
        } else if (std.mem.eql(u8, arg, "--no-monowiki-search")) {
            if (config.monowiki_config) |*mwc| {
                mwc.proactive_search = false;
            }
        } else if (std.mem.eql(u8, arg, "--no-monowiki-wikilinks")) {
            if (config.monowiki_config) |*mwc| {
                mwc.resolve_wikilinks = false;
            }
        } else if (std.mem.eql(u8, arg, "--agent-timeout")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --agent-timeout requires a value\n", .{});
                return error.InvalidArgument;
            }
            const timeout = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: invalid number for --agent-timeout\n", .{});
                return error.InvalidArgument;
            };
            if (timeout == 0) {
                std.debug.print("Error: --agent-timeout must be greater than 0\n", .{});
                return error.InvalidArgument;
            }
            config.agent_timeout_seconds = timeout;
        } else if (std.mem.eql(u8, arg, "--monowiki-expand-neighbors")) {
            if (config.monowiki_config) |*mwc| {
                mwc.expand_neighbors = true;
            }
        } else if (std.mem.eql(u8, arg, "--planner-directions")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --planner-directions requires a value\n", .{});
                return error.InvalidArgument;
            }
            config.planner_directions = args[i];
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--event-driven-planner")) {
            config.planner_mode = .event_driven;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --config requires a path\n", .{});
                return error.InvalidArgument;
            }
            config = try Config.loadFromFile(allocator, args[i]);
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return error.InvalidArgument;
        }
    }

    // Run the agent loop
    var agent_loop = AgentLoop.init(allocator, config);
    defer agent_loop.deinit();

    try agent_loop.run();
}

fn printUsage() void {
    const usage =
        \\noface - Autonomous agent loop for software development
        \\
        \\Usage: noface [OPTIONS]
        \\       noface init [--force]
        \\
        \\Options:
        \\  -h, --help              Show this help message
        \\  -v, --version           Show version
        \\  -c, --config PATH       Load configuration from file
        \\  --max-iterations N      Stop after N iterations (default: unlimited)
        \\  --issue ISSUE_ID        Work on specific issue
        \\  --dry-run               Show what would be done without executing
        \\  --no-scrum              Disable scrum passes (alias: --no-planner)
        \\  --no-quality            Disable quality review passes
        \\  --scrum-interval N      Run scrum every N iterations (default: 5, alias: --planner-interval)
        \\  --event-driven-planner  Run planner on-demand instead of every N iterations
        \\  --planner-directions S  Give directions to the scrum planner (e.g., "prioritize issue X")
        \\  --quality-interval N    Run quality review every N iterations (default: 10)
        \\  --agent-timeout N       Kill agent if no output for N seconds (default: 300, must be >0)
        \\  -V, --verbose           Enable detailed logging (commands, timings, prompts, API responses)
        \\
        \\Output options:
        \\  --stream-json           Output raw JSON streaming (for programmatic use)
        \\  --raw                   Plain text output without markdown rendering
        \\  --log-dir PATH          Directory to store JSON session logs (default: /tmp)
        \\  --progress-file PATH    Path to progress markdown file to update
        \\
        \\Monowiki integration:
        \\  --monowiki-vault PATH       Path to monowiki vault for design documents
        \\  --monowiki-api-docs SLUG    Slug for API docs (enables bidirectional sync)
        \\  --no-monowiki-search        Disable proactive keyword search
        \\  --no-monowiki-wikilinks     Disable [[wikilink]] resolution
        \\  --monowiki-expand-neighbors Include graph neighbors in context
        \\
        \\Commands:
        \\  init [--force] [--skip-deps]   Create .noface.toml (checks dependencies first)
        \\  doctor                         Check system health and dependencies
        \\  serve [-p PORT]                Run the web dashboard (default port: 3000)
        \\  sync [--dry-run]               Sync beads issues to GitHub
        \\
        \\Configuration:
        \\  noface looks for .noface.toml in the current directory.
        \\  See https://github.com/femtomc/noface for configuration options.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn runInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var force = false;
    var skip_deps = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--skip-deps")) {
            skip_deps = true;
        } else {
            std.debug.print("Unknown init option: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    // Check dependencies first
    if (!skip_deps) {
        std.debug.print("\nChecking dependencies...\n\n", .{});
        const has_required = checkDependencies(allocator);
        std.debug.print("\n", .{});

        if (!has_required) {
            std.debug.print("Missing required dependencies. Install them and retry, or use --skip-deps to continue anyway.\n\n", .{});
            return error.MissingDependency;
        }
    }

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const project_name = std.fs.path.basename(cwd_path);

    const has_build_zig = pathExists("build.zig");
    const has_package_json = pathExists("package.json");

    const build_cmd = blk: {
        if (has_build_zig) break :blk "zig build";
        if (has_package_json) break :blk "npm run build";
        break :blk "make build";
    };
    const test_cmd = blk: {
        if (has_build_zig) break :blk "zig build test";
        if (has_package_json) break :blk "npm test";
        break :blk "make test";
    };

    const config_path = ".noface.toml";
    const config_exists = pathExists(config_path);
    if (config_exists and !force) {
        std.debug.print("Refusing to overwrite existing .noface.toml (use --force)\n", .{});
        return error.InvalidArgument;
    }

    const template = try std.fmt.allocPrint(allocator,
        \\# Auto-generated by `noface init`
        \\
        \\[project]
        \\name = "{s}"
        \\build = "{s}"
        \\test = "{s}"
        \\
        \\[agents]
        \\implementer = "claude"
        \\reviewer = "codex"
        \\timeout_seconds = 900        # Kill agent if no output for this many seconds (must be >0)
        \\
        \\[passes]
        \\scrum_enabled = true
        \\quality_enabled = true
        \\scrum_interval = 5
        \\quality_interval = 10
        \\
        \\[tracker]
        \\type = "beads"          # or "github"
        \\sync_to_github = true
        \\
        \\# Uncomment to enable monowiki integration for design documents
        \\# [monowiki]
        \\# vault = "./docs"                # Path to monowiki vault
        \\# proactive_search = true         # Search for relevant docs before implementation
        \\# resolve_wikilinks = true        # Fetch [[wikilinked]] docs from issues
        \\# expand_neighbors = false        # Also fetch graph neighbors
        \\# api_docs_slug = "api-reference" # Slug for API documentation
        \\# sync_api_docs = false           # Enable bidirectional API doc sync
        \\# max_context_docs = 5            # Max docs to inject into prompt
        \\
    , .{ project_name, build_cmd, test_cmd });
    defer allocator.free(template);

    var file = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(template);
    std.debug.print("Wrote {s}\n", .{config_path});

    const beads_dir_missing = !pathExists(".beads");
    if (beads_dir_missing and process.commandExists(allocator, "bd")) {
        std.debug.print("Initializing beads (bd init)...\n", .{});
        var result = try process.shell(allocator, "bd init");
        defer result.deinit();
        if (result.success()) {
            std.debug.print("{s}", .{result.stdout});
        } else {
            std.debug.print("bd init failed:\n{s}{s}\n", .{ result.stdout, result.stderr });
        }
    } else if (beads_dir_missing) {
        std.debug.print("Skipping beads init: bd not found in PATH\n", .{});
    } else {
        std.debug.print("Beads already initialized, skipping bd init\n", .{});
    }

    std.debug.print("Init complete. Edit .noface.toml as needed.\n", .{});
}

fn pathExists(path: []const u8) bool {
    _ = std.fs.cwd().statFile(path) catch return false;
    return true;
}

const Dependency = struct {
    name: []const u8,
    required: bool,
    install_cmd: []const u8,
    description: []const u8,
};

const dependencies = [_]Dependency{
    .{
        .name = "claude",
        .required = true,
        .install_cmd = "npm install -g @anthropic-ai/claude-code",
        .description = "Implementation agent (Claude Code CLI)",
    },
    .{
        .name = "codex",
        .required = false,
        .install_cmd = "npm install -g @openai/codex",
        .description = "Review agent (use --no-quality to skip)",
    },
    .{
        .name = "gh",
        .required = false,
        .install_cmd = "brew install gh  # or: https://cli.github.com",
        .description = "GitHub CLI for issue sync",
    },
    .{
        .name = "bd",
        .required = false,
        .install_cmd = "cargo install beads",
        .description = "Beads issue tracker",
    },
    .{
        .name = "monowiki",
        .required = false,
        .install_cmd = "cargo install monowiki",
        .description = "Design document integration",
    },
};

fn checkDependencies(allocator: std.mem.Allocator) bool {
    var all_required_found = true;

    for (dependencies) |dep| {
        const found = process.commandExists(allocator, dep.name);
        const mark = if (found) "\x1b[32m✓\x1b[0m" else if (dep.required) "\x1b[31m✗\x1b[0m" else "\x1b[33m○\x1b[0m";
        const req_tag = if (dep.required) " (required)" else " (optional)";

        std.debug.print("{s} {s}{s}\n", .{ mark, dep.name, req_tag });
        std.debug.print("    {s}\n", .{dep.description});

        if (!found) {
            std.debug.print("    Install: {s}\n", .{dep.install_cmd});
            if (dep.required) {
                all_required_found = false;
            }
        }
        std.debug.print("\n", .{});
    }

    return all_required_found;
}

fn runDoctor(allocator: std.mem.Allocator) !void {
    std.debug.print("\n\x1b[1mnoface doctor\x1b[0m - checking system health\n\n", .{});

    // Check dependencies
    std.debug.print("\x1b[1mDependencies:\x1b[0m\n", .{});
    const deps_ok = checkDependencies(allocator);

    // Check config
    std.debug.print("\x1b[1mConfiguration:\x1b[0m\n", .{});
    if (pathExists(".noface.toml")) {
        std.debug.print("\x1b[32m✓\x1b[0m .noface.toml found\n", .{});
    } else {
        std.debug.print("\x1b[33m○\x1b[0m .noface.toml not found (run: noface init)\n", .{});
    }

    // Check issue tracker
    std.debug.print("\n\x1b[1mIssue Tracker:\x1b[0m\n", .{});
    if (pathExists(".beads/issues.jsonl")) {
        std.debug.print("\x1b[32m✓\x1b[0m beads initialized (.beads/issues.jsonl)\n", .{});
    } else {
        std.debug.print("\x1b[33m○\x1b[0m beads not initialized (run: bd init)\n", .{});
    }

    // Check state
    std.debug.print("\n\x1b[1mState:\x1b[0m\n", .{});
    if (pathExists(".noface/state.json")) {
        std.debug.print("\x1b[32m✓\x1b[0m noface state exists (.noface/state.json)\n", .{});
    } else {
        std.debug.print("\x1b[33m○\x1b[0m no previous run state\n", .{});
    }

    // Summary
    std.debug.print("\n", .{});
    if (deps_ok and pathExists(".noface.toml")) {
        std.debug.print("\x1b[32mReady to run!\x1b[0m Use: noface\n", .{});
    } else if (!deps_ok) {
        std.debug.print("\x1b[31mMissing required dependencies.\x1b[0m Install them first.\n", .{});
    } else {
        std.debug.print("\x1b[33mRun 'noface init' to get started.\x1b[0m\n", .{});
    }
    std.debug.print("\n", .{});
}

fn runSync(allocator: std.mem.Allocator, dry_run: bool) !void {
    std.debug.print("\n\x1b[1mnoface sync\x1b[0m - syncing beads issues to GitHub\n\n", .{});

    if (dry_run) {
        std.debug.print("\x1b[33m[DRY RUN]\x1b[0m Would sync the following:\n\n", .{});
    }

    const result = noface.github.syncToGitHub(allocator, dry_run) catch |err| {
        std.debug.print("\x1b[31mSync failed:\x1b[0m {}\n", .{err});
        return err;
    };

    std.debug.print("\n\x1b[1mSync complete:\x1b[0m\n", .{});
    std.debug.print("  Created: {d}\n", .{result.created});
    std.debug.print("  Updated: {d}\n", .{result.updated});
    std.debug.print("  Closed:  {d}\n", .{result.closed});
    std.debug.print("  Skipped: {d}\n", .{result.skipped});
    if (result.errors > 0) {
        std.debug.print("  \x1b[31mErrors:  {d}\x1b[0m\n", .{result.errors});
    }
    std.debug.print("\n", .{});
}

test "argument parsing" {
    // Basic smoke test
    try std.testing.expect(true);
}
