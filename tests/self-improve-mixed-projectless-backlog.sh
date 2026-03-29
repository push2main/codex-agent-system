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
      "id": "local-pending",
      "title": "Local pending improvement",
      "project": "codex-agent-system",
      "status": "pending_approval"
    },
    {
      "id": "local-completed",
      "title": "Completed local task",
      "project": "codex-agent-system",
      "status": "completed"
    },
    {
      "id": "legacy-foreign-01",
      "title": "Legacy foreign approved 01",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-02",
      "title": "Legacy foreign approved 02",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-03",
      "title": "Legacy foreign approved 03",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-04",
      "title": "Legacy foreign approved 04",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-05",
      "title": "Legacy foreign approved 05",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-06",
      "title": "Legacy foreign approved 06",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-07",
      "title": "Legacy foreign approved 07",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-08",
      "title": "Legacy foreign approved 08",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-09",
      "title": "Legacy foreign approved 09",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-10",
      "title": "Legacy foreign approved 10",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-11",
      "title": "Legacy foreign approved 11",
      "status": "approved"
    },
    {
      "id": "legacy-foreign-12",
      "title": "Legacy foreign approved 12",
      "status": "approved"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.18,
  "timeout_failure_rate": 0.04,
  "first_pass_success_rate": 0.68,
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 9,
  "retry_total_count": 11,
  "approved_tasks": 12,
  "approved_backlog": 12,
  "pending_approval_tasks": 1,
  "task_registry_total": 14,
  "task_registry_payload_bytes": 8192,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 100
}
EOF

touch "$REPO_ROOT/codex-memory/tasks.log"
touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_file="$REPO_ROOT/codex-learning/self-improve-run.json"
artifact_summary="$(
  jq -r '
    [
      .gating.backlog_gate_active,
      .metrics_snapshot.backlog,
      .gating.active_self_improve_count
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$artifact_summary" != $'false\t1\t0' ]; then
  echo "unexpected mixed projectless backlog summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve mixed projectless backlog test passed"
