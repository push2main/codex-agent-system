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
      "id": "task-130-improve-first-pass-success-rate",
      "task": "[self-improve:critical] Improve first-pass success rate -- Tasks fail even on first attempt (50% first-pass success). Improve planner context quality, reduce prompt size, and ensure task descriptions are specific enough. (files: agents/planner.sh)",
      "title": "Improve first-pass success rate",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "queued",
      "priority": 7,
      "created_at": "2026-03-24T22:00:12Z",
      "updated_at": "2026-03-26T21:09:08Z"
    },
    {
      "id": "task-131-break-retry-churn",
      "task": "[self-improve:high] Break retry churn -- 15 tasks consumed 23 extra step attempts without resolution. Implement exponential backoff on retries and skip tasks that fail with identical errors. (files: agents/orchestrator.sh)",
      "title": "Break retry churn",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "queued",
      "priority": 6,
      "created_at": "2026-03-24T22:00:12Z",
      "updated_at": "2026-03-26T18:10:44Z"
    },
    {
      "id": "task-132-reduce-strategy-saturation",
      "task": "[self-improve:medium] Reduce strategy saturation -- Strategy engine has 2 saturated failed tasks and is generating work faster than it completes it. Increase ENTERPRISE_ACTIONABLE_TARGET, add generation cooldown, and prune duplicate/similar task proposals. (files: scripts/strategy-loop.sh)",
      "title": "Reduce strategy saturation",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "queued",
      "priority": 4,
      "created_at": "2026-03-24T22:00:12Z",
      "updated_at": "2026-03-26T21:09:08Z"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.10,
  "recent_success_rate": 0.10,
  "first_pass_success_rate": 1.0,
  "timeout_failure_rate": 0.32,
  "zero_step_timeout_rate": 0.97,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 2,
  "retry_total_count": 2,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "queued_tasks": 3,
  "running_tasks": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T10:15:00Z",
  "total_tasks": 48
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.active_self_improve_count,
      .gating.submission_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'3\t1\t3\tcritical_low_success_rate' ]; then
  echo "unexpected metadata repair artifact summary: $artifact_summary" >&2
  exit 1
fi

repair_summary="$(
  jq -r '
    .tasks
    | map(select(.status == "queued"))
    | map([
        .title,
        .execution_task,
        (.task_intent.source // ""),
        (.task_intent.objective // ""),
        ((.history // [])[-1].action // "")
      ] | @tsv)
    | .[]
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
expected_summary=$'Improve first-pass success rate\t[self-improve:critical] Improve first-pass success rate -- Tasks fail even on first attempt (50% first-pass success). Improve planner context quality, reduce prompt size, and ensure task descriptions are specific enough. (files: agents/planner.sh)\tself-improve\tImprove first-pass success rate\tmetadata_repair\nBreak retry churn\t[self-improve:high] Break retry churn -- 15 tasks consumed 23 extra step attempts without resolution. Implement exponential backoff on retries and skip tasks that fail with identical errors. (files: agents/orchestrator.sh)\tself-improve\tBreak retry churn\tmetadata_repair\nReduce strategy saturation\t[self-improve:medium] Reduce strategy saturation -- Strategy engine has 2 saturated failed tasks and is generating work faster than it completes it. Increase ENTERPRISE_ACTIONABLE_TARGET, add generation cooldown, and prune duplicate/similar task proposals. (files: scripts/strategy-loop.sh)\tself-improve\tReduce strategy saturation\tmetadata_repair'
if [ "$repair_summary" != "$expected_summary" ]; then
  echo "unexpected repaired queued-task summary: $repair_summary" >&2
  exit 1
fi

pending_summary="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.task_intent.source // "")] | @tsv)
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$pending_summary" != $'Recover stale pipeline\tself-improve' ]; then
  echo "expected only the new recovery family to remain pending after metadata repair: $pending_summary" >&2
  exit 1
fi

echo "self improve active self-improve metadata repair test passed"
