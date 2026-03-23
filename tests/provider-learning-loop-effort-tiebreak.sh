#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project-ui"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$MOCK_BIN" "$PROJECT_DIR"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues" "$TEST_ROOT/codex-dashboard"

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-23T18:00:00Z","project":"codex-agent-system","task":"Refine dashboard board spacing on mobile","provider":"claude","result":"SUCCESS","attempts":1,"total_step_attempts":1,"score":8,"branch":"","pr_url":"","run_id":"claude-run-1","duration_seconds":12}
{"timestamp":"2026-03-23T18:01:00Z","project":"codex-agent-system","task":"Adjust dashboard card layout for iPhone","provider":"claude","result":"SUCCESS","attempts":1,"total_step_attempts":1,"score":8,"branch":"","pr_url":"","run_id":"claude-run-2","duration_seconds":12}
{"timestamp":"2026-03-23T18:02:00Z","project":"codex-agent-system","task":"Improve mobile dashboard navigation","provider":"claude","result":"SUCCESS","attempts":1,"total_step_attempts":1,"score":8,"branch":"","pr_url":"","run_id":"claude-run-3","duration_seconds":12}
{"timestamp":"2026-03-23T18:03:00Z","project":"codex-agent-system","task":"Refine dashboard board spacing on mobile","provider":"codex","result":"SUCCESS","attempts":1,"total_step_attempts":3,"score":8,"branch":"","pr_url":"","run_id":"codex-run-1","duration_seconds":18}
{"timestamp":"2026-03-23T18:04:00Z","project":"codex-agent-system","task":"Adjust dashboard card layout for iPhone","provider":"codex","result":"SUCCESS","attempts":1,"total_step_attempts":3,"score":8,"branch":"","pr_url":"","run_id":"codex-run-2","duration_seconds":18}
{"timestamp":"2026-03-23T18:05:00Z","project":"codex-agent-system","task":"Improve mobile dashboard navigation","provider":"codex","result":"SUCCESS","attempts":1,"total_step_attempts":4,"score":8,"branch":"","pr_url":"","run_id":"codex-run-3","duration_seconds":20}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-learned-loop-effort-provider",
      "title": "Tighten dashboard card spacing for mobile board review",
      "project": "project-ui",
      "status": "approved",
      "updated_at": "2026-03-23T18:10:00Z",
      "created_at": "2026-03-23T18:09:00Z",
      "task_intent": {
        "objective": "Tighten dashboard card spacing for mobile board review",
        "context_hint": "Improve iPhone dashboard scanning.",
        "constraints": ["Keep the UI stable."]
      }
    }
  ]
}
EOF

cat >"$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >>"$TMP_DIR/claude.invoked"
printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"status":"success","message":"claude lower loop effort","data":{}}}\n'
EOF

cat >"$MOCK_BIN/codex" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >>"$TMP_DIR/codex.invoked"
output_file=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      output_file="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "\$output_file" ] || exit 2
cat >"\$output_file" <<'JSON'
{"status":"success","message":"codex fallback","data":{}}
JSON
EOF

chmod +x "$MOCK_BIN/claude" "$MOCK_BIN/codex"

export PATH="$MOCK_BIN:$PATH"
export TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json"
export TASK_LOG="$TEST_ROOT/codex-memory/tasks.log"

source "$TEST_ROOT/scripts/lib.sh"

compute_provider_stats
[ -f "$TEST_ROOT/codex-learning/provider-stats.json" ]
jq -e '
  .claude.ui.task_count == 3 and
  .claude.ui.success_rate == 1 and
  .claude.ui.avg_total_step_attempts == 1 and
  .codex.ui.task_count == 3 and
  .codex.ui.success_rate == 1 and
  .codex.ui.avg_total_step_attempts == 3.33 and
  .codex.ui.avg_extra_step_attempts == 2.33
' "$TEST_ROOT/codex-learning/provider-stats.json" >/dev/null

provider_info="$(resolve_task_provider_info "project-ui" "Tighten dashboard card spacing for mobile board review")"
[ "$(printf '%s\n' "$provider_info" | sed -n '1p')" = "claude" ]
printf '%s\n' "$provider_info" | sed -n '2p' | grep -q 'avg total step attempts'

OUTPUT_FILE="$TMP_DIR/output.json"
run_agent_exec planner "$PROJECT_DIR" "Tighten dashboard card spacing for mobile board review" "Return deterministic JSON." "$OUTPUT_FILE"
[ "$(current_exec_provider)" = "claude" ]
jq -e '.message == "claude lower loop effort"' "$OUTPUT_FILE" >/dev/null
[ -f "$TMP_DIR/claude.invoked" ]
[ ! -f "$TMP_DIR/codex.invoked" ]

echo "provider learning loop effort tie-break test passed"
