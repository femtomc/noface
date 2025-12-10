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
const transcript_mod = @import("transcript.zig");

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

    /// Workers waiting to be resumed (blocked on files held by other workers)
    /// Maps worker_id to the issue they were working on
    waiting_workers: std.AutoHashMapUnmanaged(u32, WaitingWorker) = .{},

    /// Transcript database for logging worker sessions
    transcript_db: ?transcript_mod.TranscriptDb = null,

    /// Info about a waiting worker
    const WaitingWorker = struct {
        issue_id: []const u8,
        blocked_on_file: []const u8,
        wait_started: i64,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config, orchestrator_state: *OrchestratorState) WorkerPool {
        // Try to open transcript database (non-fatal if it fails)
        const transcript_db = transcript_mod.TranscriptDb.open(allocator) catch |err| blk: {
            logWarn("Failed to open transcript DB: {}, worker sessions will not be logged", .{err});
            break :blk null;
        };

        return .{
            .allocator = allocator,
            .config = cfg,
            .state = orchestrator_state,
            .transcript_db = transcript_db,
        };
    }

    pub fn deinit(self: *WorkerPool) void {
        // Close transcript database
        if (self.transcript_db) |*db| {
            db.close();
        }

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

        // Free waiting workers
        var it = self.waiting_workers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.issue_id);
            self.allocator.free(entry.value_ptr.blocked_on_file);
        }
        self.waiting_workers.deinit(self.allocator);
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

            // 2. Check for workers that have signaled they're blocked on a file
            try self.checkForBlockedWorkers();

            // 3. Collect results from completed workers
            try self.collectCompletedWorkers();

            // 4. Detect and handle idle/timed out workers
            const crashed = try self.detectCrashedWorkers();
            if (crashed > 0) {
                logWarn("Detected {d} crashed/timed out worker(s)", .{crashed});
            }

            // 5. Process any pending results
            var locks_released = false;
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
                        locks_released = true;

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

            // 6. If locks were released, try to wake up waiting workers
            if (locks_released) {
                const woken = try self.wakeUnblockedWorkers();
                if (woken > 0) {
                    logInfo("Woke {d} waiting worker(s)", .{woken});
                }
            }

            // 7. Assign unassigned issues to idle workers
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

            // 8. Brief sleep to avoid busy-waiting
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
    /// If `resuming` is true, the worker was previously blocked and is being restarted
    fn startWorker(self: *WorkerPool, worker_id: u32, issue_id: []const u8) !void {
        try self.startWorkerWithResume(worker_id, issue_id, false);
    }

    /// Start a worker process, optionally as a resume from a blocked state
    fn startWorkerWithResume(self: *WorkerPool, worker_id: u32, issue_id: []const u8, resuming: bool) !void {
        // Build the worker command
        // Each worker runs: noface --worker --issue <issue_id>
        // For now, we use claude directly with the implementation prompt
        const prompt = try self.buildWorkerPrompt(issue_id, resuming);
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

        // Start transcript session for this worker
        if (self.transcript_db) |*db| {
            worker.transcript_db = db;
            if (db.startSession(issue_id, worker_id, resuming)) |session_id| {
                worker.transcript_session_id = session_id;
            } else |_| {}
        }

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
    fn buildWorkerPrompt(self: *WorkerPool, issue_id: []const u8, resuming: bool) ![]const u8 {
        // Get manifest for this issue to include in prompt
        const manifest = self.state.getManifest(issue_id);

        // Build the list of files this worker owns
        var owned_files_buf: [4096]u8 = undefined;
        var owned_files_len: usize = 0;

        if (manifest) |m| {
            for (m.primary_files) |file| {
                if (owned_files_len > 0) {
                    if (owned_files_len + 2 < owned_files_buf.len) {
                        owned_files_buf[owned_files_len] = ',';
                        owned_files_buf[owned_files_len + 1] = ' ';
                        owned_files_len += 2;
                    }
                }
                const to_copy = @min(file.len, owned_files_buf.len - owned_files_len);
                @memcpy(owned_files_buf[owned_files_len..][0..to_copy], file[0..to_copy]);
                owned_files_len += to_copy;
            }
        }

        const owned_files = if (owned_files_len > 0)
            owned_files_buf[0..owned_files_len]
        else
            "(no manifest - you may modify any file)";

        // Add resume context if this worker was previously blocked
        const resume_context = if (resuming)
            \\
            \\IMPORTANT - RESUMING PREVIOUS WORK:
            \\You were previously working on this issue but got blocked because another engineer
            \\was modifying a file you needed. That work is now complete.
            \\
            \\Before starting fresh, CHECK YOUR PROGRESS:
            \\1. Run `git status` and `git diff` to see what changes already exist
            \\2. If you already made changes, DON'T redo them - continue from where you left off
            \\3. If tests were failing due to another file, try running them again now
            \\
        else
            "";

        return std.fmt.allocPrint(self.allocator,
            \\You are a senior software engineer working autonomously on issue {s} in the {s} project.
            \\
            \\MANIFEST - FILES YOU OWN:
            \\{s}
            \\
            \\You are working in PARALLEL with other engineers on different issues.
            \\Other engineers may be modifying other files at the same time.
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
            \\   - If tests fail, check WHY they fail (see PARALLEL WORK CONFLICTS below)
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
            \\
            \\PARALLEL WORK CONFLICTS:
            \\If build or tests fail with errors in files YOU DON'T OWN (not in your manifest above):
            \\1. Check if the error is in a file you modified - if so, fix it
            \\2. If the error is in a file you did NOT modify and is NOT in your manifest:
            \\   - Another engineer is likely modifying that file right now
            \\   - Output: BLOCKED_BY_FILE: <path/to/file.zig>
            \\   - The orchestrator will pause you and wake you when the file is available
            \\   - Example: if you see "error: src/foo.zig:42: ..." and src/foo.zig is not yours,
            \\     output "BLOCKED_BY_FILE: src/foo.zig"
            \\
            \\QUALITY STANDARDS:
            \\- Code should be clear enough to not need comments explaining *what* it does
            \\- Error messages should help users understand what went wrong
            \\- No hardcoded values that should be configurable
            \\- Handle edge cases explicitly, don't rely on "it probably won't happen"
            \\
            \\CONSTRAINTS:
            \\- Do NOT commit until review explicitly approves
            \\- Do NOT modify files outside your manifest (listed above)
            \\- Do NOT add dependencies without clear justification
            \\
            \\When finished, output: ISSUE_COMPLETE
            \\If blocked by another engineer's file, output: BLOCKED_BY_FILE: <path>
            \\If blocked for other reasons, output: BLOCKED: <reason>
        , .{
            issue_id,
            self.config.project_name,
            owned_files,
            resume_context,
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

    /// Check all running workers for BLOCKED_BY_FILE signals and mark them as waiting
    fn checkForBlockedWorkers(self: *WorkerPool) !void {
        for (0..self.state.num_workers) |i| {
            const worker_id: u32 = @intCast(i);
            if (self.worker_processes[worker_id]) |*worker| {
                if (worker.isBlocked()) {
                    const blocked_file = worker.getBlockedFile() orelse continue;

                    // Check if the file is actually locked by another worker
                    const issue_id = self.state.workers[worker_id].current_issue orelse continue;
                    if (self.isFileLockedByOther(blocked_file, issue_id)) {
                        logInfo("Worker {d} blocked on file {s} (locked by another worker)", .{
                            worker_id,
                            blocked_file,
                        });
                        try self.markWorkerWaiting(worker_id, blocked_file);
                    } else {
                        // File is not locked by another worker - the error might be something else
                        // Let the worker continue and handle it
                        logWarn("Worker {d} reported blocked on {s}, but file is not locked - ignoring", .{
                            worker_id,
                            blocked_file,
                        });
                        // Clear the blocked flag so it doesn't keep triggering
                        if (worker.blocked_on_file) |file| {
                            self.allocator.free(file);
                            worker.blocked_on_file = null;
                        }
                    }
                }
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

                    // Complete transcript session before cleanup
                    if (self.transcript_db) |*db| {
                        if (worker.transcript_session_id) |session_id| {
                            db.completeSession(session_id, exit_code) catch {};
                        }
                    }

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

                    // Complete transcript session before cleanup
                    if (self.transcript_db) |*db| {
                        if (worker.transcript_session_id) |session_id| {
                            db.completeSession(session_id, 124) catch {}; // timeout exit code
                        }
                    }

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

    /// Mark a worker as waiting on a file blocked by another worker.
    /// The worker process is killed and will be restarted when the file is unlocked.
    pub fn markWorkerWaiting(self: *WorkerPool, worker_id: u32, blocked_file: []const u8) !void {
        const worker_state = &self.state.workers[worker_id];
        const issue_id = worker_state.current_issue orelse return;

        logInfo("Worker {d} waiting on file {s} (issue: {s})", .{ worker_id, blocked_file, issue_id });

        // Kill the worker process (it will be restarted when unblocked)
        if (self.worker_processes[worker_id]) |*worker| {
            worker.kill();
            worker.deinit();
            self.worker_processes[worker_id] = null;
        }

        // Store waiting worker info
        const owned_issue = try self.allocator.dupe(u8, issue_id);
        errdefer self.allocator.free(owned_issue);
        const owned_file = try self.allocator.dupe(u8, blocked_file);
        errdefer self.allocator.free(owned_file);

        try self.waiting_workers.put(self.allocator, worker_id, .{
            .issue_id = owned_issue,
            .blocked_on_file = owned_file,
            .wait_started = std.time.timestamp(),
        });

        // Update worker state
        worker_state.status = .waiting;
        worker_state.blocked_on_file = try self.allocator.dupe(u8, blocked_file);
    }

    /// Check if any waiting workers can be woken up (their blocked file is now unlocked).
    /// Returns the number of workers that were woken.
    pub fn wakeUnblockedWorkers(self: *WorkerPool) !u32 {
        var woken: u32 = 0;
        var to_wake = std.ArrayListUnmanaged(u32){};
        defer to_wake.deinit(self.allocator);

        // Find workers whose blocked file is no longer locked
        var it = self.waiting_workers.iterator();
        while (it.next()) |entry| {
            const worker_id = entry.key_ptr.*;
            const waiting = entry.value_ptr.*;

            // Check if the file is still locked by another issue
            if (self.state.locks.get(waiting.blocked_on_file)) |lock| {
                // Still locked - check if it's by a different issue than ours
                const our_issue = self.state.workers[worker_id].current_issue orelse continue;
                if (!std.mem.eql(u8, lock.issue_id, our_issue)) {
                    // Still blocked by another worker
                    continue;
                }
            }

            // File is unlocked (or locked by us) - wake this worker
            try to_wake.append(self.allocator, worker_id);
        }

        // Wake the workers
        for (to_wake.items) |worker_id| {
            if (self.waiting_workers.fetchRemove(worker_id)) |kv| {
                const waiting = kv.value;
                logInfo("Waking worker {d} - file {s} is now available", .{ worker_id, waiting.blocked_on_file });

                // Restart the worker with resume context
                self.startWorkerWithResume(worker_id, waiting.issue_id, true) catch |err| {
                    logError("Failed to restart worker {d}: {}", .{ worker_id, err });
                    // Put it back in waiting state
                    try self.waiting_workers.put(self.allocator, worker_id, waiting);
                    continue;
                };

                // Free the waiting info
                self.allocator.free(waiting.issue_id);
                self.allocator.free(waiting.blocked_on_file);

                // Clear blocked_on_file from worker state
                if (self.state.workers[worker_id].blocked_on_file) |file| {
                    self.allocator.free(file);
                    self.state.workers[worker_id].blocked_on_file = null;
                }

                woken += 1;
            }
        }

        return woken;
    }

    /// Check if a file path is currently locked by a worker other than the given issue
    pub fn isFileLockedByOther(self: *WorkerPool, file_path: []const u8, our_issue_id: []const u8) bool {
        if (self.state.locks.get(file_path)) |lock| {
            return !std.mem.eql(u8, lock.issue_id, our_issue_id);
        }
        return false;
    }

    /// Get the count of waiting workers
    pub fn waitingWorkerCount(self: *WorkerPool) u32 {
        return @intCast(self.waiting_workers.count());
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
    /// Buffer for detecting BLOCKED_BY_FILE signals in output
    output_buffer: std.ArrayListUnmanaged(u8) = .{},
    /// File that this worker is blocked on (if detected)
    blocked_on_file: ?[]const u8 = null,
    /// Line buffer for JSON parsing (accumulates until newline)
    line_buffer: std.ArrayListUnmanaged(u8) = .{},
    /// Last displayed status (to avoid duplicate messages)
    last_status: ?[]const u8 = null,
    /// Transcript session ID for this worker
    transcript_session_id: ?[]const u8 = null,
    /// Event sequence number for transcript logging
    event_seq: u32 = 0,
    /// Pointer to transcript database (owned by WorkerPool)
    transcript_db: ?*transcript_mod.TranscriptDb = null,

    const BLOCKED_SIGNAL = "BLOCKED_BY_FILE:";

    /// Worker colors for terminal output (cycle through these)
    const worker_colors = [_][]const u8{
        "\x1b[0;36m", // Cyan
        "\x1b[0;35m", // Magenta
        "\x1b[0;33m", // Yellow
        "\x1b[0;32m", // Green
        "\x1b[0;34m", // Blue
        "\x1b[0;31m", // Red
        "\x1b[0;96m", // Bright Cyan
        "\x1b[0;95m", // Bright Magenta
    };
    const reset_color = "\x1b[0m";

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
        self.output_buffer.deinit(self.allocator);
        self.line_buffer.deinit(self.allocator);
        if (self.blocked_on_file) |file| {
            self.allocator.free(file);
        }
        if (self.last_status) |status| {
            self.allocator.free(status);
        }
        if (self.transcript_session_id) |session_id| {
            self.allocator.free(session_id);
        }
    }

    /// Poll for output from the worker (non-blocking).
    /// Updates last_output_time if any output is received.
    /// Parses streaming JSON and displays formatted status summaries.
    /// Also scans for BLOCKED_BY_FILE: signals.
    pub fn pollOutput(self: *WorkerProcess) void {
        const is_test = @import("builtin").is_test;
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

                    // Add to line buffer and process complete lines
                    self.line_buffer.appendSlice(self.allocator, buf[0..n]) catch {};
                    if (!is_test) {
                        self.processLineBuffer();
                    }

                    // Also keep in output_buffer for BLOCKED_BY_FILE detection
                    self.output_buffer.appendSlice(self.allocator, buf[0..n]) catch {};

                    // Check if more data available without blocking
                    const more = std.posix.poll(&poll_fds, 0) catch 0;
                    if (more == 0 or (poll_fds[0].revents & std.posix.POLL.IN) == 0) break;
                }
            }
        }

        // Poll stderr (still forward stderr for error visibility)
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

                    // Add to line buffer for processing
                    self.line_buffer.appendSlice(self.allocator, buf[0..n]) catch {};
                    if (!is_test) {
                        self.processLineBuffer();
                    }

                    // Also keep in output_buffer for BLOCKED_BY_FILE detection
                    self.output_buffer.appendSlice(self.allocator, buf[0..n]) catch {};

                    const more = std.posix.poll(&poll_fds, 0) catch 0;
                    if (more == 0 or (poll_fds[0].revents & std.posix.POLL.IN) == 0) break;
                }
            }
        }

        if (received_output) {
            self.last_output_time = std.time.timestamp();
            // Check for BLOCKED_BY_FILE signal
            self.checkForBlockedSignal();
            // Keep buffer from growing unbounded (keep last 8KB)
            if (self.output_buffer.items.len > 8192) {
                const keep_from = self.output_buffer.items.len - 4096;
                std.mem.copyForwards(u8, self.output_buffer.items[0..4096], self.output_buffer.items[keep_from..]);
                self.output_buffer.shrinkRetainingCapacity(4096);
            }
        }
    }

    /// Process the line buffer, extracting complete lines and parsing them
    fn processLineBuffer(self: *WorkerProcess) void {
        while (true) {
            // Find newline in buffer
            const newline_pos = std.mem.indexOf(u8, self.line_buffer.items, "\n") orelse break;

            // Extract the line (without newline)
            const line = self.line_buffer.items[0..newline_pos];

            // Log to transcript DB if available
            if (self.transcript_db) |db| {
                if (self.transcript_session_id) |session_id| {
                    // Extract event type and tool name for indexing
                    const event_type = self.extractEventType(line);
                    const tool_name = self.extractToolName(line);

                    db.logEvent(
                        session_id,
                        self.event_seq,
                        event_type,
                        tool_name,
                        null, // content - not extracting for now
                        line,
                    ) catch {};
                    self.event_seq += 1;
                }
            }

            // Try to parse and display status
            self.parseAndDisplayStatus(line);

            // Remove processed line from buffer (including newline)
            const remaining = self.line_buffer.items[newline_pos + 1 ..];
            std.mem.copyForwards(u8, self.line_buffer.items[0..remaining.len], remaining);
            self.line_buffer.shrinkRetainingCapacity(remaining.len);
        }

        // Keep line buffer from growing too large (truncate if needed)
        if (self.line_buffer.items.len > 16384) {
            self.line_buffer.shrinkRetainingCapacity(0);
        }
    }

    /// Parse a JSON line and display a formatted status message
    fn parseAndDisplayStatus(self: *WorkerProcess, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;

        // Try to extract status from JSON
        const status = self.extractStatusFromJson(trimmed) orelse return;

        // Don't display duplicate statuses
        if (self.last_status) |last| {
            if (std.mem.eql(u8, last, status)) {
                return;
            }
            self.allocator.free(last);
        }
        self.last_status = self.allocator.dupe(u8, status) catch null;

        // Display with worker color and prefix
        self.displayStatus(status);
    }

    /// Extract a human-readable status from a JSON line
    fn extractStatusFromJson(self: *WorkerProcess, json: []const u8) ?[]const u8 {
        _ = self;

        // Quick checks for JSON object
        if (json.len < 2 or json[0] != '{') return null;

        // Look for tool_use events (most interesting for status)
        if (std.mem.indexOf(u8, json, "\"tool_use\"")) |_| {
            // Try to extract tool name
            if (extractJsonString(json, "\"name\"")) |tool_name| {
                // Try to extract relevant parameter based on tool
                if (std.mem.eql(u8, tool_name, "Read")) {
                    if (extractNestedJsonString(json, "\"input\"", "\"file_path\"")) |path| {
                        return formatToolStatus("Reading", path);
                    }
                    return "Reading file...";
                } else if (std.mem.eql(u8, tool_name, "Edit")) {
                    if (extractNestedJsonString(json, "\"input\"", "\"file_path\"")) |path| {
                        return formatToolStatus("Editing", path);
                    }
                    return "Editing file...";
                } else if (std.mem.eql(u8, tool_name, "Write")) {
                    if (extractNestedJsonString(json, "\"input\"", "\"file_path\"")) |path| {
                        return formatToolStatus("Writing", path);
                    }
                    return "Writing file...";
                } else if (std.mem.eql(u8, tool_name, "Bash")) {
                    if (extractNestedJsonString(json, "\"input\"", "\"command\"")) |cmd| {
                        // Truncate long commands
                        const max_len = 60;
                        if (cmd.len > max_len) {
                            return formatToolStatus("Running", cmd[0..max_len]);
                        }
                        return formatToolStatus("Running", cmd);
                    }
                    return "Running command...";
                } else if (std.mem.eql(u8, tool_name, "Grep")) {
                    if (extractNestedJsonString(json, "\"input\"", "\"pattern\"")) |pattern| {
                        return formatToolStatus("Searching", pattern);
                    }
                    return "Searching...";
                } else if (std.mem.eql(u8, tool_name, "Glob")) {
                    if (extractNestedJsonString(json, "\"input\"", "\"pattern\"")) |pattern| {
                        return formatToolStatus("Finding files", pattern);
                    }
                    return "Finding files...";
                } else {
                    return formatToolStatus("Using", tool_name);
                }
            }
        }

        // Look for content/text being generated (assistant typing)
        if (std.mem.indexOf(u8, json, "\"content_block_start\"")) |_| {
            if (std.mem.indexOf(u8, json, "\"text\"")) |_| {
                return "Thinking...";
            }
        }

        // Look for message completion
        if (std.mem.indexOf(u8, json, "\"message_stop\"")) |_| {
            return "Processing complete";
        }

        // Look for errors
        if (std.mem.indexOf(u8, json, "\"error\"")) |_| {
            if (extractJsonString(json, "\"message\"")) |msg| {
                return formatToolStatus("Error", msg);
            }
            return "Error occurred";
        }

        return null;
    }

    /// Display a status message with worker prefix and color
    fn displayStatus(self: *WorkerProcess, status: []const u8) void {
        const color = worker_colors[self.worker_id % worker_colors.len];

        // Truncate issue_id for display
        const max_issue_len = 12;
        const display_issue = if (self.issue_id.len > max_issue_len)
            self.issue_id[0..max_issue_len]
        else
            self.issue_id;

        std.debug.print("{s}[W{d}:{s}]{s} {s}\n", .{
            color,
            self.worker_id,
            display_issue,
            reset_color,
            status,
        });
    }

    /// Extract event type from JSON line for transcript logging
    fn extractEventType(self: *WorkerProcess, json: []const u8) ?[]const u8 {
        _ = self;
        if (json.len < 2 or json[0] != '{') return null;

        // Look for common event types
        if (std.mem.indexOf(u8, json, "\"tool_use\"")) |_| return "tool_use";
        if (std.mem.indexOf(u8, json, "\"content_block_start\"")) |_| return "content_block_start";
        if (std.mem.indexOf(u8, json, "\"content_block_delta\"")) |_| return "content_block_delta";
        if (std.mem.indexOf(u8, json, "\"content_block_stop\"")) |_| return "content_block_stop";
        if (std.mem.indexOf(u8, json, "\"message_start\"")) |_| return "message_start";
        if (std.mem.indexOf(u8, json, "\"message_stop\"")) |_| return "message_stop";
        if (std.mem.indexOf(u8, json, "\"error\"")) |_| return "error";

        return null;
    }

    /// Extract tool name from JSON line for transcript logging
    fn extractToolName(self: *WorkerProcess, json: []const u8) ?[]const u8 {
        _ = self;
        if (json.len < 2 or json[0] != '{') return null;

        // Only for tool_use events
        if (std.mem.indexOf(u8, json, "\"tool_use\"") == null) return null;

        return extractJsonString(json, "\"name\"");
    }

    /// Check output buffer for BLOCKED_BY_FILE: signal
    fn checkForBlockedSignal(self: *WorkerProcess) void {
        if (self.blocked_on_file != null) return; // Already detected

        const output = self.output_buffer.items;
        if (std.mem.indexOf(u8, output, BLOCKED_SIGNAL)) |pos| {
            // Found the signal - extract the file path
            const after_signal = output[pos + BLOCKED_SIGNAL.len ..];
            // Skip whitespace
            var start: usize = 0;
            while (start < after_signal.len and (after_signal[start] == ' ' or after_signal[start] == '\t')) {
                start += 1;
            }
            // Find end of file path (newline or end of buffer)
            var end = start;
            while (end < after_signal.len and after_signal[end] != '\n' and after_signal[end] != '\r') {
                end += 1;
            }
            if (end > start) {
                const file_path = std.mem.trim(u8, after_signal[start..end], " \t\r\n");
                if (file_path.len > 0) {
                    self.blocked_on_file = self.allocator.dupe(u8, file_path) catch null;
                }
            }
        }
    }

    /// Check if this worker has signaled it's blocked on a file
    pub fn isBlocked(self: *const WorkerProcess) bool {
        return self.blocked_on_file != null;
    }

    /// Get the file this worker is blocked on (if any)
    pub fn getBlockedFile(self: *const WorkerProcess) ?[]const u8 {
        return self.blocked_on_file;
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

// === JSON Helpers for Status Extraction ===

/// Simple JSON string value extraction (finds "key": "value" and returns value)
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip : and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t')) {
        i += 1;
    }
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // Skip opening quote

    // Find closing quote
    const start = i;
    while (i < after_key.len and after_key[i] != '"') {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 2; // Skip escaped char
        } else {
            i += 1;
        }
    }
    if (i >= after_key.len) return null;

    return after_key[start..i];
}

/// Extract a string from a nested JSON object (finds outer key, then inner key)
fn extractNestedJsonString(json: []const u8, outer_key: []const u8, inner_key: []const u8) ?[]const u8 {
    const outer_pos = std.mem.indexOf(u8, json, outer_key) orelse return null;
    const inner_json = json[outer_pos..];
    return extractJsonString(inner_json, inner_key);
}

/// Format a tool status message using a static buffer
/// Note: Not thread-safe, but worker output is processed sequentially
var status_format_buf: [256]u8 = undefined;

fn formatToolStatus(action: []const u8, target: []const u8) []const u8 {
    // Truncate target if too long
    const max_target = 180;
    const display_target = if (target.len > max_target) target[0..max_target] else target;

    const result = std.fmt.bufPrint(&status_format_buf, "{s}: {s}", .{ action, display_target }) catch {
        return action;
    };
    return result;
}

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
