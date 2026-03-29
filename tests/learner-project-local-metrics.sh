#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
CAPTURED_PROMPT_FILE="$TMP_DIR/learner-prompt.txt"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/agents" \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects/codex-agent-system" \
  "$TMP_DIR/bin"
cp "$ROOT_DIR/agents/learner.sh" "$REPO_ROOT/agents/learner.sh"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$TMP_DIR/bin/codex" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
output_file=""
last_arg=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      output_file="\$2"
      shift 2
      ;;
    *)
      last_arg="\$1"
      shift
      ;;
  esac
done
printf '%s\n' "\$last_arg" >"$CAPTURED_PROMPT_FILE"
printf '%s\n' '- Prefer project-local evidence before shared metrics.' >"\$output_file"
EOF
chmod +x "$TMP_DIR/bin/codex"

cat >"$REPO_ROOT/projects/codex-agent-system/memory.md" <<'EOF'
# Project Memory

- Keep learner analysis scoped to the approved metrics task.
- Prefer project-local metrics evidence before shared-global heuristics.
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current-learner-locality",
      "title": "keep learner project metrics local",
      "project": "codex-agent-system",
      "status": "approved",
      "task_intent": {
        "objective": "keep learner project metrics local",
        "context_hint": "Analyze only the learner metrics locality path without broadening into unrelated retry heuristics.",
        "constraints": [
          "Keep the change scoped to learner metrics selection.",
          "Do not broaden into cross-project strategy generation."
        ],
        "success_signals": [
          "Rules prefer project-local metrics evidence."
        ],
        "affected_files": [
          "agents/learner.sh",
          "scripts/task_metrics.py"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/learner-project-local-metrics.sh"
      }
    },
    {
      "id": "local-success-1",
      "title": "Local success one",
      "project": "codex-agent-system",
      "status": "completed",
      "execution": {
        "result": "SUCCESS",
        "attempt": 1
      }
    },
    {
      "id": "local-success-2",
      "title": "Local success two",
      "project": "codex-agent-system",
      "status": "completed",
      "execution": {
        "result": "SUCCESS",
        "attempt": 1
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T10:10:00Z","project":"codex-agent-system","task":"Local success one","result":"SUCCESS","failure_kind":"","task_id":"local-success-1","attempts":1,"score":7,"run_id":"run-local-1"}
{"timestamp":"2026-03-24T11:15:00Z","project":"codex-agent-system","task":"Local success two","result":"SUCCESS","failure_kind":"","task_id":"local-success-2","attempts":1,"score":6,"run_id":"run-local-2"}
{"timestamp":"2026-03-24T12:00:00Z","project":"superheld","task":"Remote timeout one","result":"FAILURE","failure_kind":"timeout","task_id":"remote-001","attempts":1,"score":0,"run_id":"run-remote-1"}
{"timestamp":"2026-03-24T12:10:00Z","project":"superheld","task":"Remote timeout two","result":"FAILURE","failure_kind":"timeout","task_id":"remote-002","attempts":2,"score":0,"run_id":"run-remote-2"}
{"timestamp":"2026-03-24T12:20:00Z","project":"superheld","task":"Remote retry churn","result":"FAILURE","failure_kind":"step_failure","task_id":"remote-003","attempts":2,"score":0,"run_id":"run-remote-3"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.2,
  "timeout_failure_rate": 0.4,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "learning_rules_count": 4,
  "total_tasks": 20
}
EOF

cat >"$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl" <<'EOF'
{"task_id":"remote-001","project":"superheld","attempt":2,"failed_step_index":1,"classification":"timeout","timestamp":"2026-03-24T12:01:00Z"}
{"task_id":"remote-002","project":"superheld","attempt":2,"failed_step_index":1,"classification":"timeout","timestamp":"2026-03-24T12:11:00Z"}
EOF

mkdir -p "$REPO_ROOT/codex-logs/runs/test-run"

(
  cd "$REPO_ROOT"
  PATH="$TMP_DIR/bin:$PATH" \
  TASK_ID="task-current-learner-locality" \
  TASK_REGISTRY_FILE="$REPO_ROOT/codex-memory/tasks.json" \
  bash agents/learner.sh \
    "$REPO_ROOT/projects/codex-agent-system" \
    "keep learner project metrics local" \
    "SUCCESS" \
    "$REPO_ROOT/codex-logs/runs/test-run" \
    "$REPO_ROOT/codex-learning/prompt-rules.md" \
    "$REPO_ROOT/codex-logs/runs/test-run/learner.json" >/dev/null
)

grep -q 'Metrics scope: project_local for codex-agent-system.' "$CAPTURED_PROMPT_FILE"
grep -q 'All-time success rate: 1' "$CAPTURED_PROMPT_FILE"
grep -q 'Recent (last 50): 1' "$CAPTURED_PROMPT_FILE"
grep -q 'Timeout failure rate: 0' "$CAPTURED_PROMPT_FILE"
grep -q 'Retry classification coverage: n/a (0/0).' "$CAPTURED_PROMPT_FILE"
grep -q 'PROJECT MEMORY:' "$CAPTURED_PROMPT_FILE"
grep -q 'Keep learner analysis scoped to the approved metrics task.' "$CAPTURED_PROMPT_FILE"
grep -q 'CURRENT TASK SHAPE:' "$CAPTURED_PROMPT_FILE"
grep -q -- '- Objective: keep learner project metrics local' "$CAPTURED_PROMPT_FILE"
grep -q -- '- Focus: Analyze only the learner metrics locality path without broadening into unrelated retry heuristics.' "$CAPTURED_PROMPT_FILE"
grep -q -- '- Affected files: `agents/learner.sh`, `scripts/task_metrics.py`' "$CAPTURED_PROMPT_FILE"
grep -q -- '- Verification command: `bash tests/learner-project-local-metrics.sh`' "$CAPTURED_PROMPT_FILE"

echo "learner project-local metrics test passed"
