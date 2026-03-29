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

timestamps="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
print((now - timedelta(hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ"))
print((now - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

SUCCESS_AT="$(printf '%s\n' "$timestamps" | sed -n '1p')"
RUNNING_AT="$(printf '%s\n' "$timestamps" | sed -n '2p')"

python3 - "$REPO_ROOT/codex-memory/tasks.json" "$SUCCESS_AT" "$RUNNING_AT" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-last-success",
            "title": "Last successful completion",
            "project": "codex-agent-system",
            "status": "completed",
            "created_at": sys.argv[2],
            "updated_at": sys.argv[2],
            "completed_at": sys.argv[2],
            "execution": {
                "state": "completed",
                "attempt": 1,
                "max_retries": 2,
                "result": "SUCCESS",
                "updated_at": sys.argv[2],
            },
        },
        {
            "id": "task-active-running",
            "title": "Recent running task should suppress stale recovery",
            "project": "codex-agent-system",
            "status": "running",
            "created_at": sys.argv[3],
            "updated_at": sys.argv[3],
            "execution": {
                "state": "running",
                "attempt": 1,
                "max_retries": 2,
                "result": "RUNNING",
                "updated_at": sys.argv[3],
            },
        },
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$REPO_ROOT/codex-memory/tasks.log" <<EOF
{"timestamp":"$SUCCESS_AT","project":"codex-agent-system","task":"Last successful completion","task_id":"task-last-success","result":"SUCCESS","attempts":1,"score":8}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.61,
  "recent_success_rate": 0.58,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.01,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.91,
  "retry_classified_count": 10,
  "retry_total_count": 11,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T10:15:00Z",
  "total_tasks": 48
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [
      .tasks[]
      | select((.task_intent.source // "") == "self-improve" and (.title // "") == "Recover stale pipeline")
    ] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_count" != "0" ]; then
  echo "expected running activity to suppress stale recovery task generation" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .metrics_snapshot.pipeline_stale,
      .metrics_snapshot.pipeline_stale_since
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0\tfalse\t' ]; then
  echo "unexpected self-improve active-running artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve active-running stale suppression test passed"
