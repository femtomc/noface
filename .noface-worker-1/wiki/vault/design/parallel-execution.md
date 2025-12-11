---
title: "Parallel Execution"
type: essay
tags: [design, parallelism, batching, locking]
---

# Parallel Execution

How noface runs multiple agents concurrently without conflicts.

## Current Design

1. **Planner pass** groups issues into batches based on manifest analysis
2. Issues in the same batch have **disjoint primary_files** (no overlap)
3. **Worker pool** spawns up to N parallel processes (configurable, default 8)
4. **Lock entries** track which files are held by which worker
5. Batches execute sequentially; issues within a batch execute in parallel

## Relation to Survey

This implements the **file-level locking** pattern from [[orchestration-survey]]:

> "A community-built 'Claude code agent farm' demonstrates this with a coordination protocol: each agent must create a lock file listing the files/features it intends to work on, and consult a shared active work registry to ensure no overlap."

The survey also discusses **CRDTs** for lock-free coordination (CodeCRDT achieved 100% merge convergence). This is more scalable but more complex.

## Design Decisions

### 1. Lock Granularity: File-level only (for now)

**Decision:** Start with file-level locking only. Add function-level as a future optimization for specific languages.

**File-level:**
- Easy to reason about
- Guarantees no diff overlap

**Function-level (deferred):**
- Needs parser, symbol table, stable function IDs
- Harder for languages with macros, generated code, ad-hoc patterns

**Instead, get most of the win by:**
- Task design: aim one issue per file or small set of files
- Using manifest to ensure each issue's scope is small and minimally overlapping

If later we need function-level:
- Limit to languages where we already have a good AST + symbol index
- Keep file-level as fallback

### 2. Batch Sizing: Adaptive concurrency

**Decision:** Use adaptive concurrency based on runtime signals.

**Config:**
```toml
[parallelism]
max_concurrent_global = 8      # hard cap
max_concurrent_per_repo = 4    # per-repo cap
initial_concurrency = 2        # starting point
```

**Runtime signals:**
- Average agent latency
- Queue length
- Error rate

**Policy:**
1. Start with N = 2
2. If queue backlog grows and success rate is high → increase toward max
3. If failures/timeouts increase or host is resource constrained → back off

Also: maintain a "serial bucket" for issues touching very hot files (see below).

### 3. Lock Contention: Hot file detection + mitigation

**Decision:** Track per-file lock statistics and treat "hot files" specially.

**Metrics to track:**
- Lock wait time per file
- Number of pending issues referencing each file

**If a file (e.g., `main.zig`) is often a bottleneck:**
- Force tasks that touch that file into a single-threaded lane (queue)
- Encourage planner to batch related issues touching that file into one larger issue
- Suggest refactor tasks: spawn meta-issue "split main.zig into modules"

**Implementation:**
```zig
// In-memory or persisted
const HotFileStats = struct {
    lock_count: u32,
    avg_wait_ms: u64,
    queue_depth: u32,
};
// Map: file_path -> HotFileStats
```

Use this when scheduling new issues.

### 4. Conflict Recovery: Three-step policy

**Decision:** Define a concrete conflict resolution pipeline.

**Step 1: Detect**
- Two diffs touch overlapping hunks, or
- `git apply` fails

**Step 2: Auto-merge**
- Try a 3-way merge (base, A, B)
- If succeeds cleanly, run tests
- If tests pass, accept merged result

**Step 3: LLM-assisted merge**
- Spawn a "merge agent" with both diffs + conflicts
- Ask it to produce a unified patch
- Run tests again

**Step 4: Escalate**
- If merge agent fails or tests still fail
- Escalate to human
- Leave a merge PR with both original diffs + explanation

### 5. CRDT Exploration: AST-aware patching as middle ground

**Decision:** Use AST-aware patching + 3-way merge instead of full CRDTs.

**Approach:**
- Ask agents to emit structured edits per file:
  - "Replace function foo body with …"
  - "Add new function bar…"
- Internally apply these as AST transformations, not raw text splice

**Merge behavior:**
- Two agents modifying different functions in the same file → trivially merge
- Same function → conflict; go through the conflict policy above

This gets most of the benefits of CRDT-style structural merges without full-blown replicated state machinery.

## Implementation Notes

See `src/worker_pool.zig:WorkerPool` and `src/state.zig:LockEntry`.

### TODO
- [ ] Add `HotFileStats` tracking
- [ ] Implement adaptive concurrency (start low, ramp up)
- [ ] Add serial lane for hot files
- [ ] Implement 3-way merge fallback
- [ ] Design structured edit format for AST-aware patching
