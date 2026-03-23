#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

FEED_FILE="$TMP_DIR/feed.atom"
SOURCES_FILE="$TMP_DIR/external-signal-sources.json"
OUTPUT_FILE="$TMP_DIR/external-signals.json"

cat >"$FEED_FILE" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Example Releases</title>
  <updated>2026-03-23T11:00:00Z</updated>
  <entry>
    <id>tag:example.com,2026:release-1</id>
    <title>Release 1.2.3 adds deterministic audit hooks</title>
    <updated>2026-03-23T10:30:00Z</updated>
    <summary>Structured release notes for automation.</summary>
    <link href="https://example.com/releases/1.2.3" rel="alternate" />
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
      "id": "example-releases",
      "label": "Example releases",
      "kind": "atom",
      "path": "$FEED_FILE",
      "topic": "determinism",
      "category": "stability",
      "task_hint": "Check whether the release affects deterministic execution.",
      "max_items": 1
    }
  ]
}
EOF

python3 "$ROOT_DIR/scripts/external_signals.py" "$SOURCES_FILE" "$OUTPUT_FILE" >/dev/null

python3 - "$OUTPUT_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

assert payload["source_count"] == 1
assert payload["signal_count"] == 1
signal = payload["signals"][0]
assert signal["source_id"] == "example-releases"
assert signal["source_task_id"].startswith("external-signal::example-releases::")
assert signal["title"] == "Release 1.2.3 adds deterministic audit hooks"
assert signal["url"] == "https://example.com/releases/1.2.3"
assert signal["topic"] == "determinism"
assert signal["category"] == "stability"
assert signal["task_hint"] == "Check whether the release affects deterministic execution."
assert signal["fresh"] is True
PY

echo "external signals refresh test passed"
