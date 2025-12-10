---
title: "Failure Recovery"
type: essay
tags: [design, failure, retry, recovery]
---

# Failure Recovery

How noface handles agent failures.

## Current Design

noface handles several failure modes:

1. **Transient failures** (429, 5xx, network) — retry up to 3x with exponential backoff
2. **Manifest violations** — rollback offending files, retry with stricter prompt
3. **Timeouts** (no output for N seconds) — break down issue into smaller tasks
4. **Crash recovery** — on startup, detect in-progress work from previous run, reset stale locks, restore state

Each attempt is recorded in state with outcome (success/failed/timeout/violation).

## Relation to Survey

The survey describes several recovery patterns:

**Graceful retries:**
> "The simplest recovery pattern is retrying the same prompt. Because LLM agents are stochastic, a second attempt might yield a different (possibly correct) result."

**Progressive prompting:**
> "If a direct retry doesn't help, the orchestrator should try a modified approach... break the task into smaller sub-tasks and prompt those instead."

**Preserving partial progress:**
> "A robust orchestrator will preserve this partial progress so it's not lost."

## Open Questions

1. **Retry Strategies** — Current retry is simple backoff. Should we modify the prompt on retry? Add more context? Summarize the failure?

2. **Task Breakdown** — Timeout triggers breakdown, but how does noface actually break down an issue? Is this implemented or aspirational?

3. **Partial Progress** — If an agent edits 3 files correctly but fails on the 4th, do we keep the 3? Currently unclear.

4. **Model Escalation** — The survey mentions falling back to more powerful models. Should noface try a different model on failure?

5. **Failure Classification** — Not all failures are equal. "Syntax error" vs "doesn't understand the task" vs "timeout" need different responses.

6. **Human Escalation** — After N failures, should noface pause and ask for help? Current behavior is unclear.

7. **Learning from Failures** — Should failure patterns inform future prompts? "This type of issue often fails, add extra guidance."

## Implementation Notes

See `src/loop.zig:runIteration` retry logic and `src/state.zig:IssueState`.
