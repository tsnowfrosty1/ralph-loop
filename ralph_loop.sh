#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Ralph Loop - Autonomous Overnight Agent Orchestrator
# Reads tasks from tasks.json → Executes via Claude Code CLI → Updates tasks.json
# ═══════════════════════════════════════════════════════════════════
#
# Usage:
#   ./ralph_loop.sh [project]
#
# Examples:
#   ./ralph_loop.sh                    # Process all projects
#   ./ralph_loop.sh front-door-mcp     # Process only front-door-mcp tasks
#
# Prerequisites:
#   - claude CLI installed and authenticated
#   - gh CLI authenticated (for PR creation)
#   - jq installed
#   - tasks.json file with tasks

# ─── Configuration ─────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_FILE="${SCRIPT_DIR}/tasks.json"

# Source prompt builder
source "${SCRIPT_DIR}/ralph_prompt.sh"

# ─── Globals ───────────────────────────────────────────────────────

PROJECT_FILTER="${1:-}"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${SCRIPT_DIR}/logs/${RUN_ID}"
CUMULATIVE_COST=0.0
CONSECUTIVE_FAILURES=0
TASKS_COMPLETED=0
TASKS_FAILED=0
TASKS_BLOCKED=0

# Circuit breaker settings
MAX_ITERATIONS=20
MAX_BUDGET_PER_RUN=100.00
MAX_CONSECUTIVE_FAILURES=3

# Per-task defaults
MAX_BUDGET_PER_TASK=10.00
MAX_TURNS_PER_TASK=50
ALLOWED_TOOLS="Bash,Read,Edit,Write,Glob,Grep"
REPO_DIR=""
TEST_COMMAND="npm run test"

# ─── Setup ─────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "${LOG_DIR}/ralph_loop.log"
}

log "═══════════════════════════════════════════════════"
log "Ralph Loop Starting"
log "Run ID:  ${RUN_ID}"
log "Project: ${PROJECT_FILTER:-all}"
log "═══════════════════════════════════════════════════"

# ─── Preflight Checks ─────────────────────────────────────────────

if [[ ! -f "$TASKS_FILE" ]]; then
    log "ERROR: tasks.json not found at ${TASKS_FILE}"
    log "Create one or run: ./sync_from_notion.sh"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    log "ERROR: claude CLI not found. Install it first."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log "ERROR: jq not found. Install with: brew install jq"
    exit 1
fi

if ! command -v gh &>/dev/null; then
    log "WARNING: gh CLI not found. PR creation will fail. Install with: brew install gh"
fi

# ─── Task Queue Functions (local tasks.json) ──────────────────────

get_todo_tasks() {
    # Read tasks with Status = "To Do", optionally filtered by project
    # Sort by priority (P0 first)
    local filter='.[] | select(.status == "To Do")'

    if [[ -n "$PROJECT_FILTER" ]]; then
        filter=".[] | select(.status == \"To Do\" and .project == \"${PROJECT_FILTER}\")"
    fi

    jq -c "[ ${filter} ] | sort_by(.priority)" "$TASKS_FILE"
}

update_task() {
    # Update a task in tasks.json by task_id
    # Usage: update_task <task_id> <jq_update_expression>
    local task_id="$1"
    local update_expr="$2"
    local tmp_file="${TASKS_FILE}.tmp"

    jq "map(if .task_id == \"${task_id}\" then ${update_expr} else . end)" \
        "$TASKS_FILE" > "$tmp_file" && mv "$tmp_file" "$TASKS_FILE"
}

# ─── Load Project Config ──────────────────────────────────────────

load_project_config() {
    local project="$1"
    case "$project" in
        front-door-mcp)
            REPO_DIR="${SCRIPT_DIR}/../talent-front-door"
            TEST_COMMAND="npm run test"
            ;;
        workday-mcp)
            REPO_DIR="${SCRIPT_DIR}/../workday-mcp"
            TEST_COMMAND="npm run test"
            ;;
        *)
            REPO_DIR="${SCRIPT_DIR}/../${project}"
            TEST_COMMAND="npm run test"
            ;;
    esac
}

# ─── Ensure Repo is Ready ────────────────────────────────────────

ensure_repo() {
    local task_json="$1"
    local repo_url=$(echo "$task_json" | jq -r '.repo_url // empty')
    local project=$(echo "$task_json" | jq -r '.project // empty')

    load_project_config "$project"

    if [[ -z "$REPO_DIR" ]]; then
        log "ERROR: No repo directory configured for project: $project"
        return 1
    fi

    if [[ ! -d "$REPO_DIR/.git" ]]; then
        if [[ -n "$repo_url" ]]; then
            log "Cloning repo: $repo_url → $REPO_DIR"
            git clone "$repo_url" "$REPO_DIR"
        else
            log "ERROR: Repo not found at $REPO_DIR and no repo_url in task"
            return 1
        fi
    else
        log "Pulling latest for $REPO_DIR"
        (cd "$REPO_DIR" && git checkout main && git pull origin main) || true
    fi
}

# ─── Execute a Single Task ─────────────────────────────────────────

execute_task() {
    local TASK_JSON="$1"
    local IS_RETRY="${2:-false}"
    local PREV_ERROR="${3:-}"

    local TASK_NAME=$(echo "$TASK_JSON" | jq -r '.task_name')
    local TASK_ID=$(echo "$TASK_JSON" | jq -r '.task_id')
    local ATTEMPT_COUNT=$(echo "$TASK_JSON" | jq -r '.attempt_count // 0')
    local TASK_LOG="${LOG_DIR}/${TASK_ID}.json"

    ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))

    log "────────────────────────────────────────────"
    log "Task: ${TASK_NAME}"
    log "ID:   ${TASK_ID}"
    log "Attempt: ${ATTEMPT_COUNT}"
    log "Retry: ${IS_RETRY}"
    log "────────────────────────────────────────────"

    # Update task → In Progress
    update_task "$TASK_ID" \
        ". + {\"status\": \"In Progress\", \"attempt_count\": ${ATTEMPT_COUNT}, \"assigned_run\": \"${RUN_ID}\"}"

    # Ensure repo is ready
    if ! ensure_repo "$TASK_JSON"; then
        log "ERROR: Could not prepare repo for task"
        update_task "$TASK_ID" \
            ". + {\"status\": \"Blocked\", \"error_log\": \"Repo not available\", \"attempt_count\": ${ATTEMPT_COUNT}}"
        TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
        return 1
    fi

    # Build the prompt
    local PROMPT=$(build_task_prompt "$TASK_JSON" "$REPO_DIR" "$RUN_ID" "$IS_RETRY" "$PREV_ERROR")

    # Run Claude Code
    log "Launching Claude Code..."
    local CLAUDE_OUTPUT=""
    local CLAUDE_EXIT=0

    CLAUDE_OUTPUT=$(cd "$REPO_DIR" && claude \
        --dangerously-skip-permissions \
        --print \
        --output-format json \
        --max-turns "$MAX_TURNS_PER_TASK" \
        --max-budget-usd "$MAX_BUDGET_PER_TASK" \
        --allowedTools "$ALLOWED_TOOLS" \
        --verbose \
        "$PROMPT" 2>&1) || CLAUDE_EXIT=$?

    # Save full output to log
    echo "$CLAUDE_OUTPUT" > "$TASK_LOG"

    # Parse the result
    # Claude --output-format json returns a JSON array. The last element is the result:
    #   {"type": "result", "subtype": "success"|"error", "result": "...", "cost_usd": ..., ...}
    local STATUS="failure"
    local SUMMARY=""
    local PR_URL=""
    local COST=0

    # Extract the last element (the result object) from the JSON array
    local RESULT_OBJ=$(echo "$CLAUDE_OUTPUT" | jq -c '.[-1]' 2>/dev/null || echo "{}")
    local RESULT_TYPE=$(echo "$RESULT_OBJ" | jq -r '.type // ""' 2>/dev/null || echo "")
    local RESULT_SUBTYPE=$(echo "$RESULT_OBJ" | jq -r '.subtype // ""' 2>/dev/null || echo "")
    local RESULT_TEXT=$(echo "$RESULT_OBJ" | jq -r '.result // ""' 2>/dev/null || echo "")

    if [[ "$RESULT_TYPE" == "result" && "$RESULT_SUBTYPE" == "success" ]]; then
        STATUS="success"
        SUMMARY="$RESULT_TEXT"
        # Try to find a PR URL in the result text (use -E for macOS compat)
        PR_URL=$(echo "$RESULT_TEXT" | grep -oE 'https://github\.com/[^[:space:]"]+/pull/[0-9]+' | head -1 || true)
    elif [[ "$RESULT_TYPE" == "result" ]]; then
        STATUS="failure"
        SUMMARY="$RESULT_TEXT"
    fi

    # Extract cost from the result object
    COST=$(echo "$RESULT_OBJ" | jq -r '.cost_usd // 0' 2>/dev/null || echo "0")
    CUMULATIVE_COST=$(python3 -c "print(round($CUMULATIVE_COST + $COST, 2))")

    log "Result: ${STATUS}"
    log "Cost: \$${COST} (cumulative: \$${CUMULATIVE_COST})"

    if [[ "$STATUS" == "success" ]]; then
        # Task succeeded
        local NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        log "Task completed: ${TASK_NAME}"
        update_task "$TASK_ID" \
            ". + {\"status\": \"Done\", \"attempt_count\": ${ATTEMPT_COUNT}, \"pr_url\": \"${PR_URL}\", \"cost_usd\": ${COST}, \"completed_at\": \"${NOW}\"}"
        TASKS_COMPLETED=$((TASKS_COMPLETED + 1))
        CONSECUTIVE_FAILURES=0
        return 0
    else
        # Task failed
        local ERROR_MSG="${SUMMARY:-Claude exited with code ${CLAUDE_EXIT}}"
        local MAX_ATTEMPTS=$(echo "$TASK_JSON" | jq -r '.max_attempts // 2')

        if [[ "$ATTEMPT_COUNT" -ge "$MAX_ATTEMPTS" ]]; then
            # Max retries exhausted → Blocked
            log "Task BLOCKED (max attempts reached): ${TASK_NAME}"
            update_task "$TASK_ID" \
                ". + {\"status\": \"Blocked\", \"error_log\": \"${ERROR_MSG}\", \"attempt_count\": ${ATTEMPT_COUNT}, \"cost_usd\": ${COST}}"
            TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
        else
            # Put back in To Do for retry
            log "Task failed, will retry: ${TASK_NAME}"
            update_task "$TASK_ID" \
                ". + {\"status\": \"To Do\", \"error_log\": \"${ERROR_MSG}\", \"attempt_count\": ${ATTEMPT_COUNT}, \"cost_usd\": ${COST}}"
            TASKS_FAILED=$((TASKS_FAILED + 1))
        fi

        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        return 1
    fi
}

# ─── Main Loop ─────────────────────────────────────────────────────

ITERATION=0

while true; do
    ITERATION=$((ITERATION + 1))

    log ""
    log "═══════════════════════════════════════════════════"
    log "Iteration ${ITERATION} of ${MAX_ITERATIONS}"
    log "═══════════════════════════════════════════════════"

    # ── Circuit breakers ──

    if [[ "$ITERATION" -gt "$MAX_ITERATIONS" ]]; then
        log "Max iterations (${MAX_ITERATIONS}) reached. Stopping."
        break
    fi

    if (( $(python3 -c "print(1 if $CUMULATIVE_COST >= $MAX_BUDGET_PER_RUN else 0)") )); then
        log "Budget cap (\$${MAX_BUDGET_PER_RUN}) reached. Stopping."
        break
    fi

    if [[ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
        log "Too many consecutive failures (${MAX_CONSECUTIVE_FAILURES}). Stopping."
        break
    fi

    # ── Fetch tasks from tasks.json ──

    log "Fetching tasks from tasks.json..."
    TASKS_JSON=$(get_todo_tasks)

    TASK_COUNT=$(echo "$TASKS_JSON" | jq 'length')

    if [[ "$TASK_COUNT" -eq 0 ]]; then
        log "No remaining tasks. All done!"
        break
    fi

    log "Found ${TASK_COUNT} task(s) to process"

    # ── Process each task ──

    # Use process substitution instead of pipe to avoid subshell variable loss
    while IFS= read -r TASK; do
        TASK_NAME=$(echo "$TASK" | jq -r '.task_name')
        ATTEMPT_COUNT=$(echo "$TASK" | jq -r '.attempt_count // 0')

        # Check if this is a retry
        IS_RETRY="false"
        PREV_ERROR=""
        if [[ "$ATTEMPT_COUNT" -gt 0 ]]; then
            IS_RETRY="true"
            PREV_ERROR=$(echo "$TASK" | jq -r '.error_log // "Previous attempt failed."')
        fi

        # Execute the task (don't let failures kill the loop)
        execute_task "$TASK" "$IS_RETRY" "$PREV_ERROR" || true

        # Re-check budget after each task
        if (( $(python3 -c "print(1 if $CUMULATIVE_COST >= $MAX_BUDGET_PER_RUN else 0)") )); then
            log "Budget cap reached mid-iteration. Breaking."
            break
        fi

        # Re-check consecutive failures
        if [[ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
            log "Too many consecutive failures mid-iteration. Breaking."
            break
        fi

        # Brief pause between tasks
        sleep 5
    done < <(echo "$TASKS_JSON" | jq -c '.[]')
done

# ─── Summary ───────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════"
log "Ralph Loop Complete"
log "═══════════════════════════════════════════════════"
log "Run ID:     ${RUN_ID}"
log "Iterations: ${ITERATION}"
log "Completed:  ${TASKS_COMPLETED}"
log "Failed:     ${TASKS_FAILED}"
log "Blocked:    ${TASKS_BLOCKED}"
log "Total Cost: \$${CUMULATIVE_COST}"
log "Logs:       ${LOG_DIR}/"
log "═══════════════════════════════════════════════════"

# Write summary JSON
cat > "${LOG_DIR}/summary.json" <<EOF
{
  "run_id": "${RUN_ID}",
  "iterations": ${ITERATION},
  "tasks_completed": ${TASKS_COMPLETED},
  "tasks_failed": ${TASKS_FAILED},
  "tasks_blocked": ${TASKS_BLOCKED},
  "cumulative_cost_usd": ${CUMULATIVE_COST},
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log "Summary written to ${LOG_DIR}/summary.json"
