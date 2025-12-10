# Technical Writing Agent Design

> Design document for integrating a documentation agent into noface orchestration

See also: [[research/technical-writing-agent]]

## Problem Statement

Current LLM agents produce poor technical documentation:
- Verbose, filler-heavy prose
- Miss load-bearing information
- Hallucinate nonexistent features
- Lose track of reader context
- Inconsistent across doc corpus

## Design Goals

1. **Concise**: High information density, no filler
2. **Accurate**: Tied to actual code, no hallucinations
3. **Scoped**: Only document what changed or needs docs
4. **Consistent**: Follow templates, match existing style
5. **Integrated**: Triggered automatically by orchestrator

---

## Architecture: Multi-Agent Pipeline

Based on Meta's DocAgent research, use specialized agents:

```
┌─────────────────────────────────────────────────────────────┐
│                     DOC ORCHESTRATOR                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. SCOPE AGENT                                             │
│     Input: git diff, closed issues, manifest                │
│     Output: List of doc tasks (what needs documentation)    │
│                                                             │
│  2. CONTEXT AGENT                                           │
│     Input: Doc task, codebase                               │
│     Output: Relevant code snippets, existing docs           │
│                                                             │
│  3. WRITER AGENT                                            │
│     Input: Context, template, reader profile                │
│     Output: Draft documentation                             │
│                                                             │
│  4. CRITIC AGENT                                            │
│     Input: Draft, context, style guide                      │
│     Output: Edits (cut fluff, fix errors, add missing)      │
│                                                             │
│  5. VERIFIER AGENT                                          │
│     Input: Final draft, code                                │
│     Output: Factual accuracy check                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Agent Specifications

### Scope Agent

**Purpose**: Determine what needs documentation

**Triggers**:
- New public API added
- Existing API signature changed
- New file in `docs/` or `examples/` directories
- Issue closed with label `docs-needed`
- Config options added/changed

**Outputs**:
- `DOC_TASK: api-reference <function_name>`
- `DOC_TASK: tutorial <feature>`
- `DOC_TASK: changelog <version>`
- `NO_DOCS_NEEDED` (internal change, test-only, etc.)

### Context Agent

**Purpose**: Gather relevant information for writer

**Gathers**:
- Function signatures, types, docstrings
- Related existing documentation
- Usage examples from tests
- Similar patterns in codebase

**Does NOT**:
- Read entire codebase
- Include irrelevant context

### Writer Agent

**Purpose**: Draft documentation following templates

**Templates** (enforced structure):

```markdown
## API Reference Template
### `function_name`
Brief one-line description.

**Parameters:**
- `param1` (type): Description

**Returns:**
- type: Description

**Example:**
```code
usage example
`` `

**Notes:**
- Edge cases, caveats
```

```markdown
## Tutorial Template
### Title
One sentence: what you'll learn.

**Prerequisites:**
- List assumed knowledge

**Steps:**
1. Step with code
2. Step with code

**Result:**
What user should see/have
```

### Critic Agent

**Purpose**: Cut ruthlessly, fix errors

**Checks for**:
- Filler words: "just", "simply", "basically", "very", "really"
- Redundant explanations
- Missing information (params, returns, errors)
- Inconsistency with existing docs
- Incorrect information vs code

**Actions**:
- DELETE unnecessary sentences
- REWRITE verbose passages
- ADD missing required sections
- FLAG uncertain claims for human review

### Verifier Agent

**Purpose**: Final accuracy check

**Validates**:
- Code examples compile/run
- Parameter names match actual code
- Return types are correct
- Referenced functions exist

---

## Integration with noface

### Trigger Points

```
Issue Complete
    ↓
Code Review Pass
    ↓
[DOC AGENT TRIGGERED]
    ↓
Scope Agent: "Does this need docs?"
    ↓
If yes: Run pipeline
    ↓
Output: PR with doc changes OR comment on issue
```

### Manifest Extension

Add to issue manifests:
```
docs_scope: api-reference | tutorial | none
docs_files: [list of doc files to update]
```

### Output Options

1. **Inline**: Add docstrings directly to code
2. **Separate**: Create/update markdown in `docs/`
3. **Issue comment**: Attach draft for human review
4. **PR**: Open separate docs PR

---

## Critic Loop Implementation

```
writer_draft = Writer.generate(context, template)
for i in range(MAX_ITERATIONS):
    critique = Critic.review(writer_draft)
    if critique.is_approved:
        break
    writer_draft = Writer.revise(writer_draft, critique)
return Verifier.check(writer_draft)
```

**Stopping conditions**:
- Critic approves
- Max iterations reached (escalate to human)
- No changes between iterations

---

## Reader Modeling

Include reader profile in writer prompt:

```
READER_PROFILE:
- Role: Backend developer
- Familiarity: Knows Zig basics, unfamiliar with noface internals
- Goal: Integrate noface into CI pipeline
- Skip: Basic Zig syntax, git basics
- Explain: noface-specific concepts, config options
```

Derive reader profile from:
- Doc type (API ref → experienced dev, tutorial → newcomer)
- Explicit issue labels
- Default per-project config

---

## Open Questions

1. **Fine-tuning vs prompting**: Should we fine-tune a small model on our docs style?
2. **Human gate placement**: Every doc, or only flagged ones?
3. **Incremental updates**: How to update existing docs without rewriting everything?
4. **Multi-language**: How to handle docs in multiple languages?
5. **Versioning**: How to handle docs for multiple versions?

---

## Implementation Phases

### Phase 1: Scope Detection
- Detect when docs are needed from diffs
- Output `DOC_TASK` signals

### Phase 2: Single-Agent Writer
- Basic template-driven generation
- No critic loop yet

### Phase 3: Critic Loop
- Add critic agent
- Iterative refinement

### Phase 4: Verifier
- Code example validation
- Cross-reference checking

### Phase 5: Full Pipeline
- Multi-agent orchestration
- Human review integration
