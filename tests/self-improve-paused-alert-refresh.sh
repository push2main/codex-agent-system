#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

source "$ROOT_DIR/tests/lib/self-improve-fixture.sh"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/projects/codex-agent-system" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
touch "$TEST_ROOT/codex-learning/retry-failure-analysis.jsonl"
touch "$TEST_ROOT/codex-logs/self-improve-paused"
touch -t 202603281029 "$TEST_ROOT/codex-logs/self-improve-paused"

write_self_improve_metrics_fixture "$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.13,
  "recent_success_rate": 0.0,
  "timeout_failure_rate": 0.35,
  "first_pass_success_rate": 0.0,
  "zero_step_timeout_rate": 0.91,
  "retry_churn_detected": false,
  "total_tasks": 1
}
EOF

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

OUTPUT_FILE="$TMP_DIR/self-improve-output.json"
(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" bash scripts/self-improve.sh codex-agent-system >"$OUTPUT_FILE"
)

python3 - "$TEST_ROOT/codex-learning/self-improve-run.json" "$TEST_ROOT/codex-learning/alerts.json" "$OUTPUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

run_path = Path(sys.argv[1])
alerts_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

run_payload = json.loads(run_path.read_text(encoding="utf-8"))
alerts_payload = json.loads(alerts_path.read_text(encoding="utf-8"))
output_payload = json.loads(output_path.read_text(encoding="utf-8"))

assert output_payload["status"] == "skipped", output_payload
assert output_payload["reason"] == "paused_by_file", output_payload

pause = run_payload["pause"]
assert pause["active"] is True, run_payload
assert pause["escalation"]["active"] is True, run_payload
assert pause["escalation"]["title"] == "Long-lived self-improve pause", run_payload

alerts = alerts_payload["alerts"]
assert alerts_payload["active"] is True, alerts_payload
assert alerts_payload["alert_count"] == 1, alerts_payload
assert alerts[0]["code"] == "self_improve_pause_escalated", alerts_payload
assert alerts[0]["metric"] == "self_improve_pause_escalated", alerts_payload
assert alerts[0]["details"]["pause_age_seconds"] >= 21600, alerts_payload
assert alerts[0]["details"]["pause_reason"] == "paused_by_file", alerts_payload
assert alerts[0]["details"]["pause_file"].endswith("/codex-logs/self-improve-paused"), alerts_payload
assert alerts[0]["details"]["remediation_kind"] == "remove_pause_file", alerts_payload
assert alerts[0]["details"]["remediation_title"] == "Remove self-improve pause gate", alerts_payload
assert alerts[0]["details"]["remediation_summary"].startswith("Delete "), alerts_payload
assert alerts[0]["details"]["remediation_command"].startswith("rm -f "), alerts_payload
PY

echo "self-improve paused alert refresh test passed"
