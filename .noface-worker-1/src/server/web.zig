const std = @import("std");
const process = @import("../util/process.zig");
const assets = @import("web_assets.zig");

const SESSION_DIR = "/tmp";

pub const WebServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    port: u16,
    project_root: []const u8,
    ws_clients: std.ArrayListUnmanaged(*WsClient),

    const WsClient = struct {
        stream: std.net.Stream,
        allocator: std.mem.Allocator,

        pub fn send(self: *WsClient, payload: []const u8) !void {
            try self.sendFrame(0x1, payload); // 0x1 = text frame
        }

        fn sendFrame(self: *WsClient, opcode: u8, payload: []const u8) !void {
            // WebSocket frame format
            var header: [14]u8 = undefined;
            var header_len: usize = 2;

            header[0] = 0x80 | opcode; // FIN + opcode

            if (payload.len < 126) {
                header[1] = @intCast(payload.len);
            } else if (payload.len <= 65535) {
                header[1] = 126;
                header[2] = @intCast((payload.len >> 8) & 0xFF);
                header[3] = @intCast(payload.len & 0xFF);
                header_len = 4;
            } else {
                header[1] = 127;
                const len64: u64 = payload.len;
                header[2] = @intCast((len64 >> 56) & 0xFF);
                header[3] = @intCast((len64 >> 48) & 0xFF);
                header[4] = @intCast((len64 >> 40) & 0xFF);
                header[5] = @intCast((len64 >> 32) & 0xFF);
                header[6] = @intCast((len64 >> 24) & 0xFF);
                header[7] = @intCast((len64 >> 16) & 0xFF);
                header[8] = @intCast((len64 >> 8) & 0xFF);
                header[9] = @intCast(len64 & 0xFF);
                header_len = 10;
            }

            _ = self.stream.write(header[0..header_len]) catch return;
            _ = self.stream.write(payload) catch return;
        }
    };

    pub fn init(allocator: std.mem.Allocator, port: u16, project_root: []const u8) !WebServer {
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const server = try address.listen(.{ .reuse_address = true });

        return .{
            .allocator = allocator,
            .server = server,
            .port = port,
            .project_root = project_root,
            .ws_clients = .{},
        };
    }

    pub fn deinit(self: *WebServer) void {
        for (self.ws_clients.items) |client| {
            client.stream.close();
            self.allocator.destroy(client);
        }
        self.ws_clients.deinit(self.allocator);
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

            const is_ws = self.handleRequest(conn) catch |err| {
                std.debug.print("[web] Request error: {}\n", .{err});
                conn.stream.close();
                continue;
            };

            // Only close non-WebSocket connections
            if (!is_ws) {
                conn.stream.close();
            }
        }
    }

    fn handleRequest(self: *WebServer, conn: std.net.Server.Connection) !bool {
        var buf: [4096]u8 = undefined;
        const len = try conn.stream.read(&buf);
        if (len == 0) return false;

        const request = buf[0..len];

        // Parse first line: "GET /path HTTP/1.1"
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const first_line = lines.next() orelse return false;
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return false;
        const path = parts.next() orelse return false;

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
            const json = try self.loadSessions();
            defer self.allocator.free(json);
            try self.sendResponse(conn, "200 OK", "application/json", json);
        } else if (std.mem.eql(u8, path, "/ws")) {
            // Handle WebSocket upgrade
            const ws_key = self.extractWebSocketKey(request) orelse {
                try self.sendResponse(conn, "400 Bad Request", "text/plain", "Missing Sec-WebSocket-Key");
                return false;
            };
            try self.handleWebSocketUpgrade(conn, ws_key);
            return true; // Keep connection open for WebSocket
        } else {
            try self.sendResponse(conn, "404 Not Found", "text/plain", "Not Found");
        }
        return false;
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

    fn loadSessions(self: *WebServer) ![]const u8 {
        var dir = std.fs.openDirAbsolute(SESSION_DIR, .{ .iterate = true }) catch |err| {
            std.debug.print("[web] Could not open session dir: {}\n", .{err});
            return try self.allocator.dupe(u8, "{}");
        };
        defer dir.close();

        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(self.allocator);
        try result.appendSlice(self.allocator, "{");

        var first_session = true;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "noface-session-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            // Extract issue ID from filename
            const prefix_len = "noface-session-".len;
            const suffix_len = ".json".len;
            if (entry.name.len <= prefix_len + suffix_len) continue;
            const issue_id = entry.name[prefix_len .. entry.name.len - suffix_len];

            // Read and summarize session file
            const session_content = dir.readFileAlloc(self.allocator, entry.name, 10 * 1024 * 1024) catch continue;
            defer self.allocator.free(session_content);

            const summary = self.summarizeSession(session_content) catch continue;
            defer self.allocator.free(summary);

            if (!first_session) {
                try result.appendSlice(self.allocator, ",");
            }
            first_session = false;

            // Write "issue_id": [summary]
            try result.appendSlice(self.allocator, "\"");
            try result.appendSlice(self.allocator, issue_id);
            try result.appendSlice(self.allocator, "\":");
            try result.appendSlice(self.allocator, summary);
        }

        try result.appendSlice(self.allocator, "}");
        return try self.allocator.dupe(u8, result.items);
    }

    fn summarizeSession(self: *WebServer, content: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(self.allocator);
        try result.appendSlice(self.allocator, "[");

        var first_event = true;
        var text_buffer = std.ArrayListUnmanaged(u8){};
        defer text_buffer.deinit(self.allocator);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            // Parse JSON line to extract type and relevant fields
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch continue;
            defer parsed.deinit();

            const obj = parsed.value.object;
            const event_type = obj.get("type") orelse continue;
            if (event_type != .string) continue;

            if (std.mem.eql(u8, event_type.string, "assistant")) {
                // Extract tool_use blocks from assistant messages
                const message = obj.get("message") orelse continue;
                if (message != .object) continue;
                const msg_content = message.object.get("content") orelse continue;
                if (msg_content != .array) continue;

                for (msg_content.array.items) |block| {
                    if (block != .object) continue;
                    const block_type = block.object.get("type") orelse continue;
                    if (block_type != .string) continue;

                    if (std.mem.eql(u8, block_type.string, "tool_use")) {
                        // Flush any accumulated text
                        if (text_buffer.items.len > 0) {
                            if (!first_event) try result.appendSlice(self.allocator, ",");
                            first_event = false;
                            try result.appendSlice(self.allocator, "{\"type\":\"text\",\"content\":");
                            try writeJsonString(&result, self.allocator, text_buffer.items);
                            try result.appendSlice(self.allocator, "}");
                            text_buffer.clearRetainingCapacity();
                        }

                        const tool_name = block.object.get("name") orelse continue;
                        if (tool_name != .string) continue;

                        if (!first_event) try result.appendSlice(self.allocator, ",");
                        first_event = false;
                        try result.appendSlice(self.allocator, "{\"type\":\"tool\",\"name\":");
                        try writeJsonString(&result, self.allocator, tool_name.string);

                        // Include simplified input if present
                        if (block.object.get("input")) |input| {
                            if (input == .object) {
                                try result.appendSlice(self.allocator, ",\"input\":{");
                                var input_first = true;
                                var input_iter = input.object.iterator();
                                while (input_iter.next()) |entry| {
                                    // Only include short string values
                                    if (entry.value_ptr.* == .string) {
                                        const val = entry.value_ptr.string;
                                        if (val.len <= 100) {
                                            if (!input_first) try result.appendSlice(self.allocator, ",");
                                            input_first = false;
                                            try writeJsonString(&result, self.allocator, entry.key_ptr.*);
                                            try result.appendSlice(self.allocator, ":");
                                            try writeJsonString(&result, self.allocator, val);
                                        }
                                    }
                                }
                                try result.appendSlice(self.allocator, "}");
                            }
                        }
                        try result.appendSlice(self.allocator, "}");
                    }
                }
            } else if (std.mem.eql(u8, event_type.string, "stream_event")) {
                // Extract text deltas from stream events
                const event = obj.get("event") orelse continue;
                if (event != .object) continue;
                const stream_type = event.object.get("type") orelse continue;
                if (stream_type != .string) continue;

                if (std.mem.eql(u8, stream_type.string, "content_block_delta")) {
                    const delta = event.object.get("delta") orelse continue;
                    if (delta != .object) continue;
                    const delta_type = delta.object.get("type") orelse continue;
                    if (delta_type != .string) continue;

                    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                        const text = delta.object.get("text") orelse continue;
                        if (text == .string) {
                            try text_buffer.appendSlice(self.allocator, text.string);
                        }
                    }
                }
            }
        }

        // Flush any remaining text
        if (text_buffer.items.len > 0) {
            if (!first_event) try result.appendSlice(self.allocator, ",");
            try result.appendSlice(self.allocator, "{\"type\":\"text\",\"content\":");
            try writeJsonString(&result, self.allocator, text_buffer.items);
            try result.appendSlice(self.allocator, "}");
        }

        try result.appendSlice(self.allocator, "]");
        return try self.allocator.dupe(u8, result.items);
    }

    fn extractWebSocketKey(self: *WebServer, request: []const u8) ?[]const u8 {
        _ = self;
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "Sec-WebSocket-Key:")) {
                const value = std.mem.trim(u8, line["Sec-WebSocket-Key:".len..], " \t");
                return value;
            }
        }
        return null;
    }

    fn handleWebSocketUpgrade(self: *WebServer, conn: std.net.Server.Connection, ws_key: []const u8) !void {
        // Compute WebSocket accept key: base64(sha1(key + magic))
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(ws_key);
        hasher.update(magic);
        const hash = hasher.finalResult();

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

        // Send upgrade response
        var response_buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key}) catch return error.BufferTooSmall;
        _ = try conn.stream.write(response);

        // Create WebSocket client and add to list
        const client = try self.allocator.create(WsClient);
        client.* = .{
            .stream = conn.stream,
            .allocator = self.allocator,
        };
        try self.ws_clients.append(self.allocator, client);

        // Send initial state
        const issues_json = try self.loadIssues();
        defer self.allocator.free(issues_json);
        const state_json = try self.loadState();
        defer self.allocator.free(state_json);

        var init_msg = std.ArrayListUnmanaged(u8){};
        defer init_msg.deinit(self.allocator);
        try init_msg.appendSlice(self.allocator, "{\"type\":\"init\",\"data\":{\"issues\":");
        try init_msg.appendSlice(self.allocator, issues_json);
        try init_msg.appendSlice(self.allocator, ",\"state\":");
        try init_msg.appendSlice(self.allocator, state_json);
        try init_msg.appendSlice(self.allocator, "}}");

        client.send(init_msg.items) catch {
            self.removeClient(client);
        };
    }

    fn removeClient(self: *WebServer, client: *WsClient) void {
        for (self.ws_clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.ws_clients.swapRemove(i);
                client.stream.close();
                self.allocator.destroy(client);
                return;
            }
        }
    }

    pub fn broadcast(self: *WebServer, msg_type: []const u8, data: []const u8) void {
        var msg = std.ArrayListUnmanaged(u8){};
        defer msg.deinit(self.allocator);
        msg.appendSlice(self.allocator, "{\"type\":\"") catch return;
        msg.appendSlice(self.allocator, msg_type) catch return;
        msg.appendSlice(self.allocator, "\",\"data\":") catch return;
        msg.appendSlice(self.allocator, data) catch return;
        msg.appendSlice(self.allocator, "}") catch return;

        var to_remove = std.ArrayListUnmanaged(*WsClient){};
        defer to_remove.deinit(self.allocator);

        for (self.ws_clients.items) |client| {
            client.send(msg.items) catch {
                to_remove.append(self.allocator, client) catch continue;
            };
        }

        for (to_remove.items) |client| {
            self.removeClient(client);
        }
    }
};

fn writeJsonString(result: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try result.appendSlice(allocator, "\"");
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try result.appendSlice(allocator, &buf);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }
    try result.appendSlice(allocator, "\"");
}

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
