---
title: "Verification"
type: essay
tags: [design, verification, testing, acceptance]
---

# Verification

How noface determines whether an agent succeeded.

## Current Design

noface uses multiple verification layers:

1. **Test execution** — runs the configured test command; failure = not done
2. **Reviewer approval** — dedicated reviewer agent checks each implementation
3. **Build check** — runs the configured build command (implicit in agent workflow)

The agent is instructed to self-verify (run tests, check output) before signaling ready for review.

## Relation to Survey

The survey emphasizes **automated testing as ground truth**:

> "This ensures that code isn't accepted as 'done' until it passes its tests. Even single-agent approaches like OpenAI's Codex have employed this idea (often called execute-and-fix): run the code, and if an error or failing test is detected, prompt the model to fix it."

The survey also discusses **LLM critics** as an additional layer — a second agent that reviews the code. noface implements this with dedicated reviewer agents that check each implementation before merge.

## Design Decisions

### 1. Test Coverage: Require tests for new behavior

**Decision:** Add test-centric enhancements for changes that add new behavior.

**For changes that add new behavior:**
- Ask agent to write or update tests as part of the task
- Optionally run coverage diff if coverage tool exists:
  - If new/changed lines have zero coverage → soft or hard gate

**Where tooling is limited:**
- At least ensure: "If tests exist in this module, check that they were updated"
- Warn if tests not updated for behavioral changes

### 2. Review Pass: Optional but recommended for non-trivial changes

**Decision:** Add dedicated reviewer pass as an optional gate for non-trivial changes.

**Reviewer inputs:**
- Issue description
- Old code vs new code diff
- Test results

**Reviewer outputs:**
- Verdict: `OK` / `NOT_OK` / `NEEDS_HUMAN`
- Specific comments

**Trigger heuristics:**
| Condition | Action |
|-----------|--------|
| Large diffs | Always review |
| High-risk directories | Always review |
| Changes without tests | Always review |
| Small, well-tested changes | Skip or downgrade |

### 3. Static Analysis: Integrate repo's existing tools

**Decision:** Integrate whatever static analysis the repo already has.

**Hard gates (block on failure):**
- Type errors (`mix compile`, `tsc`, `mypy`)
- Formatter failures (`mix format --check-formatted`, `prettier`)

**Soft gates (log, maybe create follow-up):**
- New lint warnings
- Security scanner findings (unless critical)

```toml
[verification.static_analysis]
hard_gates = ["mix compile --warnings-as-errors", "mix format --check-formatted"]
soft_gates = ["mix credo", "eslint"]
```

### 4. Semantic Verification: Judge agent for complex issues

**Decision:** Add semantic check step for complex issues.

**Option 1: Explicit reasoning**
- Have implementer/reviewer write: "Here is how the change addresses the issue…"
- Check coherence between explanation and diff

**Option 2: Judge agent**
- Input: issue description + old code + new code
- Question: "Does this change resolve the described behavior? Is anything missing or unrelated?"

Doesn't need to be perfect; even catching obvious mismatches is a big win.

### 5. Confidence Signals: Explicit confidence + risk metadata

**Decision:** Ask agent to output explicit confidence and risks.

**Prompt addition:**
```
After implementing, output:
CONFIDENCE: X/5
RISKS:
- [list any edge cases or uncertainties]
```

**Policy:**
- If confidence ≤ 2/5 → require reviewer + maybe human
- Also watch for heuristics:
  - Lots of TODOs in output
  - "I think / maybe" in comments
  - Weirdly small or huge diffs

### 6. Partial Acceptance: Hard vs soft gates

**Decision:** Define hard vs soft gates; never partially merge.

**Hard gates (must pass for merge):**
- Tests passing
- No syntax/build errors
- Reviewer approval

**Soft gates (can proceed with warnings):**
- Lint warnings
- Coverage thresholds
- Reviewer "nit" comments

**Policy:**
- Automated merge requires all hard gates
- Soft gate failures:
  - Either block and open follow-up issue, or
  - Allow merge but log warnings and create cleanup issues

Avoid partial merges of file subsets; use the branch model from [[failure-recovery]] instead.

### 7. Human Review Gate: Risk classification for high-risk changes

**Decision:** Build risk classification with hard human gate for sensitive areas.

**High-risk triggers:**
- Files/directories: `auth/`, `payments/`, `secrets/`, `infra/`, `prod-config/`
- Labels: `security`, `compliance`, `breaking-change`

**For high-risk changes:**
- noface never auto-merges
- Opens PR or surfaces diff with "requires human approval" flag
- Optionally pre-annotated with AI reviewer's comments

```toml
[verification.human_required]
paths = ["src/auth/", "src/payments/", "config/prod/"]
labels = ["security", "compliance"]
```

## Implementation Notes

See `lib/noface/core/worker_pool.ex` and `lib/noface/core/prompts.ex` for reviewer prompt.

### TODO
- [ ] Add test coverage checking (if coverage tool available)
- [ ] Implement reviewer pass with risk-based triggering
- [ ] Add static analysis integration (hard/soft gates)
- [ ] Add judge agent for semantic verification
- [ ] Parse confidence/risk metadata from agent output
- [ ] Add human review gate for high-risk paths
- [ ] Implement soft gate → follow-up issue creation
