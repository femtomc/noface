---
title: "Context Injection"
type: essay
tags: [design, context, prompts, monowiki]
---

# Context Injection

What information noface provides to agents and how.

## Current Design

The implementation prompt includes:

1. **Issue description** — from beads
2. **Manifest** — which files the agent can touch
3. **Build/test commands** — from `.noface.toml`
4. **Design docs** — fetched from monowiki if configured
5. **Workflow instructions** — step-by-step process (implement → test → commit)

Context is capped by `max_context_docs` setting (default 5).

## Relation to Survey

The survey warns about **context dilution**:

> "Recent studies have shown that even if all provided context is relevant, performance can degrade substantially (by 13–85%) as input length grows."

And recommends **iterative context expansion**:

> "The Context-Augmentation pattern described by Hugging Face highlights that context expansion should be iterative and need-based: the agent identifies what extra info it needs, the orchestrator fetches it."

## Design Decisions

### 1. Context Budget: Dynamic based on token budget and complexity

**Decision:** Make context budget dynamic, not fixed.

**Approach:**
- Define a target fraction of prompt tokens for retrieved docs (e.g., 30–40%)
- Fill that slot with as many top-ranked docs as fit
- Complexity heuristics:
  - More files / cross-cutting change → allow more docs
  - Tiny, local change → maybe 0–2 docs only

Keep `max_context_docs = 5` as a hard cap, but choose K ∈ [0, 5] per issue based on:
- Issue complexity score
- Available token budget
- Relevance scores of candidate docs

### 2. Relevance Ranking: Hybrid BM25 + embeddings

**Decision:** Use hybrid ranking instead of simple wikilink fetching.

**Pipeline:**
1. **Candidate generation:**
   - Wikilinks / explicit references from the issue
   - BM25 search (already have `src/bm25.zig`)
2. **Re-ranking:**
   - Embedding similarity (doc ↔ issue description)
3. **Final score:**
   ```
   score = α * BM25 + β * embedding_score + boost_if_explicitly_linked
   ```

This will beat naive "first N by wikilink" in most repos.

### 3. Code Context: Manifest files + relevant snippets

**Decision:** Include manifest files plus targeted snippets from related code.

**Always include:**
- The files in the manifest that the agent is allowed to edit

**Optionally include:**
- Small snippets from related files:
  - Direct callers/callees (if xref info available)
  - BM25/embedding matches for key identifiers in the issue

**Guardrails:**
- Truncate to relevant functions rather than whole files when possible
- If file is huge, include:
  - Signature + docstring + 1–2 nearby functions
- Use BM25 over code to pick relevant ranges, not entire files

### 4. Context Freshness: Downrank stale docs, don't hard exclude

**Decision:** Add freshness metadata + downranking, not hard exclusion.

**For each doc, track:**
- `last_updated` timestamp
- Optionally "tied-to-commit" info

**Heuristics:**
- If doc references symbols that no longer exist in code → heavily downrank or mark stale
- If `now - last_updated > threshold` and code around it changed a lot → downrank

**In the prompt, for borderline docs:**
```
Note: this doc may be outdated; prefer the current code as source of truth.
```

Relevant but slightly stale docs can still help, but the model is warned.

### 5. Negative Context: Explicit exclusion list

**Decision:** Define explicit exclusions + heuristics.

**Path-based exclusions:**
- `vendor/`, `node_modules/`, `dist/`, `build/`, `.cache/`
- `*.min.js`, large generated protobufs

**Size-based:**
- Files > X KB not included unless explicitly requested

**Type-based:**
- Binary blobs, lockfiles, big JSON dumps

Implement in retrieval pipeline so excluded files never show up as candidates.

### 6. Agent-Requested Context: Thin orchestrator layer + harness delegation

**Decision:** Lean on Claude Code's native file-opening capabilities, add thin orchestrator layer for explicit requests.

**If using Claude Code / similar harness:**
- Let the harness handle intra-session context (open file, run search, etc.)

**At orchestration level:**
- Support structured "needs more context" signals:
  ```
  NEED_CODE: auth/login.zig
  NEED_DOC: docs/auth.md
  ```
- When signal detected:
  - Fetch & add context on next call, or
  - Delegate to harness's file-opening APIs

**Don't** build a whole second interactive context loop on top of Claude.
**Do** add a thin layer to observe/log/respond when agent clearly asks for more info.

## Implementation Notes

See `src/loop.zig:buildImplementationPrompt` and `src/monowiki.zig`.

### TODO
- [ ] Implement dynamic context budget based on issue complexity
- [ ] Add hybrid ranking (BM25 + embeddings)
- [ ] Add freshness tracking to monowiki docs
- [ ] Implement exclusion list in retrieval pipeline
- [ ] Parse `NEED_CODE` / `NEED_DOC` signals from agent output
