//! Main agent loop implementation.
//!
//! Orchestrates Claude (implementation) and Codex (review) agents
//! to work on issues autonomously.

const std = @import("std");
const config_mod = @import("config.zig");
const process = @import("process.zig");
const streaming = @import("streaming.zig");

const Config = config_mod.Config;

/// Colors for terminal output
const Color = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const cyan = "\x1b[0;36m";
};

/// Agent loop state
pub const AgentLoop = struct {
    allocator: std.mem.Allocator,
    config: Config,
    iteration: u32 = 0,
    last_scrum_iteration: u32 = 0,
    last_quality_iteration: u32 = 0,
    current_issue: ?[]const u8 = null,
    interrupted: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) AgentLoop {
        return .{
            .allocator = allocator,
            .config = cfg,
        };
    }

    pub fn deinit(self: *AgentLoop) void {
        _ = self;
        // Clean up any allocated resources
    }

    /// Main entry point - run the agent loop
    pub fn run(self: *AgentLoop) !void {
        self.logInfo("Starting noface agent loop", .{});
        self.logInfo("Project: {s}", .{self.config.project_name});

        if (self.config.max_iterations > 0) {
            self.logInfo("Max iterations: {d}", .{self.config.max_iterations});
        } else {
            self.logInfo("Max iterations: unlimited", .{});
        }

        if (self.config.enable_scrum) {
            self.logInfo("Scrum interval: every {d} iteration(s)", .{self.config.scrum_interval});
        }
        if (self.config.enable_quality) {
            self.logInfo("Quality interval: every {d} iteration(s)", .{self.config.quality_interval});
        }

        // Check prerequisites
        try self.checkPrerequisites();

        // Main loop
        self.iteration = 1;
        while (!self.interrupted) {
            // Run scrum pass if due
            if (self.config.enable_scrum) {
                if (self.last_scrum_iteration == 0 or
                    (self.iteration - self.last_scrum_iteration) >= self.config.scrum_interval)
                {
                    if (!try self.runScrumPass()) {
                        self.logInfo("Agent loop stopping after failed scrum pass", .{});
                        break;
                    }
                    self.last_scrum_iteration = self.iteration;
                }
            }

            // Run quality pass if due (not on first iteration)
            if (self.config.enable_quality and self.iteration > 1) {
                if ((self.iteration - self.last_quality_iteration) >= self.config.quality_interval) {
                    _ = try self.runQualityPass();
                    self.last_quality_iteration = self.iteration;
                }
            }

            // Run main iteration
            if (!try self.runIteration()) {
                self.logInfo("Agent loop stopping", .{});
                break;
            }

            // Check iteration limit
            if (self.config.max_iterations > 0 and self.iteration >= self.config.max_iterations) {
                self.logInfo("Reached max iterations ({d})", .{self.config.max_iterations});
                break;
            }

            // If working on specific issue, stop after one
            if (self.config.specific_issue != null) {
                self.logInfo("Completed specific issue, stopping", .{});
                break;
            }

            self.iteration += 1;

            // Brief pause
            self.logInfo("Pausing 5 seconds before next iteration...", .{});
            std.Thread.sleep(5 * std.time.ns_per_s);
        }

        self.logSuccess("Agent loop finished after {d} iteration(s)", .{self.iteration});
    }

    /// Check that required tools are available
    fn checkPrerequisites(self: *AgentLoop) !void {
        self.logInfo("Checking prerequisites...", .{});

        // Check for required commands
        const required = [_][]const u8{ self.config.impl_agent, self.config.review_agent, "bd", "gh", "jq" };

        for (required) |cmd| {
            if (!process.commandExists(self.allocator, cmd)) {
                self.logError("{s} not found in PATH", .{cmd});
                return error.MissingPrerequisite;
            }
        }

        // Verify build works
        if (!self.config.dry_run) {
            var result = try process.shell(self.allocator, self.config.build_command);
            defer result.deinit();

            if (!result.success()) {
                self.logError("Project doesn't build. Fix build errors first.", .{});
                return error.BuildFailed;
            }
        }

        self.logSuccess("All prerequisites met", .{});
    }

    /// Get the next issue to work on
    fn getNextIssue(self: *AgentLoop) !?[]const u8 {
        if (self.config.specific_issue) |issue| {
            return issue;
        }

        // Get highest priority ready issue from beads
        var result = try process.shell(self.allocator, "bd ready --json 2>/dev/null | jq -r '.[0].id // empty'");
        defer result.deinit();

        if (result.success() and result.stdout.len > 0) {
            const issue_id = std.mem.trim(u8, result.stdout, " \t\n\r");
            if (issue_id.len > 0) {
                return try self.allocator.dupe(u8, issue_id);
            }
        }

        return null;
    }

    /// Run one iteration of the agent loop
    fn runIteration(self: *AgentLoop) !bool {
        self.logInfo("=== Iteration {d} ===", .{self.iteration});

        // Get next issue
        const issue_id = try self.getNextIssue() orelse {
            self.logWarn("No ready issues found. Exiting.", .{});
            return false;
        };
        defer self.allocator.free(issue_id);

        self.logInfo("Working on issue: {s}", .{issue_id});
        self.current_issue = issue_id;

        // Show issue details
        var show_result = try process.shell(self.allocator, try std.fmt.allocPrint(self.allocator, "bd show {s}", .{issue_id}));
        defer show_result.deinit();
        std.debug.print("{s}\n", .{show_result.stdout});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run {s} on issue {s}", .{ self.config.impl_agent, issue_id });
            return true;
        }

        // Build implementation prompt
        const prompt = try self.buildImplementationPrompt(issue_id);
        defer self.allocator.free(prompt);

        // Run Claude with streaming
        self.logInfo("Starting {s} session (streaming)...", .{self.config.impl_agent});
        try self.runAgentStreaming(self.config.impl_agent, prompt);

        // Sync to GitHub
        try self.syncGitHub();

        self.current_issue = null;
        return true;
    }

    /// Run a scrum/grooming pass
    fn runScrumPass(self: *AgentLoop) !bool {
        self.logInfo("Starting scrum-master grooming pass...", .{});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run scrum pass", .{});
            return true;
        }

        const prompt =
            \\You are running a periodic scrum-master grooming pass for the project backlog.
            \\
            \\RULES:
            \\- Docs are curated; READ-ONLY. Do not edit files or run build/tests.
            \\- Focus on beads issues only: review bd list/ready, dependencies, priorities, labels.
            \\- Add concise context/notes to issues, update priority/status/labels/dependencies.
            \\- Close stale items, and create new issues when gaps are found.
            \\- Do NOT start coding tasks, modify code, or commit.
            \\- Keep a clear summary of changes and end with: SCRUM_COMPLETE
        ;

        const exit_code = try self.runCodexExec(prompt);
        if (exit_code == 0) {
            self.logSuccess("Scrum pass completed", .{});
            return true;
        } else {
            self.logWarn("Scrum pass failed (exit code: {d})", .{exit_code});
            return false;
        }
    }

    /// Run a code quality review pass
    fn runQualityPass(self: *AgentLoop) !bool {
        self.logInfo("Starting code quality review pass...", .{});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run quality review", .{});
            return true;
        }

        const prompt =
            \\You are running a code quality review for the codebase.
            \\
            \\TASK: Analyze the codebase for quality issues and create high-priority beads issues.
            \\
            \\REVIEW CHECKLIST:
            \\1. Code duplication - Look for repeated code patterns that should be refactored
            \\2. Technical debt - Identify TODO/FIXME comments, workarounds, or shortcuts
            \\3. Dead code - Find unused functions, imports, or variables
            \\4. Complex functions - Flag functions that are too long or have high complexity
            \\5. Missing error handling - Identify places where errors are ignored
            \\6. Inconsistent patterns - Find deviations from established conventions
            \\7. Performance concerns - Spot obvious inefficiencies
            \\
            \\RULES:
            \\- Focus on src/ directory
            \\- READ-ONLY: Do not modify any code
            \\- For each significant finding, create a beads issue:
            \\  bd create "<Title>" -t tech-debt -p 1 --note "<Description>"
            \\- Limit to 5 most important findings per pass
            \\- End with: QUALITY_REVIEW_COMPLETE
        ;

        const exit_code = try self.runCodexExec(prompt);
        if (exit_code == 0) {
            self.logSuccess("Code quality review completed", .{});
            return true;
        } else {
            self.logWarn("Code quality review failed (exit code: {d})", .{exit_code});
            return false;
        }
    }

    /// Run codex exec with a prompt
    fn runCodexExec(self: *AgentLoop, prompt: []const u8) !u8 {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "{s} exec --dangerously-bypass-approvals-and-sandbox \"{s}\"",
            .{ self.config.review_agent, prompt },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len > 0) {
            std.debug.print("{s}", .{result.stderr});
        }

        return result.exit_code;
    }

    /// Run an agent with streaming output
    fn runAgentStreaming(self: *AgentLoop, agent: []const u8, prompt: []const u8) !void {
        // Build command
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "{s} -p --dangerously-skip-permissions --verbose --output-format stream-json --include-partial-messages \"{s}\"",
            .{ agent, prompt },
        );
        defer self.allocator.free(cmd);

        var proc = try process.StreamingProcess.spawn(self.allocator, &.{ "/bin/sh", "-c", cmd });

        var line_buf: [64 * 1024]u8 = undefined;
        while (try proc.readLine(&line_buf)) |line| {
            const event = streaming.parseStreamLine(self.allocator, line) catch continue;
            streaming.printTextDelta(event);
        }

        const exit_code = try proc.wait();
        std.debug.print("\n", .{});

        if (exit_code != 0) {
            self.logWarn("Agent exited with code {d}", .{exit_code});
        }
    }

    /// Build the implementation prompt for an issue
    fn buildImplementationPrompt(self: *AgentLoop, issue_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\You are working on issue {s} in the {s} project.
            \\
            \\STEPS:
            \\1. Run: bd show {s}
            \\2. Run: bd update {s} --status in_progress
            \\3. Implement the feature/fix described in the issue
            \\4. Run: {s} (fix any failures)
            \\5. Run: {s} review --uncommitted
            \\6. Address ALL review feedback, re-run review until approved
            \\7. After approval: touch .codex-approved
            \\8. Commit with message referencing the issue
            \\9. Run: bd close {s} --reason "Completed: <summary>"
            \\
            \\IMPORTANT: Do NOT commit until review approves. Keep iterating.
            \\When complete, your final message should be: ISSUE_COMPLETE
        , .{
            issue_id,
            self.config.project_name,
            issue_id,
            issue_id,
            self.config.test_command,
            self.config.review_agent,
            issue_id,
        });
    }

    /// Sync issues to GitHub
    fn syncGitHub(self: *AgentLoop) !void {
        if (!self.config.sync_to_github) return;

        self.logInfo("Syncing issues to GitHub...", .{});

        // Look for sync script
        var result = try process.shell(self.allocator, "[ -x ./scripts/sync-github-issues.sh ] && ./scripts/sync-github-issues.sh || echo 'No sync script found'");
        defer result.deinit();

        if (result.success()) {
            self.logSuccess("GitHub sync completed", .{});
        } else {
            self.logWarn("GitHub sync failed (non-fatal)", .{});
        }
    }

    // Logging helpers
    fn logInfo(self: *AgentLoop, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(Color.blue ++ "[INFO]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
    }

    fn logSuccess(self: *AgentLoop, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(Color.green ++ "[SUCCESS]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
    }

    fn logWarn(self: *AgentLoop, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(Color.yellow ++ "[WARN]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
    }

    fn logError(self: *AgentLoop, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(Color.red ++ "[ERROR]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
    }
};

test "agent loop init" {
    const cfg = Config.default();
    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    try std.testing.expectEqual(@as(u32, 0), loop.iteration);
}
