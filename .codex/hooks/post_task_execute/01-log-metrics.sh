#!/usr/bin/env bash
# Post-execution hook: log task metrics summary
# Receives JSON on stdin with: {event, timestamp, data: {task, project, result, score, duration}}

set -Eeuo pipefail

INPUT="$(cat)"
EVENT="$(printf '%s' "$INPUT" | jq -r '.event // "unknown"' 2>/dev/null || true)"
TASK="$(printf '%s' "$INPUT" | jq -r '.data.task // "unknown"' 2>/dev/null || true)"
RESULT="$(printf '%s' "$INPUT" | jq -r '.data.result // "unknown"' 2>/dev/null || true)"

# Simply log — hooks should be lightweight
printf '[hook:post_task_execute] %s task=%s result=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK" "$RESULT"
exit 0
