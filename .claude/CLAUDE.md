# Noface - Agent Orchestrator

Autonomous agent loop for software development. Orchestrates Claude (implementation) and Codex (review) to work on issues from your backlog.

Use `/work` to start the autonomous work loop.

## Quick Reference

```bash
# Build & test
mix compile          # Compile the project
mix test             # Run tests
mix format           # Format code (always run before commits)

# Issue tracking (bd/beads)
bd list              # List all issues
bd show <id>         # Show issue details
bd create "title"    # Create new issue
bd update <id> --status in_progress
bd close <id>        # Close an issue
bd ready             # Show ready work (no blockers)
bd sync              # Sync with git remote

# Version control (git)
git status           # Show working tree status
git diff             # Show changes
git log              # Show commit history
git add <files>      # Stage changes
git commit -m "msg"  # Commit changes

# Run the orchestrator
mix noface.start     # Start persistent server
mix noface.status    # Show server status
mix noface.pause     # Pause loop
mix noface.resume    # Resume loop
```

## Project Structure

```
lib/
  noface/
    application.ex       # OTP application, supervision tree
    cli.ex               # CLI entry point (escript)
    core/
      loop.ex            # Main orchestration loop (GenServer)
      state.ex           # CubDB-based persistent state
      config.ex          # Configuration parsing
      worker_pool.ex     # Task.Supervisor workers
      prompts.ex         # Agent prompt templates
    integrations/
      github.ex          # GitHub API integration
      gitea.ex           # Gitea API integration
      issue_sync.ex      # Issue syncing to external trackers
      monowiki.ex        # Monowiki design doc integration
      lsp.ex             # Language server protocol
    vcs/
      jj.ex              # Jujutsu VCS operations
    util/
      process.ex         # Process/shell helpers
      streaming.ex       # JSON stream parsing
      markdown.ex        # Markdown rendering
    transcript.ex        # Ecto SQLite session logging
  noface_web/
    router.ex            # Phoenix routes
    live/
      dashboard_live.ex  # Main dashboard
      issues_live.ex     # Issue browser
      vault_live.ex      # Monowiki vault browser
    controllers/
      api_controller.ex  # REST API endpoints
  mix/tasks/
    noface.ex            # Mix task entry
    noface.start.ex      # Start server
    noface.status.ex     # Show status
    noface.pause.ex      # Pause loop
    noface.resume.ex     # Resume loop
```

## Issue Tracking with `bd` (Beads)

This project uses `bd` for issue tracking. Issues are stored in `.beads/issues.jsonl` and sync with git.

### Common Workflows

```bash
# View issues
bd list                    # All open issues
bd list --status closed    # Closed issues
bd list --label bug        # Filter by label
bd ready                   # Issues ready to work on

# Create issues
bd create "Add feature X" -t feature -p 1
bd create "Fix bug Y" -t bug -p 0 --label urgent

# Work on issues
bd update noface-abc --status in_progress
bd comment noface-abc "Working on this now"
bd close noface-abc

# Dependencies
bd dep add noface-abc --depends-on noface-xyz
bd blocked                 # Show blocked issues

# Sync
bd sync                    # Push/pull issues with remote
bd info                    # Show database info
```

### Issue ID Format

Issues use prefix + hash format: `noface-abc`, `noface-xyz`

## Version Control with Git

This project uses standard git for version control.

### Common Workflows

```bash
# Check status
git status                 # What's changed
git diff                   # See diffs
git log --oneline          # Revision history

# Make changes
git add <files>            # Stage changes
git commit -m "message"    # Commit changes

# Branches
git checkout -b feature    # Create feature branch
git checkout main          # Switch to main
git merge feature          # Merge feature into current branch
```

## Configuration

Project config is in `.noface.toml`:

```toml
[project]
name = "noface"
build = "mix compile"
test = "mix test"

[agents]
implementer = "claude"
reviewer = "codex"

[passes]
planner_enabled = true
quality_enabled = true
planner_interval = 5      # Every 5 iterations
quality_interval = 10     # Every 10 iterations

[tracker]
type = "beads"
sync_to_github = true

[monowiki]
vault = "./wiki"
```

## Testing

Tests use ExUnit with Phoenix LiveView test helpers.

```bash
mix test                          # Run all tests
mix test test/noface_web/         # Run web tests only
mix test --only integration       # Tagged tests
```

### Test Structure

- `test/support/conn_case.ex` - LiveView/conn test case
- `test/support/fixtures.ex` - Test data builders
- `test/noface_web/` - LiveView tests

### Writing Tests

```elixir
defmodule NofaceWeb.MyLiveTest do
  use NofaceWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ "expected content"
  end
end
```

## Web Dashboard

Development server runs on `http://localhost:4000`:

- `/` - Main dashboard (loop status, issues, sessions)
- `/issues` - Issue browser
- `/vault` - Monowiki vault browser
- `/dev/dashboard` - Phoenix LiveDashboard (dev only)

### API Endpoints

- `GET /api/status` - Loop status
- `POST /api/pause` - Pause loop
- `POST /api/resume` - Resume loop
- `POST /api/interrupt` - Interrupt current work
- `POST /api/issues` - Create issue

## Architecture

### Supervision Tree

```
Noface.Supervisor (one_for_one)
  ├── Noface.Core.State         # CubDB state management
  ├── Noface.Util.Signals       # Signal handling (SIGINT/SIGTERM)
  ├── Noface.Transcript.Repo    # Ecto SQLite for session logs
  ├── Noface.Core.WorkerPool    # Task.Supervisor for workers
  ├── Noface.Server.Command     # CLI command server
  ├── Noface.HotReload          # Code reloading
  ├── Noface.Tools.Updater      # Tool update checker
  ├── NofaceWeb.Telemetry       # Metrics
  ├── Phoenix.PubSub            # PubSub for LiveView
  ├── NofaceWeb.Endpoint        # Phoenix web server
  └── Noface.Core.Loop          # Main orchestration loop
```

### Main Loop Flow

1. Load issues from beads (`bd ready`)
2. Run planner pass (periodic) to organize batches
3. Execute batches through worker pool
4. Run quality pass (periodic) for tech debt review
5. Sync to external trackers (GitHub/Gitea)
6. Repeat

## Elixir Style

See **`.claude/ELIXIR_STYLE.md`** for the complete style guide. Always run `mix format` before commits.

## Development Tips

### Hot Reload

The app supports hot code reloading via `Noface.HotReload`. Changes to lib/ are picked up automatically in dev.

### Debugging

```elixir
# In IEx
Noface.Core.Loop.get_loop_state()  # Inspect loop state
Noface.Core.State.get()            # Get current state

# Step-wise debugging
Noface.Core.Loop.start_paused(config)
Noface.Core.Loop.step()  # Run one iteration
```

### Environment Variables

- `MIX_ENV` - Elixir environment (dev/test/prod)
- `BD_ACTOR` - Actor name for beads audit trail
- `BEADS_DB` - Custom database path

## Common Issues

### bd daemon not running
```bash
bd daemon start
bd info  # Check daemon status
```

### Git merge conflicts
```bash
git status             # See conflicted files
git diff               # Review conflicts
# Edit files to resolve, then:
git add <resolved-files>
git commit
```

### Mix compile errors
```bash
mix deps.get
mix deps.compile
```
