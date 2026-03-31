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
  "$REPO_ROOT/projects/superheld"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.18,
  "recent_success_rate": 0.2,
  "first_pass_success_rate": 0.2,
  "timeout_failure_rate": 0.05,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 9,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 80
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$REPO_ROOT",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$REPO_ROOT/codex-memory/memory-superheld.md",
  "spec_file": "$REPO_ROOT/codex-memory/spec-superheld.md",
  "policy_file": "$REPO_ROOT/codex-memory/policy-superheld.json",
  "task_registry_file": "$REPO_ROOT/codex-memory/tasks.json"
}
EOF

python3 - <<'PY' >"$REPO_ROOT/codex-logs/self-improve-superheld-cooldown"
import time
print(int(time.time()) - 700)
PY

(
  cd "$REPO_ROOT"
  bash scripts/self-improve.sh superheld >/dev/null
)

superheld_summary="$(
  python3 - "$REPO_ROOT/codex-memory/tasks.json" "$REPO_ROOT/codex-learning/self-improve-run.json" <<'PY'
import json
import sys
from pathlib import Path

tasks = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("tasks", [])
artifact = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
project_tasks = [
    task for task in tasks
    if task.get("project") == "superheld"
    and (task.get("task_intent") or {}).get("source") == "self-improve"
]
print(
    "\t".join(
        [
            str(len(project_tasks)),
            str(artifact.get("gating", {}).get("dominant_reason") or ""),
            str(artifact.get("counts", {}).get("submitted") or 0),
        ]
    )
)
PY
)"

superheld_task_count="$(printf '%s\n' "$superheld_summary" | cut -f1)"
superheld_dominant_reason="$(printf '%s\n' "$superheld_summary" | cut -f2)"
superheld_submitted="$(printf '%s\n' "$superheld_summary" | cut -f3)"

if [ "${superheld_task_count:-0}" -lt 1 ] || [ "$superheld_dominant_reason" != "none" ] || [ "${superheld_submitted:-0}" -lt 1 ]; then
  echo "expected external project to bypass default cooldown after 700s, got: $superheld_summary" >&2
  exit 1
fi

python3 - <<'PY' >"$REPO_ROOT/codex-logs/self-improve-codex-agent-system-cooldown"
import time
print(int(time.time()) - 700)
PY

(
  cd "$REPO_ROOT"
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

core_summary="$(
  jq -r '
    [
      .gating.dominant_reason,
      .counts.submitted
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$core_summary" != $'cooldown_active\t0' ]; then
  echo "expected core project to keep 3600s default cooldown after 700s, got: $core_summary" >&2
  exit 1
fi

echo "self improve default external project cooldown test passed"
