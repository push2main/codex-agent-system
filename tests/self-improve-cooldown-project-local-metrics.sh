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
  "approved_tasks": 4,
  "pending_approval_tasks": 3,
  "queued_tasks": 1,
  "running_tasks": 1,
  "queue_starvation_detected": true,
  "zero_step_timeout_rate": 0.9,
  "task_registry_payload_bytes": 2048,
  "task_registry_pressure_bytes": 2048,
  "task_registry_pressure_sources": [
    {
      "project": "superheld",
      "file": "/tmp/superheld/.codex-agent/tasks.json",
      "payload_bytes": 66518
    },
    {
      "project": "codex-agent-system",
      "file": "/tmp/codex-agent-system/codex-memory/tasks.json",
      "payload_bytes": 2048
    }
  ],
  "task_registry_pressure_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 20
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"
date +%s >"$REPO_ROOT/codex-logs/self-improve-codex-agent-system-cooldown"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=3600 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .status,
      .counts.generated,
      .gating.dominant_reason,
      .metrics_snapshot.success_rate,
      .metrics_snapshot.timeout_rate,
      .metrics_snapshot.recent_success_rate,
      .metrics_snapshot.first_pass_success_rate,
      .metrics_snapshot.zero_step_timeout_rate,
      .metrics_snapshot.backlog,
      .metrics_snapshot.queue_starvation_detected,
      .metrics_snapshot.total_tasks,
      .metrics_snapshot.pipeline_stale,
      .metrics_snapshot.pipeline_stale_since
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'success\t0\tcooldown_active\t1\t0\t1\t1\t0\t0\tfalse\t2\ttrue\t2026-03-24T11:15:00Z' ] && [ "$artifact_summary" != $'success\t0\tcooldown_active\t1.0\t0.0\t1.0\t1.0\t0.0\t0\tfalse\t2\ttrue\t2026-03-24T11:15:00Z' ]; then
  echo "unexpected project-local cooldown artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve cooldown project-local metrics test passed"
