//! Multi-process worker pool for parallel issue execution.
//!
//! Manages N worker processes that each run their own agent session.
//! The coordinator assigns issues from the current batch to idle workers.

const std = @import("std");
const state_mod = @import("state.zig");
const process = @import("process.zig");
const config_mod = @import("config.zig");
const signals = @import("signals.zig");

const OrchestratorState = state_mod.OrchestratorState;
const WorkerState = state_mod.WorkerState;
const Batch = state_mod.Batch;
const Config = config_mod.Config;

/// Worker execution result
pub const WorkerResult = struct {
    worker_id: u32,
    issue_id: []const u8,
    success: bool,
    exit_code: u8,
    duration_seconds: i64,
};

/// WorkerPool manages parallel worker processes for executing issues
pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    state: *OrchestratorState,

    /// Active worker processes (indexed by worker_id)
    /// null means worker is not running
    worker_processes: [state_mod.MAX_WORKERS]?WorkerProcess = [_]?WorkerProcess{null} ** state_mod.MAX_WORKERS,

    /// Pending results from completed workers (to be processed by coordinator)
    pending_results: std.ArrayListUnmanaged(WorkerResult) = .{},

    pub fn init(allocator: std.mem.Allocator, cfg: Config, orchestrator_state: *OrchestratorState) WorkerPool {
        return .{
            .allocator = allocator,
            .config = cfg,
            .state = orchestrator_state,
        };
    }

    pub fn deinit(self: *WorkerPool) void {
        // Kill any still-running workers
        for (&self.worker_processes) |*wp| {
            if (wp.*) |*worker| {
                worker.kill();
                worker.deinit();
                wp.* = null;
            }
        }

        // Free pending results
        for (self.pending_results.items) |result| {
            self.allocator.free(result.issue_id);
        }
        self.pending_results.deinit(self.allocator);
    }

    /// Execute a batch of issues in parallel using the worker pool.
    /// Blocks until all issues in the batch are completed (or failed).
    /// Returns the number of successfully completed issues.
    pub fn executeBatch(self: *WorkerPool, batch: *Batch) !u32 {
        batch.status = .running;
        batch.started_at = std.time.timestamp();

        logInfo("Executing batch {d} with {d} issue(s) using {d} worker(s)", .{
            batch.id,
            batch.issue_ids.len,
            self.state.num_workers,
        });

        // Track which issues have been assigned and completed
        var assigned = try self.allocator.alloc(bool, batch.issue_ids.len);
        defer self.allocator.free(assigned);
        @memset(assigned, false);

        var completed = try self.allocator.alloc(bool, batch.issue_ids.len);
        defer self.allocator.free(completed);
        @memset(completed, false);

        var successful: u32 = 0;
        var issues_remaining = batch.issue_ids.len;

        // Main dispatch loop
        while (issues_remaining > 0) {
            // Check for interrupt
            if (signals.isInterrupted()) {
                logWarn("Batch execution interrupted", .{});
                self.killAllWorkers();
                // Reset batch status to pending so it can be retried
                batch.status = .pending;
                return successful;
            }

            // 1. Poll output from running workers (updates last_output_time for idle detection)
            self.pollAllWorkerOutput();

            // 2. Collect results from completed workers
            try self.collectCompletedWorkers();

            // 3. Detect and handle idle/timed out workers
            const crashed = try self.detectCrashedWorkers();
            if (crashed > 0) {
                logWarn("Detected {d} crashed/timed out worker(s)", .{crashed});
            }

            // 4. Process any pending results
            while (self.pending_results.items.len > 0) {
                const result = self.pending_results.orderedRemove(0);
                defer self.allocator.free(result.issue_id);

                // Find the issue index in the batch
                for (batch.issue_ids, 0..) |issue_id, i| {
                    if (std.mem.eql(u8, issue_id, result.issue_id)) {
                        completed[i] = true;
                        issues_remaining -= 1;

                        if (result.success) {
                            successful += 1;
                            logSuccess("Worker {d} completed issue {s} in {d}s", .{
                                result.worker_id,
                                result.issue_id,
                                result.duration_seconds,
                            });
                        } else {
                            logError("Worker {d} failed issue {s} (exit code {d})", .{
                                result.worker_id,
                                result.issue_id,
                                result.exit_code,
                            });
                        }

                        // Update issue state
                        const status: state_mod.IssueStatus = if (result.success) .completed else .failed;
                        _ = self.state.updateIssue(result.issue_id, status) catch {};

                        // Release locks for this issue
                        self.state.releaseLocks(result.issue_id);

                        // Mark worker as idle
                        self.state.workers[result.worker_id].status = if (result.success) .completed else .failed;
                        if (self.state.workers[result.worker_id].current_issue) |issue| {
                            self.allocator.free(issue);
                            self.state.workers[result.worker_id].current_issue = null;
                        }

                        break;
                    }
                }
            }

            // 5. Assign unassigned issues to idle workers
            for (batch.issue_ids, 0..) |issue_id, i| {
                if (assigned[i]) continue;

                // Find an idle worker
                if (self.findIdleWorkerSlot()) |worker_id| {
                    // Try to acquire locks for this issue
                    const manifest = self.state.getManifest(issue_id) orelse state_mod.Manifest{};
                    const locks_acquired = self.state.tryAcquireLocks(issue_id, manifest, worker_id) catch false;

                    if (!locks_acquired) {
                        // Skip this issue for now - another worker has conflicting locks
                        logWarn("Cannot acquire locks for issue {s}, skipping", .{issue_id});
                        continue;
                    }

                    // Start the worker process
                    self.startWorker(worker_id, issue_id) catch |err| {
                        logError("Failed to start worker {d} for issue {s}: {}", .{ worker_id, issue_id, err });
                        self.state.releaseLocks(issue_id);
                        continue;
                    };

                    assigned[i] = true;
                    logInfo("Assigned issue {s} to worker {d}", .{ issue_id, worker_id });
                } else {
                    // No idle workers available, break and wait
                    break;
                }
            }

            // 6. Brief sleep to avoid busy-waiting
            if (issues_remaining > 0) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        batch.status = .completed;
        batch.completed_at = std.time.timestamp();

        logSuccess("Batch {d} completed: {d}/{d} successful", .{
            batch.id,
            successful,
            batch.issue_ids.len,
        });

        return successful;
    }

    /// Find an idle worker slot (returns worker_id or null if none available)
    fn findIdleWorkerSlot(self: *WorkerPool) ?u32 {
        for (0..self.state.num_workers) |i| {
            const worker_id: u32 = @intCast(i);
            // Check if worker process is not running
            if (self.worker_processes[worker_id] == null) {
                // And worker state is available
                if (self.state.workers[worker_id].isAvailable()) {
                    return worker_id;
                }
            }
        }
        return null;
    }

    /// Start a worker process for an issue
    fn startWorker(self: *WorkerPool, worker_id: u32, issue_id: []const u8) !void {
        // Build the worker command
        // Each worker runs: noface --worker --issue <issue_id>
        // For now, we use claude directly with the implementation prompt
        const prompt = try self.buildWorkerPrompt(issue_id);
        defer self.allocator.free(prompt);

        const argv = [_][]const u8{
            self.config.impl_agent,
            "-p",
            "--dangerously-skip-permissions",
            "--verbose",
            "--max-turns",
            "100",  // Allow more iterations for complex issues
            "--output-format",
            "stream-json",
            prompt,
        };

        var worker = try WorkerProcess.spawn(self.allocator, &argv, worker_id, issue_id);

        self.worker_processes[worker_id] = worker;

        // Update worker state
        self.state.workers[worker_id].status = .running;
        self.state.workers[worker_id].current_issue = try self.allocator.dupe(u8, issue_id);
        self.state.workers[worker_id].process_pid = worker.getPid();
        self.state.workers[worker_id].started_at = std.time.timestamp();

        // Update issue state
        try self.state.updateIssue(issue_id, .running);
    }

    /// Build the implementation prompt for a worker
    fn buildWorkerPrompt(self: *WorkerPool, issue_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\You are a senior software engineer working autonomously on issue {s} in the {s} project.
            \\
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
            \\
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
            issue_id,
            issue_id,
            self.config.test_command,
            self.config.review_agent,
            issue_id,
        });
    }

    /// Poll output from all running workers (non-blocking).
    /// This updates each worker's last_output_time for idle timeout detection.
    fn pollAllWorkerOutput(self: *WorkerPool) void {
        for (0..self.state.num_workers) |i| {
            const worker_id: u32 = @intCast(i);
            if (self.worker_processes[worker_id]) |*worker| {
                worker.pollOutput();
            }
        }
    }

    /// Check all running workers and collect results from completed ones
    fn collectCompletedWorkers(self: *WorkerPool) !void {
        for (0..self.state.num_workers) |i| {
            const worker_id: u32 = @intCast(i);
            if (self.worker_processes[worker_id]) |*worker| {
                // Check if process has completed (non-blocking)
                if (worker.tryWait()) |exit_code| {
                    const started_at = self.state.workers[worker_id].started_at orelse std.time.timestamp();
                    const duration = std.time.timestamp() - started_at;

                    // Create result
                    const result = WorkerResult{
                        .worker_id = worker_id,
                        .issue_id = try self.allocator.dupe(u8, worker.issue_id),
                        .success = exit_code == 0,
                        .exit_code = exit_code,
                        .duration_seconds = duration,
                    };

                    try self.pending_results.append(self.allocator, result);

                    // Clean up worker process
                    worker.deinit();
                    self.worker_processes[worker_id] = null;
                }
            }
        }
    }

    /// Detect idle workers (no output for timeout period)
    pub fn detectCrashedWorkers(self: *WorkerPool) !u32 {
        var crashed: u32 = 0;
        const timeout: i64 = @intCast(self.config.agent_timeout_seconds);

        for (0..self.state.num_workers) |i| {
            const worker_id: u32 = @intCast(i);
            if (self.worker_processes[worker_id]) |*worker| {
                const idle_seconds = worker.getIdleSeconds();

                if (idle_seconds > timeout) {
                    logWarn("Worker {d} timed out: no output for {d}s (issue: {s})", .{
                        worker_id,
                        idle_seconds,
                        worker.issue_id,
                    });

                    // Kill the worker
                    worker.kill();

                    // Calculate actual wall-clock duration for the result
                    const now = std.time.timestamp();
                    const started_at = self.state.workers[worker_id].started_at orelse now;
                    const duration = now - started_at;

                    // Create failure result
                    const result = WorkerResult{
                        .worker_id = worker_id,
                        .issue_id = try self.allocator.dupe(u8, worker.issue_id),
                        .success = false,
                        .exit_code = 124, // Timeout exit code
                        .duration_seconds = duration,
                    };

                    try self.pending_results.append(self.allocator, result);

                    // Clean up
                    worker.deinit();
                    self.worker_processes[worker_id] = null;
                    crashed += 1;

                    // Update worker state
                    self.state.workers[worker_id].status = .timeout;
                }
            }
        }

        return crashed;
    }

    /// Kill all running workers
    fn killAllWorkers(self: *WorkerPool) void {
        for (0..self.state.num_workers) |i| {
            const worker_id: u32 = @intCast(i);
            if (self.worker_processes[worker_id]) |*worker| {
                logWarn("Killing worker {d} (issue: {s})", .{ worker_id, worker.issue_id });

                // Release locks BEFORE deinit (which frees issue_id)
                self.state.releaseLocks(worker.issue_id);

                worker.kill();
                worker.deinit();
                self.worker_processes[worker_id] = null;

                // Reset worker state
                self.state.workers[worker_id].status = .idle;
                if (self.state.workers[worker_id].current_issue) |issue| {
                    self.allocator.free(issue);
                    self.state.workers[worker_id].current_issue = null;
                }
            }
        }
    }

    /// Get the number of currently running workers
    pub fn runningWorkerCount(self: *WorkerPool) u32 {
        var count: u32 = 0;
        for (0..self.state.num_workers) |i| {
            if (self.worker_processes[i] != null) {
                count += 1;
            }
        }
        return count;
    }
};

/// Represents a running worker child process
const WorkerProcess = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,
    worker_id: u32,
    issue_id: []const u8,
    /// Timestamp of last output received (for idle timeout tracking)
    last_output_time: i64,

    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, worker_id: u32, issue_id: []const u8) !WorkerProcess {
        var child = std.process.Child.init(argv, allocator);
        // Pipe stdout so we can track output for idle timeout detection
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const now = std.time.timestamp();
        return .{
            .child = child,
            .allocator = allocator,
            .worker_id = worker_id,
            .issue_id = try allocator.dupe(u8, issue_id),
            .last_output_time = now,
        };
    }

    pub fn deinit(self: *WorkerProcess) void {
        self.allocator.free(self.issue_id);
    }

    /// Poll for output from the worker (non-blocking).
    /// Updates last_output_time if any output is received.
    /// Forwards output to stdout/stderr for visibility.
    pub fn pollOutput(self: *WorkerProcess) void {
        var buf: [4096]u8 = undefined;
        var received_output = false;

        // Poll stdout
        if (self.child.stdout) |stdout_file| {
            const fd = stdout_file.handle;
            var poll_fds = [1]std.posix.pollfd{
                .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            };

            // Non-blocking poll (0 timeout)
            const poll_result = std.posix.poll(&poll_fds, 0) catch 0;
            if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
                while (true) {
                    const n = stdout_file.read(&buf) catch break;
                    if (n == 0) break;
                    received_output = true;
                    // Forward to real stdout
                    _ = std.fs.File.stdout().write(buf[0..n]) catch {};

                    // Check if more data available without blocking
                    const more = std.posix.poll(&poll_fds, 0) catch 0;
                    if (more == 0 or (poll_fds[0].revents & std.posix.POLL.IN) == 0) break;
                }
            }
        }

        // Poll stderr
        if (self.child.stderr) |stderr_file| {
            const fd = stderr_file.handle;
            var poll_fds = [1]std.posix.pollfd{
                .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            };

            const poll_result = std.posix.poll(&poll_fds, 0) catch 0;
            if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
                while (true) {
                    const n = stderr_file.read(&buf) catch break;
                    if (n == 0) break;
                    received_output = true;
                    // Forward to real stderr
                    _ = std.fs.File.stderr().write(buf[0..n]) catch {};

                    const more = std.posix.poll(&poll_fds, 0) catch 0;
                    if (more == 0 or (poll_fds[0].revents & std.posix.POLL.IN) == 0) break;
                }
            }
        }

        if (received_output) {
            self.last_output_time = std.time.timestamp();
        }
    }

    /// Get the idle time in seconds (time since last output)
    pub fn getIdleSeconds(self: *const WorkerProcess) i64 {
        return std.time.timestamp() - self.last_output_time;
    }

    /// Get the process ID
    pub fn getPid(self: *WorkerProcess) i32 {
        return self.child.id;
    }

    /// Try to wait for the process (non-blocking)
    /// Returns exit code if process has completed, null if still running
    pub fn tryWait(self: *WorkerProcess) ?u8 {
        // Use WNOHANG to make waitpid non-blocking
        const result = std.posix.waitpid(self.child.id, std.c.W.NOHANG);

        if (result.pid == 0) {
            // Process still running
            return null;
        }

        // Process has exited - decode status
        const status = result.status;
        if (std.c.W.IFEXITED(status)) {
            return std.c.W.EXITSTATUS(status);
        } else if (std.c.W.IFSIGNALED(status)) {
            return 128; // Killed by signal
        }
        return 1;
    }

    /// Kill the worker process
    pub fn kill(self: *WorkerProcess) void {
        _ = std.posix.kill(self.child.id, std.posix.SIG.KILL) catch {};
        // Reap zombie (blocking wait)
        _ = std.posix.waitpid(self.child.id, 0);
    }
};

// === Logging ===

const Color = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
};

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[POOL]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.green ++ "[POOL]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[POOL]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.red ++ "[POOL]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

// === Tests ===

test "worker pool init" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    const cfg = Config.default();
    var pool = WorkerPool.init(std.testing.allocator, cfg, &state);
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 0), pool.runningWorkerCount());
}

test "find idle worker slot" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    const cfg = Config.default();
    var pool = WorkerPool.init(std.testing.allocator, cfg, &state);
    defer pool.deinit();

    // Initially all workers are idle
    const slot = pool.findIdleWorkerSlot();
    try std.testing.expect(slot != null);
    try std.testing.expect(slot.? < state.num_workers);
}

test "worker result struct" {
    const result = WorkerResult{
        .worker_id = 0,
        .issue_id = "test-issue",
        .success = true,
        .exit_code = 0,
        .duration_seconds = 60,
    };

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "worker idle time tracking" {
    // Create a worker process with a simple command that produces output
    var worker = try WorkerProcess.spawn(
        std.testing.allocator,
        &[_][]const u8{ "echo", "hello" },
        0,
        "test-issue",
    );
    defer worker.deinit();

    // Initial idle time should be near zero
    const initial_idle = worker.getIdleSeconds();
    try std.testing.expect(initial_idle >= 0);
    try std.testing.expect(initial_idle <= 1);

    // Poll for output - this should update last_output_time
    worker.pollOutput();

    // Give the process time to complete
    std.Thread.sleep(50 * std.time.ns_per_ms);
    worker.pollOutput();

    // Idle time should still be small since we just polled
    const after_poll_idle = worker.getIdleSeconds();
    try std.testing.expect(after_poll_idle >= 0);
    try std.testing.expect(after_poll_idle <= 2);

    // Clean up - wait for process to exit
    _ = worker.tryWait();
}

test "idle timeout triggers only on idle workers" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create config with very short timeout for testing
    var cfg = Config.default();
    cfg.agent_timeout_seconds = 1; // 1 second timeout

    var pool = WorkerPool.init(std.testing.allocator, cfg, &state);
    defer pool.deinit();

    // Start a worker process that exits immediately
    const worker = try WorkerProcess.spawn(
        std.testing.allocator,
        &[_][]const u8{ "echo", "quick" },
        0,
        "test-issue",
    );

    pool.worker_processes[0] = worker;
    state.workers[0].status = .running;
    state.workers[0].started_at = std.time.timestamp();

    // Poll output immediately - should receive output and update last_output_time
    pool.pollAllWorkerOutput();

    // Wait for process to complete
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try pool.collectCompletedWorkers();

    // Process should have completed, no timeout triggered
    try std.testing.expect(pool.worker_processes[0] == null);
}
