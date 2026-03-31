#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

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
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent" \
  "$EXTERNAL_WORKSPACE/packages/schema"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.12,
  "first_pass_success_rate": 0.75,
  "timeout_failure_rate": 0.01,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 9,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 1,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 25
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Incident",
  "type": "object",
  "properties": {
    "incident_type": {
      "type": "string",
      "enum": [
        "social_message_risk"
      ]
    }
  },
  "examples": []
}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-021-break-retry-churn",
      "title": "Break retry churn",
      "execution_task": "[self-improve:high] Break retry churn -- Start with `packages/schema/incident.schema.json`. 1 tasks consumed 1 extra step attempts without resolution.",
      "project": "superheld",
      "status": "pending_approval",
      "reason": "Start with `packages/schema/incident.schema.json`. 1 tasks consumed 1 extra step attempts without resolution. Implement exponential backoff on retries and skip tasks that fail with identical errors.",
      "category": "stability",
      "target_files": [
        "packages/schema/incident.schema.json"
      ],
      "task_intent": {
        "source": "self-improve",
        "objective": "Break retry churn",
        "project": "superheld",
        "category": "stability",
        "affected_files": [
          "packages/schema/incident.schema.json"
        ]
      },
      "history": []
    }
  ]
}
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_WORKSPACE/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_WORKSPACE/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_WORKSPACE/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

invalid_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-021-break-retry-churn"))
    | first
    | [.status, .shelved_reason, (.history[-1].action // ""), (.history[-1].note // "")]
    | @tsv
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

case "$invalid_summary" in
  $'shelved\tauto-shelved: external projects must not map control-plane self-improve weaknesses onto product work\tauto_shelve\tTask was automatically retired because external projects must not rewrite control-plane self-improve weaknesses into product-facing work: external projects must not map control-plane self-improve weaknesses onto product work.')
    ;;
  *)
    echo "expected invalid external pending task to be auto-shelved, got: $invalid_summary" >&2
    exit 1
    ;;
esac

echo "self improve external invalid pending shelve test passed"
