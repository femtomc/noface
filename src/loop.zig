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
const github = @import("github.zig");
const state_mod = @import("state.zig");
const worker_pool_mod = @import("worker_pool.zig");
const transcript_mod = @import("transcript.zig");

const Config = config_mod.Config;
const OutputFormat = config_mod.OutputFormat;
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

        // Initialize orchestrator state (with crash recovery)
        try self.initState();
        self.logInfo("State initialized ({d} previous iterations)", .{self.iteration});

        // Main loop
        if (self.iteration == 0) self.iteration = 1;
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

            // Try batch execution first (parallel workers)
            // If no batches available, fall back to sequential single-issue execution
            const batch_executed = try self.runBatchIteration();

            if (!batch_executed) {
                // No batches available, run sequential iteration
                if (!try self.runIteration()) {
                    self.logInfo("Agent loop stopping", .{});
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

        // Capture baseline of changed files before agent runs
        // This allows us to distinguish pre-existing changes from agent-made changes
        const baseline = try self.captureChangedFilesBaseline();
        defer self.freeBaseline(baseline);

        // Run Claude with streaming and retry logic
        self.logInfo("Starting {s} session (streaming)...", .{self.config.impl_agent});
        const retry_config = RetryConfig{};
        var attempt: u8 = 0;
        var last_exit_code: u8 = 0;
        var last_violation: ?ManifestComplianceResult = null;
        defer if (last_violation) |*v| v.deinit(self.allocator);

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

            // Use stricter prompt if previous attempt had manifest violation
            const effective_prompt = if (last_violation) |v| blk: {
                const stricter = self.buildStricterPrompt(issue_id, v) catch prompt;
                break :blk stricter;
            } else prompt;
            defer if (last_violation != null and effective_prompt.ptr != prompt.ptr) {
                self.allocator.free(effective_prompt);
            };

            last_exit_code = try self.runAgentStreaming(self.config.impl_agent, effective_prompt, issue_id);

            // Check if we were interrupted
            if (self.isInterrupted()) {
                self.logWarn("Session was interrupted", .{});
                self.current_issue = null;
                signals.setCurrentIssue(null);
                return false;
            }

            // Check manifest compliance regardless of agent exit code
            // (failed agents might still have modified forbidden files)
            self.logInfo("Checking manifest compliance...", .{});
            var compliance = try self.verifyManifestCompliance(issue_id, baseline);

            if (!compliance.compliant) {
                // Manifest violation detected
                self.logError("Manifest violation detected!", .{});

                if (compliance.forbidden_files_touched.len > 0) {
                    self.logError("Forbidden files touched: {d}", .{compliance.forbidden_files_touched.len});
                    for (compliance.forbidden_files_touched) |f| {
                        self.logError("  - {s}", .{f});
                    }
                }
                if (compliance.unauthorized_files.len > 0) {
                    self.logError("Unauthorized files modified: {d}", .{compliance.unauthorized_files.len});
                    for (compliance.unauthorized_files) |f| {
                        self.logError("  - {s}", .{f});
                    }
                }

                // Record violation in state
                if (self.state) |*s| {
                    // Build violation notes
                    var notes_buf: [1024]u8 = undefined;
                    const notes = std.fmt.bufPrint(&notes_buf, "Manifest violation: {d} forbidden, {d} unauthorized files", .{
                        compliance.forbidden_files_touched.len,
                        compliance.unauthorized_files.len,
                    }) catch "Manifest violation";

                    s.recordAttempt(issue_id, .violation, notes) catch {};
                }

                // Rollback only the violating files (preserve pre-existing changes)
                try self.rollbackViolatingFiles(compliance);

                // Save violation for stricter prompt on retry
                if (last_violation) |*v| v.deinit(self.allocator);
                last_violation = compliance;

                // Set exit code to indicate violation (for retry logic)
                last_exit_code = EXIT_CODE_MANIFEST_VIOLATION;

                // Check if we should retry
                if (attempt + 1 < retry_config.max_attempts) {
                    self.logWarn("Will retry with stricter prompt", .{});
                    continue;
                } else {
                    self.logError("Max retries exceeded after manifest violations", .{});
                    break;
                }
            } else {
                // Compliant - clean up compliance result
                compliance.deinit(self.allocator);

                // If agent succeeded, we're done
                if (last_exit_code == 0) {
                    self.logSuccess("Manifest compliance verified", .{});
                    break;
                }
            }

            // Check if we should retry (agent failed but no manifest violation)
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

        // Common manifest generation section
        const manifest_section =
            \\
            \\FILE MANIFEST GENERATION:
            \\For each issue that will be worked on, predict which files will be modified.
            \\This is CRITICAL for enabling parallel execution without file conflicts.
            \\
            \\After analyzing each issue, output a MANIFEST block:
            \\
            \\```manifest
            \\ISSUE: <issue-id>
            \\PRIMARY_FILES:
            \\- src/path/to/file.zig
            \\- src/another/file.zig
            \\READ_FILES:
            \\- src/shared/types.zig
            \\FORBIDDEN_FILES:
            \\- src/main.zig
            \\```
            \\
            \\Guidelines for manifest generation:
            \\- PRIMARY_FILES: Files this issue will modify (exclusive access needed)
            \\- READ_FILES: Files that will be read but not modified (shared access OK)
            \\- FORBIDDEN_FILES: Files that must NOT be touched (e.g., unrelated modules)
            \\- Analyze the issue description and acceptance criteria carefully
            \\- Consider which modules/files are relevant based on the codebase structure
            \\- If unsure, include more files in PRIMARY_FILES (safer for conflict detection)
            \\- Use glob patterns sparingly: prefer explicit file paths
            \\
            \\After outputting a manifest, store it as a comment on the issue:
            \\  bd comment <issue-id> "MANIFEST: primary=[file1,file2] read=[file3] forbidden=[file4]"
            \\
            \\PARALLEL BATCH GROUPING:
            \\After generating manifests for all ready issues, group them into parallel batches.
            \\Issues in the same batch can be worked on simultaneously by multiple workers.
            \\
            \\Rules for batch grouping:
            \\1. Issues with OVERLAPPING PRIMARY_FILES must be in DIFFERENT batches (file conflict)
            \\2. If issue A depends on issue B (A is blocked by B), they must be in DIFFERENT batches
            \\   - B's batch must come BEFORE A's batch (respect dependency ordering)
            \\3. Maximize parallelism: put as many non-conflicting issues in each batch as possible
            \\4. Earlier batches should contain foundation/blocking work
            \\
            \\Output batch groupings as PARALLEL_BATCH blocks:
            \\
            \\```batch
            \\PARALLEL_BATCH: 1
            \\ISSUES:
            \\- issue-abc
            \\- issue-xyz
            \\REASON: No file conflicts, independent changes
            \\```
            \\
            \\```batch
            \\PARALLEL_BATCH: 2
            \\ISSUES:
            \\- issue-def
            \\REASON: Depends on issue-abc from batch 1
            \\```
            \\
        ;

        // Two different prompts: with design docs (monowiki) or without
        if (self.config.monowiki_config) |mwc| {
            return std.fmt.allocPrint(self.allocator,
                \\You are the strategic planner for {s}.
                \\
                \\DESIGN DOCUMENTS:
                \\The design documents define what we're building. They are your primary source of truth.
                \\Location: {s}
                \\
                \\Commands:
                \\- monowiki search "<query>" --json    # Find relevant design docs
                \\- monowiki note <slug> --format json  # Read a specific document
                \\- monowiki graph neighbors --slug <slug> --json  # Find related docs
                \\
                \\OBJECTIVE:
                \\Chart an implementation path through the issue backlog that progresses toward
                \\the architecture and features specified in the design documents.
                \\
                \\ASSESS CURRENT STATE:
                \\1. Run `bd list` to see all issues
                \\2. Run `bd ready` to see the implementation queue
                \\3. Survey design documents to understand target architecture
                \\4. For each ready issue, analyze which files will need modification
                \\
                \\PLANNING TASKS:
                \\
                \\Gap Analysis:
                \\- Compare design documents against existing issues
                \\- Identify design elements with no corresponding issues
                \\- Create issues to fill gaps (reference the design doc slug)
                \\
                \\Priority Assignment:
                \\- P0: Blocking issues, security vulnerabilities, broken builds
                \\- P1: Foundation work that unblocks other features
                \\- P2: Features specified in design docs
                \\- P3: Nice-to-haves, future work
                \\
                \\Sequencing:
                \\- Ensure dependencies flow correctly (foundations before features)
                \\- Use `bd dep add <issue> <blocker>` to express dependencies
                \\{s}{s}
                \\CONSTRAINTS:
                \\- READ-ONLY for code and design documents
                \\- Only modify beads issues (create, update, close, add deps, comment)
                \\- Do not begin implementation work
                \\- Do NOT search for design docs outside the monowiki vault
                \\
                \\OUTPUT:
                \\1. Output MANIFEST blocks for all ready issues
                \\2. Store each manifest as a bd comment
                \\3. Output PARALLEL_BATCH blocks grouping non-conflicting issues
                \\4. Summarize gaps identified, issues created, and recommended critical path
                \\End with: PLANNING_COMPLETE
            , .{ self.config.project_name, mwc.vault, directions_section, manifest_section });
        } else {
            // No design docs - simpler backlog management prompt
            return std.fmt.allocPrint(self.allocator,
                \\You are the strategic planner for {s}.
                \\
                \\NOTE: No design documents are configured for this project.
                \\Focus on organizing and prioritizing the existing backlog.
                \\
                \\OBJECTIVE:
                \\Manage the issue backlog to ensure work is well-organized and sequenced.
                \\
                \\ASSESS CURRENT STATE:
                \\1. Run `bd list` to see all issues
                \\2. Run `bd ready` to see the implementation queue
                \\3. Run `bd blocked` to see what's waiting on dependencies
                \\4. For each ready issue, analyze which files will need modification
                \\
                \\PLANNING TASKS:
                \\
                \\Priority Review:
                \\- P0: Blocking issues, security vulnerabilities, broken builds
                \\- P1: Foundation work that unblocks other features
                \\- P2: Standard features and improvements
                \\- P3: Nice-to-haves, future work
                \\
                \\Sequencing:
                \\- Ensure dependencies flow correctly (foundations before features)
                \\- Use `bd dep add <issue> <blocker>` to express dependencies
                \\- Split issues that are too large into smaller pieces
                \\
                \\Issue Quality:
                \\- Each issue should have a clear, actionable title
                \\- Description should explain what, why, and acceptance criteria
                \\{s}{s}
                \\CONSTRAINTS:
                \\- READ-ONLY for code files
                \\- Only modify beads issues (create, update, close, add deps, comment)
                \\- Do not begin implementation work
                \\- Do NOT search for design docs - there are none configured
                \\
                \\OUTPUT:
                \\1. Output MANIFEST blocks for all ready issues
                \\2. Store each manifest as a bd comment
                \\3. Output PARALLEL_BATCH blocks grouping non-conflicting issues
                \\4. Summarize any changes made and recommend the critical path
                \\End with: PLANNING_COMPLETE
            , .{ self.config.project_name, directions_section, manifest_section });
        }
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

                // Load manifests from beads comments into state
                const loaded = try self.loadManifestsFromComments();
                if (loaded > 0) {
                    self.logInfo("Loaded {d} manifest(s) from beads comments", .{loaded});
                }

                // Generate parallel batches from manifests
                const batches = try self.generateBatchesFromManifests();
                if (batches > 0) {
                    self.logInfo("Generated {d} parallel batch(es)", .{batches});
                }

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

    /// Load manifests from beads comments for all ready issues
    fn loadManifestsFromComments(self: *AgentLoop) !u32 {
        var state = &(self.state orelse return 0);
        var loaded: u32 = 0;

        // Get list of ready issues
        var ready_result = try process.shell(self.allocator, "bd ready --json 2>/dev/null | jq -r '.[].id'");
        defer ready_result.deinit();

        if (!ready_result.success() or ready_result.stdout.len == 0) {
            return 0;
        }

        // Parse issue IDs (one per line)
        var lines = std.mem.tokenizeScalar(u8, ready_result.stdout, '\n');
        while (lines.next()) |issue_id| {
            const trimmed_id = std.mem.trim(u8, issue_id, " \t\r");
            if (trimmed_id.len == 0) continue;

            // Fetch comments for this issue
            const cmd = try std.fmt.allocPrint(
                self.allocator,
                "bd comments {s} --json 2>/dev/null",
                .{trimmed_id},
            );
            defer self.allocator.free(cmd);

            var comments_result = try process.shell(self.allocator, cmd);
            defer comments_result.deinit();

            if (!comments_result.success()) continue;

            // Look for MANIFEST comment and parse it
            if (try self.parseManifestFromComments(comments_result.stdout)) |manifest| {
                try state.setManifest(trimmed_id, manifest);
                loaded += 1;
            }
        }

        return loaded;
    }

    /// Parse a manifest from beads comments JSON
    /// Looks for comment text matching: "MANIFEST: primary=[...] read=[...] forbidden=[...]"
    fn parseManifestFromComments(self: *AgentLoop, comments_json: []const u8) !?state_mod.Manifest {
        // Simple parsing - look for "MANIFEST:" pattern in the JSON
        const manifest_marker = "MANIFEST:";

        // Find the marker in any comment text
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, comments_json, search_start, manifest_marker)) |pos| {
            // Find the end of this manifest line (either newline or end of string value)
            const after_marker = comments_json[pos + manifest_marker.len ..];

            // Extract the manifest content (until newline, quote, or end)
            var end_idx: usize = 0;
            while (end_idx < after_marker.len) : (end_idx += 1) {
                const c = after_marker[end_idx];
                if (c == '\n' or c == '"' or c == '\\') break;
            }

            const manifest_content = std.mem.trim(u8, after_marker[0..end_idx], " \t");

            // Parse the manifest content
            if (self.parseManifestLine(manifest_content)) |manifest| {
                return manifest;
            }

            search_start = pos + manifest_marker.len;
        }

        return null;
    }

    /// Parse manifest line: "primary=[file1,file2] read=[file3] forbidden=[file4]"
    fn parseManifestLine(self: *AgentLoop, line: []const u8) ?state_mod.Manifest {
        var primary_files = std.ArrayListUnmanaged([]const u8){};
        var read_files = std.ArrayListUnmanaged([]const u8){};
        var forbidden_files = std.ArrayListUnmanaged([]const u8){};

        errdefer {
            for (primary_files.items) |f| self.allocator.free(f);
            primary_files.deinit(self.allocator);
            for (read_files.items) |f| self.allocator.free(f);
            read_files.deinit(self.allocator);
            for (forbidden_files.items) |f| self.allocator.free(f);
            forbidden_files.deinit(self.allocator);
        }

        // Parse primary=[...]
        if (std.mem.indexOf(u8, line, "primary=[")) |start| {
            const bracket_start = start + "primary=[".len;
            if (std.mem.indexOfPos(u8, line, bracket_start, "]")) |bracket_end| {
                const files_str = line[bracket_start..bracket_end];
                var files = std.mem.splitScalar(u8, files_str, ',');
                while (files.next()) |file| {
                    const trimmed = std.mem.trim(u8, file, " \t");
                    if (trimmed.len > 0) {
                        primary_files.append(self.allocator, self.allocator.dupe(u8, trimmed) catch continue) catch continue;
                    }
                }
            }
        }

        // Parse read=[...]
        if (std.mem.indexOf(u8, line, "read=[")) |start| {
            const bracket_start = start + "read=[".len;
            if (std.mem.indexOfPos(u8, line, bracket_start, "]")) |bracket_end| {
                const files_str = line[bracket_start..bracket_end];
                var files = std.mem.splitScalar(u8, files_str, ',');
                while (files.next()) |file| {
                    const trimmed = std.mem.trim(u8, file, " \t");
                    if (trimmed.len > 0) {
                        read_files.append(self.allocator, self.allocator.dupe(u8, trimmed) catch continue) catch continue;
                    }
                }
            }
        }

        // Parse forbidden=[...]
        if (std.mem.indexOf(u8, line, "forbidden=[")) |start| {
            const bracket_start = start + "forbidden=[".len;
            if (std.mem.indexOfPos(u8, line, bracket_start, "]")) |bracket_end| {
                const files_str = line[bracket_start..bracket_end];
                var files = std.mem.splitScalar(u8, files_str, ',');
                while (files.next()) |file| {
                    const trimmed = std.mem.trim(u8, file, " \t");
                    if (trimmed.len > 0) {
                        forbidden_files.append(self.allocator, self.allocator.dupe(u8, trimmed) catch continue) catch continue;
                    }
                }
            }
        }

        // Only return manifest if we parsed at least some primary files
        if (primary_files.items.len == 0) {
            for (read_files.items) |f| self.allocator.free(f);
            read_files.deinit(self.allocator);
            for (forbidden_files.items) |f| self.allocator.free(f);
            forbidden_files.deinit(self.allocator);
            primary_files.deinit(self.allocator);
            return null;
        }

        return state_mod.Manifest{
            .primary_files = primary_files.toOwnedSlice(self.allocator) catch return null,
            .read_files = read_files.toOwnedSlice(self.allocator) catch return null,
            .forbidden_files = forbidden_files.toOwnedSlice(self.allocator) catch return null,
        };
    }

    /// Generate parallel batches from loaded manifests
    /// Groups non-conflicting issues into batches that can run in parallel
    /// Returns the number of batches created
    ///
    /// NOTE: This only considers "ready" issues (from `bd ready`) which are
    /// by definition unblocked - they have no pending dependencies. Therefore,
    /// we don't need to check dependencies between ready issues since `bd ready`
    /// already enforces dependency ordering by only returning unblocked issues.
    fn generateBatchesFromManifests(self: *AgentLoop) !u32 {
        var state = &(self.state orelse return 0);

        // Clear any existing pending batches
        state.clearPendingBatches();

        // Get list of ready issues with manifests
        // NOTE: `bd ready` returns only unblocked issues, so dependency ordering
        // is already enforced - we don't need to check dependencies between them.
        var ready_result = try process.shell(self.allocator, "bd ready --json 2>/dev/null | jq -r '.[].id'");
        defer ready_result.deinit();

        if (!ready_result.success() or ready_result.stdout.len == 0) {
            return 0;
        }

        // Collect ready issues that have manifests
        var ready_issues = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (ready_issues.items) |id| self.allocator.free(id);
            ready_issues.deinit(self.allocator);
        }

        var lines = std.mem.tokenizeScalar(u8, ready_result.stdout, '\n');
        while (lines.next()) |issue_id| {
            const trimmed_id = std.mem.trim(u8, issue_id, " \t\r");
            if (trimmed_id.len == 0) continue;

            // Only include issues that have manifests
            if (state.getManifest(trimmed_id) != null) {
                try ready_issues.append(self.allocator, try self.allocator.dupe(u8, trimmed_id));
            }
        }

        if (ready_issues.items.len == 0) {
            return 0;
        }

        // Greedy batch assignment algorithm:
        // For each unassigned issue, try to add it to the current batch
        // If it conflicts with any issue in current batch, start a new batch
        var assigned = try self.allocator.alloc(bool, ready_issues.items.len);
        defer self.allocator.free(assigned);
        @memset(assigned, false);

        var batches_created: u32 = 0;

        while (true) {
            // Start a new batch with unassigned issues
            var batch_issues = std.ArrayListUnmanaged([]const u8){};
            errdefer {
                for (batch_issues.items) |id| self.allocator.free(id);
                batch_issues.deinit(self.allocator);
            }

            for (ready_issues.items, 0..) |issue_id, i| {
                if (assigned[i]) continue;

                // Check if this issue conflicts with any issue already in the batch
                var conflicts = false;
                for (batch_issues.items) |batch_issue_id| {
                    if (state.issuesConflict(issue_id, batch_issue_id)) {
                        conflicts = true;
                        break;
                    }
                }

                if (!conflicts) {
                    // Add to current batch
                    try batch_issues.append(self.allocator, try self.allocator.dupe(u8, issue_id));
                    assigned[i] = true;
                }
            }

            // If no issues were added, we're done
            if (batch_issues.items.len == 0) {
                batch_issues.deinit(self.allocator);
                break;
            }

            // Create the batch
            const batch_size = batch_issues.items.len;
            const batch_id = try state.addBatch(try batch_issues.toOwnedSlice(self.allocator));
            batches_created += 1;

            // Log batch contents
            self.logInfo("  Batch {d}: {d} issue(s)", .{ batch_id, batch_size });

            // Check if all issues are assigned
            var all_assigned = true;
            for (assigned) |a| {
                if (!a) {
                    all_assigned = false;
                    break;
                }
            }
            if (all_assigned) break;
        }

        return batches_created;
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

        return std.fmt.allocPrint(self.allocator,
            \\You are the strategic planner for {s}.
            \\
            \\CONTEXT:
            \\The implementation agent failed to complete the following issue after multiple attempts.
            \\Your task is to break it down into smaller, more manageable sub-issues.
            \\
            \\FAILED ISSUE:
            \\ID: {s}
            \\Details: {s}
            \\
            \\BREAKDOWN INSTRUCTIONS:
            \\1. Analyze why this issue might be too complex for a single implementation pass
            \\2. Identify logical sub-tasks that can be completed independently
            \\3. Create 2-5 new issues using `bd create` that together accomplish the original goal
            \\4. Set appropriate dependencies between the new issues using `bd dep add`
            \\5. Update the original issue to depend on the new sub-issues (making it a tracking issue)
            \\
            \\COMMANDS:
            \\- bd create "title" -t task -p <priority> --description "..." --acceptance "..."
            \\- bd dep add <issue-id> <depends-on-id>   # first issue depends on second
            \\- bd update <issue-id> --status open      # reset status if needed
            \\- bd show <issue-id>                      # view issue details
            \\
            \\GUIDELINES:
            \\- Each sub-issue should be completable in a single agent session
            \\- Lower priority sub-issues should come first (foundations before features)
            \\- Include clear acceptance criteria for each sub-issue
            \\- The original issue ({s}) should remain open and depend on all sub-issues
            \\
            \\End with: BREAKDOWN_COMPLETE
        , .{ self.config.project_name, issue_id, issue_json, issue_id });
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

    /// Special exit code indicating agent timeout
    pub const EXIT_CODE_TIMEOUT: u8 = 124; // Same as GNU timeout

    /// Special exit code indicating manifest violation
    pub const EXIT_CODE_MANIFEST_VIOLATION: u8 = 125;

    /// Result of manifest compliance check
    pub const ManifestComplianceResult = struct {
        compliant: bool,
        unauthorized_files: []const []const u8 = &.{},
        forbidden_files_touched: []const []const u8 = &.{},

        pub fn deinit(self: *ManifestComplianceResult, allocator: std.mem.Allocator) void {
            for (self.unauthorized_files) |f| allocator.free(f);
            if (self.unauthorized_files.len > 0) allocator.free(self.unauthorized_files);
            for (self.forbidden_files_touched) |f| allocator.free(f);
            if (self.forbidden_files_touched.len > 0) allocator.free(self.forbidden_files_touched);
        }
    };

    /// Capture baseline of changed files before agent runs
    /// Returns list of file paths that were already modified or untracked
    fn captureChangedFilesBaseline(self: *AgentLoop) ![]const []const u8 {
        var baseline = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (baseline.items) |f| self.allocator.free(f);
            baseline.deinit(self.allocator);
        }

        // Helper to check if already in baseline
        const isInBaseline = struct {
            fn check(bl: []const []const u8, file: []const u8) bool {
                for (bl) |b| {
                    if (std.mem.eql(u8, b, file)) return true;
                }
                return false;
            }
        }.check;

        // Get unstaged changes
        var diff_result = try process.shell(self.allocator, "git diff --name-only HEAD");
        defer diff_result.deinit();

        if (diff_result.success()) {
            var lines = std.mem.tokenizeScalar(u8, diff_result.stdout, '\n');
            while (lines.next()) |file| {
                const trimmed = std.mem.trim(u8, file, " \t\r");
                if (trimmed.len > 0) {
                    try baseline.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                }
            }
        }

        // Get staged changes
        var staged_result = try process.shell(self.allocator, "git diff --name-only --cached");
        defer staged_result.deinit();

        if (staged_result.success()) {
            var lines = std.mem.tokenizeScalar(u8, staged_result.stdout, '\n');
            while (lines.next()) |file| {
                const trimmed = std.mem.trim(u8, file, " \t\r");
                if (trimmed.len == 0) continue;
                // Avoid duplicates
                if (!isInBaseline(baseline.items, trimmed)) {
                    try baseline.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                }
            }
        }

        // Get untracked files (so we can distinguish pre-existing from agent-created)
        var untracked_result = try process.shell(self.allocator, "git ls-files --others --exclude-standard");
        defer untracked_result.deinit();

        if (untracked_result.success()) {
            var lines = std.mem.tokenizeScalar(u8, untracked_result.stdout, '\n');
            while (lines.next()) |file| {
                const trimmed = std.mem.trim(u8, file, " \t\r");
                if (trimmed.len == 0) continue;
                // Avoid duplicates
                if (!isInBaseline(baseline.items, trimmed)) {
                    try baseline.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                }
            }
        }

        return try baseline.toOwnedSlice(self.allocator);
    }

    /// Free baseline file list
    fn freeBaseline(self: *AgentLoop, baseline: []const []const u8) void {
        for (baseline) |f| self.allocator.free(f);
        if (baseline.len > 0) self.allocator.free(baseline);
    }

    /// Verify that agent changes comply with the issue's manifest
    /// baseline contains files that were already modified before agent ran
    /// Returns compliance result with details of any violations
    fn verifyManifestCompliance(self: *AgentLoop, issue_id: []const u8, baseline: []const []const u8) !ManifestComplianceResult {
        // Get manifest for this issue
        const manifest = if (self.state) |*s| s.getManifest(issue_id) else null;

        // No manifest means no restrictions (legacy behavior)
        if (manifest == null) {
            return .{ .compliant = true };
        }
        const m = manifest.?;

        // Get list of changed files from git diff
        var diff_result = try process.shell(self.allocator, "git diff --name-only HEAD");
        defer diff_result.deinit();

        if (!diff_result.success()) {
            // If git diff fails, assume compliant (could be not in a git repo)
            self.logWarn("git diff failed, skipping manifest check", .{});
            return .{ .compliant = true };
        }

        // Also check staged changes
        var staged_result = try process.shell(self.allocator, "git diff --name-only --cached");
        defer staged_result.deinit();

        // Also check untracked files (new files created by agent)
        var untracked_result = try process.shell(self.allocator, "git ls-files --others --exclude-standard");
        defer untracked_result.deinit();

        // Parse changed files
        var unauthorized = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (unauthorized.items) |f| self.allocator.free(f);
            unauthorized.deinit(self.allocator);
        }

        var forbidden_touched = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (forbidden_touched.items) |f| self.allocator.free(f);
            forbidden_touched.deinit(self.allocator);
        }

        // Helper to check if file was in baseline (pre-existing change)
        const isInBaseline = struct {
            fn check(bl: []const []const u8, file: []const u8) bool {
                for (bl) |b| {
                    if (std.mem.eql(u8, b, file)) return true;
                }
                return false;
            }
        }.check;

        // Helper to check if file is already in violation lists
        const isInList = struct {
            fn check(list: []const []const u8, file: []const u8) bool {
                for (list) |f| {
                    if (std.mem.eql(u8, f, file)) return true;
                }
                return false;
            }
        }.check;

        // Check unstaged changes
        var lines = std.mem.tokenizeScalar(u8, diff_result.stdout, '\n');
        while (lines.next()) |file| {
            const trimmed = std.mem.trim(u8, file, " \t\r");
            if (trimmed.len == 0) continue;

            // Skip files that were already modified before agent ran
            if (isInBaseline(baseline, trimmed)) continue;

            // Check if file is forbidden
            if (m.isForbidden(trimmed)) {
                try forbidden_touched.append(self.allocator, try self.allocator.dupe(u8, trimmed));
            } else if (!m.allowsWrite(trimmed)) {
                // Check if file is outside allowed primary_files
                try unauthorized.append(self.allocator, try self.allocator.dupe(u8, trimmed));
            }
        }

        // Check staged changes
        var staged_lines = std.mem.tokenizeScalar(u8, staged_result.stdout, '\n');
        while (staged_lines.next()) |file| {
            const trimmed = std.mem.trim(u8, file, " \t\r");
            if (trimmed.len == 0) continue;

            // Skip files that were already modified before agent ran
            if (isInBaseline(baseline, trimmed)) continue;

            // Check if file is forbidden
            if (m.isForbidden(trimmed)) {
                // Avoid duplicates
                if (!isInList(forbidden_touched.items, trimmed)) {
                    try forbidden_touched.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                }
            } else if (!m.allowsWrite(trimmed)) {
                // Avoid duplicates
                if (!isInList(unauthorized.items, trimmed)) {
                    try unauthorized.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                }
            }
        }

        // Check untracked files (new files created by agent)
        if (untracked_result.success()) {
            var untracked_lines = std.mem.tokenizeScalar(u8, untracked_result.stdout, '\n');
            while (untracked_lines.next()) |file| {
                const trimmed = std.mem.trim(u8, file, " \t\r");
                if (trimmed.len == 0) continue;

                // Skip files that were already untracked before agent ran
                if (isInBaseline(baseline, trimmed)) continue;

                // Check if file is forbidden
                if (m.isForbidden(trimmed)) {
                    // Avoid duplicates
                    if (!isInList(forbidden_touched.items, trimmed)) {
                        try forbidden_touched.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                    }
                } else if (!m.allowsWrite(trimmed)) {
                    // Avoid duplicates
                    if (!isInList(unauthorized.items, trimmed)) {
                        try unauthorized.append(self.allocator, try self.allocator.dupe(u8, trimmed));
                    }
                }
            }
        }

        const has_violations = unauthorized.items.len > 0 or forbidden_touched.items.len > 0;

        return .{
            .compliant = !has_violations,
            .unauthorized_files = try unauthorized.toOwnedSlice(self.allocator),
            .forbidden_files_touched = try forbidden_touched.toOwnedSlice(self.allocator),
        };
    }

    /// Rollback only the files that the agent touched (not pre-existing changes)
    /// compliance_result contains the violating files to rollback
    fn rollbackViolatingFiles(self: *AgentLoop, compliance_result: ManifestComplianceResult) !void {
        self.logWarn("Rolling back violating files...", .{});

        var files_to_rollback = std.ArrayListUnmanaged([]const u8){};
        defer files_to_rollback.deinit(self.allocator);

        // Collect all files that need to be rolled back
        for (compliance_result.unauthorized_files) |f| {
            try files_to_rollback.append(self.allocator, f);
        }
        for (compliance_result.forbidden_files_touched) |f| {
            try files_to_rollback.append(self.allocator, f);
        }

        if (files_to_rollback.items.len == 0) {
            self.logInfo("No files to rollback", .{});
            return;
        }

        // Rollback each file individually
        for (files_to_rollback.items) |file| {
            // Unstage if staged
            const unstage_cmd = try std.fmt.allocPrint(self.allocator, "git reset HEAD -- \"{s}\"", .{file});
            defer self.allocator.free(unstage_cmd);
            var unstage_result = try process.shell(self.allocator, unstage_cmd);
            defer unstage_result.deinit();

            // Restore file to HEAD state (for tracked files)
            const checkout_cmd = try std.fmt.allocPrint(self.allocator, "git checkout HEAD -- \"{s}\" 2>/dev/null || true", .{file});
            defer self.allocator.free(checkout_cmd);
            var checkout_result = try process.shell(self.allocator, checkout_cmd);
            defer checkout_result.deinit();

            // For new untracked files, just remove them
            const rm_cmd = try std.fmt.allocPrint(self.allocator, "git clean -f -- \"{s}\" 2>/dev/null || true", .{file});
            defer self.allocator.free(rm_cmd);
            var rm_result = try process.shell(self.allocator, rm_cmd);
            defer rm_result.deinit();

            self.logInfo("  Rolled back: {s}", .{file});
        }

        self.logInfo("Rollback complete ({d} file(s))", .{files_to_rollback.items.len});
    }

    /// Build a stricter prompt after manifest violation
    fn buildStricterPrompt(self: *AgentLoop, issue_id: []const u8, violation_result: ManifestComplianceResult) ![]const u8 {
        const base_prompt = try self.buildImplementationPrompt(issue_id);
        defer self.allocator.free(base_prompt);

        // Build violation details
        var violation_details = std.ArrayListUnmanaged(u8){};
        defer violation_details.deinit(self.allocator);

        try violation_details.appendSlice(self.allocator,
            \\
            \\CRITICAL WARNING - PREVIOUS ATTEMPT VIOLATED FILE MANIFEST:
            \\Your previous attempt modified files outside the allowed scope. This is NOT allowed.
            \\
            \\
        );

        if (violation_result.forbidden_files_touched.len > 0) {
            try violation_details.appendSlice(self.allocator, "FORBIDDEN FILES TOUCHED (must NEVER modify):\n");
            for (violation_result.forbidden_files_touched) |f| {
                try violation_details.appendSlice(self.allocator, "  - ");
                try violation_details.appendSlice(self.allocator, f);
                try violation_details.appendSlice(self.allocator, "\n");
            }
        }

        if (violation_result.unauthorized_files.len > 0) {
            try violation_details.appendSlice(self.allocator, "UNAUTHORIZED FILES MODIFIED (not in primary_files):\n");
            for (violation_result.unauthorized_files) |f| {
                try violation_details.appendSlice(self.allocator, "  - ");
                try violation_details.appendSlice(self.allocator, f);
                try violation_details.appendSlice(self.allocator, "\n");
            }
        }

        try violation_details.appendSlice(self.allocator,
            \\
            \\You MUST only modify the files explicitly allowed in the manifest.
            \\Run `bd show <issue-id>` and check the MANIFEST comment for allowed files.
            \\If you need to modify additional files, explain why in a comment and stop.
            \\
            \\
        );

        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ violation_details.items, base_prompt });
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
            \\7. Create marker: `touch .noface/codex-approved`
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

        const sync_result = github.syncToGitHub(self.allocator, self.config.dry_run) catch |err| {
            self.logWarn("GitHub sync failed (non-fatal): {}", .{err});
            return;
        };

        if (sync_result.errors > 0 and sync_result.created == 0 and sync_result.closed == 0) {
            // Only errors, likely a prerequisite failure (gh not installed, not authenticated, etc.)
            self.logWarn("GitHub sync skipped (gh CLI not available or not in a GitHub repo)", .{});
        } else {
            self.logSuccess("GitHub sync: {d} created, {d} closed, {d} skipped", .{
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

        // Manifest violation (125) is handled specially in the main loop with stricter prompts
        // Don't retry via the generic retry mechanism
        if (exit_code == EXIT_CODE_MANIFEST_VIOLATION) return false;

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

test "should not retry on timeout" {
    // Timeout (exit code 124) should NOT be retried
    try std.testing.expect(!AgentLoop.shouldRetry(AgentLoop.EXIT_CODE_TIMEOUT));
}

test "should not retry on manifest violation" {
    // Manifest violation (exit code 125) should NOT be retried via generic retry
    // (it's handled specially with stricter prompts)
    try std.testing.expect(!AgentLoop.shouldRetry(AgentLoop.EXIT_CODE_MANIFEST_VIOLATION));
}

test "timeout exit code is 124" {
    // Verify timeout exit code matches GNU timeout convention
    try std.testing.expectEqual(@as(u8, 124), AgentLoop.EXIT_CODE_TIMEOUT);
}

test "manifest violation exit code is 125" {
    try std.testing.expectEqual(@as(u8, 125), AgentLoop.EXIT_CODE_MANIFEST_VIOLATION);
}

test "parse manifest line" {
    const cfg = Config.default();
    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    // Test valid manifest line
    const line = "primary=[src/loop.zig,src/state.zig] read=[src/config.zig] forbidden=[src/main.zig]";
    const manifest = loop.parseManifestLine(line);

    try std.testing.expect(manifest != null);

    const m = manifest.?;
    defer {
        for (m.primary_files) |f| std.testing.allocator.free(f);
        if (m.primary_files.len > 0) std.testing.allocator.free(m.primary_files);
        for (m.read_files) |f| std.testing.allocator.free(f);
        if (m.read_files.len > 0) std.testing.allocator.free(m.read_files);
        for (m.forbidden_files) |f| std.testing.allocator.free(f);
        if (m.forbidden_files.len > 0) std.testing.allocator.free(m.forbidden_files);
    }

    try std.testing.expectEqual(@as(usize, 2), m.primary_files.len);
    try std.testing.expectEqual(@as(usize, 1), m.read_files.len);
    try std.testing.expectEqual(@as(usize, 1), m.forbidden_files.len);

    try std.testing.expect(std.mem.eql(u8, m.primary_files[0], "src/loop.zig"));
    try std.testing.expect(std.mem.eql(u8, m.primary_files[1], "src/state.zig"));
    try std.testing.expect(std.mem.eql(u8, m.read_files[0], "src/config.zig"));
    try std.testing.expect(std.mem.eql(u8, m.forbidden_files[0], "src/main.zig"));
}

test "parse manifest line - no primary files returns null" {
    const cfg = Config.default();
    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    // Test line without primary files returns null
    const line = "read=[src/config.zig] forbidden=[src/main.zig]";
    const manifest = loop.parseManifestLine(line);
    try std.testing.expect(manifest == null);
}

test "parse manifest line - empty returns null" {
    const cfg = Config.default();
    var loop = AgentLoop.init(std.testing.allocator, cfg);
    defer loop.deinit();

    const manifest = loop.parseManifestLine("");
    try std.testing.expect(manifest == null);
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
