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
      "id": "task-001-planner-fallback",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-27T19:00:00Z",
      "failure_context": {
        "failure_kind": "unknown",
        "failed_step": "plan: Created deterministic fallback plan."
      }
    },
    {
      "id": "task-002-planner-fallback",
      "title": "Improve retry success rate",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-27T19:05:00Z",
      "failure_context": {
        "failure_kind": "unknown",
        "failed_step": "plan: Created deterministic fallback plan."
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "recent_success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 20
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

self_improve_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${self_improve_count:-0}" -ne 0 ]; then
  echo "expected planner fallback placeholder failures to be ignored" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0\t0\tno_detected_weakness' ]; then
  echo "unexpected planner fallback placeholder artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve planner fallback placeholder filter test passed"
