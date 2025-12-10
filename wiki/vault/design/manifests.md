---
title: "File Manifests"
type: essay
tags: [design, manifests, access-control]
---

# File Manifests

How noface controls what files each agent can touch.

## Current Design

Manifests declare three access levels per issue:

- **PRIMARY_FILES** — exclusive write access (locked during execution)
- **READ_FILES** — shared read-only access
- **FORBIDDEN_FILES** — must never be touched

The planner generates manifests by analyzing each issue. After an agent completes, noface runs `git diff` and verifies compliance. Violations trigger rollback of offending files and retry with a stricter prompt.

## Relation to Survey

This implements the **Manifest-Driven AI Development (MAID)** pattern from [[orchestration-survey]]:

> "A recent methodology called Manifest-Driven AI Development (MAID) takes this further by treating the manifest as an enforceable contract: after generation, a validator checks that only the declared files/functions were altered and no undeclared edits occurred."

## Open Questions

1. **Granularity** — File-level is coarse. Should we support function-level or line-range manifests?

2. **Manifest Generation** — How good is the planner at predicting which files an issue will touch? What's the false-negative rate (files needed but not declared)?

3. **Manifest Violations** — Current behavior is rollback + retry. Should we ever accept a violation if the change is clearly correct?

4. **Dynamic Expansion** — Should agents be able to request additional files mid-execution? Or does that break the isolation model?

## Implementation Notes

See `src/state.zig:Manifest` and `src/loop.zig:verifyManifestCompliance`.
