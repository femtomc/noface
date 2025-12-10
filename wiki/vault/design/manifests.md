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

## Design Decisions

### 1. Granularity: File-level with soft function hints

**Decision:** Stick to file-level manifests as the hard safety boundary. Add soft function-level hints inside the prompt.

- Use the manifest as: "these are the only files you're allowed to change"
- Inside each file, include function-level "edit targets" in the prompt:
  ```
  You may edit only these functions in foo.zig: [foo, bar].
  ```
- Line-ranges are brittle (they drift with edits and refactors)
- Function-level locking requires language-aware parsing and a robust symbol table — nice-to-have for later, not v1 safety

### 2. Manifest Generation: Instrumentation + replan on miss

**Decision:** Treat false negatives as an instrumentation problem first.

Log for each issue:
- `manifest_files_predicted`
- `files_actually_touched` (from diff)

Compute:
- **False positives:** predicted but unused (acceptable — widens safety sandbox)
- **False negatives:** needed but not declared (problematic)

**Short-term behavior:** If the agent attempts to touch a non-manifest file:
1. Reject that attempt
2. Spawn a replan: run planner again with the new file explicitly mentioned
   - e.g. "You also needed X.zig; update your manifest"

**Goal:** Tune planner + retrieval so false negatives are rare.

### 3. Manifest Violations: Never accept as-is

**Decision:** Never accept a violation directly. Use violations as hints for replanning.

If the change is clearly correct:
1. Record: "Agent wanted to touch foo.zig too"
2. Re-run planner with that fact, generate a new manifest including foo.zig
3. Re-run the implementation under the new manifest
4. Only then accept

For interactive mode, offer:
```
Agent touched out-of-manifest file X, the change looks good.
➜ [Accept & expand manifest] / [Re-run] / [Discard]
```

The automation path should always have a manifest-consistent attempt before merging.

### 4. Dynamic Expansion: Yes, via orchestrator-mediated "manifest v2"

**Decision:** Allow agents to request additional files mid-run, but only through explicit orchestrator coordination with locking rules applied.

**Flow:**
1. Agent hits missing symbol/doc and outputs:
   ```
   NEED_FILE: src/auth.zig
   ```
   or
   ```
   NEED_DOC: design/auth.md
   ```
2. Orchestrator checks locks:
   - If `auth.zig` is free:
     - Acquire lock
     - Produce manifest v2 including `auth.zig`
     - Re-prompt the agent with expanded manifest and new file content
   - If locked by another task:
     - Tell agent: "You cannot access auth.zig because it's locked; proceed without or wait"

This preserves the isolation model:
- No silent expansion
- All expansions are explicit, logged, and coordinated with concurrency control

## Implementation Notes

See `src/state.zig:Manifest` and `src/loop.zig:verifyManifestCompliance`.

### TODO
- [ ] Add manifest instrumentation (predicted vs actual files)
- [ ] Implement replan-on-violation flow
- [ ] Add `NEED_FILE` / `NEED_DOC` signal parsing
- [ ] Add function-level hints to prompt builder
