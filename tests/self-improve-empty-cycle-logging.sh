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

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.62,
  "first_pass_success_rate": 0.62,
  "timeout_failure_rate": 0.0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 24
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null 2>&1
)

if ! grep -F "Registered 0 of 0 improvement tasks in registry as pending_approval" "$REPO_ROOT/codex-logs/system.log" >/dev/null 2>&1; then
  echo "expected empty self-improve cycle to log 0 of 0 registered tasks" >&2
  exit 1
fi

artifact_file="$REPO_ROOT/codex-learning/self-improve-run.json"
if [ ! -f "$artifact_file" ]; then
  echo "expected self-improve run artifact to be written" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .counts.skipped,
      .gating.dominant_reason
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$artifact_summary" != $'0\t0\t0\tno_detected_weakness' ]; then
  echo "unexpected empty-cycle artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve empty cycle logging test passed"
