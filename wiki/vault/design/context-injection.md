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

## Open Questions

1. **Context Budget** — Is `max_context_docs = 5` the right number? Should it be dynamic based on issue complexity?

2. **Relevance Ranking** — Currently we fetch docs by wikilink or search. Should we score/rank by semantic relevance? Embeddings?

3. **Code Context** — Should we inject relevant source files? Which ones? The survey mentions BM25 search over codebase (noface has `src/bm25.zig`).

4. **Context Freshness** — If a doc is stale (refers to old API), it could mislead the agent. How do we detect/handle this?

5. **Negative Context** — What explicitly *shouldn't* be included? Large generated files? Vendored deps? How do we filter?

6. **Agent-Requested Context** — Should agents be able to ask for more context mid-run? Or does the harness (Claude Code) handle this internally?

## Implementation Notes

See `src/loop.zig:buildImplementationPrompt` and `src/monowiki.zig`.
