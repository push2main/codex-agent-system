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
      "id": "task-001-completed",
      "title": "Completed task",
      "project": "codex-agent-system",
      "status": "completed",
      "score": 8,
      "updated_at": "2099-01-01T07:00:00Z",
      "execution": {
        "state": "completed",
        "result": "SUCCESS",
        "attempt": 1,
        "updated_at": "2099-01-01T07:00:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2099-01-01T07:00:00Z","project":"codex-agent-system","task":"Completed task","task_id":"task-001-completed","result":"SUCCESS","attempts":1,"score":8}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "updated_at": "",
  "success_rate": 0.12,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.22,
  "approved_tasks": null,
  "pending_approval_tasks": null,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 100,
  "task_registry_total": null
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2099-01-01T07:00:00Z",
  "signals": [
    {
      "source_id": "fixture",
      "title": "Fresh fixture signal",
      "url": "https://example.com/fresh",
      "published_at": "2099-01-01T06:50:00Z",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

self_improve_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${self_improve_count:-0}" -ne 0 ]; then
  echo "expected refreshed persisted metrics to suppress stale timeout-driven self-improve tasks" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .metrics_snapshot.success_rate,
      .metrics_snapshot.timeout_rate,
      .gating.analysis_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0\t1.0\t0.0\tno_detected_weakness' ]; then
  echo "unexpected self-improve artifact after metrics refresh: $artifact_summary" >&2
  exit 1
fi

metrics_summary="$(
  jq -r '
    [
      .success_rate,
      .timeout_failure_rate,
      .approved_tasks,
      .task_registry_total
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'1.0\t0.0\t0\t1' ]; then
  echo "expected persisted metrics refresh to overwrite stale values: $metrics_summary" >&2
  exit 1
fi

metrics_input_summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason,
      (.metrics_input.missing_keys | join(","))
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$metrics_input_summary" != $'refreshed\ttrue\tmissing_required_keys\t' ]; then
  echo "unexpected refreshed metrics input summary: $metrics_input_summary" >&2
  exit 1
fi

echo "self improve metrics refresh test passed"
