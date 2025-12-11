//! Simple markdown rendering for terminal output.
//!
//! Provides basic markdown rendering without external dependencies like glow.
//! Handles headers, bold, italic, code blocks, and lists.

const std = @import("std");

/// ANSI color codes for terminal styling
const Style = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const italic = "\x1b[3m";
    const dim = "\x1b[2m";
    const cyan = "\x1b[0;36m";
    const yellow = "\x1b[0;33m";
    const green = "\x1b[0;32m";
    const magenta = "\x1b[0;35m";
};

/// Render markdown text to terminal with ANSI styling
pub fn render(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};

    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_code_block = false;
    var first_line = true;

    while (lines.next()) |line| {
        if (!first_line) {
            try output.append(allocator, '\n');
        }
        first_line = false;

        // Code block fences
        if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = !in_code_block;
            if (in_code_block) {
                try output.appendSlice(allocator, Style.dim);
                // Skip the fence line itself
            } else {
                try output.appendSlice(allocator, Style.reset);
            }
            continue;
        }

        if (in_code_block) {
            // Code block content - render as-is with dim styling
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, line);
            continue;
        }

        // Headers
        if (std.mem.startsWith(u8, line, "### ")) {
            try output.appendSlice(allocator, Style.yellow);
            try output.appendSlice(allocator, Style.bold);
            try output.appendSlice(allocator, line[4..]);
            try output.appendSlice(allocator, Style.reset);
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ")) {
            try output.appendSlice(allocator, Style.cyan);
            try output.appendSlice(allocator, Style.bold);
            try output.appendSlice(allocator, line[3..]);
            try output.appendSlice(allocator, Style.reset);
            continue;
        }
        if (std.mem.startsWith(u8, line, "# ")) {
            try output.appendSlice(allocator, Style.magenta);
            try output.appendSlice(allocator, Style.bold);
            try output.appendSlice(allocator, line[2..]);
            try output.appendSlice(allocator, Style.reset);
            continue;
        }

        // Bullet lists
        if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            try output.appendSlice(allocator, Style.green);
            try output.appendSlice(allocator, "• ");
            try output.appendSlice(allocator, Style.reset);
            try renderInline(allocator, &output, line[2..]);
            continue;
        }

        // Numbered lists
        if (line.len >= 3) {
            var i: usize = 0;
            while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
            if (i > 0 and i < line.len - 1 and line[i] == '.' and line[i + 1] == ' ') {
                try output.appendSlice(allocator, Style.green);
                try output.appendSlice(allocator, line[0 .. i + 1]);
                try output.append(allocator, ' ');
                try output.appendSlice(allocator, Style.reset);
                try renderInline(allocator, &output, line[i + 2 ..]);
                continue;
            }
        }

        // Regular line with inline formatting
        try renderInline(allocator, &output, line);
    }

    return output.toOwnedSlice(allocator);
}

/// Render inline markdown elements (bold, italic, code)
fn renderInline(allocator: std.mem.Allocator, output: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;

    while (i < line.len) {
        // Bold: **text**
        if (i + 1 < line.len and std.mem.eql(u8, line[i .. i + 2], "**")) {
            if (std.mem.indexOf(u8, line[i + 2 ..], "**")) |end| {
                try output.appendSlice(allocator, Style.bold);
                try output.appendSlice(allocator, line[i + 2 .. i + 2 + end]);
                try output.appendSlice(allocator, Style.reset);
                i += 4 + end;
                continue;
            }
        }

        // Inline code: `text`
        if (line[i] == '`') {
            if (std.mem.indexOf(u8, line[i + 1 ..], "`")) |end| {
                try output.appendSlice(allocator, Style.dim);
                try output.appendSlice(allocator, line[i + 1 .. i + 1 + end]);
                try output.appendSlice(allocator, Style.reset);
                i += 2 + end;
                continue;
            }
        }

        // Italic: *text* (but not **)
        if (line[i] == '*' and (i + 1 >= line.len or line[i + 1] != '*')) {
            if (std.mem.indexOf(u8, line[i + 1 ..], "*")) |end| {
                if (end > 0 and line[i + end] != '*') {
                    try output.appendSlice(allocator, Style.italic);
                    try output.appendSlice(allocator, line[i + 1 .. i + 1 + end]);
                    try output.appendSlice(allocator, Style.reset);
                    i += 2 + end;
                    continue;
                }
            }
        }

        // Regular character
        try output.append(allocator, line[i]);
        i += 1;
    }
}

/// Print rendered markdown directly to stdout
pub fn print(allocator: std.mem.Allocator, input: []const u8) void {
    const rendered = render(allocator, input) catch {
        // Fallback: print unrendered
        _ = std.fs.File.write(std.fs.File.stdout(), input) catch {};
        return;
    };
    defer allocator.free(rendered);
    _ = std.fs.File.write(std.fs.File.stdout(), rendered) catch {};
}

test "render headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = "# Header 1\n## Header 2\n### Header 3";
    const output = try render(arena.allocator(), input);

    // Just verify it doesn't crash and produces output
    try std.testing.expect(output.len > 0);
}

test "render code block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = "```\ncode here\n```";
    const output = try render(arena.allocator(), input);
    try std.testing.expect(output.len > 0);
}

test "render bullet list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = "- Item 1\n- Item 2\n* Item 3";
    const output = try render(arena.allocator(), input);
    try std.testing.expect(std.mem.indexOf(u8, output, "•") != null);
}
