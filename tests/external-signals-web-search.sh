#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

HTML_FILE="$TMP_DIR/search.html"
SOURCES_FILE="$TMP_DIR/external-signal-sources.json"
OUTPUT_FILE="$TMP_DIR/external-signals.json"

cat >"$HTML_FILE" <<'EOF'
<html>
  <body>
    <a class="result__a" href="https://example.com/post-1">Deterministic agent evaluations in practice</a>
    <a class="result__a" href="https://example.com/post-2">Retry budgets for autonomous systems</a>
  </body>
</html>
EOF

cat >"$SOURCES_FILE" <<EOF
{
  "auto_refresh": true,
  "refresh_cooldown_seconds": 0,
  "freshness_window_seconds": 86400,
  "request_timeout_seconds": 1,
  "sources": [
    {
      "id": "example-search",
      "label": "Example search",
      "kind": "web_search",
      "path": "$HTML_FILE",
      "query": "deterministic agent evaluation",
      "topic": "agent_research",
      "category": "stability",
      "task_hint": "Check whether the search results suggest a bounded reliability improvement.",
      "max_items": 2
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

assert payload["signal_count"] == 2
first = payload["signals"][0]
second = payload["signals"][1]
assert first["kind"] == "web_search"
assert first["source_id"] == "example-search"
assert first["topic"] == "agent_research"
assert second["url"] == "https://example.com/post-2"
PY

echo "external signals web search test passed"
