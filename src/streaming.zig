//! Streaming JSON parser for Claude's stream-json output format.
//!
//! Parses Claude's streaming JSON events and extracts text content
//! for real-time display.

const std = @import("std");

/// Event types from Claude's stream-json format
pub const EventType = enum {
    system,
    assistant,
    user,
    stream_event,
    result,
    unknown,
};

/// Parsed streaming event
pub const StreamEvent = struct {
    event_type: EventType,
    /// For text_delta events, contains the text chunk
    text: ?[]const u8 = null,
    /// For tool_use events, contains the tool name
    tool_name: ?[]const u8 = null,
    /// For result events, contains the final result
    result: ?[]const u8 = null,
    /// Whether this is an error
    is_error: bool = false,
};

/// Parse a single JSON line from Claude's streaming output
pub fn parseStreamLine(allocator: std.mem.Allocator, line: []const u8) !StreamEvent {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return .{ .event_type = .unknown };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return .{ .event_type = .unknown };

    const obj = root.object;

    // Get event type
    const type_str = if (obj.get("type")) |t| switch (t) {
        .string => |s| s,
        else => return .{ .event_type = .unknown },
    } else return .{ .event_type = .unknown };

    const event_type: EventType = if (std.mem.eql(u8, type_str, "stream_event"))
        .stream_event
    else if (std.mem.eql(u8, type_str, "assistant"))
        .assistant
    else if (std.mem.eql(u8, type_str, "user"))
        .user
    else if (std.mem.eql(u8, type_str, "system"))
        .system
    else if (std.mem.eql(u8, type_str, "result"))
        .result
    else
        .unknown;

    var event = StreamEvent{ .event_type = event_type };

    // Handle stream_event with content_block_delta (text streaming)
    if (event_type == .stream_event) {
        if (obj.get("event")) |evt| {
            if (evt == .object) {
                const evt_obj = evt.object;
                if (evt_obj.get("type")) |evt_type| {
                    if (evt_type == .string and std.mem.eql(u8, evt_type.string, "content_block_delta")) {
                        if (evt_obj.get("delta")) |delta| {
                            if (delta == .object) {
                                if (delta.object.get("text")) |text| {
                                    if (text == .string) {
                                        event.text = try allocator.dupe(u8, text.string);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Handle assistant message with tool_use
    if (event_type == .assistant) {
        if (obj.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("content")) |content| {
                    if (content == .array and content.array.items.len > 0) {
                        const first = content.array.items[0];
                        if (first == .object) {
                            if (first.object.get("type")) |t| {
                                if (t == .string and std.mem.eql(u8, t.string, "tool_use")) {
                                    if (first.object.get("name")) |name| {
                                        if (name == .string) {
                                            event.tool_name = try allocator.dupe(u8, name.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Handle result
    if (event_type == .result) {
        if (obj.get("result")) |res| {
            if (res == .string) {
                event.result = try allocator.dupe(u8, res.string);
            }
        }
        if (obj.get("is_error")) |is_err| {
            if (is_err == .bool) {
                event.is_error = is_err.bool;
            }
        }
    }

    return event;
}

/// Stream handler callback type
pub const StreamCallback = *const fn (event: StreamEvent) void;

/// Print text delta to stdout (for streaming display)
pub fn printTextDelta(event: StreamEvent) void {
    if (event.text) |text| {
        _ = std.fs.File.stdout().write(text) catch {};
    }
    if (event.tool_name) |name| {
        std.debug.print("\n\x1b[0;36m[TOOL]\x1b[0m {s}\n", .{name});
    }
}

test "parse text delta" {
    const json =
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const event = try parseStreamLine(arena.allocator(), json);
    try std.testing.expectEqual(EventType.stream_event, event.event_type);
    try std.testing.expectEqualStrings("Hello", event.text.?);
}

test "parse tool use" {
    const json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"123"}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const event = try parseStreamLine(arena.allocator(), json);
    try std.testing.expectEqual(EventType.assistant, event.event_type);
    try std.testing.expectEqualStrings("Bash", event.tool_name.?);
}
