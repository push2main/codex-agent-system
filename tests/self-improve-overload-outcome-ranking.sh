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

timeout_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-timeout-rate",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$timeout_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-retry-churn",
      "title": "Recent retry churn evidence",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$timeout_failure_at",
      "failed_at": "$timeout_failure_at",
      "execution": {
        "state": "failed",
        "attempt": 2,
        "total_step_attempts": 527,
        "max_retries": 2,
        "result": "FAILURE",
        "updated_at": "$timeout_failure_at"
      }
    }
  ]
}
EOF

python3 - "$REPO_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
tasks = payload.get("tasks", [])
for idx in range(12):
    tasks.append({
        "id": f"task-approved-{idx + 1:03d}",
        "title": f"Approved backlog item {idx + 1}",
        "project": "codex-agent-system",
        "status": "approved",
        "updated_at": "2026-03-27T12:00:00Z",
        "approved_at": "2026-03-27T12:00:00Z",
        "execution": {
            "state": "approved",
            "attempt": 0,
            "max_retries": 2,
            "updated_at": "2026-03-27T12:00:00Z",
        },
    })
payload["tasks"] = tasks
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

cat >"$REPO_ROOT/codex-memory/tasks.log" <<EOF
{"timestamp":"$timeout_failure_at","project":"codex-agent-system","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","total_step_attempts":0,"task_id":"task-001-timeout-rate","attempts":1,"score":0,"run_id":"run-timeout-family"}
{"timestamp":"$timeout_failure_at","project":"codex-agent-system","task":"Recent retry churn evidence","result":"FAILURE","failure_kind":"step_failure","total_step_attempts":527,"task_id":"task-002-retry-churn","attempts":2,"score":0,"run_id":"run-retry-family"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "first_pass_success_rate": 0.85,
  "timeout_failure_rate": 0.17,
  "approved_tasks": 91,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 1043660,
  "task_registry_pressure_detected": true,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 63,
  "loop_effort_extra_step_attempts": 158,
  "external_signal_status": "fresh",
  "total_tasks": 476
}
EOF

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=3600 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_OVERLOAD_FAMILY_OUTCOME_LOOKBACK_SECONDS=604800 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected overload gate to keep exactly one self-improve task when ranking candidates by family outcomes" >&2
  exit 1
fi

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Drain approval backlog" ]; then
  echo "expected backlog starvation override to preserve approval drain work under overload" >&2
  exit 1
fi

artifact_file="$REPO_ROOT/codex-learning/self-improve-run.json"
overload_summary="$(
  jq -r '
    [
      .gating.overload.active,
      .gating.overload.preserved_title,
      .gating.overload.preserved_reason,
      .gating.overload.candidate_count,
      .gating.overload.blocked_candidate_count
    ] | @tsv
  ' "$artifact_file"
)"
if [ "$overload_summary" != $'true\tDrain approval backlog\tapproved_backlog_starvation\t4\t0' ]; then
  echo "unexpected overload artifact summary: $overload_summary" >&2
  exit 1
fi

retry_candidate_summary="$(
  jq -r '
    .gating.overload.candidates
    | map(select(.title == "Break retry churn"))
    | first
    | [
        .rank,
        .score,
        .signal_priority,
        .selected
      ] | @tsv
  ' "$artifact_file"
)"
if [ "$retry_candidate_summary" != $'2\t55\t15\tfalse' ]; then
  echo "unexpected retry churn candidate overload context: $retry_candidate_summary" >&2
  exit 1
fi

echo "self improve overload outcome ranking test passed"
