//! noface - Autonomous agent loop for software development
//!
//! A Zig implementation of an agentic development loop that orchestrates
//! Claude (implementation) and Codex (review) to work on issues autonomously.

const std = @import("std");

// Core modules
pub const config = @import("core/config.zig");
pub const loop = @import("core/loop.zig");
pub const state = @import("core/state.zig");
pub const worker_pool = @import("core/worker_pool.zig");
pub const prompts = @import("core/prompts.zig");

// VCS modules
pub const jj = @import("vcs/jj.zig");

// Integration modules
pub const github = @import("integrations/github.zig");
pub const monowiki = @import("integrations/monowiki.zig");
pub const lsp = @import("integrations/lsp.zig");

// Utility modules
pub const process = @import("util/process.zig");
pub const signals = @import("util/signals.zig");
pub const streaming = @import("util/streaming.zig");
pub const markdown = @import("util/markdown.zig");
pub const bm25 = @import("util/bm25.zig");
pub const transcript = @import("util/transcript.zig");

// Server modules
pub const web = @import("server/web.zig");

// Re-exports for convenience
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
pub const JjRepo = jj.JjRepo;

test {
    std.testing.refAllDecls(@This());
}
