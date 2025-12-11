---
title: noface
description: Design documentation for the noface autonomous agent orchestrator
---

# noface

An autonomous agent orchestrator for software development. noface coordinates black-box agents (Claude Code, Codex) to work on issues from your backlog — in parallel, with conflict detection, crash recovery, and quality gates.

## Research

- [[orchestration-survey]] — Literature survey on design patterns for orchestrating code agents

## Design

Core infrastructure decisions:

- [[manifests]] — File access control via PRIMARY/READ/FORBIDDEN declarations
- [[parallel-execution]] — Batching, locking, and conflict avoidance
- [[context-injection]] — What information agents receive and how
- [[multi-pass]] — Planner → Implementer → Reviewer architecture
- [[failure-recovery]] — Retry, rollback, escalation strategies
- [[verification]] — How we know an agent succeeded

## Quick Links

- [GitHub](https://github.com/...)
- [Issue Tracker](/.beads/issues.jsonl)
