//! Main agent loop implementation.
//!
//! Orchestrates Claude (implementation) and Codex (review) agents
//! to work on issues autonomously.

const std = @import("std");
const config_mod = @import("config.zig");
const process = @import("process.zig");
const streaming = @import("streaming.zig");
const signals = @import("signals.zig");
const markdown = @import("markdown.zig");

const Config = config_mod.Config;
const OutputFormat = config_mod.OutputFormat;

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
    session_log_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) AgentLoop {
        // Install signal handlers
        signals.install();

        return .{
            .allocator = allocator,
            .config = cfg,
        };
    }

    pub fn deinit(self: *AgentLoop) void {
        // Reset signal handlers
        signals.reset();

        // Clean up any allocated resources
        if (self.session_log_path) |path| {
            self.allocator.free(path);
        }
    }

    /// Check if we've been interrupted
    fn isInterrupted(self: *AgentLoop) bool {
        _ = self;
        return signals.isInterrupted();
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
        while (!self.isInterrupted()) {
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
            return try self.allocator.dupe(u8, issue);
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
        signals.setCurrentIssue(issue_id);

        // Show issue details
        const show_cmd = try std.fmt.allocPrint(self.allocator, "bd show {s}", .{issue_id});
        defer self.allocator.free(show_cmd);
        var show_result = try process.shell(self.allocator, show_cmd);
        defer show_result.deinit();
        std.debug.print("{s}\n", .{show_result.stdout});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run {s} on issue {s}", .{ self.config.impl_agent, issue_id });
            self.current_issue = null;
            signals.setCurrentIssue(null);
            return true;
        }

        // Build implementation prompt (includes monowiki context if available)
        const prompt = try self.buildImplementationPrompt(issue_id);
        defer self.allocator.free(prompt);

        // Generate log file path
        const json_log_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/noface-session-{s}.json",
            .{ self.config.log_dir, issue_id },
        );
        defer self.allocator.free(json_log_path);

        // Run Claude with streaming
        self.logInfo("Starting {s} session (streaming)...", .{self.config.impl_agent});
        const exit_code = try self.runAgentStreaming(self.config.impl_agent, prompt, json_log_path);

        // Check if we were interrupted
        if (self.isInterrupted()) {
            self.logWarn("Session was interrupted", .{});
            self.current_issue = null;
            signals.setCurrentIssue(null);
            return false;
        }

        if (exit_code != 0) {
            self.logError("Agent session failed (exit code: {d})", .{exit_code});
            self.current_issue = null;
            signals.setCurrentIssue(null);
            return false;
        }

        // Verify issue was closed
        try self.verifyIssueClosed(issue_id);

        // Sync to GitHub
        try self.syncGitHub();

        self.current_issue = null;
        signals.setCurrentIssue(null);
        return true;
    }

    /// Verify that an issue was properly closed
    fn verifyIssueClosed(self: *AgentLoop, issue_id: []const u8) !void {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "bd show {s} --json 2>/dev/null | jq -r '.[0].status // \"unknown\"'",
            .{issue_id},
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        const status = std.mem.trim(u8, result.stdout, " \t\n\r");
        if (std.mem.eql(u8, status, "closed")) {
            self.logSuccess("Issue {s} completed and closed", .{issue_id});
        } else {
            self.logWarn("Issue {s} status: {s} (expected: closed)", .{ issue_id, status });
        }
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
            \\4. Complex functions - Flag functions that are too long or have high cyclomatic complexity
            \\5. Missing error handling - Identify places where errors are ignored or not handled properly
            \\6. Inconsistent patterns - Find deviations from established codebase conventions
            \\7. Performance concerns - Spot obvious inefficiencies (N+1 patterns, unnecessary allocations)
            \\
            \\RULES:
            \\- Focus on src/ directory
            \\- READ-ONLY: Do not modify any code
            \\- For each significant finding, create a beads issue:
            \\  bd create "<Title>" -t tech-debt -p 1 --note "<Description of the issue and location>"
            \\- Use priority 1 (high) for issues that impact maintainability
            \\- Use priority 2 for minor issues
            \\- Be specific about file paths and line numbers (e.g., src/foo.zig:42)
            \\- Group related issues together (don't create duplicate issues)
            \\- Check existing issues first (bd list) to avoid duplicates
            \\- Limit to 5 most important findings per pass
            \\
            \\OUTPUT:
            \\- List each finding with file:line reference
            \\- Show the bd create command used for each issue
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
        var result = try process.run(self.allocator, &.{
            self.config.review_agent,
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            prompt,
        });
        defer result.deinit();

        std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len > 0) {
            std.debug.print("{s}", .{result.stderr});
        }

        return result.exit_code;
    }

    /// Run an agent with streaming output and JSON logging
    fn runAgentStreaming(self: *AgentLoop, agent: []const u8, prompt: []const u8, json_log_path: []const u8) !u8 {
        // Build argv to avoid shell quoting pitfalls
        const argv = [_][]const u8{
            agent,
            "-p",
            "--dangerously-skip-permissions",
            "--verbose",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            prompt,
        };

        // Open log file for JSON output
        const log_file = std.fs.cwd().createFile(json_log_path, .{}) catch |err| {
            self.logWarn("Failed to create log file {s}: {}", .{ json_log_path, err });
            return try self.runAgentStreamingWithoutLog(&argv);
        };
        defer log_file.close();

        var proc = try process.StreamingProcess.spawn(self.allocator, &argv);

        // Collect full response for final markdown rendering
        var full_response = std.ArrayListUnmanaged(u8){};
        defer full_response.deinit(self.allocator);

        var line_buf: [64 * 1024]u8 = undefined;
        while (try proc.readLine(&line_buf)) |line| {
            // Check for interrupt
            if (self.isInterrupted()) {
                proc.kill();
                break;
            }

            // Write raw JSON line to log file
            _ = log_file.write(line) catch {};
            _ = log_file.write("\n") catch {};

            // Parse and display based on output format
            var event = streaming.parseStreamLine(self.allocator, line) catch continue;

            switch (self.config.output_format) {
                .stream_json => {
                    // Output raw JSON
                    const stdout = std.fs.File.stdout();
                    _ = stdout.write(line) catch {};
                    _ = stdout.write("\n") catch {};
                },
                .text => {
                    // Stream text deltas and collect for final render
                    if (event.text) |text| {
                        try full_response.appendSlice(self.allocator, text);
                        const stdout = std.fs.File.stdout();
                        _ = stdout.write(text) catch {};
                    }
                    if (event.tool_name) |name| {
                        std.debug.print("\n{s}[TOOL]{s} {s}\n", .{ Color.cyan, Color.reset, name });
                    }
                },
                .raw => {
                    // Plain text without styling
                    streaming.printTextDelta(event);
                },
            }

            streaming.deinitEvent(self.allocator, &event);
        }

        const exit_code = try proc.wait();
        std.debug.print("\n", .{});

        // Render final markdown summary if in text mode and we have content
        if (self.config.output_format == .text and full_response.items.len > 0) {
            self.logInfo("=== Final Result ===", .{});
            markdown.print(self.allocator, full_response.items);
            std.debug.print("\n", .{});
        }

        self.logInfo("Session log saved to: {s}", .{json_log_path});

        return exit_code;
    }

    /// Fallback streaming without log file
    fn runAgentStreamingWithoutLog(self: *AgentLoop, argv: []const []const u8) !u8 {
        var proc = try process.StreamingProcess.spawn(self.allocator, argv);

        var line_buf: [64 * 1024]u8 = undefined;
        while (try proc.readLine(&line_buf)) |line| {
            if (self.isInterrupted()) {
                proc.kill();
                break;
            }
            var event = streaming.parseStreamLine(self.allocator, line) catch continue;
            streaming.printTextDelta(event);
            streaming.deinitEvent(self.allocator, &event);
        }

        const exit_code = try proc.wait();
        std.debug.print("\n", .{});
        return exit_code;
    }

    /// Build the implementation prompt for an issue
    fn buildImplementationPrompt(self: *AgentLoop, issue_id: []const u8) ![]const u8 {
        // Build optional monowiki section
        const monowiki_section = if (self.config.monowiki_vault) |vault|
            try std.fmt.allocPrint(self.allocator,
                \\
                \\DESIGN DOCUMENTS:
                \\Design documents are available via monowiki. Use these commands to find relevant context:
                \\- monowiki search "<query>" --json      # Search for design docs
                \\- monowiki note <slug> --format json    # Read a specific document
                \\- monowiki graph neighbors --slug <slug> --json  # Find related docs
                \\Vault location: {s}
                \\
            , .{vault})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(monowiki_section);

        // Build optional progress file section
        const progress_section = if (self.config.progress_file) |path|
            try std.fmt.allocPrint(self.allocator,
                \\10. Update {s} with:
                \\    - Date
                \\    - Issue worked on
                \\    - What was accomplished
                \\    - Any discoveries or blockers
                \\
            , .{path})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(progress_section);

        return std.fmt.allocPrint(self.allocator,
            \\You are working on issue {s} in the {s} project.
            \\{s}
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
            \\{s}
            \\IMPORTANT: Do NOT commit until review approves. Keep iterating.
            \\When complete, your final message should be: ISSUE_COMPLETE
        , .{
            issue_id,
            self.config.project_name,
            monowiki_section,
            issue_id,
            issue_id,
            self.config.test_command,
            self.config.review_agent,
            issue_id,
            progress_section,
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
