#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 1.0,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 1.0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "zero_step_timeout_rate": 0.0
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-25T08:30:00Z",
  "counts": {
    "detected": 1,
    "generated": 1,
    "submitted": 1,
    "skipped": 0,
    "blocked_analysis": 0
  }
}
EOF

touch -t 202603250830 "$TEST_ROOT/codex-learning/self-improve-run.json"
touch -t 202603251000 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 202603250900 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 202603250900 "$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$TEST_ROOT",
  "repo_url": "https://github.com/push2main/codex-agent-system/",
  "automation_id": "push2main-codex-agent-system",
  "memory_file": "$TEST_ROOT/projects/codex-agent-system/memory.md",
  "spec_file": "$TEST_ROOT/projects/codex-agent-system/spec.md",
  "policy_file": "$TEST_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$TEST_ROOT/codex-memory/tasks.json"
}
EOF

OUTPUT_FILE="$TMP_DIR/context.json"
(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" bash scripts/prepare-automation-context.sh \
    codex-agent-system \
    2 >"$OUTPUT_FILE"
)

jq -e '
  .status == "success" and
  (.data.files.self_improve_run_file | type == "string" and endswith("/codex-learning/self-improve-run.json"))
' "$OUTPUT_FILE" >/dev/null

jq -e '
  .data.self_improve_artifact.exists == true and
  .data.self_improve_artifact.status == "stale" and
  .data.self_improve_artifact.stale == true and
  .data.self_improve_artifact.reason == "metrics_newer" and
  .data.self_improve_artifact.compared_source == "metrics.json" and
  .data.self_improve_artifact.remediation.active == true and
  .data.self_improve_artifact.remediation.kind == "rerun_self_improve" and
  .data.self_improve_artifact.remediation.title == "Refresh self-improve artifact" and
  .data.self_improve_artifact.remediation.command == "bash scripts/self-improve.sh codex-agent-system" and
  .data.self_improve_artifact.remediation.summary == "Run bash scripts/self-improve.sh codex-agent-system to regenerate ranking details from current metrics."
' "$OUTPUT_FILE" >/dev/null

echo "prepare automation context self-improve artifact staleness test passed"
