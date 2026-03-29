#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
source "$ROOT_DIR/tests/lib/self-improve-fixture.sh"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects/codex-agent-system/automation-memory"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$REPO_ROOT",
  "task_registry_file": "$REPO_ROOT/codex-memory/tasks.json",
  "automation_id": "push2main-codex-agent-system"
}
EOF

cat >"$REPO_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-25T08:05:00Z | weakness=Improve retry success rate | improvement=Improve retry success rate | outcome=failure submitted=1/1 detected=1 duration_s=1 | next=none | external_sync_pending=false
- 2026-03-25T07:50:00Z | weakness=Reduce timeout rate | improvement=Reduce timeout rate | outcome=success submitted=1/2 detected=2 duration_s=1 | next=Improve retry success rate | external_sync_pending=false
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"project":"codex-agent-system","result":"SUCCESS","attempt":1}
{"project":"codex-agent-system","result":"SUCCESS","attempt":2}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
{"project":"codex-agent-system","result":"FAILURE","failure_kind":"timeout","total_step_attempts":1}
EOF

write_self_improve_metrics_fixture "$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.11,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "latest_external_signal_source": "OpenAI Python releases",
  "total_tasks": 100
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-29T17:00:00Z",
  "signals": [
    {
      "source": "OpenAI Python releases",
      "title": "v2.30.0",
      "url": "https://github.com/openai/openai-python/releases/tag/v2.30.0",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

submitted_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | .[0].title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"

if [ "$submitted_title" != "Reduce timeout rate" ]; then
  echo "expected recent failure to suppress stale automation-memory next hint, got: $submitted_title" >&2
  exit 1
fi

echo "self improve automation memory recent failure supersedes next test passed"
