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
OUTPUT_FILE="$TMP_DIR/strategy-output.json"

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

: >"$TEST_ROOT/codex-memory/tasks.log"

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

(
  cd "$TEST_ROOT"
  RESEARCH_DOCKER_DISABLE=1 \
  EXTERNAL_SIGNAL_SOURCES_FILE="$SOURCES_FILE" \
  EXTERNAL_SIGNALS_FILE="$SIGNALS_FILE" \
  bash agents/strategy.sh codex-agent-system "$OUTPUT_FILE" >/dev/null
)

python3 - "$TEST_ROOT/codex-learning/metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["external_signal_status"] == "fresh"
assert metrics["external_signal_count"] == 1
assert metrics["fresh_external_signal_count"] == 1
assert metrics["external_signal_error_count"] == 0
assert metrics["latest_external_signal_source"] == "Example browser updates"
assert metrics["latest_external_signal_title"] == "Release 2.0.0 improves browser trace determinism"
assert metrics["latest_external_signal_url"] == "https://example.com/releases/2.0.0"
assert metrics["latest_external_signal_published_at"] == "2026-03-23T10:40:00Z"
PY

echo "strategy external signal metrics refresh test passed"
