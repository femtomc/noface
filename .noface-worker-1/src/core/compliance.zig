//! Manifest compliance verification.
//!
//! Checks that agent file modifications comply with declared manifests.
//! Provides baseline capture, diff analysis, and rollback capabilities.
//!
//! This module centralizes compliance logic used by both sequential (loop.zig)
//! and parallel (worker_pool.zig) execution paths.

const std = @import("std");
const state_mod = @import("state.zig");
const jj = @import("../vcs/jj.zig");

const OrchestratorState = state_mod.OrchestratorState;
const Manifest = state_mod.Manifest;

/// Result of manifest compliance check
pub const ComplianceResult = state_mod.ManifestComplianceResult;

/// Instrumentation data for tracking manifest prediction accuracy
pub const Instrumentation = state_mod.ManifestInstrumentation;

/// Baseline of changed files captured before agent runs
pub const Baseline = struct {
    files: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Baseline) void {
        for (self.files) |f| self.allocator.free(f);
        if (self.files.len > 0) self.allocator.free(self.files);
        self.files = &.{};
    }

    pub fn isEmpty(self: *const Baseline) bool {
        return self.files.len == 0;
    }
};

/// ComplianceChecker provides manifest compliance verification.
///
/// Ensures agent file modifications comply with declared manifests by:
/// - Capturing baseline of pre-existing changes before agent runs
/// - Verifying modifications against manifest rules
/// - Supporting rollback of violating files
/// - Computing instrumentation metrics for manifest accuracy tracking
pub const ComplianceChecker = struct {
    allocator: std.mem.Allocator,
    state: ?*OrchestratorState = null,

    pub fn init(allocator: std.mem.Allocator) ComplianceChecker {
        return .{ .allocator = allocator };
    }

    pub fn initWithState(allocator: std.mem.Allocator, state: *OrchestratorState) ComplianceChecker {
        return .{ .allocator = allocator, .state = state };
    }

    /// Capture baseline of changed files before agent runs.
    /// Returns list of file paths that were already modified or untracked.
    /// The baseline is used to exclude pre-existing changes from compliance checks.
    pub fn captureBaseline(self: *ComplianceChecker) !Baseline {
        var repo = jj.JjRepo.init(self.allocator);
        var changed = try repo.getAllChangedFiles();
        // Don't defer deinit - we need to copy strings first before freeing

        var baseline = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (baseline.items) |f| self.allocator.free(f);
            baseline.deinit(self.allocator);
        }

        // Copy all unique files (jj uses modified/added/deleted)
        for (changed.modified) |f| {
            try baseline.append(self.allocator, try self.allocator.dupe(u8, f));
        }
        for (changed.added) |f| {
            if (!isInList(baseline.items, f)) {
                try baseline.append(self.allocator, try self.allocator.dupe(u8, f));
            }
        }
        for (changed.deleted) |f| {
            if (!isInList(baseline.items, f)) {
                try baseline.append(self.allocator, try self.allocator.dupe(u8, f));
            }
        }

        // Now safe to free the original changed files
        changed.deinit();

        return .{
            .files = try baseline.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Verify that agent changes comply with the issue's manifest.
    /// baseline: files that were already modified before agent ran
    /// Returns compliance result with details of any violations and instrumentation data.
    pub fn verify(self: *ComplianceChecker, issue_id: []const u8, baseline: *const Baseline) !ComplianceResult {
        // Get manifest for this issue
        const manifest = if (self.state) |s| s.getManifest(issue_id) else null;

        // No manifest means no restrictions (legacy behavior)
        if (manifest == null) {
            return .{ .compliant = true };
        }
        const m = manifest.?;

        // Get all changed files using jj module
        var repo = jj.JjRepo.init(self.allocator);
        var changed = try repo.getAllChangedFiles();
        defer changed.deinit();

        // Collect all changed files into a single list
        var all_changed = std.ArrayListUnmanaged([]const u8){};
        defer all_changed.deinit(self.allocator);

        for (changed.modified) |f| {
            try all_changed.append(self.allocator, f);
        }
        for (changed.added) |f| {
            if (!isInList(all_changed.items, f)) {
                try all_changed.append(self.allocator, f);
            }
        }
        for (changed.deleted) |f| {
            if (!isInList(all_changed.items, f)) {
                try all_changed.append(self.allocator, f);
            }
        }

        return self.verifyFiles(m, baseline.files, all_changed.items);
    }

    /// Verify compliance for a specific list of changed files.
    /// This allows callers to provide filtered file lists (e.g., excluding other workers' files).
    pub fn verifyFiles(
        self: *ComplianceChecker,
        manifest: Manifest,
        baseline: []const []const u8,
        changed_files: []const []const u8,
    ) !ComplianceResult {
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

        // Process all changed files
        for (changed_files) |file| {
            // Skip files that were already modified before agent ran
            if (isInList(baseline, file)) continue;

            // Track all touched files for instrumentation
            if (!isInList(all_touched.items, file)) {
                try all_touched.append(self.allocator, try self.allocator.dupe(u8, file));
            }

            // Check if file is forbidden
            if (manifest.isForbidden(file)) {
                if (!isInList(forbidden_touched.items, file)) {
                    try forbidden_touched.append(self.allocator, try self.allocator.dupe(u8, file));
                }
            } else if (!manifest.allowsWrite(file)) {
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
        for (manifest.primary_files) |pf| {
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

    /// Rollback files that violated the manifest.
    /// Uses jj restore to revert files to their parent state.
    pub fn rollback(self: *ComplianceChecker, result: *const ComplianceResult) !void {
        var repo = jj.JjRepo.init(self.allocator);

        // Rollback unauthorized files
        for (result.unauthorized_files) |file| {
            try repo.rollbackFile(file);
        }

        // Rollback forbidden files
        for (result.forbidden_files_touched) |file| {
            try repo.rollbackFile(file);
        }
    }

    /// Get all files that need to be rolled back from a compliance result.
    /// Caller does NOT own the returned slice (points to result's internal data).
    pub fn getViolatingFiles(self: *ComplianceChecker, result: *const ComplianceResult) ![]const []const u8 {
        var files = std.ArrayListUnmanaged([]const u8){};
        errdefer files.deinit(self.allocator);

        for (result.unauthorized_files) |f| {
            try files.append(self.allocator, f);
        }
        for (result.forbidden_files_touched) |f| {
            try files.append(self.allocator, f);
        }

        return files.toOwnedSlice(self.allocator);
    }

    /// Get count of total violations.
    pub fn violationCount(result: *const ComplianceResult) usize {
        return result.unauthorized_files.len + result.forbidden_files_touched.len;
    }
};

/// Log compliance result details for debugging.
pub fn logComplianceResult(result: *const ComplianceResult, issue_id: []const u8) void {
    if (result.compliant) {
        logInfo("Issue {s}: Manifest compliance verified", .{issue_id});
    } else {
        logWarn("Issue {s}: Manifest violation detected!", .{issue_id});

        if (result.forbidden_files_touched.len > 0) {
            logWarn("Forbidden files touched: {d}", .{result.forbidden_files_touched.len});
            for (result.forbidden_files_touched) |f| {
                logWarn("  - {s}", .{f});
            }
        }
        if (result.unauthorized_files.len > 0) {
            logWarn("Unauthorized files modified: {d}", .{result.unauthorized_files.len});
            for (result.unauthorized_files) |f| {
                logWarn("  - {s}", .{f});
            }
        }
    }
}

/// Log instrumentation metrics for a compliance result.
pub fn logInstrumentation(result: *const ComplianceResult, allocator: std.mem.Allocator, verbose: bool) void {
    const inst = result.instrumentation orelse return;

    const predicted_count = inst.manifest_files_predicted.len;
    const touched_count = inst.files_actually_touched.len;
    const false_pos = inst.countFalsePositives();
    const false_neg = inst.countFalseNegatives();

    logInfo("Manifest instrumentation: predicted={d}, touched={d}, false_positives={d}, false_negatives={d}", .{
        predicted_count,
        touched_count,
        false_pos,
        false_neg,
    });

    if (inst.computeAccuracy()) |accuracy| {
        logInfo("Manifest accuracy: {d:.1}%", .{accuracy});
    }

    if (verbose) {
        if (predicted_count > 0) {
            std.debug.print("  Manifest predicted files:\n", .{});
            for (inst.manifest_files_predicted) |f| {
                std.debug.print("    - {s}\n", .{f});
            }
        }
        if (touched_count > 0) {
            std.debug.print("  Files actually touched:\n", .{});
            for (inst.files_actually_touched) |f| {
                std.debug.print("    - {s}\n", .{f});
            }
        }

        // Log false positives (predicted but not touched)
        if (false_pos > 0) {
            std.debug.print("  False positives (predicted but not touched):\n", .{});
            const fp_files = inst.getFalsePositives(allocator) catch return;
            defer {
                for (fp_files) |f| allocator.free(f);
                if (fp_files.len > 0) allocator.free(fp_files);
            }
            for (fp_files) |f| {
                std.debug.print("    - {s}\n", .{f});
            }
        }

        // Log false negatives (touched but not predicted)
        if (false_neg > 0) {
            std.debug.print("  False negatives (touched but not predicted):\n", .{});
            const fn_files = inst.getFalseNegatives(allocator) catch return;
            defer {
                for (fn_files) |f| allocator.free(f);
                if (fn_files.len > 0) allocator.free(fn_files);
            }
            for (fn_files) |f| {
                std.debug.print("    - {s}\n", .{f});
            }
        }
    }
}

// === Helpers ===

fn isInList(list: []const []const u8, file: []const u8) bool {
    for (list) |f| {
        if (std.mem.eql(u8, f, file)) return true;
    }
    return false;
}

// === Logging ===

const Color = struct {
    const reset = "\x1b[0m";
    const blue = "\x1b[0;34m";
    const yellow = "\x1b[1;33m";
};

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[COMPLIANCE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[COMPLIANCE]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

// === Tests ===

test "ComplianceChecker init" {
    const checker = ComplianceChecker.init(std.testing.allocator);
    _ = checker;
}

test "Baseline deinit empty" {
    var baseline = Baseline{
        .files = &.{},
        .allocator = std.testing.allocator,
    };
    baseline.deinit();
    try std.testing.expect(baseline.isEmpty());
}

test "isInList finds matching file" {
    const list = &[_][]const u8{ "file1.zig", "file2.zig", "file3.zig" };
    try std.testing.expect(isInList(list, "file2.zig"));
    try std.testing.expect(!isInList(list, "file4.zig"));
}

test "ComplianceResult no manifest means compliant" {
    var checker = ComplianceChecker.init(std.testing.allocator);
    // Without state, no manifest exists
    var baseline = Baseline{
        .files = &.{},
        .allocator = std.testing.allocator,
    };
    defer baseline.deinit();

    var result = try checker.verify("test-issue", &baseline);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.compliant);
}

test "violationCount returns sum of violations" {
    var result = ComplianceResult{
        .compliant = false,
        .unauthorized_files = &[_][]const u8{ "a.zig", "b.zig" },
        .forbidden_files_touched = &[_][]const u8{"c.zig"},
    };
    try std.testing.expectEqual(@as(usize, 3), ComplianceChecker.violationCount(&result));
}
