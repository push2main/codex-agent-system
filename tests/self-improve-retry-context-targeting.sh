#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"

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

make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "first_pass_success_rate": 0.67,
  "timeout_failure_rate": 0.02,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "retry_classification_coverage": 0.22,
  "retry_classified_count": 13,
  "retry_total_count": 58,
  "external_signal_status": "fresh",
  "total_tasks": 140
}
EOF

python3 - "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = []
for idx in range(1, 11):
    rows.append({
        "task_id": f"retry-{idx:02d}",
        "project": "codex-agent-system",
        "attempt": 2,
        "failed_step_index": 1,
        "classification": "unknown",
        "timestamp": f"2026-03-25T03:{19 + idx:02d}:00Z",
        "task_context": {
            "objective": "Tighten queue timeout diagnostics",
            "context_hint": "Keep retry diagnostics scoped to queue timeout evidence.",
            "affected_files": ["scripts/queue-worker.sh", "agents/orchestrator.sh"],
        },
    })

rows.append({
    "task_id": "retry-cross-project",
    "project": "other-project",
    "attempt": 2,
    "failed_step_index": 1,
    "classification": "unknown",
    "timestamp": "2026-03-25T03:40:00Z",
    "task_context": {
        "objective": "Other project retry",
        "context_hint": "Should not leak across projects.",
        "affected_files": ["scripts/strategy-loop.sh"],
    },
})

path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
PY

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.title // "") == "Improve retry failure classification coverage"))
    | first
    | [
        .reason // "",
        ((.task_intent.affected_files // []) | join(","))
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
expected=$'Only 0% of retry failures are classified (0/10); broaden deterministic failure capture before tuning broader retry behavior by enriching reviewer/evaluator context in orchestrator.sh and extending classify_failure patterns. Recent unknown retries cluster around Tighten queue timeout diagnostics. Start with the current task-context files: scripts/queue-worker.sh, agents/orchestrator.sh, scripts/lib.sh.\tscripts/queue-worker.sh,agents/orchestrator.sh,scripts/lib.sh'
if [ "$summary" != "$expected" ]; then
  echo "unexpected retry-context-targeted self-improve task: $summary" >&2
  exit 1
fi

echo "self improve retry context targeting test passed"
