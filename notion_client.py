#!/usr/bin/env python3
"""
Notion client for Ralph Loop.
Reads tasks from the Kanban board, updates status, logs errors.
Uses the Notion API directly (no MCP dependency).
"""

import os
import sys
import json
import re
import urllib.request
import urllib.error
from datetime import datetime, timezone


NOTION_API_KEY = os.environ.get("NOTION_API_KEY", "")
NOTION_API_VERSION = "2022-06-28"
NOTION_API_BASE = "https://api.notion.com/v1"


def _headers():
    return {
        "Authorization": f"Bearer {NOTION_API_KEY}",
        "Notion-Version": NOTION_API_VERSION,
        "Content-Type": "application/json",
    }


def _request(method, path, body=None):
    """Make a request to the Notion API."""
    url = f"{NOTION_API_BASE}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=_headers(), method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        print(f"[notion_client] API error {e.code}: {error_body}", file=sys.stderr)
        raise


def sanitize_task_text(text):
    """
    Strip shell metacharacters from task text to prevent injection.
    Allows basic punctuation but removes backticks, $(), pipes, etc.
    """
    # Remove dangerous shell patterns
    dangerous = ["`", "$(", "${", "&&", "||", ";", "|", ">", "<", "\\n", "\\r"]
    clean = text
    for d in dangerous:
        clean = clean.replace(d, "")
    # Also strip any remaining backticks or dollar signs
    clean = re.sub(r'[`$]', '', clean)
    return clean.strip()


# ─── Query Tasks ───────────────────────────────────────────────────

def get_todo_tasks(database_id, project_filter=None):
    """
    Query Notion for tasks with Status = 'To Do', sorted by Priority.
    Returns a list of task dicts.
    """
    filters = [
        {
            "property": "Status",
            "select": {"equals": "To Do"}
        }
    ]

    if project_filter:
        filters.append({
            "property": "Project",
            "select": {"equals": project_filter}
        })

    body = {
        "filter": {
            "and": filters
        },
        "sorts": [
            {
                "property": "Priority",
                "direction": "ascending"
            }
        ]
    }

    result = _request("POST", f"/databases/{database_id}/query", body)
    tasks = []

    for page in result.get("results", []):
        props = page["properties"]
        task = {
            "page_id": page["id"],
            "url": page["url"],
            "task_name": _get_title(props.get("Task Name", {})),
            "status": _get_select(props.get("Status", {})),
            "priority": _get_select(props.get("Priority", {})),
            "type": _get_select(props.get("Type", {})),
            "project": _get_select(props.get("Project", {})),
            "description": sanitize_task_text(_get_rich_text(props.get("Description", {}))),
            "repo_url": _get_url(props.get("Repo URL", {})),
            "branch": _get_rich_text(props.get("Branch", {})) or "main",
            "attempt_count": _get_number(props.get("Attempt Count", {})) or 0,
            "max_attempts": _get_number(props.get("Max Attempts", {})) or 2,
            "direct_commit": _get_checkbox(props.get("Direct Commit", {})),
        }
        tasks.append(task)

    return tasks


# ─── Update Task Status ───────────────────────────────────────────

def update_task_status(page_id, status, **kwargs):
    """
    Update a task's status and optional fields.
    kwargs can include: error_log, attempt_count, assigned_run, pr_url, cost_usd
    """
    properties = {
        "Status": {"select": {"name": status}}
    }

    if "error_log" in kwargs and kwargs["error_log"]:
        properties["Error Log"] = {
            "rich_text": [{"text": {"content": str(kwargs["error_log"])[:2000]}}]
        }

    if "attempt_count" in kwargs:
        properties["Attempt Count"] = {"number": kwargs["attempt_count"]}

    if "assigned_run" in kwargs:
        properties["Assigned Run"] = {
            "rich_text": [{"text": {"content": str(kwargs["assigned_run"])}}]
        }

    if "pr_url" in kwargs and kwargs["pr_url"]:
        properties["PR URL"] = {"url": kwargs["pr_url"]}

    if "cost_usd" in kwargs and kwargs["cost_usd"] is not None:
        properties["Cost (USD)"] = {"number": kwargs["cost_usd"]}

    if status == "Done":
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        properties["Completed At"] = {
            "date": {"start": now}
        }

    body = {"properties": properties}
    return _request("PATCH", f"/pages/{page_id}", body)


# ─── Property Extractors ──────────────────────────────────────────

def _get_title(prop):
    items = prop.get("title", [])
    return items[0]["text"]["content"] if items else ""

def _get_rich_text(prop):
    items = prop.get("rich_text", [])
    return items[0]["text"]["content"] if items else ""

def _get_select(prop):
    sel = prop.get("select")
    return sel["name"] if sel else ""

def _get_url(prop):
    return prop.get("url", "")

def _get_number(prop):
    return prop.get("number")

def _get_checkbox(prop):
    return prop.get("checkbox", False)


# ─── CLI Interface ─────────────────────────────────────────────────

def main():
    """CLI interface for the orchestrator script to call."""
    if not NOTION_API_KEY:
        print("Error: NOTION_API_KEY environment variable not set", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) < 3:
        print("Usage: notion_client.py <command> <database_id> [args...]", file=sys.stderr)
        print("Commands:", file=sys.stderr)
        print("  get_tasks <database_id> [project]  - Get To Do tasks as JSON", file=sys.stderr)
        print("  update <page_id> <status> [json_kwargs]  - Update task status", file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]

    if command == "get_tasks":
        database_id = sys.argv[2]
        project = sys.argv[3] if len(sys.argv) > 3 else None
        tasks = get_todo_tasks(database_id, project)
        print(json.dumps(tasks, indent=2))

    elif command == "update":
        page_id = sys.argv[2]
        status = sys.argv[3]
        kwargs = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        result = update_task_status(page_id, status, **kwargs)
        print(json.dumps({"ok": True, "page_id": page_id, "status": status}))

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
