//! SQLite-based transcript storage for noface sessions.
//!
//! Stores streaming JSON events from agent sessions in a compact SQLite database.
//! Database location: .noface/transcripts.db

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// Use SQLITE_STATIC (null) - strings must remain valid until sqlite3_step completes
// This is fine for our use case since we pass slices that remain valid during the call
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const TranscriptDb = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    const DB_PATH = ".noface/transcripts.db";

    /// Open or create the transcript database
    pub fn open(allocator: std.mem.Allocator) !TranscriptDb {
        // Ensure .noface directory exists
        std.fs.cwd().makeDir(".noface") catch |err| {
            if (err != error.PathAlreadyExists) return error.CannotCreateDir;
        };

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(DB_PATH, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.CannotOpenDatabase;
        }

        var self = TranscriptDb{
            .db = db,
            .allocator = allocator,
        };

        try self.initSchema();
        return self;
    }

    /// Close the database connection
    pub fn close(self: *TranscriptDb) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    /// Initialize database schema
    fn initSchema(self: *TranscriptDb) !void {
        const schema =
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    session_id TEXT UNIQUE NOT NULL,
            \\    issue_id TEXT NOT NULL,
            \\    worker_id INTEGER,
            \\    started_at INTEGER NOT NULL,
            \\    completed_at INTEGER,
            \\    exit_code INTEGER,
            \\    resuming INTEGER DEFAULT 0
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS events (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    session_id TEXT NOT NULL,
            \\    seq INTEGER NOT NULL,
            \\    timestamp INTEGER NOT NULL,
            \\    event_type TEXT,
            \\    tool_name TEXT,
            \\    content TEXT,
            \\    raw_json TEXT NOT NULL,
            \\    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
            \\CREATE INDEX IF NOT EXISTS idx_sessions_issue ON sessions(issue_id);
        ;

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, schema, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.SchemaInitFailed;
        }
    }

    /// Start a new session, returns session_id
    pub fn startSession(self: *TranscriptDb, issue_id: []const u8, worker_id: ?u32, resuming: bool) ![]const u8 {
        const timestamp = std.time.timestamp();

        // Generate unique session ID
        var session_id_buf: [64]u8 = undefined;
        const session_id = std.fmt.bufPrint(&session_id_buf, "{s}-{d}-{d}", .{
            issue_id,
            timestamp,
            if (worker_id) |w| w else 0,
        }) catch return error.FormatError;

        const sql = "INSERT INTO sessions (session_id, issue_id, worker_id, started_at, resuming) VALUES (?, ?, ?, ?, ?)";

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, issue_id.ptr, @intCast(issue_id.len), SQLITE_STATIC);
        if (worker_id) |w| {
            _ = c.sqlite3_bind_int(stmt, 3, @intCast(w));
        } else {
            _ = c.sqlite3_bind_null(stmt, 3);
        }
        _ = c.sqlite3_bind_int64(stmt, 4, timestamp);
        _ = c.sqlite3_bind_int(stmt, 5, if (resuming) 1 else 0);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.InsertFailed;

        // Return owned copy of session_id
        return self.allocator.dupe(u8, session_id) catch return error.OutOfMemory;
    }

    /// Complete a session with exit code
    pub fn completeSession(self: *TranscriptDb, session_id: []const u8, exit_code: u8) !void {
        const sql = "UPDATE sessions SET completed_at = ?, exit_code = ? WHERE session_id = ?";

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, std.time.timestamp());
        _ = c.sqlite3_bind_int(stmt, 2, exit_code);
        _ = c.sqlite3_bind_text(stmt, 3, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.UpdateFailed;
    }

    /// Log a streaming event
    pub fn logEvent(
        self: *TranscriptDb,
        session_id: []const u8,
        seq: u32,
        event_type: ?[]const u8,
        tool_name: ?[]const u8,
        content: ?[]const u8,
        raw_json: []const u8,
    ) !void {
        const sql =
            \\INSERT INTO events (session_id, seq, timestamp, event_type, tool_name, content, raw_json)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(seq));
        _ = c.sqlite3_bind_int64(stmt, 3, std.time.timestamp());

        if (event_type) |et| {
            _ = c.sqlite3_bind_text(stmt, 4, et.ptr, @intCast(et.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 4);
        }

        if (tool_name) |tn| {
            _ = c.sqlite3_bind_text(stmt, 5, tn.ptr, @intCast(tn.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 5);
        }

        if (content) |ct| {
            // Truncate content if too long (keep first 1000 chars)
            const max_content = 1000;
            const truncated = if (ct.len > max_content) ct[0..max_content] else ct;
            _ = c.sqlite3_bind_text(stmt, 6, truncated.ptr, @intCast(truncated.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 6);
        }

        _ = c.sqlite3_bind_text(stmt, 7, raw_json.ptr, @intCast(raw_json.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.InsertFailed;
    }

    /// Get event count for a session
    pub fn getEventCount(self: *TranscriptDb, session_id: []const u8) !u32 {
        const sql = "SELECT COUNT(*) FROM events WHERE session_id = ?";

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return 0;

        return @intCast(c.sqlite3_column_int(stmt, 0));
    }

    /// Get all sessions for an issue
    pub fn getSessionsForIssue(self: *TranscriptDb, issue_id: []const u8) ![]SessionInfo {
        const sql =
            \\SELECT session_id, worker_id, started_at, completed_at, exit_code, resuming
            \\FROM sessions WHERE issue_id = ? ORDER BY started_at DESC
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, issue_id.ptr, @intCast(issue_id.len), SQLITE_STATIC);

        var sessions = std.ArrayList(SessionInfo).init(self.allocator);
        errdefer {
            for (sessions.items) |s| self.allocator.free(s.session_id);
            sessions.deinit();
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const sid_ptr = c.sqlite3_column_text(stmt, 0);
            const sid_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const session_id_copy = try self.allocator.dupe(u8, sid_ptr[0..sid_len]);

            const worker_id: ?u32 = if (c.sqlite3_column_type(stmt, 1) != c.SQLITE_NULL)
                @intCast(c.sqlite3_column_int(stmt, 1))
            else
                null;

            try sessions.append(.{
                .session_id = session_id_copy,
                .worker_id = worker_id,
                .started_at = c.sqlite3_column_int64(stmt, 2),
                .completed_at = if (c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL)
                    c.sqlite3_column_int64(stmt, 3)
                else
                    null,
                .exit_code = if (c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL)
                    @intCast(c.sqlite3_column_int(stmt, 4))
                else
                    null,
                .resuming = c.sqlite3_column_int(stmt, 5) != 0,
            });
        }

        return sessions.toOwnedSlice();
    }

    pub const SessionInfo = struct {
        session_id: []const u8,
        worker_id: ?u32,
        started_at: i64,
        completed_at: ?i64,
        exit_code: ?u8,
        resuming: bool,
    };
};

// === Tests ===

test "transcript db basic operations" {
    // Use a test database path
    const test_db_path = "/tmp/noface-test-transcripts.db";
    defer std.fs.cwd().deleteFile(test_db_path) catch {};

    const allocator = std.testing.allocator;
    _ = allocator;

    // Create test db manually for isolated testing
    var db: ?*c.sqlite3 = null;
    _ = c.sqlite3_open(test_db_path, &db);
    defer {
        if (db) |d| _ = c.sqlite3_close(d);
    }

    // Just verify SQLite is working
    try std.testing.expect(db != null);
}
