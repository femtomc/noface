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

## Open Questions

1. **Lock Granularity** — File-level prevents conflicts but may be too conservative. Two agents could safely edit different functions in the same file. Is function-level locking worth the complexity?

2. **Batch Sizing** — How do we decide how many issues to batch together? More parallelism = faster, but also more resource contention and harder debugging.

3. **Lock Contention** — With many issues, popular files (e.g., `main.zig`) become bottlenecks. How do we detect and mitigate hot files?

4. **Conflict Recovery** — If a conflict somehow occurs (manifest was wrong), what's the resolution strategy? Currently undefined.

5. **CRDT Exploration** — Is there a simpler middle ground between locks and full CRDTs? AST-aware merging?

## Implementation Notes

See `src/worker_pool.zig:WorkerPool` and `src/state.zig:LockEntry`.
