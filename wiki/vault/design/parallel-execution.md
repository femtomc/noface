---
title: "Parallel Execution"
type: essay
tags: [design, parallelism, jj, workspaces]
---

# Parallel Execution

How noface runs multiple agents concurrently without conflicts.

## Current Design

noface uses **jj (Jujutsu) workspaces** for parallel execution:

1. Each worker gets an **isolated workspace** (`.noface-worker-N/`)
2. Workers can modify any files without coordination
3. Changes are **squashed and merged** at the root after review approval
4. **Greedy scheduler** assigns ready issues to idle workers

## Architecture

```
Root repo (main working copy)
├── .noface-worker-0/  (jj workspace)
├── .noface-worker-1/  (jj workspace)
├── .noface-worker-2/  (jj workspace)
└── ...
```

### Workflow

1. **Worker spawned** → runs in its isolated workspace
2. **Implementation** → worker modifies files freely
3. **Review** → reviewer agent checks changes in the workspace
4. **Merge** → merge agent squashes workspace changes to root

### Why jj Workspaces?

jj workspaces provide true isolation:
- Each workspace has its own working copy
- No file locking needed
- No manifest-based conflict detection
- Conflicts only possible at merge time (handled by merge agent)

## Conflict Resolution

Since workers are isolated, conflicts only arise during merge:

1. **Merge agent** attempts `jj squash --from <workspace> --into @`
2. If conflicts occur, merge agent resolves them
3. Tests run to verify the merge
4. If merge fails, escalate to human

## Configuration

```toml
[parallelism]
num_workers = 5  # Number of parallel workers (default: 5, max: 8)
```

## Implementation Notes

See `src/core/worker_pool.zig:WorkerPool` and `src/vcs/jj.zig:JjRepo`.

### Worker Phases

Each worker progresses through phases:
1. `implementing` → worker implements the issue
2. `reviewing` → reviewer checks the implementation
3. `merging` → merge agent integrates changes

### Greedy Scheduling

The scheduler is simple and greedy:
```
while has_ready_work:
    for each idle_worker:
        issue = next_ready_issue()
        if issue:
            spawn_worker(worker, issue)

    poll_workers()
    handle_completions()
```

No batching or manifest analysis needed - jj handles isolation.
