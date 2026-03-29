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
      "id": "task-157-inventory-current-decision-path-for-reco",
      "title": "Inventory current decision path for recover stale pipeline",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-28T04:07:32Z",
      "strategy_template": "bounded_learning_inventory",
      "failure_context": {
        "failure_kind": "unknown_persistent",
        "failed_step": "Inspect the current code path and runtime signals behind recover stale pipeline, then write one compact inventory artifact at codex-memory/self-improve-inventory-recover-stale-pipeline.md naming the exact files, functions, metrics, and decision points that the next self-improve retry must edit. Do not implement code changes in the same run."
      }
    },
    {
      "id": "task-158-inventory-current-decision-path-for-reco",
      "title": "Inventory current decision path for recover stale pipeline",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-28T04:22:45Z",
      "strategy_template": "bounded_learning_inventory",
      "failure_context": {
        "failure_kind": "review_rejection",
        "failed_step": "Inspect the current code path and runtime signals behind recover stale pipeline, then write one compact inventory artifact at codex-memory/self-improve-inventory-recover-stale-pipeline.md naming the exact files, functions, metrics, and decision points that the next self-improve retry must edit. Do not implement code changes in the same run."
      }
    },
    {
      "id": "task-159-fix-repeated-failure-inspect-the-current",
      "title": "Fix repeated failure: Inspect the current code path and runtime signals behind rec",
      "execution_task": "[self-improve:medium] Fix repeated failure: Inspect the current code path and runtime signals behind rec -- Error occurred 2 times across tasks task-158-inventory-current-decision-path-for-reco, task-157-inventory-current-decision-path-for-reco. This is a systematic issue that should be fixed at the root cause.",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-28T04:28:48Z",
      "reason": "Error occurred 2 times across tasks task-158-inventory-current-decision-path-for-reco, task-157-inventory-current-decision-path-for-reco. This is a systematic issue that should be fixed at the root cause.",
      "task_intent": {
        "source": "self-improve",
        "objective": "Fix repeated failure: Inspect the current code path and runtime signals behind rec",
        "project": "codex-agent-system",
        "category": "code_quality",
        "context_hint": "Error occurred 2 times across tasks task-158-inventory-current-decision-path-for-reco, task-157-inventory-current-decision-path-for-reco. This is a systematic issue that should be fixed at the root cause.",
        "affected_files": []
      },
      "history": []
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
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 8,
  "retry_total_count": 8,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 1,
  "pending_approval_blocked_detected": true,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 3,
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
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

wrapper_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-159-fix-repeated-failure-inspect-the-current"))
    | first
    | [.status, .shelved_reason, (.history[-1].action // ""), (.history[-1].note // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
case "$wrapper_summary" in
  $'shelved\tauto-shelved: repeated-failure placeholder is a known non-actionable wrapper failure\tauto_shelve\tTask was automatically retired because it matches a generic repeated-failure placeholder with no actionable root cause: repeated-failure placeholder is a known non-actionable wrapper failure.')
    ;;
  *)
    echo "expected inspect-only repeated-failure wrapper to be auto-shelved, got: $wrapper_summary" >&2
    exit 1
    ;;
esac

task_count="$(
  jq '.tasks | length' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 3 ]; then
  echo "expected no replacement self-improve wrapper task to be generated" >&2
  exit 1
fi

pending_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${pending_count:-0}" -ne 0 ]; then
  echo "expected no pending self-improve task after inspect-only wrapper retirement" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.retired_obsolete_pending_tasks
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0\t0\t1' ]; then
  echo "unexpected inspect-only wrapper artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve inventory repeated failure shelve test passed"
