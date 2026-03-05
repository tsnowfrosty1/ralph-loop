#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Ralph Loop - One-Time Setup
# Run this once to prepare your environment
# ═══════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "═══════════════════════════════════════════════════"
echo "Ralph Loop Setup"
echo "═══════════════════════════════════════════════════"

# ─── Check Dependencies ────────────────────────────────────────────

echo ""
echo "Checking dependencies..."

check_dep() {
    if command -v "$1" &>/dev/null; then
        echo "  ✓ $1 found: $(command -v "$1")"
        return 0
    else
        echo "  ✗ $1 NOT FOUND — install with: $2"
        return 1
    fi
}

MISSING=0
check_dep "claude" "npm install -g @anthropic-ai/claude-code" || MISSING=1
check_dep "jq" "brew install jq" || MISSING=1
check_dep "python3" "brew install python3" || MISSING=1
check_dep "gh" "brew install gh" || MISSING=1
check_dep "git" "xcode-select --install" || MISSING=1

if [[ "$MISSING" -eq 1 ]]; then
    echo ""
    echo "Some dependencies are missing. Install them and re-run setup."
    echo "  (gh is optional but required for PR creation)"
fi

# ─── Check gh auth ────────────────────────────────────────────────

echo ""
echo "Checking GitHub auth..."

if gh auth status &>/dev/null 2>&1; then
    echo "  ✓ gh CLI is authenticated"
else
    echo "  ✗ gh CLI is NOT authenticated"
    echo "    Run: gh auth login"
fi

# ─── Create Directory Structure ────────────────────────────────────

echo ""
echo "Creating directory structure..."

mkdir -p "${SCRIPT_DIR}/logs"
echo "  ✓ logs/ directory created"

# ─── Make Scripts Executable ───────────────────────────────────────

echo ""
echo "Making scripts executable..."

chmod +x "${SCRIPT_DIR}/ralph_loop.sh"
chmod +x "${SCRIPT_DIR}/ralph_prompt.sh"
chmod +x "${SCRIPT_DIR}/setup.sh"

echo "  ✓ All scripts are executable"

# ─── Check tasks.json ─────────────────────────────────────────────

echo ""
echo "Checking task queue..."

if [[ -f "${SCRIPT_DIR}/tasks.json" ]]; then
    TASK_COUNT=$(jq 'length' "${SCRIPT_DIR}/tasks.json" 2>/dev/null || echo "0")
    TODO_COUNT=$(jq '[ .[] | select(.status == "To Do") ] | length' "${SCRIPT_DIR}/tasks.json" 2>/dev/null || echo "0")
    echo "  ✓ tasks.json found: ${TASK_COUNT} total tasks, ${TODO_COUNT} in To Do"
else
    echo "  ✗ tasks.json not found"
    echo "    Create one manually or ask Claude to sync from Notion"
fi

# ─── Check Sibling Repos ──────────────────────────────────────────

echo ""
echo "Checking project repos..."

if [[ -d "${SCRIPT_DIR}/../talent-front-door/.git" ]]; then
    echo "  ✓ talent-front-door found at ../talent-front-door"
else
    echo "  ✗ talent-front-door NOT found at ../talent-front-door"
fi

if [[ -d "${SCRIPT_DIR}/../workday-mcp/.git" ]]; then
    echo "  ✓ workday-mcp found at ../workday-mcp"
else
    echo "  - workday-mcp not found at ../workday-mcp (optional)"
fi

# ─── Done ──────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════"
echo "Setup Complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "To run the loop:"
echo "  ./ralph_loop.sh front-door-mcp"
echo ""
echo "For overnight runs:"
echo "  nohup ./ralph_loop.sh front-door-mcp > overnight.log 2>&1 &"
echo ""
echo "To add tasks, edit tasks.json or ask Claude to sync from Notion."
echo ""
