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
  "success_rate": 0.12,
  "recent_success_rate": 0.14,
  "timeout_failure_rate": 0.31,
  "first_pass_success_rate": 0.0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "retry_churn_detected": false,
  "external_signal_status": "fresh",
  "zero_step_timeout_rate": 0.92,
  "total_tasks": 10
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-25T08:30:00Z",
  "selected_improvement": "Reduce timeout rate",
  "selection": {
    "selected_title": "Reduce timeout rate",
    "state": "submitted",
    "submitted_titles": ["Reduce timeout rate"],
    "ranked_titles": ["Reduce timeout rate", "Improve first-pass success rate"],
    "next_title": "Improve first-pass success rate"
  },
  "counts": {
    "detected": 2,
    "generated": 2,
    "submitted": 1,
    "skipped": 1,
    "blocked_analysis": 0
  },
  "gating": {
    "dominant_reason": "submission_limit",
    "analysis_reason": "submission_limit",
    "submission_reason": "critical_low_success_rate"
  }
}
EOF

touch -t 202603250820 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 202603250820 "$TEST_ROOT/codex-memory/tasks.log"
touch -t 202603250825 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 202603250830 "$TEST_ROOT/codex-learning/self-improve-run.json"

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
  .data.self_improve_artifact.exists == true and
  .data.self_improve_artifact.status == "current" and
  .data.self_improve_artifact.stale == false and
  .data.self_improve_artifact.reason == "up_to_date" and
  .data.self_improve_artifact.generated_at == "2026-03-25T08:30:00Z" and
  .data.self_improve_artifact.selected_improvement == "Reduce timeout rate" and
  .data.self_improve_artifact.selection.selected_title == "Reduce timeout rate" and
  .data.self_improve_artifact.selection.state == "submitted" and
  .data.self_improve_artifact.selection.submitted_titles == ["Reduce timeout rate"] and
  .data.self_improve_artifact.selection.ranked_titles == ["Reduce timeout rate", "Improve first-pass success rate"] and
  .data.self_improve_artifact.selection.next_title == "Improve first-pass success rate" and
  .data.self_improve_artifact.counts.detected == 2 and
  .data.self_improve_artifact.counts.generated == 2 and
  .data.self_improve_artifact.counts.submitted == 1 and
  .data.self_improve_artifact.counts.skipped == 1 and
  .data.self_improve_artifact.counts.blocked_analysis == 0 and
  .data.self_improve_artifact.pause.active == false and
  .data.self_improve_artifact.pause.reason == "none" and
  .data.self_improve_artifact.gating.dominant_reason == "submission_limit" and
  .data.self_improve_artifact.gating.analysis_reason == "submission_limit" and
  .data.self_improve_artifact.gating.submission_reason == "critical_low_success_rate"
' "$OUTPUT_FILE" >/dev/null

echo "prepare automation context self-improve artifact details test passed"
