#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning"
}

run_case() {
  local case_name="$1"
  local tasks_payload="$2"
  local metrics_payload="$3"
  local expected_queue_starvation="$4"
  local expected_pending_blocked="$5"

  local repo_root="$TMP_DIR/$case_name"
  make_repo "$repo_root"

  printf '%s\n' "$tasks_payload" >"$repo_root/codex-memory/tasks.json"
  printf '%s\n' "$metrics_payload" >"$repo_root/codex-learning/metrics.json"

  (
    cd "$repo_root"
    bash scripts/validate-metrics.sh >/dev/null
  )

  local actual_summary
  actual_summary="$(
    python3 - "$repo_root/codex-learning/metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    metrics = json.load(handle)

print(
    "\t".join(
        [
            str(metrics.get("queue_starvation_detected")).lower(),
            str(metrics.get("pending_approval_blocked_detected")).lower(),
        ]
    )
)
PY
  )"

  local expected_summary="${expected_queue_starvation}"$'\t'"${expected_pending_blocked}"
  if [ "$actual_summary" != "$expected_summary" ]; then
    echo "unexpected board-health summary for $case_name: $actual_summary" >&2
    exit 1
  fi
}

run_case \
  "approved-backlog-starvation" \
  '{
    "tasks": [
      {
        "id": "task-approved",
        "title": "Approved work should preserve queue starvation",
        "project": "codex-agent-system",
        "status": "approved",
        "updated_at": "2026-03-27T21:00:00Z"
      }
    ]
  }' \
  '{
    "approved_tasks": 1,
    "approved_backlog": 1,
    "pending_approval_tasks": 0,
    "queued_tasks": 0,
    "running_tasks": 0,
    "task_registry_total": 1,
    "queue_starvation_detected": true,
    "pending_approval_blocked_detected": false,
    "retry_churn_detected": false
  }' \
  "true" \
  "false"

run_case \
  "pending-approval-blocked" \
  '{
    "tasks": [
      {
        "id": "task-pending",
        "title": "Pending approval should not look like queue starvation",
        "project": "codex-agent-system",
        "status": "pending_approval",
        "updated_at": "2026-03-27T21:05:00Z"
      }
    ]
  }' \
  '{
    "approved_tasks": 0,
    "approved_backlog": 0,
    "pending_approval_tasks": 1,
    "queued_tasks": 0,
    "running_tasks": 0,
    "task_registry_total": 1,
    "queue_starvation_detected": false,
    "pending_approval_blocked_detected": false,
    "retry_churn_detected": false
  }' \
  "false" \
  "true"

echo "validate metrics board health test passed"
