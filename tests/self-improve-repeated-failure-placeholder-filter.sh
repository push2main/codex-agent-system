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

run_self_improve() {
  local repo_root="$1"
  (
    cd "$repo_root"
    IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
  )
}

write_baseline_metrics() {
  local repo_root="$1"
  cat >"$repo_root/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "recent_success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "pending_approval_blocked_detected": false,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 2,
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
}

PLACEHOLDER_REPO="$TMP_DIR/placeholder-repo"
make_repo "$PLACEHOLDER_REPO"

cat >"$PLACEHOLDER_REPO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-placeholder",
      "title": "Placeholder failure one",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-25T18:00:00Z",
      "failure_context": {
        "failure_kind": "unknown_persistent",
        "failed_step": "Queue execution failed after exhausting retries."
      }
    },
    {
      "id": "task-002-placeholder",
      "title": "Placeholder failure two",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-25T18:05:00Z",
      "failure_context": {
        "failure_kind": "unknown_persistent",
        "failed_step": "Queue execution failed after exhausting retries."
      }
    }
  ]
}
EOF

write_baseline_metrics "$PLACEHOLDER_REPO"

run_self_improve "$PLACEHOLDER_REPO"

placeholder_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$PLACEHOLDER_REPO/codex-memory/tasks.json"
)"
if [ "${placeholder_count:-0}" -ne 0 ]; then
  echo "expected generic repeated placeholder failures to be ignored" >&2
  exit 1
fi

ACTIONABLE_REPO="$TMP_DIR/actionable-repo"
make_repo "$ACTIONABLE_REPO"

cat >"$ACTIONABLE_REPO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-101-actionable",
      "title": "Actionable failure one",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-25T18:10:00Z",
      "failure_context": {
        "failure_kind": "infra",
        "failed_step": "Resolve queue worker lease reconciliation before retry handoff."
      }
    },
    {
      "id": "task-102-actionable",
      "title": "Actionable failure two",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-25T18:15:00Z",
      "failure_context": {
        "failure_kind": "infra",
        "failed_step": "Resolve queue worker lease reconciliation before retry handoff."
      }
    }
  ]
}
EOF

write_baseline_metrics "$ACTIONABLE_REPO"

run_self_improve "$ACTIONABLE_REPO"

actionable_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | first
    | .title // ""
  ' "$ACTIONABLE_REPO/codex-memory/tasks.json"
)"

case "$actionable_title" in
  "Fix repeated failure: Resolve queue worker lease reconciliation before retry hand"*)
    ;;
  *)
    echo "expected actionable repeated failures to remain eligible for self-improve follow-up" >&2
    exit 1
    ;;
esac

echo "self improve repeated failure placeholder filter test passed"
