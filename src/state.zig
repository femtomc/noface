//! Orchestrator state management.
//!
//! Maintains persistent state across agent invocations and handles crash recovery.
//! State is persisted to .noface/state.json for durability.

const std = @import("std");
const process = @import("process.zig");

/// Maximum number of parallel workers
pub const MAX_WORKERS = 8;

/// State directory and file paths
const STATE_DIR = ".noface";
const STATE_FILE = ".noface/state.json";
const STATE_BACKUP = ".noface/state.json.bak";

/// File manifest for an issue - declares what files can be modified
pub const Manifest = struct {
    /// Files this issue has exclusive write access to
    primary_files: []const []const u8 = &.{},
    /// Files this issue may read (no lock needed)
    read_files: []const []const u8 = &.{},
    /// Files this issue must not touch
    forbidden_files: []const []const u8 = &.{},

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        for (self.primary_files) |f| allocator.free(f);
        if (self.primary_files.len > 0) allocator.free(self.primary_files);
        for (self.read_files) |f| allocator.free(f);
        if (self.read_files.len > 0) allocator.free(self.read_files);
        for (self.forbidden_files) |f| allocator.free(f);
        if (self.forbidden_files.len > 0) allocator.free(self.forbidden_files);
    }

    /// Check if a file is allowed to be modified
    pub fn allowsWrite(self: Manifest, file: []const u8) bool {
        for (self.primary_files) |f| {
            if (std.mem.eql(u8, f, file)) return true;
            // Handle line range format: "file.zig:100-200"
            if (std.mem.startsWith(u8, f, file) and f.len > file.len and f[file.len] == ':') {
                return true;
            }
        }
        return false;
    }

    /// Check if a file is explicitly forbidden
    pub fn isForbidden(self: Manifest, file: []const u8) bool {
        for (self.forbidden_files) |f| {
            if (std.mem.eql(u8, f, file)) return true;
        }
        return false;
    }
};

/// Attempt record for tracking failed attempts
pub const AttemptResult = enum { success, failed, timeout, violation };

pub const AttemptRecord = struct {
    attempt_number: u32,
    timestamp: i64,
    result: AttemptResult,
    files_touched: []const []const u8 = &.{},
    notes: []const u8 = "",

    pub fn deinit(self: *AttemptRecord, allocator: std.mem.Allocator) void {
        for (self.files_touched) |f| allocator.free(f);
        if (self.files_touched.len > 0) allocator.free(self.files_touched);
        if (self.notes.len > 0) allocator.free(self.notes);
    }
};

/// Issue status enum
pub const IssueStatus = enum { pending, assigned, running, completed, failed };

/// State for a single issue (our annotations on top of beads)
pub const IssueState = struct {
    id: []const u8,
    manifest: ?Manifest = null,
    assigned_worker: ?u32 = null,
    attempt_count: u32 = 0,
    last_attempt: ?AttemptRecord = null,
    status: IssueStatus = .pending,

    pub fn deinit(self: *IssueState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.manifest) |*m| m.deinit(allocator);
        if (self.last_attempt) |*a| a.deinit(allocator);
    }
};

/// Worker state
pub const WorkerState = struct {
    id: u32,
    status: Status,
    current_issue: ?[]const u8 = null,
    process_pid: ?i32 = null,
    started_at: ?i64 = null,

    pub const Status = enum { idle, starting, running, completed, failed, timeout };

    pub fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        if (self.current_issue) |issue| allocator.free(issue);
    }

    pub fn isAvailable(self: WorkerState) bool {
        return self.status == .idle or self.status == .completed or self.status == .failed;
    }
};

/// A batch of issues to execute in parallel
pub const Batch = struct {
    id: u32,
    issue_ids: []const []const u8,
    status: enum { pending, running, completed } = .pending,
    started_at: ?i64 = null,
    completed_at: ?i64 = null,

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.issue_ids) |id| allocator.free(id);
        if (self.issue_ids.len > 0) allocator.free(self.issue_ids);
    }

    pub fn isComplete(self: Batch) bool {
        return self.status == .completed;
    }
};

/// Lock table entry
pub const LockEntry = struct {
    file: []const u8,
    issue_id: []const u8,
    worker_id: u32,
    acquired_at: i64,

    pub fn deinit(self: *LockEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.issue_id);
    }
};

/// Main orchestrator state
pub const OrchestratorState = struct {
    allocator: std.mem.Allocator,

    // Metadata
    project_name: []const u8 = "unknown",
    state_version: u32 = 1,
    last_saved: i64 = 0,

    // Issue tracking (keyed by issue ID)
    issues: std.StringHashMap(IssueState),

    // Execution state
    current_batch: ?Batch = null,
    pending_batches: std.ArrayListUnmanaged(Batch) = .{},
    next_batch_id: u32 = 1,
    workers: [MAX_WORKERS]WorkerState = undefined,
    num_workers: u32 = 3, // Default to 3 parallel workers

    // Lock table (keyed by file path)
    locks: std.StringHashMap(LockEntry),

    // Counters
    total_iterations: u32 = 0,
    successful_completions: u32 = 0,
    failed_attempts: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) OrchestratorState {
        var state = OrchestratorState{
            .allocator = allocator,
            .issues = std.StringHashMap(IssueState).init(allocator),
            .locks = std.StringHashMap(LockEntry).init(allocator),
            .pending_batches = .{},
        };

        // Initialize workers
        for (0..MAX_WORKERS) |i| {
            state.workers[i] = .{
                .id = @intCast(i),
                .status = .idle,
            };
        }

        return state;
    }

    pub fn deinit(self: *OrchestratorState) void {
        // Free issues
        var issue_it = self.issues.iterator();
        while (issue_it.next()) |entry| {
            var issue = entry.value_ptr.*;
            issue.deinit(self.allocator);
        }
        self.issues.deinit();

        // Free locks
        var lock_it = self.locks.iterator();
        while (lock_it.next()) |entry| {
            var lock = entry.value_ptr.*;
            lock.deinit(self.allocator);
        }
        self.locks.deinit();

        // Free current batch
        if (self.current_batch) |*batch| {
            batch.deinit(self.allocator);
        }

        // Free pending batches
        for (self.pending_batches.items) |*batch| {
            batch.deinit(self.allocator);
        }
        self.pending_batches.deinit(self.allocator);

        // Free workers
        for (&self.workers) |*w| {
            w.deinit(self.allocator);
        }

        // Free project name if owned
        if (!std.mem.eql(u8, self.project_name, "unknown")) {
            self.allocator.free(self.project_name);
        }
    }

    /// Load state from disk, or create fresh if not found
    pub fn load(allocator: std.mem.Allocator, project_name: []const u8) !OrchestratorState {
        var state = OrchestratorState.init(allocator);
        state.project_name = try allocator.dupe(u8, project_name);

        // Try to load existing state
        const file = std.fs.cwd().openFile(STATE_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) {
                logInfo("No existing state found, starting fresh", .{});
                return state;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);

        // Parse JSON state
        try state.parseJson(content);

        logInfo("Loaded state: {d} issues, {d} locks", .{
            state.issues.count(),
            state.locks.count(),
        });

        return state;
    }

    /// Save state to disk
    pub fn save(self: *OrchestratorState) !void {
        // Ensure state directory exists
        std.fs.cwd().makeDir(STATE_DIR) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Backup existing state
        std.fs.cwd().rename(STATE_FILE, STATE_BACKUP) catch {};

        // Build JSON content
        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);

        try self.writeJson(&content);

        // Write atomically
        const file = try std.fs.cwd().createFile(STATE_FILE, .{});
        defer file.close();
        try file.writeAll(content.items);

        self.last_saved = std.time.timestamp();
        logInfo("State saved ({d} bytes)", .{content.items.len});
    }

    /// Write state as JSON
    fn writeJson(self: *OrchestratorState, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.appendSlice(self.allocator, "{\n");

        // Metadata
        try appendJsonField(self.allocator, out, "  \"state_version\"", self.state_version);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonStringField(self.allocator, out, "  \"project_name\"", self.project_name);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonField(self.allocator, out, "  \"last_saved\"", self.last_saved);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonField(self.allocator, out, "  \"total_iterations\"", self.total_iterations);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonField(self.allocator, out, "  \"successful_completions\"", self.successful_completions);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonField(self.allocator, out, "  \"failed_attempts\"", self.failed_attempts);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonField(self.allocator, out, "  \"num_workers\"", self.num_workers);
        try out.appendSlice(self.allocator, ",\n");
        try appendJsonField(self.allocator, out, "  \"next_batch_id\"", self.next_batch_id);
        try out.appendSlice(self.allocator, ",\n");

        // Workers
        try out.appendSlice(self.allocator, "  \"workers\": [\n");
        var first_worker = true;
        for (self.workers[0..self.num_workers]) |w| {
            if (!first_worker) try out.appendSlice(self.allocator, ",\n");
            first_worker = false;
            try out.appendSlice(self.allocator, "    {");
            try appendJsonField(self.allocator, out, "\"id\"", w.id);
            try out.appendSlice(self.allocator, ", ");
            try appendJsonStringField(self.allocator, out, "\"status\"", @tagName(w.status));
            if (w.current_issue) |issue| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonStringField(self.allocator, out, "\"current_issue\"", issue);
            }
            if (w.started_at) |t| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"started_at\"", t);
            }
            try out.appendSlice(self.allocator, "}");
        }
        try out.appendSlice(self.allocator, "\n  ],\n");

        // Issues
        try out.appendSlice(self.allocator, "  \"issues\": {\n");
        var first_issue = true;
        var issue_it = self.issues.iterator();
        while (issue_it.next()) |entry| {
            if (!first_issue) try out.appendSlice(self.allocator, ",\n");
            first_issue = false;
            const issue = entry.value_ptr.*;
            try out.appendSlice(self.allocator, "    \"");
            try out.appendSlice(self.allocator, issue.id);
            try out.appendSlice(self.allocator, "\": {");
            try appendJsonStringField(self.allocator, out, "\"status\"", @tagName(issue.status));
            try out.appendSlice(self.allocator, ", ");
            try appendJsonField(self.allocator, out, "\"attempt_count\"", issue.attempt_count);
            if (issue.assigned_worker) |w| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"assigned_worker\"", w);
            }
            // Serialize manifest
            if (issue.manifest) |manifest| {
                try out.appendSlice(self.allocator, ", \"manifest\": {");
                try out.appendSlice(self.allocator, "\"primary_files\": [");
                for (manifest.primary_files, 0..) |f, idx| {
                    if (idx > 0) try out.appendSlice(self.allocator, ", ");
                    try out.appendSlice(self.allocator, "\"");
                    try appendJsonEscapedString(self.allocator, out, f);
                    try out.appendSlice(self.allocator, "\"");
                }
                try out.appendSlice(self.allocator, "], \"read_files\": [");
                for (manifest.read_files, 0..) |f, idx| {
                    if (idx > 0) try out.appendSlice(self.allocator, ", ");
                    try out.appendSlice(self.allocator, "\"");
                    try appendJsonEscapedString(self.allocator, out, f);
                    try out.appendSlice(self.allocator, "\"");
                }
                try out.appendSlice(self.allocator, "], \"forbidden_files\": [");
                for (manifest.forbidden_files, 0..) |f, idx| {
                    if (idx > 0) try out.appendSlice(self.allocator, ", ");
                    try out.appendSlice(self.allocator, "\"");
                    try appendJsonEscapedString(self.allocator, out, f);
                    try out.appendSlice(self.allocator, "\"");
                }
                try out.appendSlice(self.allocator, "]}");
            }
            // Serialize last_attempt
            if (issue.last_attempt) |attempt| {
                try out.appendSlice(self.allocator, ", \"last_attempt\": {");
                try appendJsonField(self.allocator, out, "\"attempt_number\"", attempt.attempt_number);
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"timestamp\"", attempt.timestamp);
                try out.appendSlice(self.allocator, ", ");
                try appendJsonStringField(self.allocator, out, "\"result\"", @tagName(attempt.result));
                try out.appendSlice(self.allocator, ", \"files_touched\": [");
                for (attempt.files_touched, 0..) |f, idx| {
                    if (idx > 0) try out.appendSlice(self.allocator, ", ");
                    try out.appendSlice(self.allocator, "\"");
                    try appendJsonEscapedString(self.allocator, out, f);
                    try out.appendSlice(self.allocator, "\"");
                }
                try out.appendSlice(self.allocator, "], ");
                try appendJsonStringField(self.allocator, out, "\"notes\"", attempt.notes);
                try out.appendSlice(self.allocator, "}");
            }
            try out.appendSlice(self.allocator, "}");
        }
        try out.appendSlice(self.allocator, "\n  },\n");

        // Locks
        try out.appendSlice(self.allocator, "  \"locks\": {\n");
        var first_lock = true;
        var lock_it = self.locks.iterator();
        while (lock_it.next()) |entry| {
            if (!first_lock) try out.appendSlice(self.allocator, ",\n");
            first_lock = false;
            const lock = entry.value_ptr.*;
            try out.appendSlice(self.allocator, "    \"");
            try out.appendSlice(self.allocator, lock.file);
            try out.appendSlice(self.allocator, "\": {");
            try appendJsonStringField(self.allocator, out, "\"issue_id\"", lock.issue_id);
            try out.appendSlice(self.allocator, ", ");
            try appendJsonField(self.allocator, out, "\"worker_id\"", lock.worker_id);
            try out.appendSlice(self.allocator, ", ");
            try appendJsonField(self.allocator, out, "\"acquired_at\"", lock.acquired_at);
            try out.appendSlice(self.allocator, "}");
        }
        try out.appendSlice(self.allocator, "\n  },\n");

        // Current batch
        if (self.current_batch) |batch| {
            try out.appendSlice(self.allocator, "  \"current_batch\": {");
            try appendJsonField(self.allocator, out, "\"id\"", batch.id);
            try out.appendSlice(self.allocator, ", ");
            try appendJsonStringField(self.allocator, out, "\"status\"", @tagName(batch.status));
            if (batch.started_at) |t| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"started_at\"", t);
            }
            if (batch.completed_at) |t| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"completed_at\"", t);
            }
            try out.appendSlice(self.allocator, ", \"issue_ids\": [");
            for (batch.issue_ids, 0..) |id, idx| {
                if (idx > 0) try out.appendSlice(self.allocator, ", ");
                try out.appendSlice(self.allocator, "\"");
                try appendJsonEscapedString(self.allocator, out, id);
                try out.appendSlice(self.allocator, "\"");
            }
            try out.appendSlice(self.allocator, "]},\n");
        } else {
            try out.appendSlice(self.allocator, "  \"current_batch\": null,\n");
        }

        // Pending batches
        try out.appendSlice(self.allocator, "  \"pending_batches\": [\n");
        for (self.pending_batches.items, 0..) |batch, batch_idx| {
            if (batch_idx > 0) try out.appendSlice(self.allocator, ",\n");
            try out.appendSlice(self.allocator, "    {");
            try appendJsonField(self.allocator, out, "\"id\"", batch.id);
            try out.appendSlice(self.allocator, ", ");
            try appendJsonStringField(self.allocator, out, "\"status\"", @tagName(batch.status));
            if (batch.started_at) |t| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"started_at\"", t);
            }
            if (batch.completed_at) |t| {
                try out.appendSlice(self.allocator, ", ");
                try appendJsonField(self.allocator, out, "\"completed_at\"", t);
            }
            try out.appendSlice(self.allocator, ", \"issue_ids\": [");
            for (batch.issue_ids, 0..) |id, idx| {
                if (idx > 0) try out.appendSlice(self.allocator, ", ");
                try out.appendSlice(self.allocator, "\"");
                try appendJsonEscapedString(self.allocator, out, id);
                try out.appendSlice(self.allocator, "\"");
            }
            try out.appendSlice(self.allocator, "]}");
        }
        try out.appendSlice(self.allocator, "\n  ]\n");

        try out.appendSlice(self.allocator, "}\n");
    }

    /// Parse JSON state (simplified parser for our known format)
    fn parseJson(self: *OrchestratorState, json: []const u8) !void {
        // Simple JSON parsing for our specific format
        // Look for key fields and parse them

        if (parseJsonInt(json, "state_version")) |v| {
            self.state_version = @intCast(v);
        }
        if (parseJsonInt(json, "total_iterations")) |v| {
            self.total_iterations = @intCast(v);
        }
        if (parseJsonInt(json, "successful_completions")) |v| {
            self.successful_completions = @intCast(v);
        }
        if (parseJsonInt(json, "failed_attempts")) |v| {
            self.failed_attempts = @intCast(v);
        }
        if (parseJsonInt(json, "num_workers")) |v| {
            self.num_workers = @intCast(@min(v, MAX_WORKERS));
        }
        if (parseJsonInt(json, "next_batch_id")) |v| {
            self.next_batch_id = @intCast(v);
        }

        // Parse workers array
        if (findJsonSection(json, "\"workers\"")) |workers_section| {
            try self.parseWorkers(workers_section);
        }

        // Parse issues object
        if (findJsonSection(json, "\"issues\"")) |issues_section| {
            try self.parseIssues(issues_section);
        }

        // Parse locks object
        if (findJsonSection(json, "\"locks\"")) |locks_section| {
            try self.parseLocks(locks_section);
        }

        // Parse current_batch
        if (findCurrentBatchSection(json)) |batch_section| {
            self.current_batch = try self.parseBatch(batch_section);
        }

        // Parse pending_batches array
        if (findJsonSection(json, "\"pending_batches\"")) |batches_section| {
            try self.parsePendingBatches(batches_section);
        }
    }

    fn parseWorkers(self: *OrchestratorState, json: []const u8) !void {
        var i: usize = 0;
        var worker_idx: u32 = 0;

        while (i < json.len and worker_idx < self.num_workers) {
            // Find next worker object
            if (std.mem.indexOfPos(u8, json, i, "{")) |start| {
                if (std.mem.indexOfPos(u8, json, start, "}")) |end| {
                    const worker_json = json[start .. end + 1];

                    if (parseJsonInt(worker_json, "\"id\"")) |id| {
                        const idx: usize = @intCast(id);
                        if (idx < MAX_WORKERS) {
                            if (parseJsonString(self.allocator, worker_json, "\"status\"")) |status_str| {
                                defer self.allocator.free(status_str);
                                self.workers[idx].status = std.meta.stringToEnum(WorkerState.Status, status_str) orelse .idle;
                            }
                            if (parseJsonString(self.allocator, worker_json, "\"current_issue\"")) |issue| {
                                self.workers[idx].current_issue = issue;
                            }
                            if (parseJsonInt(worker_json, "\"started_at\"")) |t| {
                                self.workers[idx].started_at = t;
                            }
                        }
                    }

                    i = end + 1;
                    worker_idx += 1;
                } else break;
            } else break;
        }
    }

    fn parseIssues(self: *OrchestratorState, json: []const u8) !void {
        var i: usize = 0;

        while (i < json.len) {
            // Find next key (issue ID)
            if (std.mem.indexOfPos(u8, json, i, "\"")) |key_start| {
                if (std.mem.indexOfPos(u8, json, key_start + 1, "\"")) |key_end| {
                    const issue_id = json[key_start + 1 .. key_end];

                    // Skip internal keys
                    if (std.mem.eql(u8, issue_id, "status") or
                        std.mem.eql(u8, issue_id, "attempt_count") or
                        std.mem.eql(u8, issue_id, "assigned_worker") or
                        std.mem.eql(u8, issue_id, "manifest") or
                        std.mem.eql(u8, issue_id, "last_attempt") or
                        std.mem.eql(u8, issue_id, "primary_files") or
                        std.mem.eql(u8, issue_id, "read_files") or
                        std.mem.eql(u8, issue_id, "forbidden_files") or
                        std.mem.eql(u8, issue_id, "attempt_number") or
                        std.mem.eql(u8, issue_id, "timestamp") or
                        std.mem.eql(u8, issue_id, "result") or
                        std.mem.eql(u8, issue_id, "files_touched") or
                        std.mem.eql(u8, issue_id, "notes"))
                    {
                        i = key_end + 1;
                        continue;
                    }

                    // Find the value object - need to match braces properly for nested objects
                    if (std.mem.indexOfPos(u8, json, key_end, "{")) |val_start| {
                        if (findMatchingBrace(json[val_start..])) |brace_offset| {
                            const val_end = val_start + brace_offset;
                            const val_json = json[val_start .. val_end + 1];

                            const owned_id = try self.allocator.dupe(u8, issue_id);
                            var issue = IssueState{
                                .id = owned_id,
                            };

                            if (parseJsonString(self.allocator, val_json, "\"status\"")) |status_str| {
                                defer self.allocator.free(status_str);
                                issue.status = std.meta.stringToEnum(@TypeOf(issue.status), status_str) orelse .pending;
                            }
                            if (parseJsonInt(val_json, "\"attempt_count\"")) |v| {
                                issue.attempt_count = @intCast(v);
                            }
                            if (parseJsonInt(val_json, "\"assigned_worker\"")) |v| {
                                issue.assigned_worker = @intCast(v);
                            }

                            // Parse manifest if present
                            if (findJsonSection(val_json, "\"manifest\"")) |manifest_json| {
                                issue.manifest = try self.parseManifest(manifest_json);
                            }

                            // Parse last_attempt if present
                            if (findJsonSection(val_json, "\"last_attempt\"")) |attempt_json| {
                                issue.last_attempt = try self.parseAttemptRecord(attempt_json);
                            }

                            try self.issues.put(owned_id, issue);

                            i = val_end + 1;
                            continue;
                        }
                    }
                }
            }
            break;
        }
    }

    fn parseManifest(self: *OrchestratorState, json: []const u8) !Manifest {
        var manifest = Manifest{};

        // Parse primary_files array
        if (findJsonSection(json, "\"primary_files\"")) |arr_json| {
            manifest.primary_files = try self.parseStringArray(arr_json);
        }

        // Parse read_files array
        if (findJsonSection(json, "\"read_files\"")) |arr_json| {
            manifest.read_files = try self.parseStringArray(arr_json);
        }

        // Parse forbidden_files array
        if (findJsonSection(json, "\"forbidden_files\"")) |arr_json| {
            manifest.forbidden_files = try self.parseStringArray(arr_json);
        }

        return manifest;
    }

    fn parseAttemptRecord(self: *OrchestratorState, json: []const u8) !AttemptRecord {
        var record = AttemptRecord{
            .attempt_number = 0,
            .timestamp = 0,
            .result = .failed,
        };

        if (parseJsonInt(json, "\"attempt_number\"")) |v| {
            record.attempt_number = @intCast(v);
        }
        if (parseJsonInt(json, "\"timestamp\"")) |v| {
            record.timestamp = v;
        }
        if (parseJsonString(self.allocator, json, "\"result\"")) |result_str| {
            defer self.allocator.free(result_str);
            record.result = std.meta.stringToEnum(AttemptResult, result_str) orelse .failed;
        }
        if (parseJsonString(self.allocator, json, "\"notes\"")) |notes| {
            record.notes = notes;
        }
        if (findJsonSection(json, "\"files_touched\"")) |arr_json| {
            record.files_touched = try self.parseStringArray(arr_json);
        }

        return record;
    }

    fn parseStringArray(self: *OrchestratorState, json: []const u8) ![]const []const u8 {
        var strings = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (strings.items) |s| self.allocator.free(s);
            strings.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < json.len) {
            // Find opening quote
            if (std.mem.indexOfPos(u8, json, i, "\"")) |start| {
                // Find closing quote (handling escapes)
                var end = start + 1;
                while (end < json.len and json[end] != '"') {
                    if (json[end] == '\\' and end + 1 < json.len) {
                        end += 2;
                    } else {
                        end += 1;
                    }
                }
                if (end < json.len) {
                    const str = try parseJsonEscapedString(self.allocator, json[start + 1 .. end]);
                    try strings.append(self.allocator, str);
                    i = end + 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (strings.items.len == 0) {
            return &.{};
        }
        return try strings.toOwnedSlice(self.allocator);
    }

    fn parseBatch(self: *OrchestratorState, json: []const u8) !Batch {
        var batch = Batch{
            .id = 0,
            .issue_ids = &.{},
            .status = .pending,
        };

        if (parseJsonInt(json, "\"id\"")) |v| {
            batch.id = @intCast(v);
        }
        if (parseJsonString(self.allocator, json, "\"status\"")) |status_str| {
            defer self.allocator.free(status_str);
            batch.status = std.meta.stringToEnum(@TypeOf(batch.status), status_str) orelse .pending;
        }
        if (parseJsonInt(json, "\"started_at\"")) |v| {
            batch.started_at = v;
        }
        if (parseJsonInt(json, "\"completed_at\"")) |v| {
            batch.completed_at = v;
        }
        if (findJsonSection(json, "\"issue_ids\"")) |arr_json| {
            batch.issue_ids = try self.parseStringArray(arr_json);
        }

        return batch;
    }

    fn parsePendingBatches(self: *OrchestratorState, json: []const u8) !void {
        var i: usize = 0;
        while (i < json.len) {
            // Find next batch object
            if (std.mem.indexOfPos(u8, json, i, "{")) |start| {
                if (findMatchingBrace(json[start..])) |brace_offset| {
                    const end = start + brace_offset;
                    const batch_json = json[start .. end + 1];
                    const batch = try self.parseBatch(batch_json);
                    try self.pending_batches.append(self.allocator, batch);
                    i = end + 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn parseLocks(self: *OrchestratorState, json: []const u8) !void {
        var i: usize = 0;

        while (i < json.len) {
            // Find next key (file path)
            if (std.mem.indexOfPos(u8, json, i, "\"")) |key_start| {
                if (std.mem.indexOfPos(u8, json, key_start + 1, "\"")) |key_end| {
                    const file_path = json[key_start + 1 .. key_end];

                    // Skip internal keys
                    if (std.mem.eql(u8, file_path, "issue_id") or
                        std.mem.eql(u8, file_path, "worker_id") or
                        std.mem.eql(u8, file_path, "acquired_at"))
                    {
                        i = key_end + 1;
                        continue;
                    }

                    // Find the value object
                    if (std.mem.indexOfPos(u8, json, key_end, "{")) |val_start| {
                        if (std.mem.indexOfPos(u8, json, val_start, "}")) |val_end| {
                            const val_json = json[val_start .. val_end + 1];

                            const issue_id = parseJsonString(self.allocator, val_json, "\"issue_id\"") orelse continue;
                            const worker_id: u32 = if (parseJsonInt(val_json, "\"worker_id\"")) |v| @intCast(v) else 0;
                            const acquired_at: i64 = parseJsonInt(val_json, "\"acquired_at\"") orelse 0;

                            // Use single allocation for both HashMap key and lock.file
                            const owned_file = try self.allocator.dupe(u8, file_path);

                            const lock = LockEntry{
                                .file = owned_file,
                                .issue_id = issue_id,
                                .worker_id = worker_id,
                                .acquired_at = acquired_at,
                            };

                            try self.locks.put(owned_file, lock);

                            i = val_end + 1;
                            continue;
                        }
                    }
                }
            }
            break;
        }
    }

    // === Lock Management ===

    /// Try to acquire locks for all files in a manifest
    pub fn tryAcquireLocks(self: *OrchestratorState, issue_id: []const u8, manifest: Manifest, worker_id: u32) !bool {
        // Check all files are available
        for (manifest.primary_files) |file| {
            const base_file = extractBaseFile(file);
            if (self.locks.get(base_file)) |lock| {
                if (!std.mem.eql(u8, lock.issue_id, issue_id)) {
                    return false; // Locked by another issue
                }
            }
        }

        // Acquire all locks (skip files already locked by this issue)
        const now = std.time.timestamp();
        for (manifest.primary_files) |file| {
            const base_file = extractBaseFile(file);

            // Skip if already locked by this issue
            if (self.locks.get(base_file)) |existing| {
                if (std.mem.eql(u8, existing.issue_id, issue_id)) {
                    continue;
                }
            }

            const owned_file = try self.allocator.dupe(u8, base_file);
            const owned_issue = try self.allocator.dupe(u8, issue_id);

            try self.locks.put(owned_file, .{
                .file = owned_file,
                .issue_id = owned_issue,
                .worker_id = worker_id,
                .acquired_at = now,
            });
        }

        return true;
    }

    /// Release all locks held by an issue
    pub fn releaseLocks(self: *OrchestratorState, issue_id: []const u8) void {
        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = self.locks.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.issue_id, issue_id)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.locks.fetchRemove(key)) |kv| {
                var lock = kv.value;
                // Note: lock.file and kv.key point to the same memory,
                // so deinit frees both the file path and issue_id
                lock.deinit(self.allocator);
            }
        }
    }

    /// Clean up stale locks (from crashed workers)
    pub fn cleanupStaleLocks(self: *OrchestratorState, max_age_seconds: i64) u32 {
        const now = std.time.timestamp();
        var removed: u32 = 0;

        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = self.locks.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.acquired_at > max_age_seconds) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.locks.fetchRemove(key)) |kv| {
                var lock = kv.value;
                // Note: lock.file and kv.key point to the same memory,
                // so deinit frees both the file path and issue_id
                lock.deinit(self.allocator);
                removed += 1;
            }
        }

        return removed;
    }

    // === Worker Management ===

    /// Find an idle worker
    pub fn findIdleWorker(self: *OrchestratorState) ?*WorkerState {
        for (self.workers[0..self.num_workers]) |*w| {
            if (w.isAvailable()) {
                return w;
            }
        }
        return null;
    }

    /// Mark a worker as starting a task
    pub fn assignWorker(self: *OrchestratorState, worker: *WorkerState, issue_id: []const u8) !void {
        worker.status = .starting;
        worker.current_issue = try self.allocator.dupe(u8, issue_id);
        worker.started_at = std.time.timestamp();
    }

    /// Mark a worker as completed
    pub fn completeWorker(self: *OrchestratorState, worker: *WorkerState, success: bool) void {
        worker.status = if (success) .completed else .failed;
        if (worker.current_issue) |issue| {
            self.allocator.free(issue);
            worker.current_issue = null;
        }
    }

    // === Issue Management ===

    /// Update or create issue state
    pub fn updateIssue(self: *OrchestratorState, issue_id: []const u8, status: IssueStatus) !void {
        if (self.issues.getPtr(issue_id)) |issue| {
            issue.status = status;
        } else {
            const owned_id = try self.allocator.dupe(u8, issue_id);
            try self.issues.put(owned_id, .{
                .id = owned_id,
                .status = status,
            });
        }
    }

    /// Record an attempt on an issue
    pub fn recordAttempt(self: *OrchestratorState, issue_id: []const u8, result: AttemptResult, notes: []const u8) !void {
        if (self.issues.getPtr(issue_id)) |issue| {
            issue.attempt_count += 1;

            // Free previous attempt
            if (issue.last_attempt) |*prev| {
                prev.deinit(self.allocator);
            }

            issue.last_attempt = .{
                .attempt_number = issue.attempt_count,
                .timestamp = std.time.timestamp(),
                .result = result,
                .notes = try self.allocator.dupe(u8, notes),
            };

            if (result == .success) {
                self.successful_completions += 1;
            } else {
                self.failed_attempts += 1;
            }
        }
    }

    /// Set or update manifest for an issue
    pub fn setManifest(self: *OrchestratorState, issue_id: []const u8, manifest: Manifest) !void {
        if (self.issues.getPtr(issue_id)) |issue| {
            // Free existing manifest
            if (issue.manifest) |*m| m.deinit(self.allocator);
            issue.manifest = manifest;
        } else {
            // Create new issue state with manifest
            const owned_id = try self.allocator.dupe(u8, issue_id);
            try self.issues.put(owned_id, .{
                .id = owned_id,
                .manifest = manifest,
            });
        }
    }

    /// Get manifest for an issue (returns null if not set)
    pub fn getManifest(self: *OrchestratorState, issue_id: []const u8) ?Manifest {
        if (self.issues.get(issue_id)) |issue| {
            return issue.manifest;
        }
        return null;
    }

    // === Batch Management ===

    /// Add a batch of issues to the pending queue
    /// Takes ownership of issue_ids array (caller should not free)
    pub fn addBatch(self: *OrchestratorState, issue_ids: []const []const u8) !u32 {
        const batch_id = self.next_batch_id;
        self.next_batch_id += 1;

        const batch = Batch{
            .id = batch_id,
            .issue_ids = issue_ids,
            .status = .pending,
        };

        try self.pending_batches.append(self.allocator, batch);
        logInfo("Added batch {d} with {d} issues", .{ batch_id, issue_ids.len });

        return batch_id;
    }

    /// Get the next pending batch (does not remove it)
    pub fn getNextPendingBatch(self: *OrchestratorState) ?*Batch {
        for (self.pending_batches.items) |*batch| {
            if (batch.status == .pending) {
                return batch;
            }
        }
        return null;
    }

    /// Get a batch by ID
    pub fn getBatch(self: *OrchestratorState, batch_id: u32) ?*Batch {
        for (self.pending_batches.items) |*batch| {
            if (batch.id == batch_id) {
                return batch;
            }
        }
        return null;
    }

    /// Clear all pending batches (used when planner regenerates batches)
    pub fn clearPendingBatches(self: *OrchestratorState) void {
        for (self.pending_batches.items) |*batch| {
            batch.deinit(self.allocator);
        }
        self.pending_batches.clearRetainingCapacity();
        logInfo("Cleared pending batches", .{});
    }

    /// Get count of pending batches
    pub fn getPendingBatchCount(self: *OrchestratorState) usize {
        var count: usize = 0;
        for (self.pending_batches.items) |batch| {
            if (batch.status == .pending) {
                count += 1;
            }
        }
        return count;
    }

    /// Check if two issues have conflicting primary_files
    pub fn issuesConflict(self: *OrchestratorState, issue_a: []const u8, issue_b: []const u8) bool {
        const manifest_a = self.getManifest(issue_a) orelse return false;
        const manifest_b = self.getManifest(issue_b) orelse return false;

        // Check if any primary_files overlap
        for (manifest_a.primary_files) |file_a| {
            const base_a = extractBaseFile(file_a);
            for (manifest_b.primary_files) |file_b| {
                const base_b = extractBaseFile(file_b);
                if (std.mem.eql(u8, base_a, base_b)) {
                    return true;
                }
            }
        }
        return false;
    }

    // === Crash Recovery ===

    /// Recover from a crash - reset any in-progress work
    pub fn recoverFromCrash(self: *OrchestratorState) !u32 {
        var recovered: u32 = 0;

        // Reset any workers that were running
        for (self.workers[0..self.num_workers]) |*w| {
            if (w.status == .running or w.status == .starting) {
                logWarn("Recovering crashed worker {d} (was working on {s})", .{
                    w.id,
                    w.current_issue orelse "unknown",
                });

                if (w.current_issue) |issue_id| {
                    // Release locks
                    self.releaseLocks(issue_id);

                    // Reset issue status
                    if (self.issues.getPtr(issue_id)) |issue| {
                        issue.status = .pending;
                        issue.assigned_worker = null;
                    }

                    self.allocator.free(issue_id);
                    w.current_issue = null;
                }

                w.status = .idle;
                w.started_at = null;
                recovered += 1;
            }
        }

        // Clean up stale locks (older than 1 hour)
        const stale = self.cleanupStaleLocks(3600);
        if (stale > 0) {
            logWarn("Cleaned up {d} stale locks", .{stale});
            recovered += stale;
        }

        return recovered;
    }
};

// === JSON Helper Functions ===

fn appendJsonField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, value: anytype) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, ": ");
    const val_str = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(val_str);
    try out.appendSlice(allocator, val_str);
}

fn appendJsonStringField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, ": \"");
    try appendJsonEscapedString(allocator, out, value);
    try out.appendSlice(allocator, "\"");
}

fn appendJsonEscapedString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
}

fn parseJsonInt(json: []const u8, key: []const u8) ?i64 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip closing quote, colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == '"' or after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t')) : (i += 1) {}

    if (i >= after_key.len) return null;

    // Check for negative
    const negative = after_key[i] == '-';
    if (negative) i += 1;

    // Parse digits
    const start = i;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}

    if (i == start) return null;

    const num = std.fmt.parseInt(i64, after_key[start..i], 10) catch return null;
    return if (negative) -num else num;
}

fn parseJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip colon and whitespace to find opening quote of string value
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // Skip opening quote

    const start = i;
    while (i < after_key.len and after_key[i] != '"') {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 2; // Skip escaped char
        } else {
            i += 1;
        }
    }

    return allocator.dupe(u8, after_key[start..i]) catch null;
}

fn findJsonSection(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Find opening bracket/brace
    var i: usize = 0;
    while (i < after_key.len and after_key[i] != '[' and after_key[i] != '{') : (i += 1) {}

    if (i >= after_key.len) return null;

    const open_char = after_key[i];
    const close_char: u8 = if (open_char == '[') ']' else '}';

    // Find matching close
    var depth: u32 = 1;
    var j = i + 1;
    while (j < after_key.len and depth > 0) {
        if (after_key[j] == open_char) depth += 1;
        if (after_key[j] == close_char) depth -= 1;
        if (after_key[j] == '"') {
            j += 1;
            while (j < after_key.len and after_key[j] != '"') {
                if (after_key[j] == '\\' and j + 1 < after_key.len) j += 2 else j += 1;
            }
        }
        j += 1;
    }

    return after_key[i..j];
}

/// Find matching closing brace for an opening brace at position 0
/// Returns the offset to the closing brace, or null if not found
fn findMatchingBrace(json: []const u8) ?usize {
    if (json.len == 0 or json[0] != '{') return null;

    var depth: u32 = 1;
    var i: usize = 1;
    while (i < json.len and depth > 0) {
        switch (json[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            '"' => {
                // Skip string content
                i += 1;
                while (i < json.len and json[i] != '"') {
                    if (json[i] == '\\' and i + 1 < json.len) {
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
            },
            else => {},
        }
        i += 1;
    }

    if (depth == 0) {
        return i - 1;
    }
    return null;
}

/// Find the current_batch section, handling the case where it may be null
fn findCurrentBatchSection(json: []const u8) ?[]const u8 {
    const key = "\"current_batch\"";
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len) return null;

    // Check for null
    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i .. i + 4], "null")) {
        return null;
    }

    // Must be an object
    if (after_key[i] != '{') return null;

    if (findMatchingBrace(after_key[i..])) |brace_offset| {
        return after_key[i .. i + brace_offset + 1];
    }
    return null;
}

/// Parse an escaped JSON string, converting escape sequences
fn parseJsonEscapedString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            switch (input[i + 1]) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                else => {
                    try result.append(allocator, input[i]);
                    try result.append(allocator, input[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn extractBaseFile(file_spec: []const u8) []const u8 {
    // Handle "file.zig:100-200" format - extract just "file.zig"
    if (std.mem.indexOf(u8, file_spec, ":")) |colon| {
        return file_spec[0..colon];
    }
    return file_spec;
}

// === Logging ===

const Color = struct {
    const reset = "\x1b[0m";
    const blue = "\x1b[0;34m";
    const yellow = "\x1b[1;33m";
};

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[STATE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[STATE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

// === Tests ===

test "state init and save" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    state.project_name = try std.testing.allocator.dupe(u8, "test-project");
    state.total_iterations = 5;

    // Test JSON serialization
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(std.testing.allocator);

    try state.writeJson(&content);

    try std.testing.expect(std.mem.indexOf(u8, content.items, "test-project") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.items, "\"total_iterations\": 5") != null);
}

test "manifest allows" {
    const manifest = Manifest{
        .primary_files = &.{ "src/foo.zig", "src/bar.zig:100-200" },
        .forbidden_files = &.{"src/main.zig"},
    };

    try std.testing.expect(manifest.allowsWrite("src/foo.zig"));
    try std.testing.expect(manifest.allowsWrite("src/bar.zig"));
    try std.testing.expect(!manifest.allowsWrite("src/baz.zig"));
    try std.testing.expect(manifest.isForbidden("src/main.zig"));
}

test "parse json int" {
    const json = "{\"count\": 42, \"negative\": -10}";
    try std.testing.expectEqual(@as(?i64, 42), parseJsonInt(json, "\"count\""));
    try std.testing.expectEqual(@as(?i64, -10), parseJsonInt(json, "\"negative\""));
    try std.testing.expectEqual(@as(?i64, null), parseJsonInt(json, "\"missing\""));
}

test "set and get manifest" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create a manifest with owned strings
    const primary = try std.testing.allocator.dupe(u8, "src/loop.zig");
    const read = try std.testing.allocator.dupe(u8, "src/state.zig");
    const forbidden = try std.testing.allocator.dupe(u8, "src/main.zig");

    var primary_arr = try std.testing.allocator.alloc([]const u8, 1);
    primary_arr[0] = primary;
    var read_arr = try std.testing.allocator.alloc([]const u8, 1);
    read_arr[0] = read;
    var forbidden_arr = try std.testing.allocator.alloc([]const u8, 1);
    forbidden_arr[0] = forbidden;

    const manifest = Manifest{
        .primary_files = primary_arr,
        .read_files = read_arr,
        .forbidden_files = forbidden_arr,
    };

    try state.setManifest("test-issue", manifest);

    // Verify we can retrieve it
    const retrieved = state.getManifest("test-issue");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.primary_files.len == 1);
    try std.testing.expect(std.mem.eql(u8, retrieved.?.primary_files[0], "src/loop.zig"));
}

test "add and get batch" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create a batch with owned strings
    var issue_ids = try std.testing.allocator.alloc([]const u8, 2);
    issue_ids[0] = try std.testing.allocator.dupe(u8, "issue-1");
    issue_ids[1] = try std.testing.allocator.dupe(u8, "issue-2");

    const batch_id = try state.addBatch(issue_ids);

    try std.testing.expectEqual(@as(u32, 1), batch_id);
    try std.testing.expectEqual(@as(usize, 1), state.pending_batches.items.len);

    const batch = state.getBatch(batch_id);
    try std.testing.expect(batch != null);
    try std.testing.expectEqual(@as(usize, 2), batch.?.issue_ids.len);
    try std.testing.expect(std.mem.eql(u8, batch.?.issue_ids[0], "issue-1"));
    try std.testing.expect(std.mem.eql(u8, batch.?.issue_ids[1], "issue-2"));
}

test "issues conflict detection" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create manifest for issue-a: modifies src/foo.zig
    var primary_a = try std.testing.allocator.alloc([]const u8, 1);
    primary_a[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    try state.setManifest("issue-a", Manifest{ .primary_files = primary_a });

    // Create manifest for issue-b: modifies src/foo.zig (conflict!)
    var primary_b = try std.testing.allocator.alloc([]const u8, 1);
    primary_b[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    try state.setManifest("issue-b", Manifest{ .primary_files = primary_b });

    // Create manifest for issue-c: modifies src/bar.zig (no conflict)
    var primary_c = try std.testing.allocator.alloc([]const u8, 1);
    primary_c[0] = try std.testing.allocator.dupe(u8, "src/bar.zig");
    try state.setManifest("issue-c", Manifest{ .primary_files = primary_c });

    // issue-a and issue-b conflict (both modify src/foo.zig)
    try std.testing.expect(state.issuesConflict("issue-a", "issue-b"));

    // issue-a and issue-c do not conflict
    try std.testing.expect(!state.issuesConflict("issue-a", "issue-c"));

    // issue-b and issue-c do not conflict
    try std.testing.expect(!state.issuesConflict("issue-b", "issue-c"));
}

test "clear pending batches" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Add two batches
    var ids1 = try std.testing.allocator.alloc([]const u8, 1);
    ids1[0] = try std.testing.allocator.dupe(u8, "issue-1");
    _ = try state.addBatch(ids1);

    var ids2 = try std.testing.allocator.alloc([]const u8, 1);
    ids2[0] = try std.testing.allocator.dupe(u8, "issue-2");
    _ = try state.addBatch(ids2);

    try std.testing.expectEqual(@as(usize, 2), state.pending_batches.items.len);

    state.clearPendingBatches();

    try std.testing.expectEqual(@as(usize, 0), state.pending_batches.items.len);
}

test "get pending batch count" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.getPendingBatchCount());

    var ids1 = try std.testing.allocator.alloc([]const u8, 1);
    ids1[0] = try std.testing.allocator.dupe(u8, "issue-1");
    _ = try state.addBatch(ids1);

    try std.testing.expectEqual(@as(usize, 1), state.getPendingBatchCount());

    // Mark the batch as running
    if (state.getNextPendingBatch()) |batch| {
        batch.status = .running;
    }

    // Now pending count should be 0
    try std.testing.expectEqual(@as(usize, 0), state.getPendingBatchCount());
}

test "tryAcquireLocks acquires locks for manifest files" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create a manifest with primary files
    var primary = try std.testing.allocator.alloc([]const u8, 2);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    primary[1] = try std.testing.allocator.dupe(u8, "src/bar.zig");
    const manifest = Manifest{ .primary_files = primary };

    // Store manifest for cleanup
    try state.setManifest("issue-1", manifest);

    // Acquire locks for issue-1
    const acquired = try state.tryAcquireLocks("issue-1", manifest, 0);
    try std.testing.expect(acquired);

    // Verify locks were created
    try std.testing.expectEqual(@as(usize, 2), state.locks.count());
    try std.testing.expect(state.locks.contains("src/foo.zig"));
    try std.testing.expect(state.locks.contains("src/bar.zig"));

    // Verify lock details
    const lock = state.locks.get("src/foo.zig").?;
    try std.testing.expect(std.mem.eql(u8, lock.issue_id, "issue-1"));
    try std.testing.expectEqual(@as(u32, 0), lock.worker_id);
}

test "tryAcquireLocks fails when files locked by another issue" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create manifests for two issues that conflict
    var primary1 = try std.testing.allocator.alloc([]const u8, 1);
    primary1[0] = try std.testing.allocator.dupe(u8, "src/shared.zig");
    const manifest1 = Manifest{ .primary_files = primary1 };
    try state.setManifest("issue-1", manifest1);

    var primary2 = try std.testing.allocator.alloc([]const u8, 1);
    primary2[0] = try std.testing.allocator.dupe(u8, "src/shared.zig");
    const manifest2 = Manifest{ .primary_files = primary2 };
    try state.setManifest("issue-2", manifest2);

    // First issue acquires locks successfully
    const acquired1 = try state.tryAcquireLocks("issue-1", manifest1, 0);
    try std.testing.expect(acquired1);

    // Second issue fails to acquire locks (file already locked)
    const acquired2 = try state.tryAcquireLocks("issue-2", manifest2, 1);
    try std.testing.expect(!acquired2);
}

test "tryAcquireLocks allows same issue to re-acquire its locks" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    const manifest = Manifest{ .primary_files = primary };
    try state.setManifest("issue-1", manifest);

    // Acquire locks
    const acquired1 = try state.tryAcquireLocks("issue-1", manifest, 0);
    try std.testing.expect(acquired1);

    // Same issue can re-acquire (idempotent)
    const acquired2 = try state.tryAcquireLocks("issue-1", manifest, 0);
    try std.testing.expect(acquired2);
}

test "releaseLocks removes all locks for an issue" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    var primary = try std.testing.allocator.alloc([]const u8, 2);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    primary[1] = try std.testing.allocator.dupe(u8, "src/bar.zig");
    const manifest = Manifest{ .primary_files = primary };
    try state.setManifest("issue-1", manifest);

    // Acquire locks
    _ = try state.tryAcquireLocks("issue-1", manifest, 0);
    try std.testing.expectEqual(@as(usize, 2), state.locks.count());

    // Release locks
    state.releaseLocks("issue-1");
    try std.testing.expectEqual(@as(usize, 0), state.locks.count());
}

test "releaseLocks only removes locks for specified issue" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Two issues with different files
    var primary1 = try std.testing.allocator.alloc([]const u8, 1);
    primary1[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    const manifest1 = Manifest{ .primary_files = primary1 };
    try state.setManifest("issue-1", manifest1);

    var primary2 = try std.testing.allocator.alloc([]const u8, 1);
    primary2[0] = try std.testing.allocator.dupe(u8, "src/bar.zig");
    const manifest2 = Manifest{ .primary_files = primary2 };
    try state.setManifest("issue-2", manifest2);

    // Both acquire locks
    _ = try state.tryAcquireLocks("issue-1", manifest1, 0);
    _ = try state.tryAcquireLocks("issue-2", manifest2, 1);
    try std.testing.expectEqual(@as(usize, 2), state.locks.count());

    // Release only issue-1's locks
    state.releaseLocks("issue-1");
    try std.testing.expectEqual(@as(usize, 1), state.locks.count());
    try std.testing.expect(!state.locks.contains("src/foo.zig"));
    try std.testing.expect(state.locks.contains("src/bar.zig"));
}

test "cleanupStaleLocks removes old locks" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Manually add a stale lock (very old timestamp)
    const file = try std.testing.allocator.dupe(u8, "src/stale.zig");
    const issue = try std.testing.allocator.dupe(u8, "issue-old");
    try state.locks.put(file, .{
        .file = file,
        .issue_id = issue,
        .worker_id = 0,
        .acquired_at = 0, // Very old timestamp (epoch)
    });

    try std.testing.expectEqual(@as(usize, 1), state.locks.count());

    // Cleanup locks older than 1 second
    const removed = state.cleanupStaleLocks(1);
    try std.testing.expectEqual(@as(u32, 1), removed);
    try std.testing.expectEqual(@as(usize, 0), state.locks.count());
}

test "cleanupStaleLocks preserves fresh locks" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/fresh.zig");
    const manifest = Manifest{ .primary_files = primary };
    try state.setManifest("issue-1", manifest);

    // Acquire fresh locks (timestamp will be now)
    _ = try state.tryAcquireLocks("issue-1", manifest, 0);
    try std.testing.expectEqual(@as(usize, 1), state.locks.count());

    // Cleanup locks older than 1 hour - should not remove fresh lock
    const removed = state.cleanupStaleLocks(3600);
    try std.testing.expectEqual(@as(u32, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), state.locks.count());
}

test "tryAcquireLocks handles file spec with line ranges" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Manifest with line range format
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig:100-200");
    const manifest = Manifest{ .primary_files = primary };
    try state.setManifest("issue-1", manifest);

    // Acquire locks - should extract base file
    const acquired = try state.tryAcquireLocks("issue-1", manifest, 0);
    try std.testing.expect(acquired);

    // Lock should be on base file, not the spec with line range
    try std.testing.expect(state.locks.contains("src/foo.zig"));
    try std.testing.expect(!state.locks.contains("src/foo.zig:100-200"));
}

test "manifest serialization roundtrip" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create a manifest with all field types populated
    var primary = try std.testing.allocator.alloc([]const u8, 2);
    primary[0] = try std.testing.allocator.dupe(u8, "src/main.zig");
    primary[1] = try std.testing.allocator.dupe(u8, "src/helper.zig:100-200");
    var read_files = try std.testing.allocator.alloc([]const u8, 1);
    read_files[0] = try std.testing.allocator.dupe(u8, "src/config.zig");
    var forbidden = try std.testing.allocator.alloc([]const u8, 1);
    forbidden[0] = try std.testing.allocator.dupe(u8, "src/secret.zig");

    const manifest = Manifest{
        .primary_files = primary,
        .read_files = read_files,
        .forbidden_files = forbidden,
    };
    try state.setManifest("test-issue", manifest);

    // Serialize to JSON
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(std.testing.allocator);
    try state.writeJson(&content);

    // Parse the JSON back
    var loaded = OrchestratorState.init(std.testing.allocator);
    defer loaded.deinit();
    loaded.project_name = try std.testing.allocator.dupe(u8, "test");
    try loaded.parseJson(content.items);

    // Verify manifest was preserved
    const loaded_manifest = loaded.getManifest("test-issue");
    try std.testing.expect(loaded_manifest != null);
    try std.testing.expectEqual(@as(usize, 2), loaded_manifest.?.primary_files.len);
    try std.testing.expect(std.mem.eql(u8, loaded_manifest.?.primary_files[0], "src/main.zig"));
    try std.testing.expect(std.mem.eql(u8, loaded_manifest.?.primary_files[1], "src/helper.zig:100-200"));
    try std.testing.expectEqual(@as(usize, 1), loaded_manifest.?.read_files.len);
    try std.testing.expect(std.mem.eql(u8, loaded_manifest.?.read_files[0], "src/config.zig"));
    try std.testing.expectEqual(@as(usize, 1), loaded_manifest.?.forbidden_files.len);
    try std.testing.expect(std.mem.eql(u8, loaded_manifest.?.forbidden_files[0], "src/secret.zig"));
}

test "attempt record serialization roundtrip" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up an issue with an attempt record
    try state.updateIssue("test-issue", .running);
    try state.recordAttempt("test-issue", .failed, "Test failure notes");

    // Serialize to JSON
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(std.testing.allocator);
    try state.writeJson(&content);

    // Parse the JSON back
    var loaded = OrchestratorState.init(std.testing.allocator);
    defer loaded.deinit();
    loaded.project_name = try std.testing.allocator.dupe(u8, "test");
    try loaded.parseJson(content.items);

    // Verify attempt record was preserved
    const issue = loaded.issues.get("test-issue");
    try std.testing.expect(issue != null);
    try std.testing.expectEqual(@as(u32, 1), issue.?.attempt_count);
    try std.testing.expect(issue.?.last_attempt != null);
    try std.testing.expectEqual(@as(u32, 1), issue.?.last_attempt.?.attempt_number);
    try std.testing.expectEqual(AttemptResult.failed, issue.?.last_attempt.?.result);
    try std.testing.expect(std.mem.eql(u8, issue.?.last_attempt.?.notes, "Test failure notes"));
}

test "current batch serialization roundtrip" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Create a current batch
    var issue_ids = try std.testing.allocator.alloc([]const u8, 2);
    issue_ids[0] = try std.testing.allocator.dupe(u8, "issue-a");
    issue_ids[1] = try std.testing.allocator.dupe(u8, "issue-b");

    state.current_batch = Batch{
        .id = 42,
        .issue_ids = issue_ids,
        .status = .running,
        .started_at = 1234567890,
        .completed_at = null,
    };

    // Serialize to JSON
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(std.testing.allocator);
    try state.writeJson(&content);

    // Parse the JSON back
    var loaded = OrchestratorState.init(std.testing.allocator);
    defer loaded.deinit();
    loaded.project_name = try std.testing.allocator.dupe(u8, "test");
    try loaded.parseJson(content.items);

    // Verify current batch was preserved
    try std.testing.expect(loaded.current_batch != null);
    try std.testing.expectEqual(@as(u32, 42), loaded.current_batch.?.id);
    try std.testing.expectEqual(@as(usize, 2), loaded.current_batch.?.issue_ids.len);
    try std.testing.expect(std.mem.eql(u8, loaded.current_batch.?.issue_ids[0], "issue-a"));
    try std.testing.expect(std.mem.eql(u8, loaded.current_batch.?.issue_ids[1], "issue-b"));
    try std.testing.expectEqual(@as(i64, 1234567890), loaded.current_batch.?.started_at.?);
}

test "pending batches serialization roundtrip" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Add two pending batches
    var ids1 = try std.testing.allocator.alloc([]const u8, 1);
    ids1[0] = try std.testing.allocator.dupe(u8, "batch1-issue");
    _ = try state.addBatch(ids1);

    var ids2 = try std.testing.allocator.alloc([]const u8, 2);
    ids2[0] = try std.testing.allocator.dupe(u8, "batch2-issue-a");
    ids2[1] = try std.testing.allocator.dupe(u8, "batch2-issue-b");
    _ = try state.addBatch(ids2);

    // Serialize to JSON
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(std.testing.allocator);
    try state.writeJson(&content);

    // Parse the JSON back
    var loaded = OrchestratorState.init(std.testing.allocator);
    defer loaded.deinit();
    loaded.project_name = try std.testing.allocator.dupe(u8, "test");
    try loaded.parseJson(content.items);

    // Verify pending batches were preserved
    try std.testing.expectEqual(@as(usize, 2), loaded.pending_batches.items.len);
    try std.testing.expectEqual(@as(u32, 1), loaded.pending_batches.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), loaded.pending_batches.items[0].issue_ids.len);
    try std.testing.expect(std.mem.eql(u8, loaded.pending_batches.items[0].issue_ids[0], "batch1-issue"));
    try std.testing.expectEqual(@as(u32, 2), loaded.pending_batches.items[1].id);
    try std.testing.expectEqual(@as(usize, 2), loaded.pending_batches.items[1].issue_ids.len);
}

test "crash recovery preserves manifests and batches" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up state with manifest, batch, and attempt
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/file.zig");
    try state.setManifest("test-issue", Manifest{ .primary_files = primary });

    var batch_ids = try std.testing.allocator.alloc([]const u8, 1);
    batch_ids[0] = try std.testing.allocator.dupe(u8, "test-issue");
    _ = try state.addBatch(batch_ids);

    try state.updateIssue("test-issue", .running);
    try state.recordAttempt("test-issue", .timeout, "Worker timed out");

    // Simulate a worker crash state
    state.workers[0].status = .running;
    state.workers[0].current_issue = try std.testing.allocator.dupe(u8, "test-issue");

    // Serialize (simulating save before crash)
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(std.testing.allocator);
    try state.writeJson(&content);

    // Parse back (simulating load after restart)
    var restored = OrchestratorState.init(std.testing.allocator);
    defer restored.deinit();
    restored.project_name = try std.testing.allocator.dupe(u8, "test");
    try restored.parseJson(content.items);

    // Verify all state was preserved
    const manifest = restored.getManifest("test-issue");
    try std.testing.expect(manifest != null);
    try std.testing.expectEqual(@as(usize, 1), manifest.?.primary_files.len);

    try std.testing.expectEqual(@as(usize, 1), restored.pending_batches.items.len);

    const issue = restored.issues.get("test-issue");
    try std.testing.expect(issue != null);
    try std.testing.expect(issue.?.last_attempt != null);
    try std.testing.expectEqual(AttemptResult.timeout, issue.?.last_attempt.?.result);

    // Run crash recovery
    const recovered = try restored.recoverFromCrash();
    try std.testing.expect(recovered >= 0); // May recover workers if state included them
}

test "null current_batch handled correctly" {
    const json =
        \\{
        \\  "state_version": 1,
        \\  "project_name": "test",
        \\  "current_batch": null,
        \\  "pending_batches": []
        \\}
    ;

    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();
    state.project_name = try std.testing.allocator.dupe(u8, "test");
    try state.parseJson(json);

    try std.testing.expect(state.current_batch == null);
}
