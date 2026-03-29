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
touch "$TEST_ROOT/codex-learning/retry-failure-analysis.jsonl"

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 1.0,
  "recent_success_rate": 1.0,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 1.0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "retry_churn_detected": false,
  "external_signal_status": "fresh",
  "zero_step_timeout_rate": 0.0,
  "total_tasks": 1
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
touch -t 202603250900 "$TEST_ROOT/codex-learning/metrics.json"

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

cat >"$TEST_ROOT/scripts/self-improve.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
chmod +x "$TEST_ROOT/scripts/self-improve.sh"

OUTPUT_FILE="$TMP_DIR/context.json"
(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" AUTOMATION_CONTEXT_AUTO_REFRESH_SELF_IMPROVE=1 bash scripts/prepare-automation-context.sh \
    codex-agent-system \
    2 >"$OUTPUT_FILE"
)

jq -e '
  .status == "success" and
  .data.self_improve_artifact_refresh.enabled == true and
  .data.self_improve_artifact_refresh.performed == true and
  .data.self_improve_artifact_refresh.status == "refresh_failed" and
  .data.self_improve_artifact_refresh.reason == "metrics_newer" and
  .data.self_improve_artifact.exists == true and
  .data.self_improve_artifact.status == "stale" and
  .data.self_improve_artifact.stale == true and
  .data.self_improve_artifact.reason == "metrics_newer"
' "$OUTPUT_FILE" >/dev/null

echo "prepare automation context self-improve artifact refresh failure test passed"
