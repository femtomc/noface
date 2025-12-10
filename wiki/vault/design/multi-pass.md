---
title: "Multi-Pass Architecture"
type: essay
tags: [design, planner, reviewer, passes]
---

# Multi-Pass Architecture

How noface uses multiple agent passes to improve quality.

## Current Design

noface runs three types of passes:

1. **Planner pass** (Codex) — every N iterations
   - Analyzes issue backlog
   - Generates file manifests for each issue
   - Groups non-conflicting issues into parallel batches

2. **Implementation pass** (Claude) — per issue
   - Receives issue + manifest + context
   - Implements the change, runs tests, commits

3. **Quality pass** (Codex) — every M iterations
   - Scans codebase for tech debt
   - Creates new issues for findings

## Relation to Survey

This follows the **Planner → Implementer** pattern from [[orchestration-survey]]:

> "The self-planning study by Jiang et al. (2025) exemplifies this: the LLM generates concise, structured planning steps from the intent, then in the implementation phase it 'generates code step by step, guided by the preceding planning steps'. This two-pass approach yielded significantly higher correctness than a single-pass solution."

The survey also discusses **Reviewer passes** for catching mistakes. noface's quality pass is similar but focuses on proactive debt detection rather than reviewing specific changes.

## Open Questions

1. **Pass Intervals** — `planner_interval = 5` and `quality_interval = 10` are arbitrary. What's optimal? Should they be adaptive?

2. **Reviewer Pass** — Should noface add a dedicated reviewer pass that checks each implementation before accepting? Current flow trusts tests + manifest.

3. **Feedback Loops** — If the quality pass finds issues, they become new issues. But there's no direct feedback to the implementer. Should there be?

4. **Pass Ordering** — Planner runs periodically, not before every implementation. Does this cause stale manifests? Should planner run on-demand?

5. **Diminishing Returns** — The survey notes additional passes have diminishing returns. How do we measure if a pass is worth the cost?

6. **Model Selection** — Planner/quality use Codex; implementation uses Claude. Is this the right split? Should we try other combinations?

## Implementation Notes

See `src/loop.zig:runPlannerPass`, `runQualityPass`, `runIteration`.
