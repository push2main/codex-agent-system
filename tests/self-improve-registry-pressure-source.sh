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
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"
make_repo "$REPO_ROOT"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<EOF
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 984518,
  "task_registry_pressure_detected": true,
  "task_registry_pressure_primary_surface": "dashboard_read_path",
  "task_registry_pressure_sources": [
    {
      "project": "superheld",
      "file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json",
      "payload_bytes": 852069
    },
    {
      "project": "codex-agent-system",
      "file": "$REPO_ROOT/codex-memory/tasks.json",
      "payload_bytes": 132449
    }
  ],
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq -r '
    .tasks
    | map(select(.task_intent.source == "self-improve"))
    | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"

if [ "${task_count:-0}" -ne 0 ]; then
  echo "expected cross-project registry pressure to avoid creating a local self-improve task" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.detected,
      .counts.generated,
      .counts.blocked_analysis,
      .gating.analysis_reason,
      ((.metrics_snapshot.registry_bytes // 0) | tostring),
      ((.metrics_snapshot.shared_registry_bytes // 0) | tostring),
      ((.metrics_snapshot.local_registry_bytes // 0) | tostring),
      (.metrics_snapshot.registry_pressure_scope // ""),
      (.metrics_snapshot.registry_pressure_dominant_source.project // "")
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

case "$artifact_summary" in
  $'1\t0\t1\tcross_project_registry_pressure\t984518\t984518\t132449\tcross_project\tsuperheld')
    ;;
  *)
    echo "unexpected self-improve artifact for cross-project registry pressure: $artifact_summary" >&2
    exit 1
    ;;
esac

echo "self improve registry pressure source test passed"
