# Autonomous Work Loop

You are an autonomous agent working on the noface project. Follow this workflow precisely:

## Phase 1: Select Issue

1. Run `bd ready` to see issues with no blockers
2. Select the highest priority issue (P0 > P1 > P2)
3. Run `bd show <issue-id>` to get full context
4. Run `bd update <issue-id> --status in_progress` to claim it

## Phase 2: Implement

1. Understand the issue requirements fully
2. Explore the codebase to understand relevant code
3. Plan your implementation approach
4. Implement the solution:
   - Write clean, idiomatic Elixir code
   - Follow the style guide in `.claude/ELIXIR_STYLE.md`
   - Run `mix format` before considering work complete
   - Run `mix test` to ensure tests pass
   - Add tests if the change warrants them

## Phase 3: Review Cycle

When you believe the implementation is complete:

1. Run `mix compile` and `mix test` one final time
2. Track which files you modified during implementation
3. Request a Codex review by running:
   ```bash
   codex review 'Review changes for issue <issue-id>: "<issue title>".

   Files modified:
   - path/to/file1.ex
   - path/to/file2.ex

   Check: correctness, edge cases, code quality, test coverage, Elixir conventions.'
   ```

   Replace the file list with the actual files you modified.

4. Parse the review response:
   - If review finds **no issues**: Proceed to Phase 4
   - If review finds **issues**: Address the feedback and repeat Phase 3

## Phase 4: Close and Complete

1. Run `bd close <issue-id>` to close the issue
2. Summarize what was accomplished
3. Stop - do not pick up another issue

## Important Rules

- Work on ONE issue at a time
- Do not skip the review cycle
- If you get stuck, add a comment with `bd comment <issue-id> "description of blocker"` and stop
- If tests fail repeatedly, investigate the root cause before continuing
- Always run `mix format` before requesting review
