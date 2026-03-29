"""Strategy loop: count recent timeouts from system.log (last 30 minutes).

Extracted from strategy-loop.sh inline heredoc (iteration 20 fix) to avoid
macOS bash 3.2 parsing bug with <<'MARKER' inside $() command substitutions.

Usage: python3 scripts/strategy-timeout-snapshot.py SYSTEM_LOG_PATH
Output: count\tlatest_marker
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import sys

log_path = Path(sys.argv[1])
cutoff = datetime.now(timezone.utc) - timedelta(minutes=30)
count = 0
latest_marker = ""

try:
    lines = log_path.read_text(encoding="utf-8", errors="ignore").splitlines()
except Exception:
    lines = []

for line in lines:
    if "timed out" not in line:
        continue
    match = re.match(r"\[(.*?)\]", line)
    if match is None:
        continue
    marker = match.group(1).strip()
    try:
        timestamp = datetime.fromisoformat(marker.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        continue
    if timestamp < cutoff:
        continue
    count += 1
    if marker > latest_marker:
        latest_marker = marker

print(f"{count}\t{latest_marker}")
