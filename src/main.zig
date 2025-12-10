const std = @import("std");
const noface = @import("noface");

const Config = noface.Config;
const AgentLoop = noface.AgentLoop;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command line arguments
    var config = Config.default();
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
        \\Configuration:
        \\  noface looks for .noface.toml in the current directory.
        \\  See https://github.com/femtomc/noface for configuration options.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

test "argument parsing" {
    // Basic smoke test
    try std.testing.expect(true);
}
