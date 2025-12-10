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

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/femtomc/noface/main/install.sh | bash
```

This installs noface and its dependencies:
- **beads** - Local issue tracking
- **claude** - Implementation agent
- **codex** - Code review agent
- **gh** - GitHub CLI
- **jq** - JSON processor

## Quick Start

```bash
# Initialize issue tracking in your project
cd your-project
bd init

# Create some issues
bd create "Add user authentication" -t feature -p 1
bd create "Fix memory leak in parser" -t bug -p 0

# Run the agent loop
noface
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

[passes]
scrum_enabled = true
scrum_interval = 5      # Every 5 iterations
quality_enabled = true
quality_interval = 10   # Every 10 iterations

[tracker]
type = "beads"          # or "github"
sync_to_github = true
```

## CLI Options

```
noface [OPTIONS]

Options:
  -h, --help              Show help message
  -v, --version           Show version
  -c, --config PATH       Load configuration from file
  --max-iterations N      Stop after N iterations (default: unlimited)
  --issue ISSUE_ID        Work on specific issue
  --dry-run               Show what would be done without executing
  --no-scrum              Disable scrum passes
  --no-quality            Disable quality review passes
  --scrum-interval N      Run scrum every N iterations (default: 5)
  --quality-interval N    Run quality review every N iterations (default: 10)
```

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

**Scrum Pass** (every 5 iterations by default):
- Reviews the backlog
- Updates priorities and dependencies
- Closes stale issues
- Creates new issues for gaps

**Quality Pass** (every 10 iterations by default):
- Analyzes codebase for technical debt
- Finds code duplication
- Identifies dead code
- Creates issues for findings

## Building from Source

```bash
git clone https://github.com/femtomc/noface.git
cd noface
zig build -Doptimize=ReleaseFast
./zig-out/bin/noface --help
```

## License

MIT
