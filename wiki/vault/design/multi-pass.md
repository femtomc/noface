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

## Design Decisions

### 1. Pass Intervals: Event-driven + adaptive (not fixed)

**Decision:** Move from fixed intervals to event-driven + adaptive.

**Planner:**
- Run on-demand for new issues (always)
- Run periodically when:
  - A manifest violation occurs (planner "missed" a file)
  - Large codebase change merged (e.g., big refactor)

**Quality:**
- Run when:
  - A batch of N issues is completed
  - A spike in failures or bug reports is observed

Keep `planner_interval` and `quality_interval` as fallback periodic jobs, but teach orchestrator to invoke them in response to signals.

### 2. Reviewer Pass: Yes, for high-risk changes

**Decision:** Add a dedicated reviewer pass, but only for certain classes of changes.

**Trigger reviewer when:**
- Diff size > threshold
- Changed files in `security/`, `auth/`, `infra/`, `config/`
- No tests exist or coverage is low

**For low-risk, tiny changes where tests are strong:**
- Tests + manifest is probably enough; skip reviewer to save cost

### 3. Feedback Loops: Quality findings feed back to implementer

**Decision:** Quality findings should feed back directly to next implementation attempt.

**Implementation:**
- When quality pass opens "follow-up issues", attach:
  - Links to the original issue
  - The quality agent's analysis (e.g., "didn't handle null case in X")
- When implementer picks up follow-up issue, include analysis in prompt:
  ```
  The previous attempt failed because: [list]. Fix these specific problems.
  ```

This turns the quality pass into a teacher, not just a bug generator.

### 4. Pass Ordering: Planner on-demand per-issue (not just periodic)

**Decision:** Run planner on-demand for manifests, keep periodic for backlog management.

**Flow:**
1. New issue arrives
2. Planner runs, generates manifest + hints
3. Implementation runs

**Periodic planner still exists for:**
- Rebalancing / reprioritizing backlog
- Suggesting new refactor issues

Relying only on periodic planner is where "stale manifests" come from.

### 5. Diminishing Returns: Data-driven pass value metrics

**Decision:** Log per-pass value metrics and make decisions data-driven.

**For each pass type (planner, reviewer, quality), count:**
- How often it changes outcome:
  - Reviewer finds a bug → implementation corrected
  - Quality pass yields issues not caught otherwise

**Track:**
- Average tokens / time per pass
- Compute: "Bugs caught per thousand tokens" or "per minute"

If reviewer catches issues in 1/50 changes but costs a lot, restrict it to riskier paths.

### 6. Model Selection: Abstract behind roles, default to strong model

**Decision:** Short term, keep it simple and unify models where reasoning matters.

**Design:**
```toml
[models]
planner = "claude"       # strong model for planning
implementer = "claude"   # strong model for implementation
reviewer = "claude"      # can use cheaper if cost-sensitive
quality = "codex"        # can use cheaper for triage
```

**Rationale:**
- Planner quality matters a lot; using same strong model as implementer often improves plans
- Quality/triage can often use cheaper model if cost is a concern

Make it easy to A/B test different combinations.

## Implementation Notes

See `src/loop.zig:runPlannerPass`, `runQualityPass`, `runIteration`.

### TODO
- [ ] Implement on-demand planner trigger for new issues
- [ ] Add reviewer pass with risk-based triggering
- [ ] Attach quality findings to follow-up issues
- [ ] Add per-pass metrics logging
- [ ] Abstract model selection behind role config
