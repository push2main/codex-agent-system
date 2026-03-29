#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-local-success",
      "title": "Local success one",
      "project": "codex-agent-system",
      "status": "completed",
      "score": 7,
      "created_at": "2026-03-24T10:00:00Z",
      "updated_at": "2026-03-24T10:10:00Z",
      "completed_at": "2026-03-24T10:10:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-24T10:10:00Z"
      }
    },
    {
      "id": "task-002-local-success",
      "title": "Local success two",
      "project": "codex-agent-system",
      "status": "completed",
      "score": 6,
      "created_at": "2026-03-24T11:00:00Z",
      "updated_at": "2026-03-24T11:15:00Z",
      "completed_at": "2026-03-24T11:15:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-24T11:15:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T10:10:00Z","project":"codex-agent-system","task":"Local success one","result":"SUCCESS","failure_kind":"","task_id":"task-001-local-success","attempts":1,"score":7,"run_id":"run-local-1"}
{"timestamp":"2026-03-24T11:15:00Z","project":"codex-agent-system","task":"Local success two","result":"SUCCESS","failure_kind":"","task_id":"task-002-local-success","attempts":1,"score":6,"run_id":"run-local-2"}
{"timestamp":"2026-03-24T12:00:00Z","project":"superheld","task":"Remote timeout one","result":"FAILURE","failure_kind":"timeout","task_id":"remote-001","attempts":1,"score":0,"run_id":"run-remote-1"}
{"timestamp":"2026-03-24T12:10:00Z","project":"superheld","task":"Remote timeout two","result":"FAILURE","failure_kind":"timeout","task_id":"remote-002","attempts":2,"score":0,"run_id":"run-remote-2"}
{"timestamp":"2026-03-24T12:20:00Z","project":"superheld","task":"Remote retry churn","result":"FAILURE","failure_kind":"step_failure","task_id":"remote-003","attempts":2,"score":0,"run_id":"run-remote-3"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.2,
  "timeout_failure_rate": 0.4,
  "first_pass_success_rate": 0.85,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "retry_churn_detected": true,
  "loop_effort_task_count": 12,
  "loop_effort_extra_step_attempts": 30,
  "strategy_saturation_detected": false,
  "saturated_failed_tasks": 0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_total": 2,
  "task_registry_payload_bytes": 2048,
  "task_registry_pressure_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 20
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-24T12:30:00Z",
  "signals": [
    {
      "source_id": "fixture",
      "title": "Fresh fixture signal",
      "url": "https://example.com/fresh",
      "published_at": "2026-03-24T12:25:00Z",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

pending_self_improve_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
pending_self_improve_title="$(
  jq -r '
    first(
      .tasks[]
      | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")
      | .title
    ) // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${pending_self_improve_count:-0}" -gt 1 ]; then
  echo "expected at most one local self-improve follow-up" >&2
  exit 1
fi
if [ "${pending_self_improve_count:-0}" -eq 1 ] && [ "$pending_self_improve_title" != "Recover stale pipeline" ]; then
  echo "expected only stale local pipeline recovery to remain eligible, got: $pending_self_improve_title" >&2
  exit 1
fi

metrics_summary="$(
  jq -r '
    [
      .metrics_snapshot.success_rate,
      .metrics_snapshot.timeout_rate,
      .metrics_snapshot.recent_success_rate,
      .metrics_snapshot.total_tasks
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$metrics_summary" != $'1\t0\t1\t2' ] && [ "$metrics_summary" != $'1.0\t0.0\t1.0\t2' ]; then
  echo "unexpected project-local metrics snapshot: $metrics_summary" >&2
  exit 1
fi

pipeline_summary="$(
  jq -r '
    [
      .metrics_snapshot.pipeline_stale,
      .metrics_snapshot.pipeline_stale_since,
      .gating.backlog_gate_active
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$pipeline_summary" != $'true\t2026-03-24T11:15:00Z\tfalse' ]; then
  echo "unexpected pipeline status summary: $pipeline_summary" >&2
  exit 1
fi

echo "self improve project-local metrics test passed"
