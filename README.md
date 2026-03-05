# Ralph Loop

An autonomous overnight agent orchestrator that reads tasks from a queue, executes them via [Claude Code CLI](https://docs.claude.com/en/docs/claude-code), and pushes the results to GitHub — all while you sleep.

Ralph Loop was built to handle repetitive codebase maintenance at scale: removing emojis, fixing TypeScript types, adding error handling, updating documentation, and more. Point it at a task queue and a repo, and Ralph works through the list autonomously with built-in safety guardrails.

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌──────────┐
│  tasks.json  │────▸│  ralph_loop  │────▸│  Claude Code │────▸│  GitHub  │
│  (task queue)│◂────│  (orchestrator)│◂────│  CLI         │     │  (repo)  │
└─────────────┘     └──────────────┘     └─────────────┘     └──────────┘
       ▲                                                            │
       │              ┌──────────────┐                              │
       └──────────────│  Notion DB   │◂─────────────────────────────┘
                      │  (optional UI)│        (two-way sync via Cowork)
                      └──────────────┘
```

1. **Ralph reads** `tasks.json` for tasks with status `To Do`, sorted by priority
2. **For each task**, Ralph checks out the target repo, builds a structured prompt, and launches Claude Code CLI
3. **Claude Code** reads the codebase, makes changes, runs tests, and commits (either direct or via PR)
4. **Ralph updates** `tasks.json` with the result — `Done`, `Failed`, or `Blocked`
5. **Circuit breakers** stop the loop if budget is exceeded, too many failures occur, or all tasks are complete

## Features

- **Autonomous execution** — runs unattended overnight with no human intervention
- **Priority-based queue** — P0 tasks run first, P3 last
- **Automatic retries** — failed tasks get re-queued with error context for a smarter second attempt
- **Circuit breakers** — budget caps ($100/run default), max iterations (20), and consecutive failure limits (3)
- **Per-task cost tracking** — every task logs its Claude API cost
- **Direct commit or PR mode** — choose per-task whether to commit straight to main or open a PR
- **Structured logging** — every run gets a timestamped log directory with per-task JSON output
- **Notion integration** — optional two-way sync for visual task management via Cowork MCP
- **Shell injection protection** — task descriptions are sanitized before being passed to Claude

## Quick Start

### Prerequisites

- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated (for PR creation)
- `jq` installed (`brew install jq`)
- `python3` available
- Target repo(s) cloned as sibling directories

### Setup

```bash
# Clone this repo
git clone https://github.com/tsnowfrosty1/ralph-loop.git
cd ralph-loop

# Run the setup checker
./setup.sh

# Clone your target repo as a sibling directory
cd ..
git clone https://github.com/your-org/your-repo.git
```

### Run It

```bash
# Process tasks for a specific project
./ralph_loop.sh front-door-mcp

# Process all projects
./ralph_loop.sh

# Run overnight (detached)
nohup ./ralph_loop.sh front-door-mcp > overnight.log 2>&1 &
```

## Task Schema

Tasks live in `tasks.json` as an array of objects:

```json
{
  "task_id": "task-007",
  "task_name": "Remove emoji characters from UI strings",
  "status": "To Do",
  "priority": "P1",
  "type": "Code",
  "project": "front-door-mcp",
  "description": "Find and remove all emoji characters from user-facing strings in src/. Replace with text equivalents where appropriate.",
  "repo_url": "https://github.com/your-org/your-repo",
  "branch": "main",
  "attempt_count": 0,
  "max_attempts": 2,
  "direct_commit": true,
  "error_log": "",
  "pr_url": "",
  "cost_usd": 0,
  "assigned_run": "",
  "completed_at": ""
}
```

| Field | Description |
|-------|-------------|
| `task_id` | Unique identifier (e.g., `task-007`) |
| `task_name` | Short description used in commit messages |
| `status` | `To Do`, `In Progress`, `Done`, `Failed`, or `Blocked` |
| `priority` | `P0` (critical) through `P3` (nice-to-have) |
| `type` | `Code`, `Docs`, `Test`, or `Config` |
| `project` | Project name, maps to repo config |
| `description` | Detailed instructions for Claude |
| `repo_url` | Git remote URL for cloning |
| `branch` | Target branch (default: `main`) |
| `attempt_count` | How many times Ralph has tried this task |
| `max_attempts` | Max retries before marking as `Blocked` |
| `direct_commit` | `true` = commit to branch, `false` = open a PR |
| `error_log` | Last error message (populated on failure) |
| `pr_url` | Pull request URL (populated on success with PR mode) |
| `cost_usd` | Claude API cost for this task |
| `assigned_run` | Run ID that last processed this task |
| `completed_at` | ISO timestamp when task was completed |

## Safety Guardrails

Ralph is designed to be safe for unattended operation:

- **Budget cap**: Stops if cumulative cost exceeds $100 per run (configurable)
- **Iteration limit**: Maximum 20 passes through the task queue
- **Consecutive failure breaker**: Stops after 3 failures in a row
- **Per-task budget**: Each task is capped at $10 of Claude API usage
- **Scoped tools**: Claude only gets access to `Bash`, `Read`, `Edit`, `Write`, `Glob`, `Grep` — no web access, no arbitrary tool use
- **No destructive operations**: Tasks cannot modify CI/CD, environment variables, or package dependencies unless explicitly instructed
- **Input sanitization**: Task descriptions are stripped of shell metacharacters to prevent injection

## Architecture

```
ralph-loop/
├── ralph_loop.sh        # Main orchestrator loop
├── ralph_prompt.sh      # Prompt template builder
├── ralph_config.yaml    # Project definitions and global settings
├── notion_client.py     # Notion API client (optional, for direct API sync)
├── notion_config.json   # Notion database IDs and field mapping
├── setup.sh             # One-time environment setup checker
├── tasks.json           # The task queue (runtime source of truth)
└── logs/
    └── run-YYYYMMDD-HHMMSS/
        ├── ralph_loop.log   # Human-readable run log
        ├── summary.json     # Run statistics
        └── task-XXX.json    # Raw Claude output per task
```

### Key Components

**`ralph_loop.sh`** — The main loop. Reads `tasks.json`, iterates through `To Do` tasks sorted by priority, launches Claude Code for each, and updates statuses. Includes all circuit breaker logic.

**`ralph_prompt.sh`** — Builds structured prompts from task data. Handles retry context (passes previous error to Claude for smarter retries) and git workflow instructions (direct commit vs. PR).

**`ralph_config.yaml`** — Defines project-to-repo mappings, Claude Code CLI settings, and global safety thresholds.

**`notion_client.py`** — Standalone Notion API client for environments where you want to read/write tasks directly from Notion without Cowork. Includes input sanitization.

## Notion Integration (Optional)

Ralph supports two-way sync with a Notion database for visual task management:

- **Add tasks in Notion** → they get pulled into `tasks.json` before a run
- **Ralph completes tasks** → statuses, costs, and PR URLs get pushed back to Notion

The sync currently runs through [Cowork](https://claude.com) Notion MCP tools. To use it:

1. Create a Notion database with the schema matching `notion_config.json`
2. Use Cowork to sync between Notion and `tasks.json`
3. The `notion_config.json` file stores database IDs and field mappings

For standalone Notion API access (without Cowork), set the `NOTION_API_KEY` environment variable and use `notion_client.py`.

## Configuration

Edit `ralph_config.yaml` to customize:

```yaml
global:
  max_iterations: 20           # Max loop cycles
  max_budget_per_run: 100.00   # Total budget cap ($)
  max_consecutive_failures: 3  # Stop after N failures in a row

projects:
  your-project:
    repo: "https://github.com/org/repo"
    branch: main
    max_budget_per_task: 10.00
    max_turns_per_task: 50
    allowed_tools: "Bash,Read,Edit,Write,Glob,Grep"
    test_command: "npm run test"
```

## Adding Tasks

### Manually (tasks.json)

Add a new object to the `tasks.json` array with `status: "To Do"`.

### Via Notion

Add a row to the Notion database and use Cowork to sync it to `tasks.json`.

### Via Script

```bash
# Example: add a task with jq
jq '. += [{
  "task_id": "task-099",
  "task_name": "Add input validation to API endpoints",
  "status": "To Do",
  "priority": "P1",
  "type": "Code",
  "project": "front-door-mcp",
  "description": "Add zod validation to all API endpoint handlers in src/routes/.",
  "repo_url": "https://github.com/your-org/your-repo",
  "branch": "main",
  "attempt_count": 0,
  "max_attempts": 2,
  "direct_commit": false,
  "error_log": "",
  "pr_url": "",
  "cost_usd": 0,
  "assigned_run": "",
  "completed_at": ""
}]' tasks.json > tmp.json && mv tmp.json tasks.json
```

## Logs

Each run creates a timestamped directory under `logs/`:

```
logs/run-20260304-191031/
├── ralph_loop.log    # Full run log with timestamps
├── summary.json      # { tasks_completed: 25, cumulative_cost_usd: 42.50, ... }
├── task-002.json     # Raw Claude output for task-002
├── task-003.json     # Raw Claude output for task-003
└── ...
```

The `summary.json` gives you a quick overview:

```json
{
  "run_id": "run-20260304-191031",
  "iterations": 3,
  "tasks_completed": 25,
  "tasks_failed": 0,
  "tasks_blocked": 0,
  "cumulative_cost_usd": 42.50,
  "finished_at": "2026-03-05T02:51:00Z"
}
```

## License

MIT

## Built With

- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) — the AI agent that does the actual work
- [Cowork](https://claude.com) — desktop AI assistant used to build and manage Ralph
- [Notion MCP](https://github.com/anthropics/notion-mcp) — optional visual task management layer
