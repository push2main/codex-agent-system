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
RECENT_SUCCESS_AT="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-reduce-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T10:05:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "$RECENT_SUCCESS_AT",
      "completed_at": "$RECENT_SUCCESS_AT",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.33,
  "zero_step_timeout_rate": 0.94,
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 1,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 240
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

retired_timeout_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-001-reduce-timeout-rate"))
    | first
    | [
        (.status // ""),
        (.shelved_reason // ""),
        (.history[-1].action // ""),
        (.history[-1].note // "")
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [[ "$retired_timeout_summary" != $'shelved\tauto-shelved: recent successful `Cap pre-step planning budget` remediation should absorb the same zero-step timeout emergency until metrics refresh\tauto_shelve\tTask was automatically retired because a narrower active self-improve task already covers the same zero-step timeout emergency: recent successful `Cap pre-step planning budget` remediation should absorb the same zero-step timeout emergency until metrics refresh.' ]]; then
  echo "expected pending generic timeout task to be retired while the recent planning-budget success cooldown is still active: $retired_timeout_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.submitted,
      .gating.retired_resolved_pending_tasks,
      (
        (.submitted_tasks // [])
        | map(select(.title == "Reduce timeout rate"))
        | length
      )
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\t0' ]; then
  echo "expected recent planning-budget success to retire the generic timeout task without opening a new one: $artifact_summary" >&2
  exit 1
fi

echo "self improve recent planning-budget success retirement test passed"
