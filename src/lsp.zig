//! LSP client for semantic code analysis.
//!
//! Communicates with language servers (zls, rust-analyzer, etc.) to provide
//! agents with semantic understanding: definitions, references, call graphs.

const std = @import("std");
const process = @import("process.zig");

/// LSP message ID counter
var next_id: i64 = 1;

/// LSP client that communicates with a language server
pub const Client = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    initialized: bool = false,
    root_path: []const u8,

    /// Spawn an LSP server
    pub fn init(allocator: std.mem.Allocator, server_cmd: []const u8, root_path: []const u8) !Client {
        const argv = [_][]const u8{server_cmd};

        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        return .{
            .allocator = allocator,
            .child = child,
            .root_path = root_path,
        };
    }

    pub fn deinit(self: *Client) void {
        // Send shutdown
        self.sendRequest("shutdown", .{}) catch {};

        // Send exit notification
        self.sendNotification("exit", .{}) catch {};

        _ = self.child.kill() catch {};
    }

    /// Initialize the LSP connection
    pub fn initialize(self: *Client) !void {
        const params = .{
            .processId = std.os.linux.getpid(),
            .rootUri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.root_path}),
            .capabilities = .{
                .textDocument = .{
                    .definition = .{ .dynamicRegistration = false },
                    .references = .{ .dynamicRegistration = false },
                    .hover = .{ .dynamicRegistration = false },
                },
            },
        };

        _ = try self.sendRequest("initialize", params);

        // Send initialized notification
        try self.sendNotification("initialized", .{});

        self.initialized = true;
    }

    /// Go to definition
    pub fn gotoDefinition(self: *Client, file_path: []const u8, line: u32, col: u32) !?Location {
        const params = .{
            .textDocument = .{
                .uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{file_path}),
            },
            .position = .{
                .line = line,
                .character = col,
            },
        };

        const response = try self.sendRequest("textDocument/definition", params);
        return parseLocation(self.allocator, response);
    }

    /// Find all references
    pub fn findReferences(self: *Client, file_path: []const u8, line: u32, col: u32) ![]Location {
        const params = .{
            .textDocument = .{
                .uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{file_path}),
            },
            .position = .{
                .line = line,
                .character = col,
            },
            .context = .{
                .includeDeclaration = true,
            },
        };

        const response = try self.sendRequest("textDocument/references", params);
        return parseLocations(self.allocator, response);
    }

    /// Get hover information (type, docs)
    pub fn hover(self: *Client, file_path: []const u8, line: u32, col: u32) !?[]const u8 {
        const params = .{
            .textDocument = .{
                .uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{file_path}),
            },
            .position = .{
                .line = line,
                .character = col,
            },
        };

        const response = try self.sendRequest("textDocument/hover", params);
        return parseHoverContent(self.allocator, response);
    }

    /// Get document symbols (functions, structs, etc.)
    pub fn documentSymbols(self: *Client, file_path: []const u8) ![]Symbol {
        const params = .{
            .textDocument = .{
                .uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{file_path}),
            },
        };

        const response = try self.sendRequest("textDocument/documentSymbol", params);
        return parseSymbols(self.allocator, response);
    }

    // === Internal JSON-RPC ===

    fn sendRequest(self: *Client, method: []const u8, params: anytype) ![]const u8 {
        const id = next_id;
        next_id += 1;

        // Build JSON-RPC message
        var msg = std.ArrayListUnmanaged(u8){};
        defer msg.deinit(self.allocator);

        const json_params = try std.json.stringifyAlloc(self.allocator, params, .{});
        defer self.allocator.free(json_params);

        const content = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
        , .{ id, method, json_params });
        defer self.allocator.free(content);

        // LSP uses Content-Length header
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{content.len});
        defer self.allocator.free(header);

        // Send
        try self.child.stdin.?.writeAll(header);
        try self.child.stdin.?.writeAll(content);

        // Read response
        return try self.readResponse();
    }

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const json_params = try std.json.stringifyAlloc(self.allocator, params, .{});
        defer self.allocator.free(json_params);

        const content = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s}}}
        , .{ method, json_params });
        defer self.allocator.free(content);

        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{content.len});
        defer self.allocator.free(header);

        try self.child.stdin.?.writeAll(header);
        try self.child.stdin.?.writeAll(content);
    }

    fn readResponse(self: *Client) ![]const u8 {
        var reader = self.child.stdout.?.reader();

        // Read Content-Length header
        var header_buf: [256]u8 = undefined;
        const header_line = try reader.readUntilDelimiter(&header_buf, '\n');

        // Parse content length
        const prefix = "Content-Length: ";
        if (!std.mem.startsWith(u8, header_line, prefix)) {
            return error.InvalidLspResponse;
        }

        const len_str = std.mem.trim(u8, header_line[prefix.len..], " \r\n");
        const content_len = try std.fmt.parseInt(usize, len_str, 10);

        // Skip empty line
        _ = try reader.readUntilDelimiter(&header_buf, '\n');

        // Read content
        const content = try self.allocator.alloc(u8, content_len);
        const read = try reader.readAll(content);
        if (read != content_len) {
            self.allocator.free(content);
            return error.IncompleteResponse;
        }

        return content;
    }
};

/// A location in source code
pub const Location = struct {
    uri: []const u8,
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,

    pub fn path(self: Location) []const u8 {
        // Strip file:// prefix
        if (std.mem.startsWith(u8, self.uri, "file://")) {
            return self.uri[7..];
        }
        return self.uri;
    }
};

/// A symbol in a document
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    location: Location,
};

pub const SymbolKind = enum(u8) {
    file = 1,
    module = 2,
    namespace = 3,
    package = 4,
    class = 5,
    method = 6,
    property = 7,
    field = 8,
    constructor = 9,
    enum_ = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    string = 15,
    number = 16,
    boolean = 17,
    array = 18,
    object = 19,
    key = 20,
    null_ = 21,
    enum_member = 22,
    struct_ = 23,
    event = 24,
    operator = 25,
    type_parameter = 26,
    _,
};

// === Response Parsing (simplified) ===

fn parseLocation(allocator: std.mem.Allocator, json: []const u8) !?Location {
    _ = allocator;
    // TODO: Proper JSON parsing
    // For now, return null - this is a sketch
    _ = json;
    return null;
}

fn parseLocations(allocator: std.mem.Allocator, json: []const u8) ![]Location {
    _ = allocator;
    _ = json;
    return &.{};
}

fn parseHoverContent(allocator: std.mem.Allocator, json: []const u8) !?[]const u8 {
    _ = allocator;
    _ = json;
    return null;
}

fn parseSymbols(allocator: std.mem.Allocator, json: []const u8) ![]Symbol {
    _ = allocator;
    _ = json;
    return &.{};
}

// === High-level API for Agents ===

/// Code graph built from LSP queries
pub const CodeGraph = struct {
    allocator: std.mem.Allocator,
    client: ?Client,

    /// All symbols indexed by file
    symbols: std.StringHashMapUnmanaged([]Symbol),

    /// Call graph: caller -> callees
    calls: std.StringHashMapUnmanaged([][]const u8),

    /// Reverse call graph: callee -> callers
    callers: std.StringHashMapUnmanaged([][]const u8),

    pub fn init(allocator: std.mem.Allocator) CodeGraph {
        return .{
            .allocator = allocator,
            .client = null,
            .symbols = .{},
            .calls = .{},
            .callers = .{},
        };
    }

    pub fn deinit(self: *CodeGraph) void {
        if (self.client) |*c| c.deinit();
        self.symbols.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.callers.deinit(self.allocator);
    }

    /// Connect to LSP and build graph
    pub fn build(self: *CodeGraph, lsp_cmd: []const u8, root_path: []const u8) !void {
        self.client = try Client.init(self.allocator, lsp_cmd, root_path);
        try self.client.?.initialize();

        // TODO: Walk directory, index each file
        // This would query documentSymbols for each file
        // Then query references to build call graph
    }

    /// Find where a symbol is defined
    pub fn definition(self: *CodeGraph, file: []const u8, line: u32, col: u32) !?Location {
        if (self.client) |*c| {
            return try c.gotoDefinition(file, line, col);
        }
        return null;
    }

    /// Find all references to symbol at position
    pub fn references(self: *CodeGraph, file: []const u8, line: u32, col: u32) ![]Location {
        if (self.client) |*c| {
            return try c.findReferences(file, line, col);
        }
        return &.{};
    }

    /// Get callers of a function
    pub fn getCallers(self: *CodeGraph, symbol_name: []const u8) [][]const u8 {
        return self.callers.get(symbol_name) orelse &.{};
    }

    /// Get callees from a function
    pub fn getCallees(self: *CodeGraph, symbol_name: []const u8) [][]const u8 {
        return self.calls.get(symbol_name) orelse &.{};
    }
};

// === Tool Interface for Agents ===

/// Format tools for agent prompts
pub fn toolDescription() []const u8 {
    return
        \\## Code Navigation Tools
        \\
        \\### goto_definition(file, line, col)
        \\Jump to where a symbol is defined.
        \\Example: goto_definition("src/loop.zig", 100, 15)
        \\
        \\### find_references(file, line, col)
        \\Find all usages of a symbol.
        \\Example: find_references("src/state.zig", 50, 10)
        \\
        \\### list_symbols(file)
        \\List all functions, structs, etc. in a file.
        \\Example: list_symbols("src/bm25.zig")
        \\
        \\### get_callers(function_name)
        \\Find all functions that call this one.
        \\Example: get_callers("parseJson")
        \\
        \\### get_callees(function_name)
        \\Find all functions called by this one.
        \\Example: get_callees("runIteration")
    ;
}
