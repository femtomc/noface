# noface

Autonomous agent loop for software development. Orchestrates Claude (implementation) and Codex (review) to work on issues from your backlog.

```
        ┌──────────────┐
        │    beads     │  Issue tracking
        │   backlog    │
        └──────┬───────┘
               │
               ▼
        ┌──────────────┐
        │   noface     │  Agent orchestration
        │    loop      │
        └──────┬───────┘
               │
       ┌───────┴───────┐
       ▼               ▼
┌──────────────┐ ┌──────────────┐
│    Claude    │ │    Codex     │
│   (impl)     │ │   (review)   │
└──────────────┘ └──────────────┘
```

## Requirements

- Elixir 1.15+
- Erlang/OTP 26+
- [beads](https://github.com/steveyegge/beads) - Issue tracking
- [claude](https://github.com/anthropics/claude-code) - Implementation agent
- [codex](https://github.com/openai/codex) - Code review agent

## Installation

```bash
git clone https://github.com/femtomc/noface.git
cd noface
mix deps.get
mix compile
```

## Quick Start

```bash
# Initialize issue tracking in your project
cd your-project
bd init

# Create some issues
bd create "Add user authentication" -t feature -p 1
bd create "Fix memory leak in parser" -t bug -p 0

# Start the orchestrator
mix noface.start
```

## Configuration

Create `.noface.toml` in your project root:

```toml
[project]
name = "My Project"
build = "make build"
test = "make test"

[agents]
implementer = "claude"
reviewer = "codex"
timeout_seconds = 900
num_workers = 5

[passes]
planner_enabled = true
planner_interval = 5      # Every 5 iterations
quality_enabled = true
quality_interval = 10     # Every 10 iterations

[tracker]
type = "beads"
sync_to_github = true
```

## CLI Options

```
noface [OPTIONS]

Options:
  -h, --help              Show help message
  -c, --config PATH       Load configuration from file
  -n, --max-iterations N  Stop after N iterations (default: unlimited)
  -i, --issue ISSUE_ID    Work on specific issue
  --dry-run               Show what would be done without executing
  --no-planner            Disable planner passes
  --no-quality            Disable quality review passes
  --planner-interval N    Run planner every N iterations (default: 5)
  --quality-interval N    Run quality review every N iterations (default: 10)
  -v, --verbose           Enable verbose logging

Output options:
  --stream-json           Output raw JSON streaming (for programmatic use)
  --raw                   Plain text output without markdown rendering

Integrations:
  --monowiki-vault PATH   Path to monowiki vault for design documents
```

## Mix Tasks

```bash
mix noface.start    # Start the orchestrator server
mix noface.status   # Show server status
mix noface.pause    # Pause the loop
mix noface.resume   # Resume the loop
```

## Web Dashboard

The Phoenix web dashboard runs on `http://localhost:4000`:

- `/` - Main dashboard (loop status, issues, sessions)
- `/issues` - Issue browser
- `/vault` - Monowiki vault browser

## How It Works

### Main Loop

1. **Get next issue** from beads (highest priority ready issue)
2. **Run Claude** to implement the feature/fix
3. **Run Codex** to review the changes
4. **Iterate** until Codex approves
5. **Commit** and close the issue
6. **Sync** to GitHub Issues
7. Repeat

### Periodic Passes

**Planner Pass** (every 5 iterations by default):
- Reviews the backlog
- Updates priorities and dependencies
- Closes stale issues
- Creates new issues for gaps

**Quality Pass** (every 10 iterations by default):
- Analyzes codebase for technical debt
- Finds code duplication
- Identifies dead code
- Creates issues for findings (with file:line references)

## Development

```bash
# Run tests
mix test

# Format code
mix format

# Start IEx with the app loaded
iex -S mix
```

## License

MIT
