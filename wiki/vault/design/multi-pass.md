---
title: "Multi-Pass Architecture"
type: essay
tags: [design, planner, reviewer, passes]
---

# Multi-Pass Architecture

How noface uses multiple agent passes to improve quality.

## Current Design

noface runs multiple types of agent passes:

1. **Planner pass** — periodic backlog management
   - Analyzes issue backlog
   - Creates issues to fill gaps (from design docs)
   - Sets priorities and dependencies

2. **Worker pass** — per issue implementation
   - Implements the change in isolated jj workspace
   - Runs tests, signals READY_FOR_REVIEW

3. **Reviewer pass** — per implementation
   - Reviews changes in worker's workspace
   - Outputs APPROVED or CHANGES_REQUESTED with feedback

4. **Merge pass** — per approved implementation
   - Squashes workspace changes to root
   - Resolves conflicts, runs tests, closes issue

5. **Quality pass** — periodic codebase scan
   - Scans codebase for tech debt
   - Creates new issues for findings

## Worker → Reviewer → Merge Flow

```
Worker implements → READY_FOR_REVIEW
                         ↓
              Reviewer checks in workspace
                    ↓           ↓
              APPROVED    CHANGES_REQUESTED
                  ↓              ↓
           Merge agent    Worker re-runs
           squashes      (with feedback)
```

Up to 5 review iterations before giving up.

## Relation to Survey

This follows the **Planner → Implementer** pattern from [[orchestration-survey]]:

> "The self-planning study by Jiang et al. (2025) exemplifies this: the LLM generates concise, structured planning steps from the intent, then in the implementation phase it 'generates code step by step, guided by the preceding planning steps'. This two-pass approach yielded significantly higher correctness than a single-pass solution."

The survey also discusses **Reviewer passes** for catching mistakes. noface implements this with a dedicated reviewer agent that checks each implementation before merge.

## Design Decisions

### 1. Pass Intervals: Event-driven + adaptive

**Planner:**
- Run periodically when backlog needs organization
- Run when no ready issues exist

**Reviewer:**
- Always runs after worker signals READY_FOR_REVIEW
- No cost optimization (every implementation gets reviewed)

**Quality:**
- Run when a batch of N issues is completed
- Run when failure rate spikes

### 2. Feedback Loops: Quality findings feed back to implementer

**Implementation:**
- When quality pass opens "follow-up issues", attach:
  - Links to the original issue
  - The quality agent's analysis
- When implementer picks up follow-up issue, include analysis in prompt

### 3. Model Selection: Abstract behind roles

**Design:**
```toml
[models]
planner = "claude"
implementer = "claude"
reviewer = "claude"
quality = "codex"
```

Make it easy to A/B test different combinations.

## Implementation Notes

See `lib/noface/core/loop.ex` and `lib/noface/core/worker_pool.ex`.

### TODO
- [ ] Add reviewer pass with risk-based triggering (skip for low-risk)
- [ ] Attach quality findings to follow-up issues
- [ ] Add per-pass metrics logging
- [ ] Abstract model selection behind role config
