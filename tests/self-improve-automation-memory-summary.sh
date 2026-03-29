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
  "success_rate": 0.80,
  "first_pass_success_rate": 0.80,
  "timeout_failure_rate": 0.11,
  "latest_external_signal_source": "OpenAI Python releases",
  "total_tasks": 10
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

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

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

EXTERNAL_MEMORY_FILE="$TMP_DIR/home/.codex/automations/push2main-codex-agent-system/memory.md"
MIRROR_MEMORY_FILE="$REPO_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"

[ -f "$EXTERNAL_MEMORY_FILE" ]
[ -f "$MIRROR_MEMORY_FILE" ]

grep -E -q '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T.* \| weakness=Reduce timeout rate \| improvement=Reduce timeout rate \| outcome=success submitted=2/2 detected=2 duration_s=[0-9]+ \| next=Improve first-pass success rate \| external_sync_pending=false$' "$EXTERNAL_MEMORY_FILE"
grep -E -q '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T.* \| weakness=Reduce timeout rate \| improvement=Reduce timeout rate \| outcome=success submitted=2/2 detected=2 duration_s=[0-9]+ \| next=Improve first-pass success rate \| external_sync_pending=false$' "$MIRROR_MEMORY_FILE"

echo "self improve automation memory summary test passed"
