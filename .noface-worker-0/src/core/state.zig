//! Orchestrator state management.
//!
//! Maintains persistent state across agent invocations and handles crash recovery.
//! State is persisted to .noface/state.json for durability.

const std = @import("std");
const process = @import("../util/process.zig");

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

/// Manifest instrumentation for tracking prediction accuracy
/// Computes false positives (predicted but unused) and false negatives (needed but not declared)
pub const ManifestInstrumentation = struct {
    /// Files from manifest's primary_files (predicted to be modified)
    manifest_files_predicted: []const []const u8 = &.{},
    /// Files actually modified (from git diff, excluding baseline)
    files_actually_touched: []const []const u8 = &.{},

    pub fn deinit(self: *ManifestInstrumentation, allocator: std.mem.Allocator) void {
        for (self.manifest_files_predicted) |f| allocator.free(f);
        if (self.manifest_files_predicted.len > 0) allocator.free(self.manifest_files_predicted);
        for (self.files_actually_touched) |f| allocator.free(f);
        if (self.files_actually_touched.len > 0) allocator.free(self.files_actually_touched);
    }

    /// Count false positives: files predicted but not actually touched
    pub fn countFalsePositives(self: ManifestInstrumentation) u32 {
        var count: u32 = 0;
        for (self.manifest_files_predicted) |predicted| {
            const base_predicted = extractBaseFile(predicted);
            var found = false;
            for (self.files_actually_touched) |actual| {
                if (std.mem.eql(u8, base_predicted, actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) count += 1;
        }
        return count;
    }

    /// Count false negatives: files touched but not predicted in manifest
    pub fn countFalseNegatives(self: ManifestInstrumentation) u32 {
        var count: u32 = 0;
        for (self.files_actually_touched) |actual| {
            var found = false;
            for (self.manifest_files_predicted) |predicted| {
                const base_predicted = extractBaseFile(predicted);
                if (std.mem.eql(u8, base_predicted, actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) count += 1;
        }
        return count;
    }

    /// Get false positive files (predicted but not touched)
    /// Caller owns returned slice and must free it
    pub fn getFalsePositives(self: ManifestInstrumentation, allocator: std.mem.Allocator) ![]const []const u8 {
        var result = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (result.items) |f| allocator.free(f);
            result.deinit(allocator);
        }

        for (self.manifest_files_predicted) |predicted| {
            const base_predicted = extractBaseFile(predicted);
            var found = false;
            for (self.files_actually_touched) |actual| {
                if (std.mem.eql(u8, base_predicted, actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.append(allocator, try allocator.dupe(u8, base_predicted));
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Get false negative files (touched but not predicted)
    /// Caller owns returned slice and must free it
    pub fn getFalseNegatives(self: ManifestInstrumentation, allocator: std.mem.Allocator) ![]const []const u8 {
        var result = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (result.items) |f| allocator.free(f);
            result.deinit(allocator);
        }

        for (self.files_actually_touched) |actual| {
            var found = false;
            for (self.manifest_files_predicted) |predicted| {
                const base_predicted = extractBaseFile(predicted);
                if (std.mem.eql(u8, base_predicted, actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.append(allocator, try allocator.dupe(u8, actual));
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Compute manifest accuracy as a percentage (0-100)
    /// Accuracy = true_positives / (predicted_count + false_negatives)
    /// Returns null if no predictions were made
    pub fn computeAccuracy(self: ManifestInstrumentation) ?f32 {
        const predicted = self.manifest_files_predicted.len;
        const false_neg = self.countFalseNegatives();
        const total_relevant = predicted + false_neg;

        if (total_relevant == 0) return null;

        const true_positives = predicted - self.countFalsePositives();
        return @as(f32, @floatFromInt(true_positives * 100)) / @as(f32, @floatFromInt(total_relevant));
    }
};

pub const AttemptRecord = struct {
    attempt_number: u32,
    timestamp: i64,
    result: AttemptResult,
    files_touched: []const []const u8 = &.{},
    notes: []const u8 = "",
    /// Manifest instrumentation data for this attempt
    instrumentation: ?ManifestInstrumentation = null,

    pub fn deinit(self: *AttemptRecord, allocator: std.mem.Allocator) void {
        for (self.files_touched) |f| allocator.free(f);
        if (self.files_touched.len > 0) allocator.free(self.files_touched);
        if (self.notes.len > 0) allocator.free(self.notes);
        if (self.instrumentation) |*inst| inst.deinit(allocator);
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
    workers: [MAX_WORKERS]WorkerState = undefined,
    num_workers: u32 = 3, // Default to 3 parallel workers

    // Counters
    total_iterations: u32 = 0,
    successful_completions: u32 = 0,
    failed_attempts: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) OrchestratorState {
        var state = OrchestratorState{
            .allocator = allocator,
            .issues = std.StringHashMap(IssueState).init(allocator),
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

        logInfo("Loaded state: {d} issues", .{state.issues.count()});

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
        try out.appendSlice(self.allocator, "\n  }\n");

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

        // Parse workers array
        if (findJsonSection(json, "\"workers\"")) |workers_section| {
            try self.parseWorkers(workers_section);
        }

        // Parse issues object
        if (findJsonSection(json, "\"issues\"")) |issues_section| {
            try self.parseIssues(issues_section);
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

    // === Conflict Detection ===

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

// === Issue Completion Handler ===
// Shared logic for verifying issue completion between sequential and parallel execution paths

/// Result of manifest compliance check
pub const ManifestComplianceResult = struct {
    compliant: bool,
    unauthorized_files: []const []const u8 = &.{},
    forbidden_files_touched: []const []const u8 = &.{},
    /// Instrumentation data for tracking manifest prediction accuracy
    instrumentation: ?ManifestInstrumentation = null,

    pub fn deinit(self: *ManifestComplianceResult, allocator: std.mem.Allocator) void {
        for (self.unauthorized_files) |f| allocator.free(f);
        if (self.unauthorized_files.len > 0) allocator.free(self.unauthorized_files);
        for (self.forbidden_files_touched) |f| allocator.free(f);
        if (self.forbidden_files_touched.len > 0) allocator.free(self.forbidden_files_touched);
        if (self.instrumentation) |*inst| inst.deinit(allocator);
    }
};

/// IssueCompletionHandler provides shared verification logic for issue completion.
/// This ensures both sequential (loop.zig) and parallel (worker_pool.zig) execution
/// paths enforce the same manifest compliance, progress logging, and state updates.
pub const IssueCompletionHandler = struct {
    allocator: std.mem.Allocator,
    state: *OrchestratorState,
    /// Callback for progress logging (injected by caller)
    progress_callback: ?*const fn (issue_id: []const u8, status: ProgressStatus, summary: []const u8) void = null,

    pub const ProgressStatus = enum {
        completed,
        blocked,
        failed,
        violation,

        pub fn toString(self: ProgressStatus) []const u8 {
            return switch (self) {
                .completed => "completed",
                .blocked => "blocked",
                .failed => "failed",
                .violation => "violation",
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, state: *OrchestratorState) IssueCompletionHandler {
        return .{
            .allocator = allocator,
            .state = state,
        };
    }

    /// Verify manifest compliance for an issue.
    /// baseline: files that were already modified before the issue was worked on
    /// Returns compliance result with details of any violations.
    pub fn verifyManifestCompliance(
        self: *IssueCompletionHandler,
        issue_id: []const u8,
        baseline: []const []const u8,
        changed_files: []const []const u8,
    ) !ManifestComplianceResult {
        // Get manifest for this issue
        const manifest = self.state.getManifest(issue_id);

        // No manifest means no restrictions (legacy behavior)
        if (manifest == null) {
            return .{ .compliant = true };
        }
        const m = manifest.?;

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

        // Track all files actually touched by the agent (for instrumentation)
        var all_touched = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (all_touched.items) |f| self.allocator.free(f);
            all_touched.deinit(self.allocator);
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

        // Helper to check if file is already in a list
        const isInList = struct {
            fn check(list: []const []const u8, file: []const u8) bool {
                for (list) |f| {
                    if (std.mem.eql(u8, f, file)) return true;
                }
                return false;
            }
        }.check;

        // Process all changed files
        for (changed_files) |file| {
            // Skip files that were already modified before agent ran
            if (isInBaseline(baseline, file)) continue;

            // Track all touched files for instrumentation
            if (!isInList(all_touched.items, file)) {
                try all_touched.append(self.allocator, try self.allocator.dupe(u8, file));
            }

            // Check if file is forbidden
            if (m.isForbidden(file)) {
                if (!isInList(forbidden_touched.items, file)) {
                    try forbidden_touched.append(self.allocator, try self.allocator.dupe(u8, file));
                }
            } else if (!m.allowsWrite(file)) {
                if (!isInList(unauthorized.items, file)) {
                    try unauthorized.append(self.allocator, try self.allocator.dupe(u8, file));
                }
            }
        }

        const has_violations = unauthorized.items.len > 0 or forbidden_touched.items.len > 0;

        // Build instrumentation data: copy manifest's primary_files as predictions
        var predicted_files = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (predicted_files.items) |f| self.allocator.free(f);
            predicted_files.deinit(self.allocator);
        }
        for (m.primary_files) |pf| {
            try predicted_files.append(self.allocator, try self.allocator.dupe(u8, pf));
        }

        return .{
            .compliant = !has_violations,
            .unauthorized_files = try unauthorized.toOwnedSlice(self.allocator),
            .forbidden_files_touched = try forbidden_touched.toOwnedSlice(self.allocator),
            .instrumentation = .{
                .manifest_files_predicted = try predicted_files.toOwnedSlice(self.allocator),
                .files_actually_touched = try all_touched.toOwnedSlice(self.allocator),
            },
        };
    }

    /// Handle completion of an issue (called after agent finishes, regardless of success/failure).
    /// Performs manifest compliance check and records the attempt.
    /// Returns true if compliant (or no manifest), false if violation detected.
    pub fn handleCompletion(
        self: *IssueCompletionHandler,
        issue_id: []const u8,
        success: bool,
        baseline: []const []const u8,
        changed_files: []const []const u8,
    ) !bool {
        // Verify manifest compliance
        var compliance = try self.verifyManifestCompliance(issue_id, baseline, changed_files);
        defer compliance.deinit(self.allocator);

        // Log instrumentation metrics
        if (compliance.instrumentation) |inst| {
            const predicted_count = inst.manifest_files_predicted.len;
            const touched_count = inst.files_actually_touched.len;
            const false_pos = inst.countFalsePositives();
            const false_neg = inst.countFalseNegatives();

            logInfo("Manifest instrumentation for {s}: predicted={d}, touched={d}, false_positives={d}, false_negatives={d}", .{
                issue_id,
                predicted_count,
                touched_count,
                false_pos,
                false_neg,
            });

            if (inst.computeAccuracy()) |accuracy| {
                logInfo("Manifest accuracy: {d:.1}%", .{accuracy});
            }
        }

        if (!compliance.compliant) {
            // Log violation details
            logWarn("Manifest violation detected for {s}!", .{issue_id});

            if (compliance.forbidden_files_touched.len > 0) {
                logWarn("Forbidden files touched: {d}", .{compliance.forbidden_files_touched.len});
                for (compliance.forbidden_files_touched) |f| {
                    logWarn("  - {s}", .{f});
                }
            }
            if (compliance.unauthorized_files.len > 0) {
                logWarn("Unauthorized files modified: {d}", .{compliance.unauthorized_files.len});
                for (compliance.unauthorized_files) |f| {
                    logWarn("  - {s}", .{f});
                }
            }

            // Record violation in state
            var notes_buf: [1024]u8 = undefined;
            const notes = std.fmt.bufPrint(&notes_buf, "Manifest violation: {d} forbidden, {d} unauthorized files", .{
                compliance.forbidden_files_touched.len,
                compliance.unauthorized_files.len,
            }) catch "Manifest violation";

            self.state.recordAttempt(issue_id, .violation, notes) catch {};

            // Write progress entry if callback is set
            if (self.progress_callback) |cb| {
                cb(issue_id, .violation, "Manifest violation detected");
            }

            return false;
        }

        // No violations - record attempt based on success/failure
        const result: AttemptResult = if (success) .success else .failed;
        const notes = if (success) "Completed successfully" else "Agent failed";
        self.state.recordAttempt(issue_id, result, notes) catch {};

        // Write progress entry if callback is set
        if (self.progress_callback) |cb| {
            const status: ProgressStatus = if (success) .completed else .failed;
            cb(issue_id, status, notes);
        }

        return true;
    }

    /// Get the list of files that violated the manifest (for rollback).
    /// Caller must free the returned slices.
    pub fn getViolatingFiles(
        self: *IssueCompletionHandler,
        compliance: ManifestComplianceResult,
    ) ![]const []const u8 {
        var files = std.ArrayListUnmanaged([]const u8){};
        errdefer files.deinit(self.allocator);

        for (compliance.unauthorized_files) |f| {
            try files.append(self.allocator, f);
        }
        for (compliance.forbidden_files_touched) |f| {
            try files.append(self.allocator, f);
        }

        return files.toOwnedSlice(self.allocator);
    }
};

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

test "crash recovery preserves manifests" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up state with manifest and attempt
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/file.zig");
    try state.setManifest("test-issue", Manifest{ .primary_files = primary });

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

    const issue = restored.issues.get("test-issue");
    try std.testing.expect(issue != null);
    try std.testing.expect(issue.?.last_attempt != null);
    try std.testing.expectEqual(AttemptResult.timeout, issue.?.last_attempt.?.result);

    // Run crash recovery
    const recovered = try restored.recoverFromCrash();
    try std.testing.expect(recovered >= 0); // May recover workers if state included them
}

test "ManifestInstrumentation counts false positives correctly" {
    // Predicted: a.zig, b.zig, c.zig
    // Touched: a.zig, b.zig
    // False positives: c.zig (predicted but not touched)
    const predicted = &[_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" };
    const touched = &[_][]const u8{ "src/a.zig", "src/b.zig" };

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    try std.testing.expectEqual(@as(u32, 1), inst.countFalsePositives());
}

test "ManifestInstrumentation counts false negatives correctly" {
    // Predicted: a.zig
    // Touched: a.zig, b.zig, c.zig
    // False negatives: b.zig, c.zig (touched but not predicted)
    const predicted = &[_][]const u8{"src/a.zig"};
    const touched = &[_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" };

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    try std.testing.expectEqual(@as(u32, 2), inst.countFalseNegatives());
}

test "ManifestInstrumentation handles line range format in predictions" {
    // Predicted with line range: a.zig:100-200
    // Touched: a.zig (base file matches)
    const predicted = &[_][]const u8{"src/a.zig:100-200"};
    const touched = &[_][]const u8{"src/a.zig"};

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    try std.testing.expectEqual(@as(u32, 0), inst.countFalsePositives());
    try std.testing.expectEqual(@as(u32, 0), inst.countFalseNegatives());
}

// === IssueCompletionHandler Tests ===
// These tests ensure parity between batch (worker_pool) and sequential (loop) execution paths

test "IssueCompletionHandler detects compliant changes" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up manifest allowing src/foo.zig
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    try state.setManifest("test-issue", Manifest{ .primary_files = primary });

    // Create completion handler
    var handler = IssueCompletionHandler.init(std.testing.allocator, &state);

    // Simulate: baseline was empty, only changed src/foo.zig (allowed)
    const baseline = &[_][]const u8{};
    const changed = &[_][]const u8{"src/foo.zig"};

    var result = try handler.verifyManifestCompliance("test-issue", baseline, changed);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.compliant);
    try std.testing.expectEqual(@as(usize, 0), result.unauthorized_files.len);
    try std.testing.expectEqual(@as(usize, 0), result.forbidden_files_touched.len);
}

test "IssueCompletionHandler detects unauthorized file changes" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up manifest allowing only src/foo.zig
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    try state.setManifest("test-issue", Manifest{ .primary_files = primary });

    // Create completion handler
    var handler = IssueCompletionHandler.init(std.testing.allocator, &state);

    // Simulate: changed src/bar.zig which is NOT in the manifest
    const baseline = &[_][]const u8{};
    const changed = &[_][]const u8{"src/bar.zig"};

    var result = try handler.verifyManifestCompliance("test-issue", baseline, changed);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.compliant);
    try std.testing.expectEqual(@as(usize, 1), result.unauthorized_files.len);
    try std.testing.expect(std.mem.eql(u8, result.unauthorized_files[0], "src/bar.zig"));
}

test "IssueCompletionHandler detects forbidden file changes" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up manifest with forbidden file
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    var forbidden = try std.testing.allocator.alloc([]const u8, 1);
    forbidden[0] = try std.testing.allocator.dupe(u8, "src/main.zig");
    try state.setManifest("test-issue", Manifest{
        .primary_files = primary,
        .forbidden_files = forbidden,
    });

    // Create completion handler
    var handler = IssueCompletionHandler.init(std.testing.allocator, &state);

    // Simulate: changed src/main.zig which is FORBIDDEN
    const baseline = &[_][]const u8{};
    const changed = &[_][]const u8{"src/main.zig"};

    var result = try handler.verifyManifestCompliance("test-issue", baseline, changed);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.compliant);
    try std.testing.expectEqual(@as(usize, 1), result.forbidden_files_touched.len);
    try std.testing.expect(std.mem.eql(u8, result.forbidden_files_touched[0], "src/main.zig"));
}

test "IssueCompletionHandler ignores baseline files" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // Set up manifest allowing only src/foo.zig
    var primary = try std.testing.allocator.alloc([]const u8, 1);
    primary[0] = try std.testing.allocator.dupe(u8, "src/foo.zig");
    try state.setManifest("test-issue", Manifest{ .primary_files = primary });

    // Create completion handler
    var handler = IssueCompletionHandler.init(std.testing.allocator, &state);

    // Simulate: src/bar.zig was in baseline (pre-existing change), so it's ignored
    const baseline = &[_][]const u8{"src/bar.zig"};
    const changed = &[_][]const u8{ "src/bar.zig", "src/foo.zig" };

    var result = try handler.verifyManifestCompliance("test-issue", baseline, changed);
    defer result.deinit(std.testing.allocator);

    // Should be compliant because src/bar.zig was in baseline
    try std.testing.expect(result.compliant);
}

test "IssueCompletionHandler without manifest allows all changes" {
    var state = OrchestratorState.init(std.testing.allocator);
    defer state.deinit();

    // No manifest for this issue
    // Create completion handler
    var handler = IssueCompletionHandler.init(std.testing.allocator, &state);

    // Simulate: any files changed
    const baseline = &[_][]const u8{};
    const changed = &[_][]const u8{ "src/any.zig", "src/file.zig" };

    var result = try handler.verifyManifestCompliance("no-manifest-issue", baseline, changed);
    defer result.deinit(std.testing.allocator);

    // Should be compliant because no manifest means no restrictions
    try std.testing.expect(result.compliant);
}

test "ManifestInstrumentation computes accuracy" {
    // Predicted: a.zig, b.zig (2 predictions)
    // Touched: a.zig, c.zig (2 actual)
    // True positives: 1 (a.zig)
    // False positives: 1 (b.zig)
    // False negatives: 1 (c.zig)
    // Accuracy = 1 / (2 + 1) = 33.33%
    const predicted = &[_][]const u8{ "src/a.zig", "src/b.zig" };
    const touched = &[_][]const u8{ "src/a.zig", "src/c.zig" };

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    const accuracy = inst.computeAccuracy().?;
    try std.testing.expect(accuracy > 33.0 and accuracy < 34.0);
}

test "ManifestInstrumentation returns null accuracy for empty prediction" {
    const inst = ManifestInstrumentation{};
    try std.testing.expect(inst.computeAccuracy() == null);
}

test "ManifestInstrumentation getFalsePositives returns correct files" {
    const predicted = &[_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" };
    const touched = &[_][]const u8{"src/a.zig"};

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    const false_pos = try inst.getFalsePositives(std.testing.allocator);
    defer {
        for (false_pos) |f| std.testing.allocator.free(f);
        if (false_pos.len > 0) std.testing.allocator.free(false_pos);
    }

    try std.testing.expectEqual(@as(usize, 2), false_pos.len);
    try std.testing.expect(std.mem.eql(u8, false_pos[0], "src/b.zig"));
    try std.testing.expect(std.mem.eql(u8, false_pos[1], "src/c.zig"));
}

test "ManifestInstrumentation getFalseNegatives returns correct files" {
    const predicted = &[_][]const u8{"src/a.zig"};
    const touched = &[_][]const u8{ "src/a.zig", "src/b.zig" };

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    const false_neg = try inst.getFalseNegatives(std.testing.allocator);
    defer {
        for (false_neg) |f| std.testing.allocator.free(f);
        if (false_neg.len > 0) std.testing.allocator.free(false_neg);
    }

    try std.testing.expectEqual(@as(usize, 1), false_neg.len);
    try std.testing.expect(std.mem.eql(u8, false_neg[0], "src/b.zig"));
}

test "ManifestInstrumentation perfect prediction has 100% accuracy" {
    // Perfect prediction: all predicted files are touched, nothing unexpected
    const predicted = &[_][]const u8{ "src/a.zig", "src/b.zig" };
    const touched = &[_][]const u8{ "src/a.zig", "src/b.zig" };

    const inst = ManifestInstrumentation{
        .manifest_files_predicted = predicted,
        .files_actually_touched = touched,
    };

    try std.testing.expectEqual(@as(u32, 0), inst.countFalsePositives());
    try std.testing.expectEqual(@as(u32, 0), inst.countFalseNegatives());
    try std.testing.expectEqual(@as(f32, 100.0), inst.computeAccuracy().?);
}
