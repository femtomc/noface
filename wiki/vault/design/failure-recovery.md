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
2. **Review rejections** — re-run worker with reviewer feedback (up to 5 iterations)
3. **Timeouts** (no output for N seconds) — break down issue into smaller tasks
4. **Crash recovery** — on startup, detect in-progress work from previous run, restore state

Each attempt is recorded in state with outcome (success/failed/timeout/violation).

## Relation to Survey

The survey describes several recovery patterns:

**Graceful retries:**
> "The simplest recovery pattern is retrying the same prompt. Because LLM agents are stochastic, a second attempt might yield a different (possibly correct) result."

**Progressive prompting:**
> "If a direct retry doesn't help, the orchestrator should try a modified approach... break the task into smaller sub-tasks and prompt those instead."

**Preserving partial progress:**
> "A robust orchestrator will preserve this partial progress so it's not lost."

## Design Decisions

### 1. Retry Strategies: Informed retries, not blind

**Decision:** Retries should include failure context and self-reflection.

**On retry, include:**
- Previous attempt's diff
- Summarized test output / error
- Instructions:
  ```
  Your previous attempt failed with: [error]. Fix that specific problem
  while preserving working parts.
  ```

**Optional self-reflection step:**
- Ask model: "Explain why your last attempt failed and how you will fix it"
- Feed that back into the actual implementation prompt

### 2. Task Breakdown: Minimal, concrete decomposition

**Decision:** Implement a simple breakdown strategy when issues are too large.

**Trigger breakdown when:**
- Issue times out repeatedly, or
- Fails after N attempts with "too big" signature (many files, large diff)

**Breakdown agent:**
- Run planner with a different prompt to propose sub-issues:
  - e.g., "Update schema in A", "Update API in B", "Update tests in C"
- Turn these into child issues, mark parent as an "epic"

**First version (simple):**
- Split by file: analyze the diff, create issues scoped to individual files or modules

Iterate toward more semantic breakdowns later.

### 3. Partial Progress: Keep on branch, all-or-nothing to main

**Decision:** Preserve partial progress in scratch branches, but merge atomically.

**Design:**
- Each issue has a scratch branch or temp workspace
- Each attempt commits to that branch
- If one file fails, you still keep the other 3 as commits in the branch
- Only when tests + gates pass do you merge that branch to main

This preserves partial progress for future attempts without exposing half-baked changes to main.

### 4. Model Escalation: Simple escalation policy

**Decision:** Define a simple model escalation policy.

**For each issue:**
- First 1–2 attempts: `default_model` (cheaper)
- If still failing with "correctable" errors (tests, syntax): escalate to `strong_model`
- Cap total attempts across all models

Keep configurable so users can opt-out if they only have access to one model.

```toml
[retry]
default_model = "claude-sonnet"
escalation_model = "claude-opus"
escalate_after_attempts = 2
max_total_attempts = 5
```

### 5. Failure Classification: Taxonomy with strategy mapping

**Decision:** Introduce a failure taxonomy and map each to a strategy.

**Taxonomy:**
| Failure Type | Strategy |
|--------------|----------|
| `SYNTAX_ERROR` | Re-prompt with same context + "fix syntax error" |
| `RUNTIME_ERROR` | Include stack trace, ask to fix |
| `TEST_FAILURE` | Include test output, ask to fix |
| `NO_DIFF` | "You must change code; your previous attempt changed nothing" |
| `TIMEOUT` | Break down task / reduce scope |
| `REVIEW_REJECTED` | Re-run worker with reviewer feedback |
| `AGENT_CONFUSION` | Involve planner or human for clarification |

### 6. Human Escalation: Clear threshold + summary

**Decision:** Define a clear escalation threshold with actionable summary.

**After N consecutive failed attempts (e.g., 3) or severe failure type:**
1. Mark issue as `BLOCKED`
2. Post a summary:
   - What was tried
   - Errors encountered
   - What the agent thinks is unclear (if any)
3. Pause automation until human:
   - Adds context
   - Edits the issue, or
   - Manually unblocks / retries

### 7. Learning from Failures: Lightweight rule-based lessons

**Decision:** Start with manual rule-based "lessons", not ML.

**Maintain a small config/ruleset:**
```toml
[[failure_hints]]
label = "migration"
hint = "Migration issues often need schema changes first. Check schema files."

[[failure_hints]]
language = "elixir"
error_pattern = "** (MatchError)"
hint = "Check pattern matching - ensure all cases are handled or use case/with statements."
```

Periodically review failure logs, add new rules where patterns are obvious.

Later: mine logs to auto-discover patterns, but manual rules get 80% of value quickly.

## Implementation Notes

See `lib/noface/core/loop.ex` retry logic and `lib/noface/core/state.ex`.

### TODO
- [ ] Add failure context to retry prompts
- [ ] Implement self-reflection step
- [ ] Add breakdown agent with file-split strategy
- [ ] Implement scratch branch model for partial progress
- [ ] Add model escalation policy
- [ ] Implement failure taxonomy enum
- [ ] Add `BLOCKED` status with human escalation summary
- [ ] Add `failure_hints` config section
