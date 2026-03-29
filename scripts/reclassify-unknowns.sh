#!/usr/bin/env bash
set -Eeuo pipefail

# Reclassify "unknown" retry failure entries using the latest (improved) classify_retry_failure function.
# Only reclassifies entries that have error_text stored. Entries without error_text remain as-is.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

RETRY_FILE="${RETRY_ANALYSIS_LOG:-$LEARNING_DIR/retry-failure-analysis.jsonl}"

[ -f "$RETRY_FILE" ] || { echo "No retry analysis file found"; exit 0; }

python3 - "$RETRY_FILE" <<'PY'
import json, sys, subprocess, tempfile, os
from pathlib import Path

retry_file = Path(sys.argv[1])
lines = retry_file.read_text(encoding="utf-8").strip().split("\n")
entries = []
reclassified = 0

for line in lines:
    if not line.strip():
        continue
    try:
        entry = json.loads(line)
    except Exception:
        entries.append(line)
        continue

    if entry.get("classification") == "unknown" and entry.get("error_text"):
        # Re-run classification with stored error text
        error_text = entry["error_text"]
        try:
            result = subprocess.run(
                ["bash", "-c", f'source "{sys.argv[1].rsplit("/", 2)[0]}/scripts/lib.sh" && classify_retry_failure "$1"', "_", error_text],
                capture_output=True, text=True, timeout=10
            )
            new_class = result.stdout.strip()
            if new_class and new_class != "unknown":
                entry["classification"] = new_class
                entry["reclassified_from"] = "unknown"
                reclassified += 1
        except Exception:
            pass

    entries.append(json.dumps(entry, separators=(",", ":")))

retry_file.write_text("\n".join(entries) + "\n", encoding="utf-8")
print(f"Reclassified {reclassified} entries from unknown to specific categories")
PY
