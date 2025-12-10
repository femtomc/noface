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
2. **Manifest compliance** — `git diff` checked against declared files; violations = rollback
3. **Build check** — runs the configured build command (implicit in agent workflow)

The agent is instructed to self-verify (run tests, check output) before committing.

## Relation to Survey

The survey emphasizes **automated testing as ground truth**:

> "This ensures that code isn't accepted as 'done' until it passes its tests. Even single-agent approaches like OpenAI's Codex have employed this idea (often called execute-and-fix): run the code, and if an error or failing test is detected, prompt the model to fix it."

And **manifest verification**:

> "Tools like MAID runner perform static analysis on the diff: did the agent only modify the allowed files and functions?"

The survey also discusses **LLM critics** as an additional layer — a second agent that reviews the code.

## Open Questions

1. **Test Coverage** — What if the tests don't cover the change? Agent could introduce a bug that passes existing tests.

2. **Review Pass** — Should noface run a dedicated reviewer agent on each change before accepting? Cost vs. benefit?

3. **Static Analysis** — Should we run linters, type checkers, security scanners as additional gates?

4. **Semantic Verification** — Tests check behavior, manifests check scope. But what about "did the agent actually address the issue?" Sometimes code passes tests but doesn't solve the problem.

5. **Confidence Signals** — Can we detect low-confidence completions? Agent says "done" but hedges in comments? Unusual patterns?

6. **Partial Acceptance** — If 2 of 3 acceptance criteria pass, do we accept partially? Or all-or-nothing?

7. **Human Review Gate** — For high-risk changes (security, config), should noface require human approval?

## Implementation Notes

See `src/loop.zig:verifyManifestCompliance` and prompt instructions for self-testing.
