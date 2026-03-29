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
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-approved-a",
      "title": "Approved task A",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-24T22:00:00Z"
    },
    {
      "id": "task-002-approved-b",
      "title": "Approved task B",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-24T22:00:01Z"
    },
    {
      "id": "task-003-approved-c",
      "title": "Approved task C",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-24T22:00:02Z"
    },
    {
      "id": "task-004-completed-success",
      "title": "Completed success",
      "project": "codex-agent-system",
      "status": "completed",
      "created_at": "2026-03-24T20:30:00Z",
      "updated_at": "2026-03-24T20:35:00Z",
      "completed_at": "2026-03-24T20:35:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-24T20:35:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T20:35:00Z","project":"codex-agent-system","task":"Completed success","result":"SUCCESS","failure_kind":"","task_id":"task-004-completed-success","attempts":1,"score":7,"run_id":"run-success-1"}
{"timestamp":"2026-03-24T20:40:00Z","project":"codex-agent-system","task":"Failure one","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-1","attempts":2,"score":0,"run_id":"run-failure-1"}
{"timestamp":"2026-03-24T20:45:00Z","project":"codex-agent-system","task":"Failure two","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-2","attempts":2,"score":0,"run_id":"run-failure-2"}
{"timestamp":"2026-03-24T20:50:00Z","project":"codex-agent-system","task":"Failure three","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-3","attempts":2,"score":0,"run_id":"run-failure-3"}
{"timestamp":"2026-03-24T20:55:00Z","project":"codex-agent-system","task":"Failure four","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-4","attempts":2,"score":0,"run_id":"run-failure-4"}
{"timestamp":"2026-03-24T21:00:00Z","project":"codex-agent-system","task":"Failure five","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-5","attempts":2,"score":0,"run_id":"run-failure-5"}
{"timestamp":"2026-03-24T21:05:00Z","project":"codex-agent-system","task":"Failure six","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-6","attempts":2,"score":0,"run_id":"run-failure-6"}
{"timestamp":"2026-03-24T21:10:00Z","project":"codex-agent-system","task":"Failure seven","result":"FAILURE","failure_kind":"execution_failure","task_id":"task-failure-7","attempts":2,"score":0,"run_id":"run-failure-7"}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-24T22:05:00Z",
  "signals": [
    {
      "title": "Fresh signal",
      "fresh": true,
      "published_at": "2026-03-24T22:00:00Z",
      "source_label": "fixture"
    }
  ],
  "errors": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 90,
  "pending_approval_tasks": 0,
  "task_registry_total": 131,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 385
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected one self-improve task when metrics backlog is stale" >&2
  exit 1
fi

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Improve retry success rate" ]; then
  echo "expected stale approved-task metrics to be ignored for backlog gating" >&2
  exit 1
fi

echo "self improve stale metrics backlog guard test passed"
