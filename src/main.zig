const std = @import("std");
const noface = @import("noface");

const Config = noface.Config;
const AgentLoop = noface.AgentLoop;
const process = noface.process;

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

    // Parse command line arguments
    var config = Config.default();
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
        } else if (std.mem.eql(u8, arg, "--no-scrum")) {
            config.enable_scrum = false;
        } else if (std.mem.eql(u8, arg, "--no-quality")) {
            config.enable_quality = false;
        } else if (std.mem.eql(u8, arg, "--scrum-interval")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --scrum-interval requires a value\n", .{});
                return error.InvalidArgument;
            }
            config.scrum_interval = std.fmt.parseInt(u32, args[i], 10) catch {
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
            config.monowiki_vault = args[i];
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
        \\  --no-scrum              Disable scrum passes
        \\  --no-quality            Disable quality review passes
        \\  --scrum-interval N      Run scrum every N iterations (default: 5)
        \\  --quality-interval N    Run quality review every N iterations (default: 10)
        \\
        \\Output options:
        \\  --stream-json           Output raw JSON streaming (for programmatic use)
        \\  --raw                   Plain text output without markdown rendering
        \\  --log-dir PATH          Directory to store JSON session logs (default: /tmp)
        \\  --progress-file PATH    Path to progress markdown file to update
        \\
        \\Integrations:
        \\  --monowiki-vault PATH   Path to monowiki vault for design documents
        \\
        \\Commands:
        \\  init [--force]          Create .noface.toml and initialize beads (if available)
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
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else {
            std.debug.print("Unknown init option: {s}\n", .{arg});
            return error.InvalidArgument;
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

    var config_path = ".noface.toml";
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

test "argument parsing" {
    // Basic smoke test
    try std.testing.expect(true);
}
