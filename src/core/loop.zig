//! Main agent loop implementation.
//!
//! Orchestrates Claude (implementation) and Codex (review) agents
//! to work on issues autonomously.

const std = @import("std");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const worker_pool_mod = @import("worker_pool.zig");
const prompts = @import("prompts.zig");
const jj = @import("../vcs/jj.zig");
const process = @import("../util/process.zig");
const streaming = @import("../util/streaming.zig");
const signals = @import("../util/signals.zig");
const markdown = @import("../util/markdown.zig");
const transcript_mod = @import("../util/transcript.zig");
const bm25 = @import("../util/bm25.zig");
const monowiki_mod = @import("../integrations/monowiki.zig");
const issue_sync = @import("../integrations/issue_sync.zig");
const github = @import("../integrations/github.zig");

const Config = config_mod.Config;
const OutputFormat = config_mod.OutputFormat;
const PlannerMode = config_mod.PlannerMode;
const Monowiki = monowiki_mod.Monowiki;
const OrchestratorState = state_mod.OrchestratorState;
const WorkerPool = worker_pool_mod.WorkerPool;

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
    state: ?OrchestratorState = null,
    worker_pool: ?WorkerPool = null,
    code_index: ?bm25.Index = null,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) AgentLoop {
        // Install signal handlers (skip during tests to avoid interfering with test runner IPC)
        if (!@import("builtin").is_test) {
            signals.install();
        }

        return .{
            .allocator = allocator,
            .config = cfg,
        };
    }

    pub fn deinit(self: *AgentLoop) void {
        // Reset signal handlers (skip during tests - we didn't install them)
        if (!@import("builtin").is_test) {
            signals.reset();
        }

        // Clean up worker pool
        if (self.worker_pool) |*pool| {
            pool.deinit();
        }

        // Save and clean up state
        if (self.state) |*s| {
            s.save() catch |err| {
                self.logWarn("Failed to save state on exit: {}", .{err});
            };
            s.deinit();
        }

        // Clean up code index
        if (self.code_index) |*idx| {
            idx.deinit();
        }

        // Clean up any allocated resources
        if (self.session_log_path) |path| {
            self.allocator.free(path);
        }
    }

    /// Initialize orchestrator state with crash recovery
    fn initState(self: *AgentLoop) !void {
        self.state = try OrchestratorState.load(self.allocator, self.config.project_name);

        // Perform crash recovery
        const recovered = try self.state.?.recoverFromCrash();
        if (recovered > 0) {
            self.logWarn("Recovered {d} items from previous crash", .{recovered});
        }

        // Restore iteration count from state
        self.iteration = self.state.?.total_iterations;

        // Initialize worker pool with config-specified worker count
        self.state.?.num_workers = self.config.num_workers;
        self.worker_pool = WorkerPool.init(self.allocator, self.config, &self.state.?);
        self.logInfo("Worker pool initialized with {d} workers", .{self.state.?.num_workers});
    }

    /// Save state periodically
    fn saveState(self: *AgentLoop) void {
        if (self.state) |*s| {
            s.total_iterations = self.iteration;
            s.save() catch |err| {
                self.logWarn("Failed to save state: {}", .{err});
            };
        }
    }

    /// Build BM25 code index for the project
    /// Indexes source files to enable token-efficient code search
    fn buildCodeIndex(self: *AgentLoop) !void {
        if (self.code_index != null) return; // Already built

        self.logInfo("Building code index for token-efficient search...", .{});
        var index = bm25.Index.init(self.allocator);
        errdefer index.deinit();

        // Index common source file extensions
        const extensions = [_][]const u8{ ".zig", ".go", ".rs", ".py", ".js", ".ts", ".c", ".h", ".cpp", ".hpp" };

        // Try src/ first, fall back to current directory
        const indexed = index.indexDirectory("src", &extensions) catch |err| blk: {
            self.logWarn("Failed to index src directory: {}", .{err});
            break :blk index.indexDirectory(".", &extensions) catch {
                self.logWarn("Code indexing failed, prompts will not include code references", .{});
                return;
            };
        };

        self.code_index = index;
        self.logInfo("Indexed {d} source files", .{indexed});
    }

    /// Extract code references relevant to an issue
    /// Returns a slice of reference strings in format "path:start-end"
    /// Caller owns the returned slice and must free it.
    fn extractCodeReferences(self: *AgentLoop, issue_text: []const u8, max_refs: u32) ![]const bm25.SearchResult {
        // Access the optional field directly via pointer to avoid copying
        const index_ptr = &self.code_index;
        if (index_ptr.*) |*index| {
            // Search the index with the issue text as query
            return index.search(issue_text, max_refs);
        }
        // No index available - return allocator-owned empty slice so caller can safely free it
        return try self.allocator.alloc(bm25.SearchResult, 0);
    }

    /// Format code references as a prompt section
    fn formatCodeReferencesSection(self: *AgentLoop, refs: []const bm25.SearchResult) ![]const u8 {
        if (refs.len == 0) return try self.allocator.dupe(u8, "");

        var section = std.ArrayListUnmanaged(u8){};
        errdefer section.deinit(self.allocator);

        try section.appendSlice(self.allocator,
            \\
            \\RELEVANT CODE REFERENCES:
            \\The orchestrator has pre-analyzed the codebase for this issue.
            \\These file:line-range references point to potentially relevant code sections.
            \\Use the Read tool to fetch content as needed - don't read everything at once.
            \\
            \\
        );

        for (refs) |ref| {
            try section.appendSlice(self.allocator, "- ");
            try section.appendSlice(self.allocator, ref.id);
            try section.appendSlice(self.allocator, "\n");
        }

        return section.toOwnedSlice(self.allocator);
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

        if (self.config.verbose) {
            self.logVerbose("Verbose mode enabled", .{});
            self.logVerbose("Implementation agent: {s}", .{self.config.impl_agent});
            self.logVerbose("Review agent: {s}", .{self.config.review_agent});
            self.logVerbose("Build command: {s}", .{self.config.build_command});
            self.logVerbose("Test command: {s}", .{self.config.test_command});
            self.logVerbose("Agent timeout: {d} seconds", .{self.config.agent_timeout_seconds});
            self.logVerbose("Num workers: {d}", .{self.config.num_workers});
        }

        if (self.config.max_iterations > 0) {
            self.logInfo("Max iterations: {d}", .{self.config.max_iterations});
        } else {
            self.logInfo("Max iterations: unlimited", .{});
        }

        if (self.config.enable_planner) {
            switch (self.config.planner_mode) {
                .interval => self.logInfo("Planner mode: interval (every {d} iteration(s))", .{self.config.planner_interval}),
                .event_driven => self.logInfo("Planner mode: event-driven (on-demand)", .{}),
            }
        }
        if (self.config.enable_quality) {
            self.logInfo("Quality interval: every {d} iteration(s)", .{self.config.quality_interval});
        }

        // Check prerequisites
        try self.checkPrerequisites();

        // Initialize orchestrator state (with crash recovery)
        try self.initState();
        self.logInfo("State initialized ({d} previous iterations)", .{self.iteration});

        // Build code index for token-efficient prompts
        try self.buildCodeIndex();

        // Main loop
        if (self.iteration == 0) self.iteration = 1;
        while (!self.isInterrupted()) {
            // Run planner pass based on mode
            if (self.config.enable_planner) {
                const should_run_planner = switch (self.config.planner_mode) {
                    .interval => self.last_planner_iteration == 0 or
                        (self.iteration - self.last_planner_iteration) >= self.config.planner_interval,
                    .event_driven => self.last_planner_iteration == 0, // Only run on first iteration initially
                };

                if (should_run_planner) {
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

            // Try batch execution first (parallel workers)
            // If no batches available, fall back to sequential single-issue execution
            const batch_executed = try self.runBatchIteration();

            if (!batch_executed) {
                // No batches available - in event-driven mode, trigger planner if not already run this iteration
                const planner_ran_this_iter = self.last_planner_iteration == self.iteration;
                if (self.config.enable_planner and self.config.planner_mode == .event_driven and !planner_ran_this_iter) {
                    self.logInfo("No pending batches, triggering planner (event-driven)", .{});
                    if (!try self.runPlannerPass()) {
                        self.logInfo("Agent loop stopping after failed planner pass", .{});
                        break;
                    }
                    self.last_planner_iteration = self.iteration;

                    // Retry batch execution after planner creates new work
                    const retry_batch = try self.runBatchIteration();
                    if (retry_batch) {
                        // Successfully executed new batch from planner
                        continue;
                    }
                }

                // No batches available, run sequential iteration
                const iteration_result = try self.runIteration();
                if (!iteration_result) {
                    // No ready issues - in event-driven mode, planner already ran this iteration, so stop
                    self.logInfo("Agent loop stopping (no work available)", .{});
                    break;
                }
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

            // Save state after each iteration
            self.saveState();

            // Brief pause
            self.logInfo("Pausing 5 seconds before next iteration...", .{});
            std.Thread.sleep(5 * std.time.ns_per_s);
        }

        // Final state save
        self.saveState();
        self.logSuccess("Agent loop finished after {d} iteration(s)", .{self.iteration});
    }

    /// Check that required tools are available
    fn checkPrerequisites(self: *AgentLoop) !void {
        self.logInfo("Checking prerequisites...", .{});

        // Check for required commands
        const required = [_][]const u8{ self.config.impl_agent, self.config.review_agent, "bd", "jq" };

        for (required) |cmd| {
            if (!process.commandExists(self.allocator, cmd)) {
                self.logError("{s} not found in PATH", .{cmd});
                return error.MissingPrerequisite;
            }
        }

        // Check gh CLI only if GitHub sync is enabled
        if (self.config.sync_to_github) {
            if (!process.commandExists(self.allocator, "gh")) {
                self.logWarn("gh CLI not found - GitHub sync will be disabled", .{});
            }
        }

        // Verify build works
        if (!self.config.dry_run) {
            self.logInfo("Running build: {s}", .{self.config.build_command});
            self.logVerbose("Executing: {s}", .{self.config.build_command});
            const build_start = std.time.nanoTimestamp();
            var result = try process.shell(self.allocator, self.config.build_command);
            defer result.deinit();
            const build_elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - build_start));
            self.logVerboseTiming("Build command", build_elapsed);

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

    /// Result of getting next issue
    const NextIssueResult = struct {
        issue_id: ?[]const u8,
        reason: enum { found, no_ready, all_blocked, empty_backlog },
    };

    /// Get the next issue to work on
    fn getNextIssue(self: *AgentLoop) !?[]const u8 {
        const result = try self.getNextIssueWithReason();
        return result.issue_id;
    }

    /// Get the next issue with reason for empty result
    fn getNextIssueWithReason(self: *AgentLoop) !NextIssueResult {
        if (self.config.specific_issue) |issue| {
            return .{
                .issue_id = try self.allocator.dupe(u8, issue),
                .reason = .found,
            };
        }

        // First, check for in_progress issues (might be stalled from previous run)
        var in_progress_result = try process.shell(
            self.allocator,
            "bd list --json 2>/dev/null | jq -r '[.[] | select(.status == \"in_progress\")] | sort_by(.priority) | .[0].id // empty'",
        );
        defer in_progress_result.deinit();

        if (in_progress_result.success() and in_progress_result.stdout.len > 0) {
            const issue_id = std.mem.trim(u8, in_progress_result.stdout, " \t\n\r");
            if (issue_id.len > 0) {
                self.logInfo("Resuming in_progress issue: {s}", .{issue_id});
                return .{
                    .issue_id = try self.allocator.dupe(u8, issue_id),
                    .reason = .found,
                };
            }
        }

        // Then check for ready issues (unblocked)
        var ready_result = try process.shell(self.allocator, "bd ready --json 2>/dev/null | jq -r '.[0].id // empty'");
        defer ready_result.deinit();

        if (ready_result.success() and ready_result.stdout.len > 0) {
            const issue_id = std.mem.trim(u8, ready_result.stdout, " \t\n\r");
            if (issue_id.len > 0) {
                return .{
                    .issue_id = try self.allocator.dupe(u8, issue_id),
                    .reason = .found,
                };
            }
        }

        // No ready issues - check if there are any open issues at all
        var open_result = try process.shell(
            self.allocator,
            "bd list --json 2>/dev/null | jq '[.[] | select(.status == \"open\")] | length'",
        );
        defer open_result.deinit();

        if (open_result.success()) {
            const count_str = std.mem.trim(u8, open_result.stdout, " \t\n\r");
            const open_count = std.fmt.parseInt(u32, count_str, 10) catch 0;

            if (open_count > 0) {
                // There are open issues but none are ready (all blocked)
                return .{ .issue_id = null, .reason = .all_blocked };
            }
        }

        return .{ .issue_id = null, .reason = .empty_backlog };
    }

    /// Try to execute the next pending batch using the worker pool.
    /// Returns true if a batch was executed, false if no batches are available.
    fn runBatchIteration(self: *AgentLoop) !bool {
        var state = &(self.state orelse return false);
        var pool = &(self.worker_pool orelse return false);

        // Check if we have pending batches
        const batch = state.getNextPendingBatch() orelse return false;

        self.logInfo("=== Batch Iteration {d} (Batch {d}) ===", .{ self.iteration, batch.id });

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would execute batch {d} with {d} issue(s)", .{ batch.id, batch.issue_ids.len });
            batch.status = .completed;
            return true;
        }

        // Execute the batch using the worker pool
        const successful = try pool.executeBatch(batch);

        self.logInfo("Batch {d} completed: {d}/{d} issues successful", .{
            batch.id,
            successful,
            batch.issue_ids.len,
        });

        // Sync to GitHub after batch completion
        try self.syncGitHub();

        // Save state after batch
        self.saveState();

        return true;
    }

    /// Run one iteration of the agent loop
    fn runIteration(self: *AgentLoop) !bool {
        self.logInfo("=== Iteration {d} ===", .{self.iteration});

        // Get next issue with reason
        const next = try self.getNextIssueWithReason();

        if (next.issue_id == null) {
            switch (next.reason) {
                .all_blocked => {
                    self.logWarn("All open issues are blocked by dependencies", .{});
                    self.logInfo("Showing blocked issues:", .{});
                    var blocked_result = try process.shell(self.allocator, "bd blocked 2>/dev/null");
                    defer blocked_result.deinit();
                    if (blocked_result.stdout.len > 0) {
                        std.debug.print("{s}\n", .{blocked_result.stdout});
                    }
                    self.logInfo("Waiting 30 seconds before checking again...", .{});
                    std.Thread.sleep(30 * std.time.ns_per_s);
                    return true; // Continue loop, don't exit
                },
                .empty_backlog => {
                    self.logSuccess("All issues completed! Backlog is empty.", .{});
                    return false; // Exit loop - we're done!
                },
                else => {
                    self.logWarn("No ready issues found. Exiting.", .{});
                    return false;
                },
            }
        }

        const issue_id = next.issue_id.?;
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

        // Log truncated prompt in verbose mode
        self.logVerbosePrompt("Implementation prompt", prompt);

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

            last_exit_code = try self.runAgentStreaming(self.config.impl_agent, prompt, issue_id);

            // Check if we were interrupted
            if (self.isInterrupted()) {
                self.logWarn("Session was interrupted", .{});
                self.current_issue = null;
                signals.setCurrentIssue(null);
                return false;
            }

            // If agent succeeded, we're done
            if (last_exit_code == 0) {
                self.logSuccess("Agent completed successfully", .{});
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

            // Ask planner to break down the issue into smaller pieces
            self.logInfo("Asking planner to break down issue into sub-issues...", .{});
            const breakdown_success = self.requestIssueBreakdown(issue_id) catch false;

            self.current_issue = null;
            signals.setCurrentIssue(null);

            if (breakdown_success) {
                self.logSuccess("Issue broken down into sub-issues, continuing loop", .{});
                self.writeProgressEntry(issue_id, .blocked, "Broken down into sub-issues");
                return true; // Continue with the new sub-issues
            } else {
                self.logWarn("Could not break down issue, stopping", .{});
                self.writeProgressEntry(issue_id, .failed, "Agent failed, could not break down");
                return false;
            }
        }

        // Verify issue was closed
        try self.verifyIssueClosed(issue_id);

        // Sync to GitHub
        try self.syncGitHub();

        self.writeProgressEntry(issue_id, .completed, "Issue closed successfully");

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
        // User directions section (if provided)
        const directions_section = if (self.config.planner_directions) |directions|
            try std.fmt.allocPrint(self.allocator,
                \\
                \\USER DIRECTIONS:
                \\The user has provided the following directions for this planning pass.
                \\These take priority over default planning heuristics:
                \\
                \\{s}
                \\
            , .{directions})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(directions_section);

        // Two different prompts: with design docs (monowiki) or without
        if (self.config.monowiki_config) |mwc| {
            return prompts.buildPlannerPromptWithMonowiki(
                self.allocator,
                self.config.project_name,
                mwc.vault,
                directions_section,
            );
        } else {
            return prompts.buildPlannerPromptSimple(
                self.allocator,
                self.config.project_name,
                directions_section,
            );
        }
    }

    /// Run a planner pass (strategic planning from design docs)
    fn runPlannerPass(self: *AgentLoop) !bool {
        self.logInfo("Starting planner pass...", .{});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run planner pass", .{});
            return true;
        }

        const planner_start = std.time.nanoTimestamp();

        const prompt = try self.buildPlannerPrompt();
        defer self.allocator.free(prompt);

        self.logVerbosePrompt("Planner prompt", prompt);

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
                const planner_elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - planner_start));
                self.logVerboseTiming("Planner pass", planner_elapsed);
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

    /// Request the planner to break down a failed issue into sub-issues
    fn requestIssueBreakdown(self: *AgentLoop, issue_id: []const u8) !bool {
        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would request breakdown of {s}", .{issue_id});
            return true;
        }

        const prompt = try self.buildBreakdownPrompt(issue_id);
        defer self.allocator.free(prompt);

        const exit_code = try self.runCodexExec(prompt);

        if (exit_code == 0) {
            self.logSuccess("Breakdown completed for {s}", .{issue_id});
            return true;
        }

        self.logWarn("Breakdown failed for {s} (exit code: {d})", .{ issue_id, exit_code });
        return false;
    }

    /// Build prompt for breaking down a failed issue
    fn buildBreakdownPrompt(self: *AgentLoop, issue_id: []const u8) ![]const u8 {
        // Get issue details
        const show_cmd = try std.fmt.allocPrint(self.allocator, "bd show {s} --json 2>/dev/null", .{issue_id});
        defer self.allocator.free(show_cmd);

        var show_result = try process.shell(self.allocator, show_cmd);
        defer show_result.deinit();

        const issue_json = if (show_result.success()) show_result.stdout else "{}";

        return prompts.buildBreakdownPrompt(
            self.allocator,
            self.config.project_name,
            issue_id,
            issue_json,
        );
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

        return prompts.buildQualityPrompt(
            self.allocator,
            self.config.project_name,
            monowiki_section,
        );
    }

    /// Run a code quality review pass
    fn runQualityPass(self: *AgentLoop) !bool {
        self.logInfo("Starting code quality review pass...", .{});

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would run quality review", .{});
            return true;
        }

        const quality_start = std.time.nanoTimestamp();

        const prompt = try self.buildQualityPrompt();
        defer self.allocator.free(prompt);

        self.logVerbosePrompt("Quality review prompt", prompt);

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
                const quality_elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - quality_start));
                self.logVerboseTiming("Quality review pass", quality_elapsed);
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

    /// Special exit code indicating agent timeout
    pub const EXIT_CODE_TIMEOUT: u8 = 124; // Same as GNU timeout

    /// Convert tool name to compact action verb
    fn compactToolAction(tool_name: []const u8) []const u8 {
        if (std.mem.eql(u8, tool_name, "Read")) return "Reading";
        if (std.mem.eql(u8, tool_name, "Edit")) return "Editing";
        if (std.mem.eql(u8, tool_name, "Write")) return "Writing";
        if (std.mem.eql(u8, tool_name, "Bash")) return "Running";
        if (std.mem.eql(u8, tool_name, "Grep")) return "Searching";
        if (std.mem.eql(u8, tool_name, "Glob")) return "Finding";
        if (std.mem.eql(u8, tool_name, "Task")) return "Spawning";
        if (std.mem.eql(u8, tool_name, "WebFetch")) return "Fetching";
        if (std.mem.eql(u8, tool_name, "WebSearch")) return "Searching";
        return tool_name;
    }

    /// Run an agent with streaming output and SQLite transcript logging
    fn runAgentStreaming(self: *AgentLoop, agent: []const u8, prompt: []const u8, issue_id: []const u8) !u8 {
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

        // Log command in verbose mode
        self.logVerbose("Executing agent command: {s} -p --dangerously-skip-permissions --verbose --output-format stream-json --include-partial-messages <prompt>", .{agent});

        const agent_start = std.time.nanoTimestamp();

        // Open transcript database
        var transcript_db = transcript_mod.TranscriptDb.open(self.allocator) catch |err| {
            self.logWarn("Failed to open transcript DB: {}, continuing without logging", .{err});
            return try self.runAgentStreamingWithoutLog(&argv);
        };
        defer transcript_db.close();

        // Start a new session
        const session_id = transcript_db.startSession(issue_id, null, false) catch |err| {
            self.logWarn("Failed to start transcript session: {}", .{err});
            return try self.runAgentStreamingWithoutLog(&argv);
        };
        defer self.allocator.free(session_id);

        var proc = try process.StreamingProcess.spawn(self.allocator, &argv);
        defer proc.deinit();

        // Collect full response for final markdown rendering
        var full_response = std.ArrayListUnmanaged(u8){};
        defer full_response.deinit(self.allocator);

        const timeout_seconds = self.config.agent_timeout_seconds;
        var line_buf: [64 * 1024]u8 = undefined;
        var event_seq: u32 = 0;

        // Log timeout setting
        if (timeout_seconds > 0) {
            self.logInfo("Agent timeout: {d} seconds", .{timeout_seconds});
        }

        var exit_code: u8 = 0;

        while (true) {
            // Check for interrupt first
            if (self.isInterrupted()) {
                proc.kill();
                exit_code = 130; // SIGINT
                break;
            }

            // Read with timeout
            const read_result = try proc.readLineWithTimeout(&line_buf, timeout_seconds);

            switch (read_result) {
                .timeout => {
                    // No output for timeout_seconds - agent is hung
                    self.logError("Agent timeout: no output for {d} seconds", .{timeout_seconds});
                    proc.kill();
                    // Reap the process to avoid zombie
                    _ = proc.wait() catch {};
                    std.debug.print("\n", .{});
                    exit_code = EXIT_CODE_TIMEOUT;
                    break;
                },
                .eof => {
                    // Process closed stdout, we're done
                    break;
                },
                .line => |line| {
                    // Parse event for logging and display
                    var event = streaming.parseStreamLine(self.allocator, line) catch continue;
                    defer streaming.deinitEvent(self.allocator, &event);

                    // Log to SQLite (convert enum to string)
                    const event_type_str = @tagName(event.event_type);
                    transcript_db.logEvent(
                        session_id,
                        event_seq,
                        event_type_str,
                        event.tool_name,
                        event.text,
                        line,
                    ) catch {};
                    event_seq += 1;

                    switch (self.config.output_format) {
                        .stream_json => {
                            // Output raw JSON
                            _ = std.fs.File.stdout().write(line) catch {};
                            _ = std.fs.File.stdout().write("\n") catch {};
                        },
                        .text => {
                            // Stream text deltas and collect for final render
                            if (event.text) |text| {
                                try full_response.appendSlice(self.allocator, text);
                                _ = std.fs.File.stdout().write(text) catch {};
                            }
                            if (event.tool_name) |name| {
                                if (event.tool_input_summary) |summary| {
                                    std.debug.print("\n{s}[TOOL]{s} {s}: {s}\n", .{ Color.cyan, Color.reset, name, summary });
                                } else {
                                    std.debug.print("\n{s}[TOOL]{s} {s}\n", .{ Color.cyan, Color.reset, name });
                                }
                            }
                        },
                        .compact => {
                            // Concise status updates (worker-style)
                            if (event.text) |text| {
                                try full_response.appendSlice(self.allocator, text);
                            }
                            if (event.tool_name) |name| {
                                const action = compactToolAction(name);
                                if (event.tool_input_summary) |summary| {
                                    // Truncate long summaries
                                    const max_len: usize = 50;
                                    const display = if (summary.len > max_len) summary[0..max_len] else summary;
                                    std.debug.print("{s}[AGENT]{s} {s} {s}\n", .{ Color.cyan, Color.reset, action, display });
                                } else {
                                    std.debug.print("{s}[AGENT]{s} {s}\n", .{ Color.cyan, Color.reset, action });
                                }
                            }
                        },
                        .raw => {
                            // Plain text without styling
                            streaming.printTextDelta(event);
                        },
                    }
                },
            }
        }

        // Get exit code from process if it wasn't set by early exit
        if (exit_code == 0) {
            exit_code = try proc.wait();
        }
        std.debug.print("\n", .{});

        // Complete the session in the transcript DB
        transcript_db.completeSession(session_id, exit_code) catch {};

        // Render final markdown summary if in text mode and we have content
        if (self.config.output_format == .text and full_response.items.len > 0) {
            self.logInfo("=== Final Result ===", .{});
            markdown.print(self.allocator, full_response.items);
            std.debug.print("\n", .{});
        }

        self.logInfo("Transcript saved to .noface/transcripts.db (session: {s})", .{session_id});

        // Log timing and response summary in verbose mode
        const agent_elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - agent_start));
        self.logVerboseTiming("Agent session", agent_elapsed);
        self.logVerbose("Agent exit code: {d}, response length: {d} bytes", .{ exit_code, full_response.items.len });

        return exit_code;
    }

    /// Fallback streaming without log file
    fn runAgentStreamingWithoutLog(self: *AgentLoop, argv: []const []const u8) !u8 {
        var proc = try process.StreamingProcess.spawn(self.allocator, argv);
        defer proc.deinit();

        const timeout_seconds = self.config.agent_timeout_seconds;
        var line_buf: [64 * 1024]u8 = undefined;

        while (true) {
            if (self.isInterrupted()) {
                proc.kill();
                break;
            }

            const read_result = try proc.readLineWithTimeout(&line_buf, timeout_seconds);

            switch (read_result) {
                .timeout => {
                    self.logError("Agent timeout: no output for {d} seconds", .{timeout_seconds});
                    proc.kill();
                    // Reap the process to avoid zombie
                    _ = proc.wait() catch {};
                    std.debug.print("\n", .{});
                    return EXIT_CODE_TIMEOUT;
                },
                .eof => break,
                .line => |line| {
                    var event = streaming.parseStreamLine(self.allocator, line) catch continue;
                    streaming.printTextDelta(event);
                    streaming.deinitEvent(self.allocator, &event);
                },
            }
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

        // Extract code references using BM25 search (token-efficient: refs not content)
        const code_refs = try self.extractCodeReferences(issue_json orelse "", 10);
        defer self.allocator.free(code_refs);
        const code_refs_section = try self.formatCodeReferencesSection(code_refs);
        defer self.allocator.free(code_refs_section);

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

        return prompts.buildImplementationPrompt(
            self.allocator,
            issue_id,
            self.config.project_name,
            code_refs_section,
            monowiki_section,
            self.config.test_command,
            self.config.review_agent,
            progress_section,
        );
    }

    /// Sync issues to configured provider (GitHub, Gitea, etc.)
    fn syncGitHub(self: *AgentLoop) !void {
        // Check if sync is enabled (legacy sync_to_github or new provider config)
        const provider_type = self.config.sync_provider.provider_type;
        if (!self.config.sync_to_github and provider_type == .none) return;

        // Determine which provider to use
        const effective_provider = if (provider_type != .none)
            provider_type
        else if (self.config.sync_to_github)
            issue_sync.ProviderType.github
        else
            issue_sync.ProviderType.none;

        if (effective_provider == .none) return;

        const provider_name = effective_provider.toString();
        self.logInfo("Syncing issues to {s}...", .{provider_name});

        // Use new provider abstraction
        var sync_config = self.config.sync_provider;
        sync_config.provider_type = effective_provider;

        const sync_result = issue_sync.syncToProvider(self.allocator, sync_config, self.config.dry_run) catch |err| {
            self.logWarn("{s} sync failed (non-fatal): {}", .{ provider_name, err });
            return;
        };

        if (sync_result.errors > 0 and sync_result.created == 0 and sync_result.closed == 0) {
            // Only errors, likely a prerequisite failure
            self.logWarn("{s} sync skipped (provider not available or not configured)", .{provider_name});
        } else {
            self.logSuccess("{s} sync: {d} created, {d} closed, {d} skipped", .{
                provider_name,
                sync_result.created,
                sync_result.closed,
                sync_result.skipped,
            });
        }
    }

    // Retry helpers
    fn shouldRetry(exit_code: u8) bool {
        // Timeout (124) should NOT be retried - if agent hung once, it will likely hang again
        // Instead, let the issue breakdown flow handle it
        if (exit_code == EXIT_CODE_TIMEOUT) return false;

        // Other non-zero exit codes may indicate transient failures
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

    /// Progress entry status for the progress file
    pub const ProgressStatus = enum {
        completed,
        blocked,
        failed,

        pub fn toString(self: ProgressStatus) []const u8 {
            return switch (self) {
                .completed => "completed",
                .blocked => "blocked",
                .failed => "failed",
            };
        }
    };

    /// Write a progress entry to the configured progress file
    /// Creates the file if missing; on write failure, logs a warning and continues
    fn writeProgressEntry(
        self: *AgentLoop,
        issue_id: []const u8,
        status: ProgressStatus,
        summary: []const u8,
    ) void {
        const progress_path = self.config.progress_file orelse return;

        if (self.config.dry_run) {
            self.logInfo("[DRY RUN] Would write progress: {s} - {s} - {s}", .{
                issue_id,
                status.toString(),
                summary,
            });
            return;
        }

        // Get current timestamp
        const timestamp = std.time.timestamp();
        const epoch_seconds: std.posix.time_t = @intCast(timestamp);
        const epoch_day = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
        const year_day = epoch_day.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_day.getDaySeconds();
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();

        // Format the entry
        const entry = std.fmt.allocPrint(
            self.allocator,
            "| {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} | {s} | {s} | {s} |\n",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                hours,
                minutes,
                seconds,
                issue_id,
                status.toString(),
                summary,
            },
        ) catch |err| {
            self.logWarn("Failed to format progress entry: {}", .{err});
            return;
        };
        defer self.allocator.free(entry);

        // Open or create the file in append mode
        const file = std.fs.cwd().openFile(progress_path, .{ .mode = .write_only }) catch |err| {
            if (err == error.FileNotFound) {
                // Create the file with header
                const new_file = std.fs.cwd().createFile(progress_path, .{}) catch |create_err| {
                    self.logWarn("Failed to create progress file '{s}': {}", .{ progress_path, create_err });
                    return;
                };
                defer new_file.close();

                const header = "# noface Progress Log\n\n| Timestamp | Issue | Status | Summary |\n|-----------|-------|--------|----------|\n";
                new_file.writeAll(header) catch |write_err| {
                    self.logWarn("Failed to write progress file header: {}", .{write_err});
                    return;
                };
                new_file.writeAll(entry) catch |write_err| {
                    self.logWarn("Failed to write progress entry: {}", .{write_err});
                    return;
                };
                return;
            }
            self.logWarn("Failed to open progress file '{s}': {}", .{ progress_path, err });
            return;
        };
        defer file.close();

        // Seek to end and append
        file.seekFromEnd(0) catch |err| {
            self.logWarn("Failed to seek to end of progress file: {}", .{err});
            return;
        };
        file.writeAll(entry) catch |err| {
            self.logWarn("Failed to write progress entry: {}", .{err});
            return;
        };
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

    /// Log verbose output (only when --verbose is enabled)
    fn logVerbose(self: *AgentLoop, comptime fmt: []const u8, args: anytype) void {
        if (self.config.verbose) {
            std.debug.print(Color.cyan ++ "[VERBOSE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
        }
    }

    /// Log verbose timing information
    fn logVerboseTiming(self: *AgentLoop, label: []const u8, elapsed_ns: u64) void {
        if (self.config.verbose) {
            const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
            std.debug.print(Color.cyan ++ "[VERBOSE]" ++ Color.reset ++ " {s}: {d}ms\n", .{ label, elapsed_ms });
        }
    }

    /// Log truncated prompt in verbose mode
    fn logVerbosePrompt(self: *AgentLoop, label: []const u8, prompt: []const u8) void {
        if (self.config.verbose) {
            const max_len: usize = 500;
            const truncated = prompt.len > max_len;
            const display_len = if (truncated) max_len else prompt.len;
            std.debug.print(Color.cyan ++ "[VERBOSE]" ++ Color.reset ++ " {s} ({d} chars):\n", .{ label, prompt.len });
            std.debug.print("  {s}", .{prompt[0..display_len]});
            if (truncated) {
                std.debug.print("... (truncated)\n", .{});
            } else {
                std.debug.print("\n", .{});
            }
        }
    }
};

test "agent loop init" {
    const cfg = Config.default();
    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    try std.testing.expectEqual(@as(u32, 0), loop.iteration);
}

test "agent loop verbose mode" {
    var cfg = Config.default();
    cfg.verbose = true;

    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    try std.testing.expect(loop.config.verbose);
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

test "should not retry on timeout" {
    // Timeout (exit code 124) should NOT be retried
    try std.testing.expect(!AgentLoop.shouldRetry(AgentLoop.EXIT_CODE_TIMEOUT));
}

test "timeout exit code is 124" {
    // Verify timeout exit code matches GNU timeout convention
    try std.testing.expectEqual(@as(u8, 124), AgentLoop.EXIT_CODE_TIMEOUT);
}

test "progress status toString" {
    try std.testing.expectEqualStrings("completed", AgentLoop.ProgressStatus.completed.toString());
    try std.testing.expectEqualStrings("blocked", AgentLoop.ProgressStatus.blocked.toString());
    try std.testing.expectEqualStrings("failed", AgentLoop.ProgressStatus.failed.toString());
}

test "writeProgressEntry creates file with header" {
    const test_file = "/tmp/noface-test-progress.md";

    // Clean up from any previous test run
    std.fs.cwd().deleteFile(test_file) catch {};

    var cfg = Config.default();
    cfg.progress_file = test_file;

    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    // Write an entry
    loop.writeProgressEntry("test-issue-1", .completed, "Test completed");

    // Read the file and verify contents
    const content = std.fs.cwd().readFileAlloc(std.testing.allocator, test_file, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read test file: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(content);

    // Verify header is present
    try std.testing.expect(std.mem.indexOf(u8, content, "# noface Progress Log") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "| Timestamp | Issue | Status | Summary |") != null);

    // Verify entry is present
    try std.testing.expect(std.mem.indexOf(u8, content, "test-issue-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Test completed") != null);

    // Clean up
    std.fs.cwd().deleteFile(test_file) catch {};
}

test "writeProgressEntry appends to existing file" {
    const test_file = "/tmp/noface-test-progress-append.md";

    // Clean up from any previous test run
    std.fs.cwd().deleteFile(test_file) catch {};

    var cfg = Config.default();
    cfg.progress_file = test_file;

    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    // Write first entry
    loop.writeProgressEntry("issue-1", .completed, "First issue done");

    // Write second entry
    loop.writeProgressEntry("issue-2", .blocked, "Second issue blocked");

    // Read the file and verify both entries
    const content = std.fs.cwd().readFileAlloc(std.testing.allocator, test_file, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read test file: {}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(content);

    // Verify both entries are present
    try std.testing.expect(std.mem.indexOf(u8, content, "issue-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "issue-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "blocked") != null);

    // Header should appear only once
    var header_count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, content[search_start..], "# noface Progress Log")) |idx| {
        header_count += 1;
        search_start = search_start + idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), header_count);

    // Clean up
    std.fs.cwd().deleteFile(test_file) catch {};
}

test "writeProgressEntry dry run does not write" {
    const test_file = "/tmp/noface-test-progress-dryrun.md";

    // Clean up from any previous test run
    std.fs.cwd().deleteFile(test_file) catch {};

    var cfg = Config.default();
    cfg.progress_file = test_file;
    cfg.dry_run = true;

    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    // Write an entry (should not actually write due to dry_run)
    loop.writeProgressEntry("dry-issue", .completed, "Should not write");

    // File should not exist
    const result = std.fs.cwd().access(test_file, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "writeProgressEntry no-op when progress_file is null" {
    const cfg = Config.default();
    // progress_file is null by default

    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    // This should be a no-op and not crash
    loop.writeProgressEntry("any-issue", .completed, "Should do nothing");
}
