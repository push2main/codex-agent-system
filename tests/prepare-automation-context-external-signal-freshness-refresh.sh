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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

write_self_improve_metrics_fixture "$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-20T12:00:00Z",
  "signals": [
    {
      "source_id": "fixture",
      "source_label": "Fixture releases",
      "title": "Old signal",
      "url": "https://example.com/releases/old",
      "published_at": "2026-03-20T12:00:00Z",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

touch -t 202603201200 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 202603201200 "$TEST_ROOT/codex-learning/external-signals.json"
touch -t 202603201200 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 202603201200 "$TEST_ROOT/codex-memory/tasks.log"

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
  HOME="$TMP_DIR/home" CODEX_EXTERNAL_SIGNAL_NOW="2026-03-28T12:00:00Z" bash scripts/prepare-automation-context.sh \
    codex-agent-system \
    2 >"$OUTPUT_FILE"
)

jq -e '
  .status == "success" and
  .data.metrics_input.status == "refreshed" and
  .data.metrics_input.reason == "stale_against_external_signal_freshness" and
  .data.metrics_input.refresh_performed == true and
  .data.metrics_input.missing_keys == []
' "$OUTPUT_FILE" >/dev/null

metrics_summary="$(
  jq -r '
    [
      .external_signal_status,
      .fresh_external_signal_count
    ] | @tsv
  ' "$TEST_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'stale\t0' ]; then
  echo "expected prepare-automation-context to refresh external-signal freshness drift: $metrics_summary" >&2
  exit 1
fi

echo "prepare automation context external signal freshness refresh test passed"
