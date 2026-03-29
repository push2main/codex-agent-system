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

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T03:20:30Z","project":"codex-agent-system","task":"Timeout task","result":"FAILURE","failure_kind":"timeout","task_id":"retry-01"}
{"timestamp":"2026-03-25T03:21:30Z","project":"codex-agent-system","task":"Timeout task","result":"FAILURE","failure_kind":"timeout","task_id":"retry-02"}
{"timestamp":"2026-03-25T03:22:30Z","project":"codex-agent-system","task":"Planning task","result":"FAILURE","failure_kind":"planning_failure","task_id":"retry-03"}
EOF

cat >"$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl" <<'EOF'
{"task_id":"retry-01","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:20:00Z"}
{"task_id":"retry-02","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:21:00Z"}
{"task_id":"retry-03","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:22:00Z"}
{"task_id":"retry-04","project":"codex-agent-system","attempt":2,"failed_step_index":1,"classification":"unknown","timestamp":"2026-03-25T03:23:00Z"}
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
      .retry_classification_coverage,
      .retry_classified_count,
      .retry_total_count,
      .retry_reclassified_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'0.75\t3\t4\t3' ]; then
  echo "unexpected retry classification fallback metrics: $metrics_summary" >&2
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
if [ "$task_title" = "Improve retry failure classification coverage" ]; then
  echo "expected fallback classifications to move self-improve beyond retry-classification coverage" >&2
  exit 1
fi

echo "self improve retry classification task-log fallback test passed"
