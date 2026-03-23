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

FEED_FILE="$TMP_DIR/feed.atom"
SOURCES_FILE="$TMP_DIR/external-signal-sources.json"
SIGNALS_FILE="$TMP_DIR/external-signals.json"
METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json"

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

cat >"$FEED_FILE" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>External updates</title>
  <updated>2026-03-23T11:00:00Z</updated>
  <entry>
    <id>tag:example.com,2026:release-2</id>
    <title>Release 2.0.0 improves browser trace determinism</title>
    <updated>2026-03-23T10:40:00Z</updated>
    <summary>New deterministic browser trace export.</summary>
    <link href="https://example.com/releases/2.0.0" rel="alternate" />
  </entry>
</feed>
EOF

cat >"$SOURCES_FILE" <<EOF
{
  "auto_refresh": true,
  "refresh_cooldown_seconds": 0,
  "freshness_window_seconds": 86400,
  "request_timeout_seconds": 1,
  "sources": [
    {
      "id": "example-browser-updates",
      "label": "Example browser updates",
      "kind": "atom",
      "path": "$FEED_FILE",
      "topic": "browser_automation",
      "category": "stability",
      "task_hint": "Check whether the update changes dashboard verification or browser automation stability.",
      "max_items": 1
    }
  ]
}
EOF

run_case() {
  local case_name="$1"
  local expected_confidence="$2"
  local expected_score="$3"

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

  : >"$TEST_ROOT/codex-memory/tasks.log"

  case "$case_name" in
    stale)
      cat >"$METRICS_FILE" <<'EOF'
{
  "external_signal_status": "stale",
  "fresh_external_signal_count": 0,
  "external_signal_error_count": 0
}
EOF
      ;;
    error)
      cat >"$METRICS_FILE" <<'EOF'
{
  "external_signal_status": "error",
  "fresh_external_signal_count": 0,
  "external_signal_error_count": 2
}
EOF
      ;;
    *)
      echo "unknown case: $case_name" >&2
      return 1
      ;;
  esac

  (
    cd "$TEST_ROOT"
    RESEARCH_DOCKER_DISABLE=1 \
    EXTERNAL_SIGNAL_SOURCES_FILE="$SOURCES_FILE" \
    EXTERNAL_SIGNALS_FILE="$SIGNALS_FILE" \
    bash agents/strategy.sh codex-agent-system "$TMP_DIR/$case_name-strategy.json" >/dev/null
  )

  python3 - "$TEST_ROOT" "$TMP_DIR/$case_name-strategy.json" "$expected_confidence" "$expected_score" "$case_name" <<'PY'
import json
import math
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]
expected_confidence = float(sys.argv[3])
expected_score = float(sys.argv[4])
expected_status = sys.argv[5]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert output["status"] == "success"
created = next(task for task in registry["tasks"] if task["id"] != "task-existing-buffer")
assert math.isclose(created["confidence"], expected_confidence, rel_tol=0, abs_tol=1e-9), created["confidence"]
assert math.isclose(created["score"], expected_score, rel_tol=0, abs_tol=1e-9), created["score"]
assert created["external_signal_learning"]["status"] == expected_status
assert math.isclose(created["external_signal_learning"]["applied_confidence"], expected_confidence, rel_tol=0, abs_tol=1e-9)
PY
}

run_case stale 0.64 3.46
run_case error 0.58 3.13

echo "strategy external signal learning test passed"
