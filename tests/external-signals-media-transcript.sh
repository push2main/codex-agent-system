#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

TRANSCRIPT_FILE="$TMP_DIR/transcript.vtt"
SOURCES_FILE="$TMP_DIR/external-signal-sources.json"
OUTPUT_FILE="$TMP_DIR/external-signals.json"

cat >"$TRANSCRIPT_FILE" <<'EOF'
WEBVTT

00:00:00.000 --> 00:00:02.000
Deterministic orchestration matters.

00:00:02.000 --> 00:00:05.000
Small retries should stay observable and bounded.
EOF

cat >"$SOURCES_FILE" <<EOF
{
  "auto_refresh": true,
  "refresh_cooldown_seconds": 0,
  "freshness_window_seconds": 86400,
  "request_timeout_seconds": 1,
  "sources": [
    {
      "id": "example-media",
      "label": "Example media transcript",
      "kind": "media_transcript",
      "transcript_path": "$TRANSCRIPT_FILE",
      "title": "Podcast episode about deterministic orchestration",
      "published_at": "2026-03-23T10:20:00Z",
      "topic": "agent_research",
      "category": "code_quality",
      "task_hint": "Check whether the transcript suggests a bounded orchestration improvement."
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

assert payload["signal_count"] == 1
signal = payload["signals"][0]
assert signal["kind"] == "media_transcript"
assert signal["source_id"] == "example-media"
assert "Deterministic orchestration matters." in signal["summary"]
assert signal["fresh"] is True
PY

echo "external signals media transcript test passed"
