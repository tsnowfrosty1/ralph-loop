#!/bin/bash
# Ralph Loop - Prompt Template Builder
# Constructs structured prompts for Claude Code from Notion task data

build_task_prompt() {
    local TASK_JSON="$1"
    local REPO_DIR="$2"
    local RUN_ID="$3"
    local IS_RETRY="${4:-false}"
    local PREV_ERROR="${5:-}"

    # Parse task fields from JSON
    local TASK_NAME=$(echo "$TASK_JSON" | jq -r '.task_name')
    local TASK_TYPE=$(echo "$TASK_JSON" | jq -r '.type')
    local PRIORITY=$(echo "$TASK_JSON" | jq -r '.priority')
    local DESCRIPTION=$(echo "$TASK_JSON" | jq -r '.description')
    local BRANCH=$(echo "$TASK_JSON" | jq -r '.branch // "main"')
    local TASK_ID=$(echo "$TASK_JSON" | jq -r '.task_id // empty')
    local DIRECT_COMMIT=$(echo "$TASK_JSON" | jq -r '.direct_commit // false')

    # Use task_id for branch name
    local BRANCH_SLUG=$(echo "$TASK_ID" | tr -d '-' | head -c 16)

    # Build retry context if this is a retry
    local RETRY_CONTEXT=""
    if [[ "$IS_RETRY" == "true" && -n "$PREV_ERROR" ]]; then
        RETRY_CONTEXT="
IMPORTANT - RETRY CONTEXT:
This is a retry. The previous attempt failed with this error:
---
${PREV_ERROR}
---
Try a DIFFERENT approach this time. If the previous approach had a fundamental issue,
consider an alternative strategy entirely.
"
    fi

    # Build git workflow instructions based on direct_commit flag
    local GIT_INSTRUCTIONS=""
    if [[ "$DIRECT_COMMIT" == "true" ]]; then
        GIT_INSTRUCTIONS="
GIT WORKFLOW (Direct Commit):
1. Make sure you are on the '${BRANCH}' branch and it is up to date: git pull origin ${BRANCH}
2. Make your changes
3. Stage and commit with message: [ralph-loop] ${TASK_NAME}
4. Push directly: git push origin ${BRANCH}
"
    else
        GIT_INSTRUCTIONS="
GIT WORKFLOW (PR-based):
1. Make sure '${BRANCH}' is up to date: git checkout ${BRANCH} && git pull origin ${BRANCH}
2. Create a feature branch: git checkout -b ralph-loop/${BRANCH_SLUG}
3. Make your changes
4. Stage and commit with message: [ralph-loop] ${TASK_NAME}
5. Push the branch: git push origin ralph-loop/${BRANCH_SLUG}
6. Create a Pull Request using gh CLI:
   gh pr create \\
     --title \"[ralph-loop] ${TASK_NAME}\" \\
     --body \"Task: ${TASK_ID}
Run: ${RUN_ID}
Type: ${TASK_TYPE}
Priority: ${PRIORITY}

## Changes
<describe what you changed and why>

## Testing
<describe how you tested>\"
7. Output the PR URL in your response
"
    fi

    # Construct the full prompt
    cat <<PROMPT
You are an autonomous coding agent working on a task from the Ralph Loop task queue.
You are working in the repository at: ${REPO_DIR}

═══════════════════════════════════════════════
TASK: ${TASK_NAME}
TYPE: ${TASK_TYPE}
PRIORITY: ${PRIORITY}
═══════════════════════════════════════════════

DESCRIPTION:
${DESCRIPTION}

${RETRY_CONTEXT}

${GIT_INSTRUCTIONS}

═══════════════════════════════════════════════
RULES — READ CAREFULLY
═══════════════════════════════════════════════

1. TESTING: You MUST run the test suite before committing. If tests fail, fix them.
   If you add new functionality, add corresponding tests.

2. DO NOT:
   - Modify package.json dependencies without explicit instruction in the task
   - Change CI/CD configuration files
   - Modify environment variables or .env files
   - Delete files unless the task specifically says to
   - Make changes outside the scope of this task

3. COMMIT MESSAGE FORMAT:
   [ralph-loop] ${TASK_NAME}

4. SCOPE: Only do what the task asks. Do not refactor unrelated code.

5. OUTPUT: When complete, output a JSON summary as the LAST thing you print:
   {"status": "success", "summary": "what you did", "files_changed": ["file1.ts", "file2.ts"], "pr_url": "https://..."}

   If you CANNOT complete the task, output:
   {"status": "failure", "reason": "why it failed", "suggestion": "what to try next"}

PROMPT
}

# Export for use by ralph_loop.sh
export -f build_task_prompt
