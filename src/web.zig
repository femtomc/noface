const std = @import("std");
const process = @import("process.zig");
const assets = @import("web_assets.zig");

pub const WebServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    port: u16,
    project_root: []const u8,

    pub fn init(allocator: std.mem.Allocator, port: u16, project_root: []const u8) !WebServer {
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const server = try address.listen(.{ .reuse_address = true });

        return .{
            .allocator = allocator,
            .server = server,
            .port = port,
            .project_root = project_root,
        };
    }

    pub fn deinit(self: *WebServer) void {
        self.server.deinit();
    }

    pub fn run(self: *WebServer) !void {
        std.debug.print("\n[noface] Web server running at http://localhost:{d}\n", .{self.port});
        std.debug.print("[noface] Press Ctrl+C to stop\n\n", .{});

        while (true) {
            const conn = self.server.accept() catch |err| {
                std.debug.print("[web] Accept error: {}\n", .{err});
                continue;
            };
            defer conn.stream.close();

            self.handleRequest(conn) catch |err| {
                std.debug.print("[web] Request error: {}\n", .{err});
            };
        }
    }

    fn handleRequest(self: *WebServer, conn: std.net.Server.Connection) !void {
        var buf: [4096]u8 = undefined;
        const len = try conn.stream.read(&buf);
        if (len == 0) return;

        const request = buf[0..len];

        // Parse first line: "GET /path HTTP/1.1"
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const first_line = lines.next() orelse return;
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        _ = method; // We only handle GET for now

        // Route the request
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            try self.sendResponse(conn, "200 OK", "text/html", assets.index_html);
        } else if (std.mem.eql(u8, path, "/assets/app.js")) {
            try self.sendResponse(conn, "200 OK", "application/javascript", assets.app_js);
        } else if (std.mem.eql(u8, path, "/assets/index.css")) {
            try self.sendResponse(conn, "200 OK", "text/css", assets.index_css);
        } else if (std.mem.eql(u8, path, "/api/issues")) {
            const json = try self.loadIssues();
            defer self.allocator.free(json);
            try self.sendResponse(conn, "200 OK", "application/json", json);
        } else if (std.mem.eql(u8, path, "/api/state")) {
            const json = try self.loadState();
            defer self.allocator.free(json);
            try self.sendResponse(conn, "200 OK", "application/json", json);
        } else if (std.mem.eql(u8, path, "/api/sessions")) {
            // Return empty sessions for now (would need to scan /tmp)
            try self.sendResponse(conn, "200 OK", "application/json", "{}");
        } else {
            try self.sendResponse(conn, "404 Not Found", "text/plain", "Not Found");
        }
    }

    fn sendResponse(self: *WebServer, conn: std.net.Server.Connection, status: []const u8, content_type: []const u8, body: []const u8) !void {
        _ = self;
        // Build response in a buffer, then write all at once
        var response_buf: [8192]u8 = undefined;
        const header = std.fmt.bufPrint(&response_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return error.BufferTooSmall;
        _ = try conn.stream.write(header);
        _ = try conn.stream.write(body);
    }

    fn loadIssues(self: *WebServer) ![]const u8 {
        const issues_path = try std.fs.path.join(self.allocator, &.{ self.project_root, ".beads", "issues.jsonl" });
        defer self.allocator.free(issues_path);

        const file = std.fs.openFileAbsolute(issues_path, .{}) catch |err| {
            std.debug.print("[web] Could not open issues file: {}\n", .{err});
            return try self.allocator.dupe(u8, "[]");
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            std.debug.print("[web] Could not read issues file: {}\n", .{err});
            return try self.allocator.dupe(u8, "[]");
        };
        defer self.allocator.free(content);

        // Convert JSONL to JSON array
        var issues = std.ArrayListUnmanaged(u8){};
        defer issues.deinit(self.allocator);
        try issues.appendSlice(self.allocator, "[");

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            if (!first) {
                try issues.appendSlice(self.allocator, ",");
            }
            first = false;
            try issues.appendSlice(self.allocator, trimmed);
        }

        try issues.appendSlice(self.allocator, "]");
        return try self.allocator.dupe(u8, issues.items);
    }

    fn loadState(self: *WebServer) ![]const u8 {
        const state_path = try std.fs.path.join(self.allocator, &.{ self.project_root, ".noface", "state.json" });
        defer self.allocator.free(state_path);

        const file = std.fs.openFileAbsolute(state_path, .{}) catch |err| {
            std.debug.print("[web] Could not open state file: {}\n", .{err});
            return try self.allocator.dupe(u8, "null");
        };
        defer file.close();

        return file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            std.debug.print("[web] Could not read state file: {}\n", .{err});
            return try self.allocator.dupe(u8, "null");
        };
    }
};

/// Run the web server as a subcommand
pub fn runServe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var port: u16 = 3000;

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --port requires a value\n", .{});
                return error.InvalidArgument;
            }
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Error: invalid port number\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printServeUsage();
            return;
        }
    }

    // Get project root (cwd)
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var server = try WebServer.init(allocator, port, cwd);
    defer server.deinit();

    try server.run();
}

fn printServeUsage() void {
    const usage =
        \\noface serve - Run the web dashboard
        \\
        \\Usage: noface serve [OPTIONS]
        \\
        \\Options:
        \\  -p, --port PORT    Port to listen on (default: 3000)
        \\  -h, --help         Show this help message
        \\
        \\The web dashboard provides a real-time view of:
        \\  - Issue tracker with filtering and dependency graph
        \\  - Agent activity and tool usage
        \\  - Orchestrator state and worker status
        \\
    ;
    std.debug.print("{s}", .{usage});
}
