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
      "id": "task-001-local-success",
      "title": "Local first-pass success",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2026-03-25T10:00:00Z",
      "completed_at": "2026-03-25T10:00:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-25T10:00:00Z"
      }
    },
    {
      "id": "task-002-local-retry",
      "title": "Local retry churn candidate",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-25T10:05:00Z",
      "failed_at": "2026-03-25T10:05:00Z",
      "execution": {
        "state": "failed",
        "attempt": 2,
        "total_step_attempts": 3,
        "max_retries": 2,
        "result": "FAILURE",
        "updated_at": "2026-03-25T10:05:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T10:00:00Z","project":"codex-agent-system","task":"Local first-pass success","result":"SUCCESS","failure_kind":"","task_id":"task-001-local-success","attempts":1,"score":7,"run_id":"run-local-1"}
{"timestamp":"2026-03-25T10:05:00Z","project":"codex-agent-system","task":"Local retry churn candidate","result":"FAILURE","failure_kind":"step_failure","task_id":"task-002-local-retry","attempts":2,"score":0,"run_id":"run-local-2"}
{"timestamp":"2026-03-25T10:06:00Z","project":"codex-agent-system","task":"Local failure two","result":"FAILURE","failure_kind":"step_failure","task_id":"task-003-local-failure","attempts":1,"score":0,"run_id":"run-local-3"}
{"timestamp":"2026-03-25T10:07:00Z","project":"codex-agent-system","task":"Local failure three","result":"FAILURE","failure_kind":"step_failure","task_id":"task-004-local-failure","attempts":1,"score":0,"run_id":"run-local-4"}
{"timestamp":"2026-03-25T10:08:00Z","project":"codex-agent-system","task":"Local failure four","result":"FAILURE","failure_kind":"step_failure","task_id":"task-005-local-failure","attempts":1,"score":0,"run_id":"run-local-5"}
EOF

cat >"$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl" <<'EOF'
{"project":"codex-agent-system","task_id":"retry-001","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-002","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-003","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-004","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-005","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-006","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-007","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-008","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-009","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-010","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-011","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-012","classification":"timeout"}
{"project":"codex-agent-system","task_id":"retry-013","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-014","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-015","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-016","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-017","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-018","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-019","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-020","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-021","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-022","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-023","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-024","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-025","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-026","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-027","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-028","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-029","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-030","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-031","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-032","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-033","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-034","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-035","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-036","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-037","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-038","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-039","classification":"unknown"}
{"project":"codex-agent-system","task_id":"retry-040","classification":"unknown"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.18,
  "timeout_failure_rate": 0.05,
  "first_pass_success_rate": 0.8,
  "retry_classification_coverage": 0.3,
  "retry_classified_count": 12,
  "retry_total_count": 40,
  "retry_churn_detected": true,
  "loop_effort_task_count": 63,
  "loop_effort_extra_step_attempts": 158,
  "strategy_saturation_detected": false,
  "approved_tasks": 90,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 1043660,
  "task_registry_pressure_detected": true,
  "external_signal_status": "fresh",
  "total_tasks": 476
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected backlog overload to preserve exactly one self-improve task" >&2
  exit 1
fi

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Improve retry failure classification coverage" ]; then
  echo "expected overload ranking to use project-local loop effort instead of global metrics" >&2
  exit 1
fi

overload_summary="$(
  jq -r '
    [
      .gating.overload.active,
      .gating.overload.preserved_title,
      .gating.overload.preserved_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$overload_summary" != $'true\tImprove retry failure classification coverage\thighest_unblocked_score' ]; then
  echo "unexpected overload summary: $overload_summary" >&2
  exit 1
fi

retry_candidate_summary="$(
  jq -r '
    .gating.overload.candidates
    | map(select(.title == "Break retry churn"))
    | first
    | [
        .score,
        .signal_priority,
        .recent_failures_since_latest_success
      ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$retry_candidate_summary" != $'40\t0\t0' ]; then
  echo "unexpected project-local retry churn candidate summary: $retry_candidate_summary" >&2
  exit 1
fi

echo "self improve overload project-local loop effort test passed"
