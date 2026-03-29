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

recent_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-timeout-rate",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 10%",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "$recent_failure_at",
      "shelved_reason": "zombie_guard: 5+ failures — shelved by self-learning iteration 8",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-timeout-rate",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 33%",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "$recent_failure_at",
      "shelved_reason": "Duplicate of zombie task-001 (same goal: reduce timeout rate). Shelved by iteration 8.",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.15,
  "recent_success_rate": 0.28,
  "first_pass_success_rate": 0.67,
  "timeout_failure_rate": 0.36,
  "retry_classification_coverage": 0.87,
  "retry_classified_count": 54,
  "retry_total_count": 62,
  "zero_step_timeout_rate": 0.94,
  "diagnostic_coverage": 1.0,
  "recent_diagnostic_coverage": 1.0,
  "failures_with_diagnostic": 443,
  "total_failure_records": 443,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 1131471,
  "task_registry_pressure_detected": true,
  "task_registry_pressure_sources": [
    {
      "project": "superheld",
      "file": "/tmp/superheld/tasks.json",
      "payload_bytes": 1082426
    },
    {
      "project": "codex-agent-system",
      "file": "/tmp/codex-agent-system/tasks.json",
      "payload_bytes": 49045
    }
  ],
  "retry_churn_detected": true,
  "loop_effort_detected": true,
  "loop_effort_task_count": 68,
  "loop_effort_extra_step_attempts": 157,
  "strategy_saturation_detected": false,
  "external_signal_status": "stale",
  "fresh_external_signal_count": 0,
  "latest_external_signal_source": "OpenAI Python releases",
  "total_tasks": 522
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=7200 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
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

if [[ "$pending_titles" != *"Cap pre-step planning budget"* ]]; then
  echo "expected planning-budget successor under zero-step timeout emergency" >&2
  exit 1
fi

if [[ "$pending_titles" == *"Reduce timeout rate"* ]]; then
  echo "expected generic timeout remediation to be suppressed once planning-budget successor is promoted" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.submission_reason,
      .metrics_snapshot.zero_step_timeout_rate
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'4\t2\tlow_success_rate\t0.94' ]; then
  echo "unexpected artifact summary for superseded generic timeout remediation: $artifact_summary" >&2
  exit 1
fi

echo "self improve zero-step timeout generic suppression test passed"
