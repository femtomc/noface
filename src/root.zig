//! noface - Autonomous agent loop for software development
//!
//! A Zig implementation of an agentic development loop that orchestrates
//! Claude (implementation) and Codex (review) to work on issues autonomously.

const std = @import("std");

pub const config = @import("config.zig");
pub const streaming = @import("streaming.zig");
pub const process = @import("process.zig");
pub const loop = @import("loop.zig");
pub const signals = @import("signals.zig");
pub const markdown = @import("markdown.zig");
pub const monowiki = @import("monowiki.zig");
pub const github = @import("github.zig");
pub const state = @import("state.zig");
pub const bm25 = @import("bm25.zig");
pub const lsp = @import("lsp.zig");
pub const worker_pool = @import("worker_pool.zig");
pub const web = @import("web.zig");
pub const transcript = @import("transcript.zig");

pub const Config = config.Config;
pub const OutputFormat = config.OutputFormat;
pub const AgentLoop = loop.AgentLoop;
pub const MonowikiConfig = monowiki.MonowikiConfig;
pub const Monowiki = monowiki.Monowiki;
pub const GitHubSync = github.GitHubSync;
pub const SyncResult = github.SyncResult;
pub const OrchestratorState = state.OrchestratorState;
pub const Manifest = state.Manifest;
pub const WorkerState = state.WorkerState;
pub const IssueStatus = state.IssueStatus;
pub const WorkerPool = worker_pool.WorkerPool;
pub const TranscriptDb = transcript.TranscriptDb;

test {
    std.testing.refAllDecls(@This());
}
