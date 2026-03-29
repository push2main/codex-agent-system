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

recent_auto_shelve_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-retry-classification",
      "title": "Improve retry failure classification coverage",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "$recent_auto_shelve_at",
      "shelved_reason": "auto-shelved: retry classification coverage recovered to 100% (10/10)",
      "task_intent": {
        "source": "self-improve"
      },
      "history": [
        {
          "at": "$recent_auto_shelve_at",
          "action": "auto_shelve",
          "from_status": "pending_approval",
          "to_status": "shelved",
          "project": "codex-agent-system",
          "note": "Task was automatically retired because the triggering retry classification signal is already back within threshold."
        }
      ]
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.12,
  "first_pass_success_rate": 0.68,
  "timeout_failure_rate": 0.03,
  "retry_classification_coverage": 0.24,
  "retry_classified_count": 15,
  "retry_total_count": 62,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 120
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=86400 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

pending_titles="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | map(.title)
    | sort
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$pending_titles" != "Improve retry failure classification coverage" ]; then
  echo "expected auto-shelved self-improve family to regenerate when the weakness returns, got: $pending_titles" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason,
      .gating.dominant_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\tnone\tnone' ]; then
  echo "unexpected run artifact after auto-shelved family regeneration: $artifact_summary" >&2
  exit 1
fi

echo "self improve auto-shelved family regeneration test passed"
