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
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T09:00:00Z","project":"codex-agent-system","task":"Last success","result":"SUCCESS","failure_kind":"","task_id":"task-last-success","attempts":1,"score":7,"run_id":"run-last-success"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.46,
  "recent_success_rate": 0.47,
  "first_pass_success_rate": 0.54,
  "timeout_failure_rate": 0.03,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 18,
  "retry_total_count": 20,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "pipeline_stale": false,
  "pipeline_stale_since": null,
  "total_tasks": 120
}
EOF

python3 - <<'PY' >"$REPO_ROOT/codex-logs/self-improve-codex-agent-system-cooldown"
import time
print(int(time.time()) - 600)
PY

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=3600 \
  IMPROVEMENT_EMERGENCY_COOLDOWN_SECONDS=300 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | [length, (last | .title // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_summary" != $'1\tRecover stale pipeline' ]; then
  echo "expected project-local stale pipeline evidence to bypass the normal cooldown: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      (.gating.dominant_reason // "none"),
      .gating.submission_reason,
      .metrics_snapshot.pipeline_stale,
      .metrics_snapshot.pipeline_stale_since
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\tnone\tdefault_limit\ttrue\t2026-03-25T09:00:00Z' ]; then
  echo "unexpected project-local emergency cooldown bypass artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve cooldown project-local emergency bypass test passed"
