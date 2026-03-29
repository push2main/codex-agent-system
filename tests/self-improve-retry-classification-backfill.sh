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
  "tasks": [
    {
      "id": "task-success-a",
      "title": "Successful task A",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2026-03-25T04:00:00Z",
      "execution": {
        "result": "SUCCESS",
        "attempt": 1
      }
    },
    {
      "id": "task-success-b",
      "title": "Successful task B",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2026-03-25T04:00:01Z",
      "execution": {
        "result": "SUCCESS",
        "attempt": 1
      }
    },
    {
      "id": "task-success-c",
      "title": "Successful task C",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2026-03-25T04:00:02Z",
      "execution": {
        "result": "SUCCESS",
        "attempt": 2
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T03:00:00Z","project":"codex-agent-system","task":"Failure 01","result":"FAILURE"}
{"timestamp":"2026-03-25T03:01:00Z","project":"codex-agent-system","task":"Failure 02","result":"FAILURE"}
{"timestamp":"2026-03-25T03:02:00Z","project":"codex-agent-system","task":"Failure 03","result":"FAILURE"}
{"timestamp":"2026-03-25T03:03:00Z","project":"codex-agent-system","task":"Failure 04","result":"FAILURE"}
{"timestamp":"2026-03-25T03:04:00Z","project":"codex-agent-system","task":"Failure 05","result":"FAILURE"}
{"timestamp":"2026-03-25T03:05:00Z","project":"codex-agent-system","task":"Failure 06","result":"FAILURE"}
{"timestamp":"2026-03-25T03:06:00Z","project":"codex-agent-system","task":"Failure 07","result":"FAILURE"}
{"timestamp":"2026-03-25T03:07:00Z","project":"codex-agent-system","task":"Failure 08","result":"FAILURE"}
{"timestamp":"2026-03-25T03:08:00Z","project":"codex-agent-system","task":"Failure 09","result":"FAILURE"}
{"timestamp":"2026-03-25T03:09:00Z","project":"codex-agent-system","task":"Failure 10","result":"FAILURE"}
{"timestamp":"2026-03-25T03:10:00Z","project":"codex-agent-system","task":"Failure 11","result":"FAILURE"}
{"timestamp":"2026-03-25T03:11:00Z","project":"codex-agent-system","task":"Failure 12","result":"FAILURE"}
{"timestamp":"2026-03-25T03:12:00Z","project":"codex-agent-system","task":"Success 01","result":"SUCCESS"}
{"timestamp":"2026-03-25T03:13:00Z","project":"codex-agent-system","task":"Success 02","result":"SUCCESS"}
EOF

cat >"$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl" <<'EOF'
{"task_id":"retry-01","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:20:00Z","error_text":"Execution timed out after 420 seconds while running verification."}
{"task_id":"retry-02","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:21:00Z","error_text":"Execution timed out after 420 seconds while running verification."}
{"task_id":"retry-03","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:22:00Z","error_text":"Fallback reviewer cannot validate this generic task deterministically."}
{"task_id":"retry-04","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:23:00Z","error_text":"Fallback reviewer cannot validate this generic task deterministically."}
{"task_id":"retry-05","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:24:00Z","error_text":"Execution timed out after 420 seconds while running verification."}
{"task_id":"retry-06","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:25:00Z","error_text":"Fallback reviewer cannot validate this generic task deterministically."}
{"task_id":"retry-07","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:26:00Z","error_text":"Execution timed out after 420 seconds while running verification."}
{"task_id":"retry-08","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:27:00Z","error_text":"Fallback reviewer cannot validate this generic task deterministically."}
{"task_id":"retry-09","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:28:00Z","error_text":"Execution timed out after 420 seconds while running verification."}
{"task_id":"retry-10","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:29:00Z","error_text":"Fallback reviewer cannot validate this generic task deterministically."}
{"task_id":"retry-11","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:30:00Z"}
{"task_id":"retry-12","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:31:00Z"}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{}
EOF

(
  cd "$REPO_ROOT"
  python3 scripts/sync-task-artifacts.py \
    "$REPO_ROOT/codex-memory/tasks.json" \
    "$REPO_ROOT/codex-memory/tasks.log" \
    "$REPO_ROOT/codex-learning/metrics.json" \
    "$REPO_ROOT/codex-learning/external-signals.json" >/dev/null
)

metrics_summary="$(
  jq -r '
    [
      .success_rate,
      .first_pass_success_rate,
      .retry_classification_coverage,
      .retry_classified_count,
      .retry_total_count,
      .retry_reclassified_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'0.14\t0.67\t0.83\t10\t12\t10' ]; then
  echo "unexpected retry classification backfill metrics: $metrics_summary" >&2
  exit 1
fi

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Improve retry success rate" ]; then
  echo "expected self-improve to move past retry classification coverage after backfill" >&2
  exit 1
fi

echo "self improve retry classification backfill test passed"
