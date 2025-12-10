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
const monowiki_mod = @import("monowiki.zig");

const Config = config_mod.Config;
const OutputFormat = config_mod.OutputFormat;
const Monowiki = monowiki_mod.Monowiki;

/// Colors for terminal output
const Color = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const cyan = "\x1b[0;36m";
};

/// Retry configuration for transient agent failures
const RetryConfig = struct {
    max_attempts: u8 = 3,
    base_delay_ms: u64 = 1000, // 1 second
    max_delay_ms: u64 = 4000, // 4 seconds
};

/// Agent loop state
pub const AgentLoop = struct {
    allocator: std.mem.Allocator,
    config: Config,
    iteration: u32 = 0,
    last_planner_iteration: u32 = 0,
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

        if (self.config.enable_planner) {
            self.logInfo("Planner interval: every {d} iteration(s)", .{self.config.planner_interval});
        }
        if (self.config.enable_quality) {
            self.logInfo("Quality interval: every {d} iteration(s)", .{self.config.quality_interval});
        }

        // Check prerequisites
        try self.checkPrerequisites();

        // Main loop
        self.iteration = 1;
        while (!self.isInterrupted()) {
            // Run planner pass if due
            if (self.config.enable_planner) {
                if (self.last_planner_iteration == 0 or
                    (self.iteration - self.last_planner_iteration) >= self.config.planner_interval)
                {
                    if (!try self.runPlannerPass()) {
                        self.logInfo("Agent loop stopping after failed planner pass", .{});
                        break;
                    }
                    self.last_planner_iteration = self.iteration;
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
            self.logInfo("Running build: {s}", .{self.config.build_command});
            var result = try process.shell(self.allocator, self.config.build_command);
            defer result.deinit();

            if (!result.success()) {
                self.logError("Project doesn't build. Fix build errors first.", .{});
                if (result.stderr.len > 0) {
                    std.debug.print("{s}\n", .{result.stderr});
                }
                if (result.stdout.len > 0) {
                    std.debug.print("{s}\n", .{result.stdout});
                }
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

        // Run Claude with streaming and retry logic
        self.logInfo("Starting {s} session (streaming)...", .{self.config.impl_agent});
        const retry_config = RetryConfig{};
        var attempt: u8 = 0;
        var last_exit_code: u8 = 0;

        while (attempt < retry_config.max_attempts) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ms = calculateBackoffMs(attempt - 1, retry_config);
                self.logWarn("Retrying agent (attempt {d}/{d}) after {d}ms delay...", .{
                    attempt + 1,
                    retry_config.max_attempts,
                    delay_ms,
                });
                sleepMs(delay_ms);
            }

            last_exit_code = try self.runAgentStreaming(self.config.impl_agent, prompt, json_log_path);

            // Check if we were interrupted
            if (self.isInterrupted()) {
                self.logWarn("Session was interrupted", .{});
                self.current_issue = null;
                signals.setCurrentIssue(null);
                return false;
            }

            // Success - break out of retry loop
            if (last_exit_code == 0) {
                break;
            }

            // Check if we should retry
            if (!shouldRetry(last_exit_code) or attempt + 1 >= retry_config.max_attempts) {
                break;
            }

            self.logWarn("Agent failed with exit code {d}, will retry", .{last_exit_code});
        }

        if (last_exit_code != 0) {
            self.logError("Agent session failed after {d} attempt(s) (exit code: {d})", .{ attempt + 1, last_exit_code });
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

    /// Build planner pass prompt with optional monowiki integration
    fn buildPlannerPrompt(self: *AgentLoop) ![]const u8 {
        const monowiki_section = if (self.config.monowiki_config) |mwc|
            try std.fmt.allocPrint(self.allocator,
                \\
                \\DESIGN DOCUMENTS:
                \\The design documents define what we're building. They are your primary source of truth.
                \\Location: {s}
                \\
                \\Commands:
                \\- monowiki search "<query>" --json    # Find relevant design docs
                \\- monowiki note <slug> --format json  # Read a specific document
                \\- monowiki graph neighbors --slug <slug> --json  # Find related docs
                \\- monowiki verify --json              # Check for broken links/issues
                \\
                \\STRATEGIC PLANNING:
                \\1. Survey the design documents to understand the target architecture
                \\2. Map existing issues to design goals - what's covered, what's missing?
                \\3. Create issues for unimplemented design elements
                \\4. Prioritize issues that unblock the critical path to the design vision
                \\5. Sequence work so foundational pieces come before dependent features
                \\
                \\When creating issues from design docs:
                \\- Reference the design doc slug in the issue note
                \\- Break large design elements into implementable chunks
                \\- Capture acceptance criteria from the design spec
                \\
                \\Do NOT edit design documents (user-curated).
                \\
            , .{mwc.vault})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(monowiki_section);

        return std.fmt.allocPrint(self.allocator,
            \\You are the strategic planner for {s}.
            \\
            \\OBJECTIVE:
            \\Chart an implementation path through the issue backlog that progresses toward
            \\the architecture and features specified in the design documents. Your job is to
            \\ensure that autonomous development work is strategically sequenced.
            \\
            \\ASSESS CURRENT STATE:
            \\1. Run `bd list` to see all issues
            \\2. Run `bd ready` to see the implementation queue
            \\{s}
            \\PLANNING TASKS:
            \\
            \\Gap Analysis:
            \\- Compare design documents against existing issues
            \\- Identify design elements with no corresponding issues
            \\- Create issues to fill gaps (reference the design doc)
            \\
            \\Priority Assignment:
            \\- Priority 0: Blocking issues, security vulnerabilities, broken builds
            \\- Priority 1: Foundation work that unblocks other features, critical path items
            \\- Priority 2: Features specified in design docs, improvements
            \\- Priority 3: Nice-to-haves, exploration, future work
            \\
            \\Sequencing:
            \\- Ensure dependencies flow correctly (foundations before features)
            \\- Group related issues that should be done together
            \\- Identify parallelizable work streams
            \\
            \\Issue Quality:
            \\- Each issue should have a clear, actionable title
            \\- Description should explain: what, why, and acceptance criteria
            \\- Add context notes linking to relevant design docs
            \\- Split issues that are too large (>1 day of work estimate)
            \\
            \\Staleness Review:
            \\- Issues untouched for 30+ days: assess if still aligned with design
            \\- Close issues that contradict or are superseded by design docs
            \\
            \\CONSTRAINTS:
            \\- READ-ONLY for code and design documents
            \\- Only modify beads issues (create, update, close)
            \\- Do not begin implementation work
            \\
            \\OUTPUT:
            \\Summarize:
            \\- Design coverage: which design docs have corresponding issues
            \\- Gaps identified and issues created
            \\- Priority/sequencing changes made
            \\- Recommended next issues for implementation (the critical path)
            \\
            \\End with: PLANNING_COMPLETE
        , .{ self.config.project_name, monowiki_section });
    }

    /// Run a planner pass (strategic planning from design docs)
    fn runPlannerPass(self: *AgentLoop) !bool {
        self.logInfo("Starting planner pass...", .{});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run planner pass", .{});
            return true;
        }

        const prompt = try self.buildPlannerPrompt();
        defer self.allocator.free(prompt);

        // Retry logic for transient failures
        const retry_config = RetryConfig{};
        var attempt: u8 = 0;
        var last_exit_code: u8 = 0;

        while (attempt < retry_config.max_attempts) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ms = calculateBackoffMs(attempt - 1, retry_config);
                self.logWarn("Retrying planner (attempt {d}/{d}) after {d}ms delay...", .{
                    attempt + 1,
                    retry_config.max_attempts,
                    delay_ms,
                });
                sleepMs(delay_ms);
            }

            last_exit_code = try self.runCodexExec(prompt);

            if (last_exit_code == 0) {
                self.logSuccess("Planner pass completed", .{});
                return true;
            }

            if (!shouldRetry(last_exit_code) or attempt + 1 >= retry_config.max_attempts) {
                break;
            }

            self.logWarn("Planner failed with exit code {d}, will retry", .{last_exit_code});
        }

        self.logWarn("Planner pass failed after {d} attempt(s) (exit code: {d})", .{ attempt + 1, last_exit_code });
        return false;
    }

    /// Build quality pass prompt with optional monowiki integration
    fn buildQualityPrompt(self: *AgentLoop) ![]const u8 {
        const monowiki_section = if (self.config.monowiki_config) |mwc| blk: {
            const api_check = if (mwc.sync_api_docs and mwc.api_docs_slug != null)
                try std.fmt.allocPrint(self.allocator,
                    \\
                    \\API DOCUMENTATION CHECK:
                    \\- Compare public APIs in code with documentation at: {s}/{s}.md
                    \\- Create issues for undocumented public functions/types
                    \\- Create issues for documented APIs that no longer exist
                    \\- Do NOT edit the API docs directly (will be updated during implementation)
                    \\
                , .{ mwc.vault, mwc.api_docs_slug.? })
            else
                try self.allocator.dupe(u8, "");
            defer self.allocator.free(api_check);

            break :blk try std.fmt.allocPrint(self.allocator,
                \\
                \\DESIGN DOCUMENTS:
                \\Design documents are available via monowiki at: {s}
                \\- Cross-reference code with design docs for architectural drift
                \\- Use: monowiki search "<query>" --json to find relevant docs
                \\- Report when code behavior diverges from documented design
                \\- Do NOT edit design documents (user-curated)
                \\{s}
            , .{ mwc.vault, api_check });
        } else try self.allocator.dupe(u8, "");
        defer self.allocator.free(monowiki_section);

        return std.fmt.allocPrint(self.allocator,
            \\You are conducting a code quality audit for {s}.
            \\
            \\OBJECTIVE:
            \\Identify maintainability issues and technical debt. Create actionable issues
            \\for problems that matter, not style nitpicks.
            \\{s}
            \\FOCUS AREAS (in priority order):
            \\
            \\1. Correctness Risks
            \\   - Potential null/undefined access
            \\   - Unchecked error conditions
            \\   - Race conditions or state inconsistencies
            \\   - Integer overflow/underflow possibilities
            \\
            \\2. Maintainability Blockers
            \\   - Functions >50 lines or >10 branches
            \\   - Circular dependencies between modules
            \\   - God objects or functions doing too many things
            \\   - Copy-pasted code blocks (3+ similar instances)
            \\
            \\3. Missing Safety Nets
            \\   - Public APIs without input validation
            \\   - Operations that could fail silently
            \\   - Missing bounds checks on arrays/slices
            \\
            \\4. Performance Red Flags
            \\   - Allocations in hot loops
            \\   - O(n²) or worse algorithms on unbounded data
            \\   - Repeated expensive computations
            \\
            \\SKIP:
            \\- Style preferences (formatting, naming conventions)
            \\- Single-use code that's clearly temporary
            \\- Test files (unless tests themselves are buggy)
            \\- Generated code
            \\
            \\PROCESS:
            \\1. Run `bd list` to check existing tech-debt issues (avoid duplicates)
            \\2. Scan src/ directory systematically
            \\3. For each finding, assess: "Would fixing this prevent a future bug or
            \\   significantly ease future development?"
            \\4. Only create issues for clear "yes" answers
            \\
            \\ISSUE CREATION:
            \\  bd create "<Verb> <specific problem>" -t tech-debt -p <1|2> --note "<details>"
            \\
            \\Include in note:
            \\- File and line number (e.g., src/loop.zig:142)
            \\- Brief description of the problem
            \\- Suggested approach (if obvious)
            \\
            \\LIMITS:
            \\- Maximum 5 issues per pass (focus on highest impact)
            \\- Priority 1: Would cause bugs or blocks feature work
            \\- Priority 2: Makes code harder to understand or modify
            \\
            \\CONSTRAINTS:
            \\- READ-ONLY: Do not modify any code or design documents
            \\- Focus on src/ directory
            \\
            \\OUTPUT:
            \\List findings with rationale, then the bd commands used.
            \\End with: QUALITY_REVIEW_COMPLETE
        , .{ self.config.project_name, monowiki_section });
    }

    /// Run a code quality review pass
    fn runQualityPass(self: *AgentLoop) !bool {
        self.logInfo("Starting code quality review pass...", .{});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run quality review", .{});
            return true;
        }

        const prompt = try self.buildQualityPrompt();
        defer self.allocator.free(prompt);

        // Retry logic for transient failures
        const retry_config = RetryConfig{};
        var attempt: u8 = 0;
        var last_exit_code: u8 = 0;

        while (attempt < retry_config.max_attempts) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ms = calculateBackoffMs(attempt - 1, retry_config);
                self.logWarn("Retrying quality review (attempt {d}/{d}) after {d}ms delay...", .{
                    attempt + 1,
                    retry_config.max_attempts,
                    delay_ms,
                });
                sleepMs(delay_ms);
            }

            last_exit_code = try self.runCodexExec(prompt);

            if (last_exit_code == 0) {
                self.logSuccess("Code quality review completed", .{});
                return true;
            }

            if (!shouldRetry(last_exit_code) or attempt + 1 >= retry_config.max_attempts) {
                break;
            }

            self.logWarn("Quality review failed with exit code {d}, will retry", .{last_exit_code});
        }

        self.logWarn("Code quality review failed after {d} attempt(s) (exit code: {d})", .{ attempt + 1, last_exit_code });
        return false;
    }

    /// Run codex exec with a prompt
    fn runCodexExec(self: *AgentLoop, prompt: []const u8) !u8 {
        // Use Child directly with inherited stdout/stderr for real-time streaming
        var child = std.process.Child.init(&.{
            self.config.review_agent,
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            prompt,
        }, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        const result = try child.wait();

        return switch (result) {
            .Exited => |code| code,
            else => 1,
        };
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
                        if (event.tool_input_summary) |summary| {
                            std.debug.print("\n{s}[TOOL]{s} {s}: {s}\n", .{ Color.cyan, Color.reset, name, summary });
                        } else {
                            std.debug.print("\n{s}[TOOL]{s} {s}\n", .{ Color.cyan, Color.reset, name });
                        }
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

    /// Fetch issue details as JSON
    fn getIssueDetails(self: *AgentLoop, issue_id: []const u8) !?[]const u8 {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "bd show {s} --json 2>/dev/null",
            .{issue_id},
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (result.success() and result.stdout.len > 0) {
            return try self.allocator.dupe(u8, result.stdout);
        }
        return null;
    }

    /// Fetch monowiki context for an issue
    fn fetchMonowikiContext(self: *AgentLoop, issue_text: []const u8) ![]const u8 {
        const mwc = self.config.monowiki_config orelse return try self.allocator.dupe(u8, "");

        var mw = Monowiki.init(self.allocator, mwc);

        // Check if monowiki is available
        if (!mw.isAvailable()) {
            self.logWarn("monowiki CLI not found, skipping design doc context", .{});
            return try self.allocator.dupe(u8, "");
        }

        // Collect notes from wikilinks
        var wikilink_notes = std.ArrayListUnmanaged(monowiki_mod.Note){};
        defer {
            for (wikilink_notes.items) |*note| {
                note.deinit(self.allocator);
            }
            wikilink_notes.deinit(self.allocator);
        }

        // Resolve [[wikilinks]] if enabled
        if (mwc.resolve_wikilinks) {
            const links = try mw.extractWikilinks(issue_text);
            defer mw.freeWikilinks(links);

            for (links) |slug| {
                if (wikilink_notes.items.len >= mwc.max_context_docs) break;

                if (try mw.fetchNote(slug)) |note| {
                    self.logInfo("Fetched design doc: {s}", .{slug});
                    try wikilink_notes.append(self.allocator, note);
                }
            }
        }

        // Proactive search if enabled
        var search_results: []monowiki_mod.SearchResult = &[_]monowiki_mod.SearchResult{};
        defer mw.freeSearchResults(search_results);

        if (mwc.proactive_search) {
            const keywords = try mw.extractKeywords(issue_text);
            defer self.allocator.free(keywords);

            if (keywords.len > 0) {
                const remaining_slots = mwc.max_context_docs -| @as(u8, @intCast(wikilink_notes.items.len));
                if (remaining_slots > 0) {
                    search_results = try mw.search(keywords, remaining_slots);
                    if (search_results.len > 0) {
                        self.logInfo("Found {d} related design docs via search", .{search_results.len});
                    }
                }
            }
        }

        // Build context string
        return mw.buildContext(search_results, wikilink_notes.items);
    }

    /// Build the implementation prompt for an issue
    fn buildImplementationPrompt(self: *AgentLoop, issue_id: []const u8) ![]const u8 {
        // Fetch issue details for context extraction
        const issue_json = try self.getIssueDetails(issue_id);
        defer if (issue_json) |json| self.allocator.free(json);

        // Fetch monowiki context proactively
        const design_context = try self.fetchMonowikiContext(issue_json orelse "");
        defer self.allocator.free(design_context);

        // Build monowiki section - always include commands, plus any fetched context
        const monowiki_section = if (self.config.monowiki_config) |mwc| blk: {
            const context_header = if (design_context.len > 0)
                \\
                \\DESIGN CONTEXT (automatically fetched):
                \\
            else
                "";

            const api_sync_note = if (mwc.sync_api_docs and mwc.api_docs_slug != null)
                try std.fmt.allocPrint(self.allocator,
                    \\
                    \\API DOCUMENTATION:
                    \\If this issue changes public APIs, update the API documentation:
                    \\- Read current: monowiki note {s} --format json
                    \\- Edit directly: {s}/{s}.md
                    \\
                , .{ mwc.api_docs_slug.?, mwc.vault, mwc.api_docs_slug.? })
            else
                try self.allocator.dupe(u8, "");
            defer self.allocator.free(api_sync_note);

            break :blk try std.fmt.allocPrint(self.allocator,
                \\
                \\DESIGN DOCUMENTS:
                \\Design documents are available via monowiki. Use these commands to find relevant context:
                \\- monowiki search "<query>" --json      # Search for design docs
                \\- monowiki note <slug> --format json    # Read a specific document
                \\- monowiki graph neighbors --slug <slug> --json  # Find related docs
                \\Vault location: {s}
                \\{s}{s}{s}
            , .{ mwc.vault, context_header, design_context, api_sync_note });
        } else if (self.config.monowiki_vault) |vault|
            // Legacy support for --monowiki-vault flag
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
                \\
                \\PROGRESS TRACKING:
                \\Update {s} with: date, issue worked on, accomplishments, and any blockers.
                \\
            , .{path})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(progress_section);

        return std.fmt.allocPrint(self.allocator,
            \\You are a senior software engineer working autonomously on issue {s} in the {s} project.
            \\{s}
            \\APPROACH:
            \\Before writing any code, take a moment to:
            \\1. Understand the issue fully - run `bd show {s}` and read carefully
            \\2. Explore related code - understand existing patterns and conventions
            \\3. Plan your approach - consider edge cases, error handling, and testability
            \\4. Keep changes minimal and focused - solve the issue, don't refactor unrelated code
            \\
            \\WORKFLOW:
            \\1. Mark issue in progress: `bd update {s} --status in_progress`
            \\2. Implement the solution following existing code style and patterns
            \\3. Verify your changes: `{s}`
            \\   - If tests fail, debug and fix before proceeding
            \\   - Add tests if the change is testable and tests don't exist
            \\4. Self-review your diff: `git diff`
            \\   - Check for: debugging artifacts, commented code, style inconsistencies
            \\5. Request review: `{s} review --uncommitted`
            \\6. Address ALL feedback - re-run review until approved
            \\7. Create marker: `touch .codex-approved`
            \\8. Commit with a clear message:
            \\   - Format: "<type>: <description>" (e.g., "fix: resolve null pointer in parser")
            \\   - Reference the issue in the body
            \\9. Close the issue: `bd close {s} --reason "Completed: <one-line summary>"`
            \\{s}
            \\QUALITY STANDARDS:
            \\- Code should be clear enough to not need comments explaining *what* it does
            \\- Error messages should help users understand what went wrong
            \\- No hardcoded values that should be configurable
            \\- Handle edge cases explicitly, don't rely on "it probably won't happen"
            \\
            \\CONSTRAINTS:
            \\- Do NOT commit until review explicitly approves
            \\- Do NOT modify code unrelated to this issue
            \\- Do NOT add dependencies without clear justification
            \\
            \\When finished, output: ISSUE_COMPLETE
            \\If blocked and cannot proceed, output: BLOCKED: <reason>
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

    // Retry helpers
    fn shouldRetry(exit_code: u8) bool {
        // Non-zero exit codes may indicate transient failures
        // Claude/Codex CLI tools return non-zero on API errors (rate limits, 5xx, network issues)
        return exit_code != 0;
    }

    fn calculateBackoffMs(attempt: u8, config: RetryConfig) u64 {
        // Exponential backoff: base * 2^attempt, capped at max
        const multiplier: u64 = @as(u64, 1) << @intCast(attempt);
        const delay = config.base_delay_ms * multiplier;
        return @min(delay, config.max_delay_ms);
    }

    fn sleepMs(ms: u64) void {
        std.Thread.sleep(ms * std.time.ns_per_ms);
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

test "retry config defaults" {
    const config = RetryConfig{};
    try std.testing.expectEqual(@as(u8, 3), config.max_attempts);
    try std.testing.expectEqual(@as(u64, 1000), config.base_delay_ms);
    try std.testing.expectEqual(@as(u64, 4000), config.max_delay_ms);
}

test "calculate backoff exponential" {
    const config = RetryConfig{};

    // Attempt 0: 1000 * 2^0 = 1000ms
    try std.testing.expectEqual(@as(u64, 1000), AgentLoop.calculateBackoffMs(0, config));

    // Attempt 1: 1000 * 2^1 = 2000ms
    try std.testing.expectEqual(@as(u64, 2000), AgentLoop.calculateBackoffMs(1, config));

    // Attempt 2: 1000 * 2^2 = 4000ms (capped at max)
    try std.testing.expectEqual(@as(u64, 4000), AgentLoop.calculateBackoffMs(2, config));

    // Attempt 3: would be 8000ms but capped at 4000ms
    try std.testing.expectEqual(@as(u64, 4000), AgentLoop.calculateBackoffMs(3, config));
}

test "should retry on non-zero exit" {
    try std.testing.expect(AgentLoop.shouldRetry(1));
    try std.testing.expect(AgentLoop.shouldRetry(255));
    try std.testing.expect(!AgentLoop.shouldRetry(0));
}
