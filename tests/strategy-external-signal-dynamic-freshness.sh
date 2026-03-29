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
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-existing-buffer",
      "title": "Keep one internal task ready",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 3,
      "effort": 1,
      "confidence": 0.82,
      "score": 2.46,
      "status": "pending_approval",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-23T11:52:18Z",
  "signals": [
    {
      "source_id": "openai-python-releases",
      "source_label": "OpenAI Python releases",
      "topic": "provider_capabilities",
      "category": "code_quality",
      "title": "v2.29.0",
      "url": "https://github.com/openai/openai-python/releases/tag/v2.29.0",
      "published_at": "2026-03-17T17:53:05Z",
      "fresh": true,
      "source_task_id": "external-signal::openai-python-releases::signal-1"
    }
  ],
  "errors": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  EXTERNAL_SIGNALS_FILE="$TEST_ROOT/codex-learning/external-signals.json" \
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-external-dynamic.json" >/dev/null
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/codex-learning/metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    registry = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert len(registry["tasks"]) == 1, registry["tasks"]
assert not any(task.get("strategy_template") == "external_signal_review" for task in registry["tasks"])
assert metrics["external_signal_status"] == "stale", metrics
assert metrics["fresh_external_signal_count"] == 0, metrics
PY

echo "strategy external signal dynamic freshness test passed"
