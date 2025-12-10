//! noface - Autonomous agent loop for software development
//!
//! A Zig implementation of an agentic development loop that orchestrates
//! Claude (implementation) and Codex (review) to work on issues autonomously.

const std = @import("std");

pub const config = @import("config.zig");
pub const streaming = @import("streaming.zig");
pub const process = @import("process.zig");
pub const loop = @import("loop.zig");

pub const Config = config.Config;
pub const AgentLoop = loop.AgentLoop;

test {
    std.testing.refAllDecls(@This());
}
